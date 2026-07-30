defmodule BlastekWeb.PhoneAuthTest do
  @moduledoc """
  Phone-first sign-in, profile completion and password reset, driven through
  GraphQL (E3-T5, E3-T6 / F0.2).

  Exercised at the schema boundary rather than through the contexts, because the
  contract a client depends on lives here — and because E8 showed that a context
  can be entirely correct while the mutation on top of it is not.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Accounts
  alias Blastek.Accounts.OtpCode
  alias Blastek.Accounts.Phone
  alias Blastek.Accounts.Sessions
  alias Blastek.Notifications.Collector
  alias BlastekWeb.Schema

  # A distinct number and IP per test. `Blastek.RateLimit` is one ETS table
  # shared by the whole run, so tests reusing a single identity would throttle
  # each other into failures that look like bugs. Real users are distinct too,
  # which makes this the more honest fixture as well.
  setup do
    n = System.unique_integer([:positive])
    suffix = n |> rem(100_000_000) |> Integer.to_string() |> String.pad_leading(8, "0")

    %{
      phone: "06" <> suffix,
      canonical: "+2126" <> suffix,
      ip: "10.#{rem(n, 200) + 1}.#{rem(div(n, 200), 200) + 1}.1"
    }
  end

  defp gql(ctx, query, extra \\ %{}) do
    Absinthe.run(query, Schema, context: Map.merge(%{client_ip: ctx.ip}, extra))
  end

  defp error_message({:ok, %{errors: [%{message: message} | _]}}), do: message

  defp request_code(ctx, purpose \\ "login", extra \\ %{}) do
    {:ok, %{data: %{"requestOtp" => details}}} =
      gql(
        ctx,
        ~s|mutation { requestOtp(phone: "#{ctx.phone}", purpose: "#{purpose}") {
          maskedPhone expiresAt resendAfter } }|,
        extra
      )

    {Collector.last_code(), details}
  end

  defp sign_in(ctx) do
    {code, _} = request_code(ctx)

    {:ok, %{data: %{"verifyOtp" => payload}}} =
      gql(
        ctx,
        ~s|mutation { verifyOtp(phone: "#{ctx.phone}", code: "#{code}") {
          token refreshToken profileComplete
          user { id phone phoneVerified profileComplete hasPassword } } }|
      )

    payload
  end

  # Moves a number's codes back in time so the resend cooldown needs no waiting.
  defp age_codes(canonical, seconds) do
    shifted =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-seconds, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.update_all(from(o in OtpCode, where: o.phone == ^canonical),
      set: [inserted_at: shifted]
    )
  end

  defp reset_token do
    [_, token] = Regex.run(~r/token=([^\s)]+)/, Collector.last().body)
    token
  end

  defp unique_email(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@example.com"

  describe "requestOtp" do
    test "sends a code and masks the number in the reply", ctx do
      {code, details} = request_code(ctx)

      assert code =~ ~r/^\d{6}$/
      # Confirms which number without reprinting it in full.
      assert details["maskedPhone"] =~ "•• ••"
      # The real number is never echoed back.
      refute details["maskedPhone"] =~ String.slice(ctx.canonical, 5, 5)
      assert details["resendAfter"] == 60
      assert Collector.last().to == ctx.canonical
    end

    test "accepts any spelling of the same number", ctx do
      spaced = String.replace_prefix(ctx.canonical, "+212", "+212 ")

      {:ok, %{data: %{"requestOtp" => _}}} =
        gql(ctx, ~s|mutation { requestOtp(phone: "#{spaced}") { maskedPhone } }|)

      assert Collector.last().to == ctx.canonical
    end

    test "says nothing about whether the number has an account", ctx do
      {_, unknown} = request_code(ctx)

      other = %{ctx | phone: "0700000001", canonical: "+212700000001"}
      user_fixture(unique_email("known"), %{phone: other.canonical})
      {_, known} = request_code(other)

      # Identical shape either way — nothing here enumerates customers.
      assert unknown["resendAfter"] == known["resendAfter"]
      assert Map.keys(unknown) == Map.keys(known)
    end

    test "rejects a landline with an actionable message", ctx do
      assert error_message(
               gql(ctx, ~s|mutation { requestOtp(phone: "0522123456") { maskedPhone } }|)
             ) =~
               "mobile number"
    end

    test "rejects nonsense", ctx do
      assert error_message(gql(ctx, ~s|mutation { requestOtp(phone: "banana") { maskedPhone } }|)) =~
               "does not look like a phone number"
    end

    test "refuses a resend inside the cooldown", ctx do
      request_code(ctx)

      assert error_message(
               gql(ctx, ~s|mutation { requestOtp(phone: "#{ctx.phone}") { maskedPhone } }|)
             ) =~
               "wait"
    end
  end

  describe "verifyOtp" do
    test "creates an account for a number nobody has used", ctx do
      payload = sign_in(ctx)

      assert payload["token"]
      assert payload["refreshToken"]
      assert payload["user"]["phone"] == ctx.canonical
      assert payload["user"]["phoneVerified"] == true
      # Nameless until asked — the PRD wants the code first, the form second.
      assert payload["profileComplete"] == false
      assert payload["user"]["hasPassword"] == false
    end

    test "returns a working session", ctx do
      payload = sign_in(ctx)
      assert {:ok, user, _session} = Accounts.verify_token(payload["token"])
      assert user.phone == ctx.canonical
    end

    test "signs the same person back into the same account", ctx do
      first = sign_in(ctx)
      age_codes(ctx.canonical, 120)
      second = sign_in(ctx)

      assert first["user"]["id"] == second["user"]["id"]
      # A second session, not a reissued one.
      refute first["token"] == second["token"]
    end

    test "rejects a wrong code without creating anything", ctx do
      {code, _} = request_code(ctx)
      wrong = if code == "000000", do: "111111", else: "000000"

      assert error_message(
               gql(
                 ctx,
                 ~s|mutation { verifyOtp(phone: "#{ctx.phone}", code: "#{wrong}") { token } }|
               )
             ) =~ "not valid"

      assert Accounts.get_by_verified_phone(ctx.canonical) == nil
    end

    test "an existing email account keeps working alongside a phone account", ctx do
      email = unique_email("both")
      email_user = user_fixture(email)

      payload = sign_in(ctx)

      refute payload["user"]["id"] == to_string(email_user.id)
      # The email login path is untouched — the acceptance criterion.
      assert {:ok, found} = Accounts.authenticate(email, "blastek123")
      assert found.id == email_user.id
    end
  end

  describe "completeProfile" do
    test "names the account and flips profileComplete", ctx do
      payload = sign_in(ctx)
      {:ok, user, _} = Accounts.verify_token(payload["token"])

      assert {:ok, %{data: %{"completeProfile" => profile}}} =
               gql(
                 ctx,
                 ~s|mutation { completeProfile(firstName: "Yasmine", lastName: "El Amrani") {
                   firstName profileComplete } }|,
                 %{current_user: user}
               )

      assert profile["firstName"] == "Yasmine"
      assert profile["profileComplete"] == true
    end

    test "requires a name", ctx do
      payload = sign_in(ctx)
      {:ok, user, _} = Accounts.verify_token(payload["token"])

      assert error_message(
               gql(ctx, ~s|mutation { completeProfile(firstName: "") { firstName } }|, %{
                 current_user: user
               })
             ) =~ "First name"
    end

    test "is refused when signed out", ctx do
      assert error_message(gql(ctx, ~s|mutation { completeProfile(firstName: "X") { id } }|)) =~
               "signed in"
    end
  end

  describe "a phone account can book" do
    test "gets a client record named after its number until it has a name", ctx do
      %{venue: venue} = venue_fixture("Phone Booking #{System.unique_integer([:positive])}")
      payload = sign_in(ctx)
      {:ok, user, _} = Accounts.verify_token(payload["token"])

      assert {:ok, client_id} = Accounts.ensure_client(user, venue.id)

      client = Repo.get!(Blastek.Salon.Client, client_id)
      # The salon needs *something* on the appointment sheet.
      assert client.first_name == Phone.format_local(ctx.canonical)
      assert client.email == ""
    end
  end

  describe "sessions" do
    test "mySessions lists devices and marks the current one", ctx do
      payload = sign_in(ctx)
      {:ok, user, session} = Accounts.verify_token(payload["token"])

      # A real User-Agent: the column stores what the browser sent, and the
      # readable label is derived on the way out.
      {:ok, _other} =
        Sessions.issue(user,
          device: "Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/121.0"
        )

      assert {:ok, %{data: %{"mySessions" => sessions}}} =
               gql(ctx, "{ mySessions { id device current } }", %{
                 current_user: user,
                 current_session: session
               })

      assert length(sessions) == 2
      assert Enum.count(sessions, & &1["current"]) == 1
      assert "Firefox on Linux" in Enum.map(sessions, & &1["device"])
    end

    test "revokeSession ends another device", ctx do
      payload = sign_in(ctx)
      {:ok, user, session} = Accounts.verify_token(payload["token"])
      {:ok, other} = Sessions.issue(user, device: "Stolen phone")

      assert {:ok, %{data: %{"revokeSession" => true}}} =
               gql(ctx, ~s|mutation { revokeSession(id: "#{other.session.id}") }|, %{
                 current_user: user,
                 current_session: session
               })

      assert {:error, :invalid} = Sessions.verify(other.token)
      # The caller's own session is untouched.
      assert {:ok, _, _} = Sessions.verify(payload["token"])
    end

    test "one account cannot revoke another's session", ctx do
      payload = sign_in(ctx)
      {:ok, user, session} = Accounts.verify_token(payload["token"])

      stranger = user_fixture(unique_email("stranger"))
      {:ok, theirs} = Sessions.issue(stranger)

      assert error_message(
               gql(ctx, ~s|mutation { revokeSession(id: "#{theirs.session.id}") }|, %{
                 current_user: user,
                 current_session: session
               })
             ) =~ "Unknown session"

      assert {:ok, _, _} = Sessions.verify(theirs.token)
    end

    test "logout ends the session behind the token", ctx do
      payload = sign_in(ctx)
      {:ok, user, session} = Accounts.verify_token(payload["token"])

      assert {:ok, %{data: %{"logout" => true}}} =
               gql(ctx, "mutation { logout }", %{
                 current_user: user,
                 current_session: session,
                 bearer_token: payload["token"]
               })

      assert {:error, :invalid} = Sessions.verify(payload["token"])
    end

    test "revokeOtherSessions keeps only the caller's", ctx do
      payload = sign_in(ctx)
      {:ok, user, session} = Accounts.verify_token(payload["token"])
      {:ok, a} = Sessions.issue(user)
      {:ok, b} = Sessions.issue(user)

      assert {:ok, %{data: %{"revokeOtherSessions" => 2}}} =
               gql(ctx, "mutation { revokeOtherSessions }", %{
                 current_user: user,
                 current_session: session
               })

      assert {:ok, _, _} = Sessions.verify(payload["token"])
      assert {:error, :invalid} = Sessions.verify(a.token)
      assert {:error, :invalid} = Sessions.verify(b.token)
    end

    test "refreshSession rotates the pair", ctx do
      payload = sign_in(ctx)

      assert {:ok, %{data: %{"refreshSession" => refreshed}}} =
               gql(
                 ctx,
                 ~s|mutation { refreshSession(refreshToken: "#{payload["refreshToken"]}") {
                   token refreshToken user { phone } } }|
               )

      assert refreshed["token"] != payload["token"]
      assert refreshed["user"]["phone"] == ctx.canonical
      assert {:ok, _, _} = Sessions.verify(refreshed["token"])
      assert {:error, :invalid} = Sessions.verify(payload["token"])
    end

    test "replaying a rotated refresh token reports a security stop", ctx do
      payload = sign_in(ctx)

      {:ok, %{data: %{"refreshSession" => _}}} =
        gql(
          ctx,
          ~s|mutation { refreshSession(refreshToken: "#{payload["refreshToken"]}") { token } }|
        )

      # The original is now one generation stale — replaying it means somebody
      # else has it.
      assert error_message(
               gql(
                 ctx,
                 ~s|mutation { refreshSession(refreshToken: "#{payload["refreshToken"]}") {
                   token } }|
               )
             ) =~ "security"
    end

    test "a refresh token from a session the user logged out of just asks for sign-in", ctx do
      payload = sign_in(ctx)
      Sessions.revoke_token(payload["token"])

      # Logging out is not an attack; the copy must not imply it was.
      message =
        error_message(
          gql(
            ctx,
            ~s|mutation { refreshSession(refreshToken: "#{payload["refreshToken"]}") {
              token } }|
          )
        )

      assert message =~ "sign in again"
      refute message =~ "security"
    end
  end

  describe "password reset by email" do
    setup do
      email = unique_email("reset")
      %{user: user_fixture(email), email: email}
    end

    test "emails a link and lets it set a new password", ctx do
      assert {:ok, %{data: %{"requestPasswordReset" => true}}} =
               gql(ctx, ~s|mutation { requestPasswordReset(email: "#{ctx.email}") }|)

      assert Collector.last().body =~ "reset-password"

      assert {:ok, %{data: %{"resetPassword" => true}}} =
               gql(
                 ctx,
                 ~s|mutation { resetPassword(token: "#{reset_token()}",
                   password: "newpassword1") }|
               )

      assert {:ok, _} = Accounts.authenticate(ctx.email, "newpassword1")
      assert {:error, _} = Accounts.authenticate(ctx.email, "blastek123")
    end

    test "reveals nothing about unknown addresses", ctx do
      assert {:ok, %{data: %{"requestPasswordReset" => true}}} =
               gql(ctx, ~s|mutation { requestPasswordReset(email: "nobody@example.com") }|)

      assert Collector.delivered() == []
    end

    test "a reset signs every device out", ctx do
      {:ok, live} = Sessions.issue(ctx.user)

      gql(ctx, ~s|mutation { requestPasswordReset(email: "#{ctx.email}") }|)

      gql(
        ctx,
        ~s|mutation { resetPassword(token: "#{reset_token()}", password: "newpassword1") }|
      )

      assert {:error, :invalid} = Sessions.verify(live.token)
    end

    test "rejects a forged token", ctx do
      assert error_message(
               gql(ctx, ~s|mutation { resetPassword(token: "forged", password: "newpassword1") }|)
             ) =~ "no longer valid"
    end

    test "a reset link is single use", ctx do
      gql(ctx, ~s|mutation { requestPasswordReset(email: "#{ctx.email}") }|)
      token = reset_token()

      assert {:ok, %{data: %{"resetPassword" => true}}} =
               gql(ctx, ~s|mutation { resetPassword(token: "#{token}",
                 password: "firstchange1") }|)

      # Intercepting the email is worth nothing once the real owner has used the
      # link: the token is bound to the password it was issued against.
      assert error_message(gql(ctx, ~s|mutation { resetPassword(token: "#{token}",
                 password: "attackerpass") }|)) =~ "no longer valid"

      assert {:ok, _} = Accounts.authenticate(ctx.email, "firstchange1")
      assert {:error, _} = Accounts.authenticate(ctx.email, "attackerpass")
    end

    test "an older link dies when a newer one is used", ctx do
      gql(ctx, ~s|mutation { requestPasswordReset(email: "#{ctx.email}") }|)
      older = reset_token()

      gql(ctx, ~s|mutation { requestPasswordReset(email: "#{ctx.email}") }|)
      newer = reset_token()

      assert {:ok, %{data: %{"resetPassword" => true}}} =
               gql(ctx, ~s|mutation { resetPassword(token: "#{newer}",
                 password: "newestpass1") }|)

      assert error_message(gql(ctx, ~s|mutation { resetPassword(token: "#{older}",
                 password: "stalepass1") }|)) =~ "no longer valid"
    end

    test "enforces a minimum password length", ctx do
      gql(ctx, ~s|mutation { requestPasswordReset(email: "#{ctx.email}") }|)

      assert error_message(
               gql(
                 ctx,
                 ~s|mutation { resetPassword(token: "#{reset_token()}", password: "short") }|
               )
             ) =~ "at least 8"
    end
  end

  describe "password reset by phone" do
    test "resets an account that has no email at all", ctx do
      payload = sign_in(ctx)
      {:ok, user, _} = Accounts.verify_token(payload["token"])
      assert user.email == nil

      age_codes(ctx.canonical, 120)
      {code, _} = request_code(ctx, "reset")

      assert {:ok, %{data: %{"resetPasswordByPhone" => true}}} =
               gql(
                 ctx,
                 ~s|mutation { resetPasswordByPhone(phone: "#{ctx.phone}", code: "#{code}",
                   password: "brandnewpass") }|
               )

      reloaded = Accounts.get_user(user.id)
      assert Pbkdf2.verify_pass("brandnewpass", reloaded.password_hash)
    end

    test "a login code cannot be used to reset a password", ctx do
      sign_in(ctx)
      age_codes(ctx.canonical, 120)
      {login_code, _} = request_code(ctx, "login")

      assert error_message(
               gql(
                 ctx,
                 ~s|mutation { resetPasswordByPhone(phone: "#{ctx.phone}", code: "#{login_code}",
                   password: "brandnewpass") }|
               )
             ) =~ "not valid"
    end
  end

  describe "changePassword" do
    test "a phone account can set its first password, keeping its session", ctx do
      payload = sign_in(ctx)
      {:ok, user, session} = Accounts.verify_token(payload["token"])
      {:ok, other} = Sessions.issue(user)

      assert {:ok, %{data: %{"changePassword" => true}}} =
               gql(ctx, ~s|mutation { changePassword(password: "myfirstpass") }|, %{
                 current_user: user,
                 current_session: session
               })

      # Still signed in here, signed out everywhere else.
      assert {:ok, _, _} = Sessions.verify(payload["token"])
      assert {:error, :invalid} = Sessions.verify(other.token)
    end

    test "an email account must prove the current password", ctx do
      user = user_fixture(unique_email("changer"))
      {:ok, tokens} = Sessions.issue(user)
      session_ctx = %{current_user: user, current_session: tokens.session}

      assert error_message(
               gql(
                 ctx,
                 ~s|mutation { changePassword(currentPassword: "wrong",
                   password: "newpassword1") }|,
                 session_ctx
               )
             ) =~ "current password is incorrect"

      assert {:ok, %{data: %{"changePassword" => true}}} =
               gql(
                 ctx,
                 ~s|mutation { changePassword(currentPassword: "blastek123",
                   password: "newpassword1") }|,
                 session_ctx
               )
    end
  end

  describe "confirmPhone" do
    test "attaches a number to an existing email account", ctx do
      user = user_fixture(unique_email("adder"))
      {code, _} = request_code(ctx, "verify", %{current_user: user})

      assert {:ok, %{data: %{"confirmPhone" => confirmed}}} =
               gql(
                 ctx,
                 ~s|mutation { confirmPhone(phone: "#{ctx.phone}", code: "#{code}") {
                   phone phoneVerified } }|,
                 %{current_user: user}
               )

      assert confirmed["phone"] == ctx.canonical
      assert confirmed["phoneVerified"] == true
    end

    test "refuses a number already verified on another account, before texting it", ctx do
      sign_in(ctx)
      other = user_fixture(unique_email("claimer"))
      age_codes(ctx.canonical, 120)

      sent_before = length(Collector.delivered())

      assert error_message(
               gql(
                 ctx,
                 ~s|mutation { requestOtp(phone: "#{ctx.phone}", purpose: "verify") {
                   maskedPhone } }|,
                 %{current_user: other}
               )
             ) =~ "already linked"

      # A stranger's phone must not be texted a code for an account they have
      # nothing to do with.
      assert length(Collector.delivered()) == sent_before
    end

    test "confirmPhone re-checks the conflict, in case it appeared mid-flight", ctx do
      other = user_fixture(unique_email("racer"))
      {code, _} = request_code(ctx, "verify", %{current_user: other})

      # The number gets claimed between requesting the code and confirming it.
      Repo.insert!(%Blastek.Accounts.User{
        email: unique_email("winner"),
        first_name: "Winner",
        phone: ctx.canonical,
        phone_verified_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      })

      assert error_message(
               gql(
                 ctx,
                 ~s|mutation { confirmPhone(phone: "#{ctx.phone}", code: "#{code}") { phone } }|,
                 %{current_user: other}
               )
             ) =~ "already linked"
    end

    test "requesting a verify code needs a session", ctx do
      assert error_message(
               gql(ctx, ~s|mutation { requestOtp(phone: "#{ctx.phone}", purpose: "verify") {
                 maskedPhone } }|)
             ) =~ "signed in"
    end
  end
end
