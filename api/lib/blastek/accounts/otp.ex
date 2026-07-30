defmodule Blastek.Accounts.OtpCode do
  @moduledoc "One issued one-time code. Only the hash is stored."
  use Ecto.Schema

  @purposes ~w(login verify reset)

  schema "otp_codes" do
    field :phone, :string
    field :code_hash, :string
    field :purpose, :string
    field :attempts, :integer, default: 0
    field :expires_at, :naive_datetime
    field :consumed_at, :naive_datetime
    timestamps(type: :naive_datetime)
  end

  def purposes, do: @purposes
end

defmodule Blastek.Accounts.Otp do
  @moduledoc """
  One-time codes (E3-T3 / F0.2).

  Six digits, five minutes, three attempts, one code live per phone and purpose.

  ## The threat, and what each number is for

  A six-digit code is a 1-in-a-million guess, which sounds strong and is not:
  unlimited attempts crack it in minutes. The defence is layered and every layer
  matters —

    * **3 attempts** kills the code, so an attacker gets three guesses per issued
      code rather than three per minute;
    * **5 minutes** bounds how long a guessed or shoulder-surfed code is worth
      anything;
    * **60-second resend cooldown** stops an attacker minting fresh codes to buy
      more attempts, and stops us texting someone a hundred times;
    * **superseding** means requesting a new code kills the old one, so attempts
      cannot be accumulated across a stack of live codes.

  ## Why codes are hashed with Pbkdf2 rather than SHA-256

  A six-digit space is a million entries — a leaked table of SHA-256 digests is
  reversed by exhaustive search faster than it can be downloaded. Pbkdf2 makes
  that search cost roughly a million times a key-derivation, which is the
  difference between "instant" and "not worth it". It costs ~100 ms per verify,
  which nobody notices on a flow that already involves reading a text message.

  ## Purposes are isolated

  Codes are scoped to `(phone, purpose)`. Asking for a login code while a
  password reset is in flight must not consume or supersede the reset code —
  they are separate conversations with the same person.
  """
  import Ecto.Query

  alias Blastek.Accounts.OtpCode
  alias Blastek.Notifications
  alias Blastek.Repo

  @code_length 6
  @ttl_seconds 300
  @max_attempts 3
  @resend_cooldown_seconds 60

  def ttl_seconds, do: @ttl_seconds
  def max_attempts, do: @max_attempts
  def resend_cooldown_seconds, do: @resend_cooldown_seconds

  @type purpose :: :login | :verify | :reset

  @doc """
  Issues a code and hands it to `Notifications` for delivery.

  Returns when the caller may resend and when the code dies, so the UI can run
  the countdown without inventing its own numbers.

  The phone must already be normalized — callers get it from
  `Blastek.Accounts.Phone.normalize_mobile/1`, which is also where an invalid
  number is rejected with a message worth showing.
  """
  @spec request(String.t(), purpose, keyword) ::
          {:ok, %{expires_at: NaiveDateTime.t(), resend_after: non_neg_integer}}
          | {:error, term}
  def request(phone, purpose, opts \\ []) when is_binary(phone) do
    purpose = to_string(purpose)

    with :ok <- validate_purpose(purpose),
         :ok <- check_cooldown(phone, purpose) do
      code = generate_code()
      expires_at = seconds_from_now(@ttl_seconds)

      Repo.transaction(fn ->
        # Supersede first: exactly one code is live per (phone, purpose), so a
        # resend cannot be used to bank extra attempts.
        supersede_live(phone, purpose)

        Repo.insert!(%OtpCode{
          phone: phone,
          purpose: purpose,
          code_hash: Pbkdf2.hash_pwd_salt(code),
          expires_at: expires_at
        })
      end)

      case Notifications.deliver_otp(phone, code, String.to_existing_atom(purpose), opts) do
        :ok ->
          {:ok, %{expires_at: expires_at, resend_after: @resend_cooldown_seconds}}

        {:error, reason} ->
          # The row stays: the code may yet arrive, and deleting it would let a
          # failed send reset the cooldown into a free resend.
          {:error, delivery_message(reason)}
      end
    end
  end

  @doc """
  Checks a code and consumes it.

  Every outcome that is not `:ok` is deliberately vague to the caller's user —
  see `message/1`. Distinguishing "no code for this number" from "wrong code"
  would turn the endpoint into a way to ask which phone numbers have accounts.
  """
  @spec verify(String.t(), purpose, String.t()) :: :ok | {:error, atom}
  def verify(phone, purpose, code) when is_binary(phone) do
    purpose = to_string(purpose)
    code = code |> to_string() |> String.replace(~r/\s/, "")

    case newest_unconsumed(phone, purpose) do
      nil ->
        # Same work as a real check, so timing does not reveal which numbers
        # have a code outstanding.
        Pbkdf2.no_user_verify()
        {:error, :invalid}

      otp ->
        cond do
          # Told apart from a wrong code deliberately. Only someone who really
          # received a code can see this, so it leaks nothing, and "invalid"
          # would send them hunting for a typo that is not there.
          expired?(otp.expires_at) -> {:error, :expired}
          otp.attempts >= @max_attempts -> {:error, :too_many_attempts}
          Pbkdf2.verify_pass(code, otp.code_hash) -> consume(otp)
          true -> record_failure(otp)
        end
    end
  end

  @doc "Human-readable failure text, safe to show a user."
  def message(:invalid), do: "That code is not valid. Check it and try again."
  def message(:expired), do: "That code has expired. Request a new one."

  def message(:too_many_attempts),
    do: "Too many incorrect attempts. Request a new code."

  def message({:cooldown, seconds}),
    do: "Please wait #{seconds} second(s) before requesting another code."

  def message(:unknown_purpose), do: "Unsupported verification type."
  def message(other) when is_binary(other), do: other
  def message(_), do: "We could not verify that code."

  @doc """
  Deletes codes that are long dead.

  Consumed and expired rows are kept briefly on purpose — they are the audit
  trail if someone reports an account takeover — but not forever.
  """
  def purge_expired(older_than_hours \\ 24) do
    cutoff = seconds_from_now(-older_than_hours * 3600)

    {count, _} =
      Repo.delete_all(from o in OtpCode, where: o.expires_at < ^cutoff)

    count
  end

  ## ---------- internals ----------

  defp validate_purpose(purpose) do
    if purpose in OtpCode.purposes(), do: :ok, else: {:error, :unknown_purpose}
  end

  defp check_cooldown(phone, purpose) do
    since = seconds_from_now(-@resend_cooldown_seconds)

    last =
      Repo.one(
        from o in OtpCode,
          where: o.phone == ^phone and o.purpose == ^purpose and o.inserted_at > ^since,
          order_by: [desc: o.inserted_at],
          limit: 1
      )

    case last do
      nil ->
        :ok

      %OtpCode{inserted_at: inserted_at} ->
        elapsed = NaiveDateTime.diff(now(), inserted_at)
        {:error, {:cooldown, max(@resend_cooldown_seconds - elapsed, 1)}}
    end
  end

  # The newest code that has not been used. Expiry is judged by the caller
  # rather than filtered here, so an expired code can be reported as expired
  # instead of vanishing into "no such code".
  defp newest_unconsumed(phone, purpose) do
    Repo.one(
      from o in OtpCode,
        where: o.phone == ^phone and o.purpose == ^purpose and is_nil(o.consumed_at),
        order_by: [desc: o.inserted_at, desc: o.id],
        limit: 1
    )
  end

  defp expired?(expires_at), do: NaiveDateTime.compare(expires_at, now()) != :gt

  defp supersede_live(phone, purpose) do
    Repo.update_all(
      from(o in OtpCode,
        where: o.phone == ^phone and o.purpose == ^purpose and is_nil(o.consumed_at)
      ),
      set: [consumed_at: now()]
    )
  end

  defp consume(otp) do
    Repo.update_all(from(o in OtpCode, where: o.id == ^otp.id), set: [consumed_at: now()])
    :ok
  end

  defp record_failure(otp) do
    attempts = otp.attempts + 1
    Repo.update_all(from(o in OtpCode, where: o.id == ^otp.id), set: [attempts: attempts])

    # Burn the code on the last attempt rather than leaving a dead row that
    # still looks live to `pending?/2`.
    if attempts >= @max_attempts do
      Repo.update_all(from(o in OtpCode, where: o.id == ^otp.id), set: [consumed_at: now()])
      {:error, :too_many_attempts}
    else
      {:error, :invalid}
    end
  end

  # Rejection sampling rather than `rem/2`: 2^32 is not a multiple of 10^6, so
  # modulo would make some codes marginally likelier than others. The bias is
  # tiny and the fix is three lines, so there is no reason to carry it.
  defp generate_code do
    limit = 1_000_000
    ceiling = div(4_294_967_296, limit) * limit

    value =
      Stream.repeatedly(fn -> :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned() end)
      |> Enum.find(&(&1 < ceiling))

    value
    |> rem(limit)
    |> Integer.to_string()
    |> String.pad_leading(@code_length, "0")
  end

  defp delivery_message(_reason),
    do: "We could not send the code. Check the number and try again."

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  defp seconds_from_now(seconds), do: NaiveDateTime.add(now(), seconds, :second)
end
