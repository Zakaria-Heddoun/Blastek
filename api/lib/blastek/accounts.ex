defmodule Blastek.Accounts.User do
  @moduledoc """
  A login. `role` is global and only distinguishes platform staff from
  everyone else — dashboard access comes from venue memberships, not from here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :role, :string, default: "customer"
    field :first_name, :string, default: ""
    field :last_name, :string, default: ""
    field :phone, :string, default: ""
    # Set once an OTP has proven the number. Only then is it an identity, which
    # is why the unique index on `phone` is conditional on it.
    field :phone_verified_at, :naive_datetime
    has_many :memberships, Blastek.Venues.VenueMember
    timestamps(type: :naive_datetime)
  end

  @doc """
  The email-and-password registration path.

  Unchanged: an account created this way still requires an email and a name.
  """
  def changeset(user, attrs) do
    user
    |> base_changeset(attrs)
    |> validate_required([:email, :first_name])
  end

  @doc """
  The phone-first path, where the number is the whole identity.

  Neither name nor email is required — the PRD asks for the name *after*
  verification, so demanding it here would put a form in front of the code the
  user just received.
  """
  def phone_changeset(user, attrs) do
    user
    |> base_changeset(attrs)
    |> validate_required([:phone])
    |> unique_constraint(:phone,
      name: :users_verified_phone_index,
      message: "is already linked to another account"
    )
  end

  @doc "Name and contact details, filled in after verification."
  def profile_changeset(user, attrs) do
    user
    |> base_changeset(attrs)
    |> validate_required([:first_name])
  end

  defp base_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :role, :first_name, :last_name, :phone, :phone_verified_at])
    |> update_change(:email, &normalize_email/1)
    |> validate_format(:email, ~r/@/, message: "must be a valid email")
    |> validate_inclusion(:role, ~w(customer admin))
    |> unique_constraint(:email, name: :users_email_index, message: "is already registered")
  end

  # Blank is stored as NULL, never "": the unique index is on `lower(email)`, so
  # two accounts with an empty-string email would collide with each other.
  defp normalize_email(nil), do: nil

  defp normalize_email(email) do
    case email |> to_string() |> String.trim() |> String.downcase() do
      "" -> nil
      trimmed -> trimmed
    end
  end
end

defmodule Blastek.Accounts do
  @moduledoc """
  User accounts: registration, login, and session-backed auth.

  Two ways to be the same person:

    * **email + password** — the original path, unchanged;
    * **phone + one-time code** — the phone-first path (F0.2), where a verified
      number *is* the identity and the name is asked afterwards.

  Both end in the same place: `Blastek.Accounts.Sessions.issue/2`. Authentication
  is no longer a stateless signed id — see that module for why.
  """
  import Ecto.Query
  alias Blastek.Accounts.Otp
  alias Blastek.Accounts.Phone
  alias Blastek.Accounts.Sessions
  alias Blastek.Accounts.User
  alias Blastek.Notifications
  alias Blastek.Repo
  alias Blastek.Salon
  alias Blastek.Venues

  @reset_salt "blastek password reset"
  @reset_max_age 60 * 60

  def get_user(id), do: Repo.get(User, id)

  def get_by_email(email) do
    case email |> to_string() |> String.trim() |> String.downcase() do
      "" ->
        nil

      email ->
        Repo.one(from u in User, where: fragment("lower(?)", u.email) == ^email, limit: 1)
    end
  end

  @doc "Finds an account by a **verified** phone. An unverified number is not an identity."
  def get_by_verified_phone(phone) when is_binary(phone) do
    Repo.one(
      from u in User,
        where: u.phone == ^phone and not is_nil(u.phone_verified_at),
        limit: 1
    )
  end

  def get_by_verified_phone(_), do: nil

  def sign_up(attrs) do
    password = to_string(attrs[:password] || "")

    if String.length(password) < 8 do
      {:error, "Password must be at least 8 characters."}
    else
      # `role` is not accepted from sign-up input: a caller cannot make itself
      # an admin, and venue access is granted through memberships.
      attrs = Map.drop(attrs, [:role])

      %User{}
      |> User.changeset(attrs)
      |> Ecto.Changeset.put_change(:password_hash, Pbkdf2.hash_pwd_salt(password))
      |> Repo.insert()
    end
  end

  @doc """
  Signs a user up and gives them a venue they own — the "create a business
  account" path. The venue is created in one transaction with its owner
  membership so a half-registered business can never exist.
  """
  def sign_up_with_venue(attrs, business_name) do
    Repo.transaction(fn ->
      with {:ok, user} <- sign_up(attrs),
           {:ok, venue} <-
             Venues.create_venue_with_owner(
               %{name: business_name, status: "active", city: attrs[:city] || ""},
               user.id
             ) do
        %{user: user, venue: venue}
      else
        {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def authenticate(email, password) do
    user = get_by_email(email)

    cond do
      user && Pbkdf2.verify_pass(to_string(password), user.password_hash) ->
        {:ok, user}

      true ->
        # constant-time-ish failure regardless of whether the email exists
        Pbkdf2.no_user_verify()
        {:error, "Invalid email or password."}
    end
  end

  def admin?(%User{role: "admin"}), do: true
  def admin?(_), do: false

  ## ---------- client records ----------

  @doc """
  Returns this user's client record at a venue, creating it on first contact.

  A customer has one client record per venue: their notes, allergies and
  history belong to the salon they visit, not to the platform.
  """
  def ensure_client(%User{} = user, venue_id) do
    case Salon.find_or_create_client(venue_id, %{
           # A phone-first account has no email and may not have filled in a
           # name yet; the client record's columns are NOT NULL, so absence
           # becomes "" rather than nil.
           first_name: presence(user.first_name, fallback_name(user)),
           last_name: presence(user.last_name, ""),
           email: presence(user.email, ""),
           phone: presence(user.phone, ""),
           user_id: user.id
         }) do
      {:ok, client} -> {:ok, client.id}
      {:error, _} -> {:error, "could not resolve client record"}
    end
  end

  @doc "Ids of every client record this account owns, across venues."
  def client_ids(%User{} = user), do: Salon.list_client_ids_for_user(user.id)

  ## ---------- phone-first auth ----------

  @doc """
  Sends a login code to a phone number.

  Says nothing about whether the number has an account. `requestOtp` is a public
  endpoint, so distinguishing "code sent" from "no such user" would turn it into
  a way to enumerate which Moroccans are Blastek customers.
  """
  def request_login_code(phone_input, opts \\ []) do
    with {:ok, phone} <- normalize_mobile(phone_input),
         {:ok, details} <- Otp.request(phone, :login, opts) do
      {:ok, Map.put(details, :phone, phone)}
    else
      {:error, reason} -> {:error, otp_error(reason)}
    end
  end

  @doc """
  Checks a login code and returns a session.

  A number that has never been seen becomes an account here — the PRD's "new
  phone = account created". The account starts nameless on purpose; the UI asks
  for a name next through `complete_profile/2`, rather than putting a form in
  front of someone who has just proven who they are.

  `profile_complete?` tells the client which screen to show.
  """
  def verify_login_code(phone_input, code, opts \\ []) do
    with {:ok, phone} <- normalize_mobile(phone_input),
         :ok <- verify_code(phone, :login, code),
         {:ok, user} <- find_or_create_by_phone(phone),
         {:ok, tokens} <- Sessions.issue(user, opts) do
      {:ok, Map.put(tokens, :user, user)}
    else
      {:error, reason} -> {:error, otp_error(reason)}
    end
  end

  @doc """
  Fills in the name (and optionally email) of a freshly verified account.

  Also usable later as ordinary profile editing.
  """
  def complete_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(Map.take(attrs, [:first_name, :last_name, :email]))
    |> Repo.update()
  end

  @doc "Whether the account has enough detail to be booked under."
  def profile_complete?(%User{first_name: name}), do: is_binary(name) and String.trim(name) != ""
  def profile_complete?(_), do: false

  @doc """
  Attaches a phone number to an existing signed-in account, by code.

  Kept apart from the login flow because the failure it guards against is
  different: here the risk is claiming a number that belongs to someone else, so
  it refuses when the number is already verified elsewhere.
  """
  def request_phone_verification(%User{}, phone_input, opts \\ []) do
    with {:ok, phone} <- normalize_mobile(phone_input),
         {:ok, details} <- Otp.request(phone, :verify, opts) do
      {:ok, Map.put(details, :phone, phone)}
    else
      {:error, reason} -> {:error, otp_error(reason)}
    end
  end

  def confirm_phone(%User{} = user, phone_input, code) do
    with {:ok, phone} <- normalize_mobile(phone_input),
         :ok <- verify_code(phone, :verify, code),
         :ok <- ensure_phone_free(phone, user.id) do
      user
      |> User.phone_changeset(%{phone: phone, phone_verified_at: now()})
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, reason} -> {:error, otp_error(reason)}
    end
  end

  ## ---------- password reset ----------

  @doc """
  Starts an email password reset.

  Always reports success. The response must not reveal whether an address has an
  account — that is the single most common way a login form leaks its user list.
  """
  def request_password_reset(email, opts \\ []) do
    case get_by_email(email) do
      nil ->
        :ok

      user ->
        token = Phoenix.Token.sign(BlastekWeb.Endpoint, @reset_salt, user.id)
        base = Keyword.get(opts, :reset_url, "http://localhost:5173/reset-password")
        Notifications.deliver_password_reset(user.email, "#{base}?token=#{token}", opts)
        :ok
    end
  end

  @doc """
  Completes an email password reset.

  Every other session is revoked: if the reset was prompted by a compromise, the
  attacker's session must not survive the fix.
  """
  def reset_password(token, new_password) do
    case Phoenix.Token.verify(BlastekWeb.Endpoint, @reset_salt, token, max_age: @reset_max_age) do
      {:ok, user_id} ->
        case get_user(user_id) do
          nil -> {:error, "That reset link is no longer valid."}
          user -> set_password(user, new_password)
        end

      _ ->
        {:error, "That reset link has expired. Request a new one."}
    end
  end

  @doc "Starts a phone password reset — the variant for accounts with no email."
  def request_password_reset_by_phone(phone_input, opts \\ []) do
    with {:ok, phone} <- normalize_mobile(phone_input) do
      # Sent whether or not the number has an account, for the same reason the
      # email variant always reports success.
      case Otp.request(phone, :reset, opts) do
        {:ok, details} -> {:ok, Map.put(details, :phone, phone)}
        {:error, reason} -> {:error, otp_error(reason)}
      end
    else
      {:error, reason} -> {:error, otp_error(reason)}
    end
  end

  def reset_password_by_phone(phone_input, code, new_password) do
    with {:ok, phone} <- normalize_mobile(phone_input),
         :ok <- verify_code(phone, :reset, code),
         user when not is_nil(user) <- get_by_verified_phone(phone) do
      set_password(user, new_password)
    else
      nil -> {:error, "That code is not valid."}
      {:error, reason} -> {:error, otp_error(reason)}
    end
  end

  @doc """
  Changes a password from inside the account, proving the current one first.

  Other devices are signed out, the caller's own is not: a password change is
  how someone responds to "I think somebody else is logged in as me", and
  leaving those sessions alive would make the change pointless. Logging the user
  out of the tab they are typing in would just be rude.

  Pass `except: session_id` to keep the current session; without it every
  session goes, which is what a reset wants.
  """
  def change_password(%User{} = user, current_password, new_password, opts \\ []) do
    cond do
      # A phone-first account setting a password for the first time has nothing
      # to prove — the session it is using is the proof.
      is_nil(user.password_hash) ->
        set_password(user, new_password, opts)

      not Pbkdf2.verify_pass(to_string(current_password), user.password_hash) ->
        {:error, "Your current password is incorrect."}

      true ->
        set_password(user, new_password, opts)
    end
  end

  defp set_password(user, new_password, opts \\ []) do
    password = to_string(new_password)

    if String.length(password) < 8 do
      {:error, "Password must be at least 8 characters."}
    else
      {:ok, updated} =
        user
        |> Ecto.Changeset.change(password_hash: Pbkdf2.hash_pwd_salt(password))
        |> Repo.update()

      Sessions.revoke_all(user.id, except: opts[:except])
      {:ok, updated}
    end
  end

  ## ---------- sessions ----------

  @doc "Starts a session for a user who has already proven who they are."
  def start_session(%User{} = user, opts \\ []), do: Sessions.issue(user, opts)

  @doc "Resolves a bearer token. Returns the user and the session behind it."
  def verify_token(token) do
    case Sessions.verify(token) do
      {:ok, user, session} -> {:ok, user, session}
      {:error, reason} -> {:error, reason}
    end
  end

  ## ---------- internals ----------

  defp find_or_create_by_phone(phone) do
    case get_by_verified_phone(phone) do
      nil ->
        %User{}
        |> User.phone_changeset(%{phone: phone, phone_verified_at: now()})
        |> Repo.insert()
        |> case do
          {:ok, user} ->
            {:ok, user}

          # Two codes verified at once for the same number: the unique index
          # decides, and the loser reads the winner's row rather than failing.
          {:error, _changeset} ->
            case get_by_verified_phone(phone) do
              nil -> {:error, "Could not create your account."}
              user -> {:ok, user}
            end
        end

      user ->
        {:ok, user}
    end
  end

  defp ensure_phone_free(phone, user_id) do
    case get_by_verified_phone(phone) do
      nil -> :ok
      %User{id: ^user_id} -> :ok
      _other -> {:error, "That number is already linked to another account."}
    end
  end

  defp normalize_mobile(input) do
    case Phone.normalize_mobile(input) do
      {:ok, phone} -> {:ok, phone}
      {:error, reason} -> {:error, Phone.message(reason)}
    end
  end

  defp verify_code(phone, purpose, code) do
    case Otp.verify(phone, purpose, code) do
      :ok -> :ok
      {:error, reason} -> {:error, Otp.message(reason)}
    end
  end

  defp otp_error(reason) when is_binary(reason), do: reason
  defp otp_error(%Ecto.Changeset{} = changeset), do: changeset
  defp otp_error(reason), do: Otp.message(reason)

  defp presence(nil, fallback), do: fallback

  defp presence(value, fallback) do
    case String.trim(to_string(value)) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  # A booking needs a name on the sheet. Until the account completes its
  # profile, the phone number is the most useful thing the salon can be shown.
  defp fallback_name(%User{phone: phone}) when is_binary(phone) and phone != "",
    do: Phone.format_local(phone)

  defp fallback_name(_), do: "Customer"

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
