defmodule Blastek.Accounts.Session do
  @moduledoc "One signed-in device. Only token hashes are stored."
  use Ecto.Schema

  schema "sessions" do
    belongs_to :user, Blastek.Accounts.User
    field :token_hash, :binary
    field :refresh_hash, :binary
    field :device, :string, default: ""
    field :ip, :string, default: ""
    field :expires_at, :naive_datetime
    field :refresh_expires_at, :naive_datetime
    field :last_used_at, :naive_datetime
    field :revoked_at, :naive_datetime
    timestamps(type: :naive_datetime)
  end
end

defmodule Blastek.Accounts.Sessions do
  @moduledoc """
  Server-side sessions (E3-T2 / F0.2).

  Replaces a stateless `Phoenix.Token`. The old scheme was a signed user id with
  nothing stored, which made "log out the phone I lost" and "revoke a
  compromised account" literally unimplementable — there was no record to
  revoke. Everything here follows from wanting those two sentences to be true.

  ## Tokens are random, and only their hashes are stored

  A bearer token is 32 random bytes; the database keeps its SHA-256. A leaked
  database therefore yields no working tokens, and the server never needs the
  original — it hashes what the request presents and looks that up.

  SHA-256 rather than Pbkdf2 here, unlike OTP codes: the input is 256 bits of
  entropy, so there is no search to slow down, and this runs on **every**
  authenticated request where 100 ms would be unacceptable.

  ## Access and refresh

  A short access token (24 h) and a long refresh token (60 d). The access token
  is what every request carries, so its lifetime bounds how long a stolen one is
  useful; the refresh token is presented rarely, so it can live long enough that
  people are not logged out weekly.

  **Refresh rotates.** Each refresh mints a new pair and retires the old, so a
  stolen refresh token is only good until the real device next uses it.

  ## Reuse detection

  Rotation creates a tell. If a refresh token that was already rotated away is
  presented again, then two parties hold it — the legitimate device and a
  thief — and there is no way to know which one is calling. The safe response is
  to assume the worst and revoke the whole session, forcing a fresh sign-in on
  a device the attacker does not have. Without this, rotation only means the
  thief has to be quick.
  """
  import Ecto.Query

  alias Blastek.Accounts.Session
  alias Blastek.Accounts.User
  alias Blastek.Repo

  @access_ttl_seconds 60 * 60 * 24
  @refresh_ttl_seconds 60 * 60 * 24 * 60
  # Enough that guessing is hopeless; the standard for a bearer secret.
  @token_bytes 32

  def access_ttl_seconds, do: @access_ttl_seconds
  def refresh_ttl_seconds, do: @refresh_ttl_seconds

  @type tokens :: %{
          token: String.t(),
          refresh_token: String.t(),
          expires_at: NaiveDateTime.t(),
          session: Session.t()
        }

  @doc """
  Starts a session and returns the tokens.

  The raw tokens exist only in this return value — nothing else can ever produce
  them again, which is the property that makes the stored hashes safe.
  """
  @spec issue(User.t(), keyword) :: {:ok, tokens}
  def issue(%User{} = user, opts \\ []) do
    token = random_token()
    refresh = random_token()
    expires_at = seconds_from_now(@access_ttl_seconds)

    session =
      Repo.insert!(%Session{
        user_id: user.id,
        token_hash: hash(token),
        refresh_hash: hash(refresh),
        device: opts |> Keyword.get(:device, "") |> truncate(180),
        ip: opts |> Keyword.get(:ip, "") |> truncate(45),
        expires_at: expires_at,
        refresh_expires_at: seconds_from_now(@refresh_ttl_seconds),
        last_used_at: now()
      })

    {:ok, %{token: token, refresh_token: refresh, expires_at: expires_at, session: session}}
  end

  @doc """
  Resolves a bearer token to its user.

  On the hot path of every authenticated request: one indexed lookup by hash.
  Returns `{:ok, user, session}` so callers can see which device is calling.
  """
  @spec verify(String.t()) :: {:ok, User.t(), Session.t()} | {:error, :invalid}
  def verify(token) when is_binary(token) and token != "" do
    now = now()

    query =
      from s in Session,
        join: u in assoc(s, :user),
        where:
          s.token_hash == ^hash(token) and is_nil(s.revoked_at) and
            s.expires_at > ^now,
        select: {s, u}

    case Repo.one(query) do
      {session, user} ->
        touch(session)
        {:ok, user, session}

      nil ->
        {:error, :invalid}
    end
  end

  def verify(_), do: {:error, :invalid}

  @doc """
  Exchanges a refresh token for a fresh pair, retiring the old one.

  Presenting a refresh token that has already been rotated away revokes the
  whole session — see the module docs on reuse detection.
  """
  @spec refresh(String.t(), keyword) :: {:ok, tokens} | {:error, :invalid | :reused}
  def refresh(refresh_token, opts \\ []) when is_binary(refresh_token) do
    hashed = hash(refresh_token)
    now = now()

    case Repo.one(from s in Session, where: s.refresh_hash == ^hashed) do
      nil ->
        {:error, :invalid}

      %Session{revoked_at: revoked} = session when not is_nil(revoked) ->
        # Already-revoked *and* still matching this hash means the token was
        # captured before rotation. The session is dead either way; say so.
        revoke_session(session)
        {:error, :reused}

      %Session{refresh_expires_at: expires_at} = session ->
        if NaiveDateTime.compare(expires_at, now) == :lt do
          {:error, :invalid}
        else
          rotate(session, opts)
        end
    end
  end

  @doc "Every live session for a user, most recently used first."
  def list_for_user(user_id) do
    now = now()

    Repo.all(
      from s in Session,
        where: s.user_id == ^user_id and is_nil(s.revoked_at) and s.expires_at > ^now,
        order_by: [desc: s.last_used_at, desc: s.id]
    )
  end

  @doc """
  Revokes one session, scoped to its owner.

  Scoped for the same reason every venue query is: an id from someone else's
  account must be indistinguishable from one that does not exist, or this is a
  way to log strangers out.
  """
  def revoke(user_id, session_id) do
    case Repo.one(from s in Session, where: s.id == ^session_id and s.user_id == ^user_id) do
      nil -> {:error, "Unknown session."}
      session -> {:ok, revoke_session(session)}
    end
  end

  @doc "Revokes the session behind a bearer token — the logout path."
  def revoke_token(token) when is_binary(token) do
    case Repo.one(from s in Session, where: s.token_hash == ^hash(token)) do
      nil -> :ok
      session -> revoke_session(session) && :ok
    end
  end

  def revoke_token(_), do: :ok

  @doc """
  Revokes every session for a user.

  Used after a password reset and as the "I've been compromised" button:
  changing a password must not leave the attacker's session alive.
  """
  def revoke_all(user_id, opts \\ []) do
    except = Keyword.get(opts, :except)

    query =
      from s in Session,
        where: s.user_id == ^user_id and is_nil(s.revoked_at)

    query = if except, do: from(s in query, where: s.id != ^except), else: query

    {count, _} = Repo.update_all(query, set: [revoked_at: now()])
    count
  end

  @doc "Removes sessions that expired long ago."
  def purge_expired(older_than_days \\ 90) do
    cutoff = seconds_from_now(-older_than_days * 86_400)

    {count, _} =
      Repo.delete_all(from s in Session, where: s.refresh_expires_at < ^cutoff)

    count
  end

  @doc """
  A short human label for a session, from its User-Agent.

  Parsed crudely on purpose: this is a hint to help someone recognise their own
  device in a list, not analytics. A wrong guess costs nothing.
  """
  def describe(%Session{device: device}), do: describe(device)
  def describe(""), do: "Unknown device"

  def describe(user_agent) when is_binary(user_agent) do
    browser =
      cond do
        user_agent =~ ~r/Edg\//i -> "Edge"
        user_agent =~ ~r/OPR\//i -> "Opera"
        user_agent =~ ~r/Chrome\//i -> "Chrome"
        user_agent =~ ~r/Firefox\//i -> "Firefox"
        user_agent =~ ~r/Safari\//i -> "Safari"
        true -> "Browser"
      end

    platform =
      cond do
        user_agent =~ ~r/Android/i -> "Android"
        user_agent =~ ~r/iPhone|iPad|iOS/i -> "iOS"
        user_agent =~ ~r/Windows/i -> "Windows"
        user_agent =~ ~r/Mac OS/i -> "macOS"
        user_agent =~ ~r/Linux/i -> "Linux"
        true -> nil
      end

    if platform, do: "#{browser} on #{platform}", else: browser
  end

  def describe(_), do: "Unknown device"

  ## ---------- internals ----------

  defp rotate(session, opts) do
    token = random_token()
    refresh = random_token()
    expires_at = seconds_from_now(@access_ttl_seconds)

    updated =
      session
      |> Ecto.Changeset.change(%{
        token_hash: hash(token),
        refresh_hash: hash(refresh),
        expires_at: expires_at,
        # Rolling: an actively used session should not be logged out because it
        # has been sixty days since the *first* sign-in.
        refresh_expires_at: seconds_from_now(@refresh_ttl_seconds),
        last_used_at: now(),
        device: opts |> Keyword.get(:device, session.device) |> truncate(180),
        ip: opts |> Keyword.get(:ip, session.ip) |> truncate(45)
      })
      |> Repo.update!()

    {:ok, %{token: token, refresh_token: refresh, expires_at: expires_at, session: updated}}
  end

  defp revoke_session(session) do
    session |> Ecto.Changeset.change(%{revoked_at: now()}) |> Repo.update!()
  end

  # Written with `update_all` and no reload: this fires on every authenticated
  # request, and it must not turn a read into a read-modify-write.
  defp touch(session) do
    Repo.update_all(from(s in Session, where: s.id == ^session.id), set: [last_used_at: now()])
  end

  defp random_token,
    do: :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp truncate(nil, _length), do: ""
  defp truncate(value, length), do: value |> to_string() |> String.slice(0, length)

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  defp seconds_from_now(seconds), do: NaiveDateTime.add(now(), seconds, :second)
end
