defmodule Blastek.OtpTest do
  @moduledoc """
  One-time codes (E3-T3 / F0.2).

  A six-digit secret is only as good as the limits around it, so most of what
  follows is about those limits rather than the happy path.
  """
  use Blastek.DataCase, async: true

  alias Blastek.Notifications.TestProvider
  alias Blastek.Accounts.Otp
  alias Blastek.Accounts.OtpCode
  alias Blastek.Notifications.Collector

  @phone "+212612345678"

  defp request!(phone \\ @phone, purpose \\ :login) do
    {:ok, details} = Otp.request(phone, purpose)
    {Collector.last_code(), details}
  end

  # Moves a row back in time so cooldowns and expiry can be tested without
  # sleeping through them.
  defp age(phone, purpose, seconds) do
    shifted = NaiveDateTime.add(NaiveDateTime.utc_now(), -seconds, :second)

    Repo.update_all(
      from(o in OtpCode, where: o.phone == ^phone and o.purpose == ^to_string(purpose)),
      set: [inserted_at: NaiveDateTime.truncate(shifted, :second)]
    )
  end

  describe "request/3" do
    test "sends a six-digit code and reports the windows" do
      {code, details} = request!()

      assert code =~ ~r/^\d{6}$/
      assert details.resend_after == Otp.resend_cooldown_seconds()

      assert_in_delta NaiveDateTime.diff(details.expires_at, NaiveDateTime.utc_now()),
                      Otp.ttl_seconds(),
                      5
    end

    test "stores a hash, never the code" do
      {code, _} = request!()
      stored = Repo.one!(from o in OtpCode, where: o.phone == ^@phone)

      refute stored.code_hash == code
      refute stored.code_hash =~ code
      # And the stored hash really is of that code.
      assert Pbkdf2.verify_pass(code, stored.code_hash)
    end

    test "the message is localized" do
      Otp.request(@phone, :login, locale: "fr")
      assert Collector.last().body =~ "Votre code Blastek"

      age(@phone, :login, 120)
      Otp.request(@phone, :login, locale: "ar")
      assert Collector.last().body =~ "رمز"
    end

    test "refuses a second code inside the cooldown" do
      request!()

      assert {:error, {:cooldown, seconds}} = Otp.request(@phone, :login)
      assert seconds > 0 and seconds <= Otp.resend_cooldown_seconds()
      # And it did not send anything.
      assert length(Collector.delivered()) == 1
    end

    test "allows a resend once the cooldown has passed" do
      request!()
      age(@phone, :login, Otp.resend_cooldown_seconds() + 1)

      assert {:ok, _} = Otp.request(@phone, :login)
      assert length(Collector.delivered()) == 2
    end

    test "a new code supersedes the old one, so attempts cannot be banked" do
      {first, _} = request!()
      age(@phone, :login, 120)
      {second, _} = request!()

      assert Otp.verify(@phone, :login, first) == {:error, :invalid}
      assert Otp.verify(@phone, :login, second) == :ok
    end

    test "rejects an unknown purpose" do
      assert Otp.request(@phone, :nonsense) == {:error, :unknown_purpose}
    end

    test "a failed delivery still consumes the cooldown" do
      # Otherwise a provider outage becomes an unlimited resend loop.
      TestProvider.with_provider(Blastek.Notifications.FailingProvider, fn ->
        assert {:error, message} = Otp.request(@phone, :login)
        assert message =~ "could not send"
        assert {:error, {:cooldown, _}} = Otp.request(@phone, :login)
      end)
    end
  end

  describe "verify/3" do
    test "accepts the right code once" do
      {code, _} = request!()

      assert Otp.verify(@phone, :login, code) == :ok
      # Single use: replaying it must fail.
      assert Otp.verify(@phone, :login, code) == {:error, :invalid}
    end

    test "tolerates spaces, because people paste codes out of messages" do
      {code, _} = request!()
      spaced = code |> String.graphemes() |> Enum.join(" ")

      assert Otp.verify(@phone, :login, spaced) == :ok
    end

    test "rejects a wrong code" do
      {code, _} = request!()
      wrong = if code == "000000", do: "111111", else: "000000"

      assert Otp.verify(@phone, :login, wrong) == {:error, :invalid}
    end

    test "dies after three attempts, even if the fourth is correct" do
      {code, _} = request!()
      wrong = if code == "000000", do: "111111", else: "000000"

      assert Otp.verify(@phone, :login, wrong) == {:error, :invalid}
      assert Otp.verify(@phone, :login, wrong) == {:error, :invalid}
      assert Otp.verify(@phone, :login, wrong) == {:error, :too_many_attempts}

      # The real code is now worthless — this is the whole defence.
      assert Otp.verify(@phone, :login, code) == {:error, :invalid}
    end

    test "reports an expired code as expired, not as wrong" do
      {code, _} = request!()

      Repo.update_all(
        from(o in OtpCode, where: o.phone == ^@phone),
        set: [expires_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -1, :second)]
      )

      # Only someone who genuinely received a code can see this, so it leaks
      # nothing — and "invalid" would send them hunting for a typo.
      assert Otp.verify(@phone, :login, code) == {:error, :expired}
      assert Otp.message(:expired) =~ "expired"
    end

    test "rejects a code for a number that never requested one" do
      assert Otp.verify("+212700000000", :login, "123456") == {:error, :invalid}
    end

    test "purposes are isolated — a login code cannot complete a reset" do
      {login_code, _} = request!(@phone, :login)
      {reset_code, _} = request!(@phone, :reset)

      assert Otp.verify(@phone, :reset, login_code) == {:error, :invalid}
      assert Otp.verify(@phone, :login, reset_code) == {:error, :invalid}

      # Each still works for its own purpose: requesting one must not have
      # superseded the other.
      assert Otp.verify(@phone, :login, login_code) == :ok
      assert Otp.verify(@phone, :reset, reset_code) == :ok
    end

    test "one phone's code does not work for another" do
      {code, _} = request!(@phone, :login)
      other = "+212700000001"

      assert Otp.verify(other, :login, code) == {:error, :invalid}
    end
  end

  describe "purge_expired/1" do
    test "removes long-dead codes and keeps live ones" do
      request!()

      Repo.insert!(%OtpCode{
        phone: "+212700000009",
        purpose: "login",
        code_hash: "x",
        expires_at: ~N[2020-01-01 00:00:00]
      })

      assert Otp.purge_expired(24) == 1
      assert Repo.aggregate(OtpCode, :count) == 1
    end
  end

  describe "generated codes" do
    test "are six digits and not obviously predictable" do
      codes =
        for n <- 1..25 do
          phone = "+21261234#{String.pad_leading(to_string(n), 4, "0")}"
          {:ok, _} = Otp.request(phone, :login)
          Collector.last_code()
        end

      assert Enum.all?(codes, &(&1 =~ ~r/^\d{6}$/))
      # Not proof of randomness, but a constant or a counter would fail this.
      assert length(Enum.uniq(codes)) >= 24
    end
  end
end
