defmodule Blastek.NotificationsTest do
  @moduledoc """
  Templates, preferences, opt-outs and the send log (E6 / F0.10).
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Notifications
  alias Blastek.Notifications.Collector
  alias Blastek.Notifications.Format
  alias Blastek.Notifications.Provider
  alias Blastek.Notifications.Templates
  alias Blastek.Notifications.TestProvider

  # Enough of every assign that no template is left with a nil in the middle of
  # a sentence.
  @assigns %{
    code: "123456",
    url: "https://blastek.ma/x",
    venue: "Le Salon Anfa",
    role: "owner",
    reason: "Add a photo.",
    service: "Coupe",
    staff: "Yasmine",
    client: "Leila Bennani",
    ref: "BK-ABC123",
    when: "samedi 2 août à 14:30",
    time: "14:30",
    phone: "+212522274880",
    cancel_url: "https://blastek.ma/a/cancel/tok",
    review_url: "https://blastek.ma/review/tok"
  }

  describe "templates" do
    test "every template in the inventory renders in every locale" do
      for template <- Templates.names(), locale <- Templates.locales() do
        body = Templates.render(template, locale, @assigns)

        assert is_binary(body) and String.length(body) > 10,
               "#{template}/#{locale} rendered #{inspect(body)}"

        # A missing assign interpolates as an empty string and reads as a
        # sentence with a hole in it, which no test would otherwise catch.
        refute body =~ "  ", "#{template}/#{locale} has a gap: #{body}"
      end
    end

    test "Arabic is a real translation, not the French one" do
      for template <- Templates.names() do
        arabic = Templates.render(template, "ar", @assigns)

        assert arabic =~ ~r/\p{Arabic}/u,
               "#{template} has no Arabic in its Arabic version: #{arabic}"

        refute arabic == Templates.render(template, "fr", @assigns)
      end
    end

    test "interpolated values are direction-isolated in Arabic" do
      # Without the isolates a Latin salon name inside an RTL sentence renders
      # in an order the writer did not choose.
      body = Templates.render(:booking_confirmed_customer, "ar", @assigns)
      assert body =~ Templates.isolate("Le Salon Anfa")
    end

    test "an unknown locale falls back to French, not to a crash" do
      assert Templates.render(:login, "de", @assigns) ==
               Templates.render(:login, "fr", @assigns)
    end

    test "reminders are optional and everything else is not" do
      # Asking for a review is us wanting something from the customer rather
      # than the consequence of anything they did, so it lives under the same
      # switch as reminders (E10 / F0.8). Being told a review was taken down is
      # the consequence of a decision about their own words, so it does not.
      optional = [:reminder_24h, :reminder_3h, :review_invite, :review_reminder]

      for template <- optional do
        assert Templates.category(template) == :reminders
      end

      for template <- Templates.names() -- optional do
        assert Templates.category(template) == :transactional,
               "#{template} should not be something a person can switch off"
      end
    end
  end

  describe "formatting" do
    test "a date and time reads as a person would say it" do
      date = ~D[2026-08-02]
      assert Format.date_time(date, 870, "fr") == "dimanche 2 août à 14:30"
      assert Format.date_time(date, 870, "en") == "Sunday 2 August at 14:30"
      assert Format.date_time(date, 870, "ar") =~ "الأحد"
    end

    test "local wall-clock really converts to UTC" do
      # Elixir's built-in database is UTC-only and raises on this. Without the
      # `:tz` package every reminder was silently scheduled an hour late — and
      # two hours off through Ramadan, when Morocco moves to UTC+0, which is
      # exactly when a salon's hours have shifted and the reminder matters most.
      assert {:ok, summer} = DateTime.from_naive(~N[2026-07-31 20:00:00], Format.timezone())
      assert summer.utc_offset + summer.std_offset == 3600

      assert DateTime.shift_zone!(summer, "Etc/UTC") ==
               DateTime.from_naive!(~N[2026-07-31 19:00:00], "Etc/UTC")

      # Ramadan 2026 runs roughly 18 February – 19 March; Morocco drops to UTC+0.
      assert {:ok, ramadan} = DateTime.from_naive(~N[2026-03-01 20:00:00], Format.timezone())
      assert ramadan.utc_offset + ramadan.std_offset == 0
    end

    test "past midnight belongs to the next day, and says so" do
      # 1470 is 00:30. Telling somebody to come "Friday at 00:30" when the salon
      # means Saturday morning is how they arrive a day late.
      assert Format.date_time(~D[2026-08-07], 1470, "fr") == "samedi 8 août à 00:30"
      assert Format.time(1470) == "00:30"
      assert Format.starts_at(~D[2026-08-07], 1470) == ~N[2026-08-08 00:30:00]
    end
  end

  describe "preferences" do
    setup do
      %{user: user_fixture("prefs-#{System.unique_integer([:positive])}@example.com")}
    end

    test "reminders are on and marketing is off by default", %{user: user} do
      assert Notifications.prefs(user) == %{"reminders" => true, "marketing" => false}
    end

    test "turning reminders off suppresses them", %{user: user} do
      {:ok, user} = Notifications.update_prefs(user, %{"reminders" => false})

      assert Notifications.suppression(:reminder_24h, "+212600000001", user) == :prefs
    end

    test "but never suppresses a confirmation", %{user: user} do
      {:ok, user} = Notifications.update_prefs(user, %{"reminders" => false})

      # F0.10: transactional messages are not optional. Somebody who opts out of
      # reminders has not opted out of knowing they have a booking.
      assert Notifications.suppression(:booking_confirmed_customer, "+212600000002", user) == nil
      assert Notifications.suppression(:login, "+212600000002", user) == nil
    end

    test "unknown preference keys are dropped rather than stored", %{user: user} do
      {:ok, user} = Notifications.update_prefs(user, %{"favourite_colour" => "teal"})
      refute Map.has_key?(user.notification_prefs, "favourite_colour")
    end
  end

  describe "one spelling of an address" do
    test "the same number written four ways canonicalizes to one" do
      for spelling <- ["+212612345678", "212612345678", "0612345678", "06 12 34 56 78"] do
        assert Notifications.canonical(spelling) == "+212612345678",
               "#{inspect(spelling)} is the same number"
      end
    end

    test "an email loses its case and its whitespace" do
      assert Notifications.canonical("  Nadia@Example.COM ") == "nadia@example.com"
    end

    test "something unparseable is kept as typed rather than mangled" do
      # A French number. `Phone` is deliberately Morocco-only and total, so
      # rather than invent a country code — delivering to the wrong person is
      # worse than not delivering — this is passed through untouched.
      assert Notifications.canonical(" +33 6 12 34 56 78 ") == "+33 6 12 34 56 78"
      assert Notifications.canonical("") == ""
      assert Notifications.canonical(nil) == nil
    end

    test "a STOP suppresses every spelling of the number that sent it" do
      # Meta reports the sender as bare digits; the account holds E.164; a
      # receptionist typed it with spaces. One person, one withdrawal of
      # consent.
      {:ok, _} = Notifications.opt_out("212612345699", "replied STOP")

      for spelling <- ["+212612345699", "212612345699", "0612345699", "06 12 34 56 99"] do
        assert Notifications.opted_out?(spelling),
               "STOP did not reach #{inspect(spelling)}"

        assert Notifications.suppression(:reminder_24h, spelling) == :opted_out
      end
    end

    test "and opting back in reaches every spelling too" do
      {:ok, _} = Notifications.opt_out("0612345688")
      assert Notifications.opted_out?("+212612345688")

      Notifications.opt_in("+212 612 345 688")
      refute Notifications.opted_out?("0612345688")
    end

    test "a message addressed loosely is logged and sent against the canonical form" do
      assert {:ok, log} =
               Notifications.send_now(:booking_confirmed_customer, "06 12 34 56 77",
                 assigns: @assigns
               )

      assert log.to == "+212612345677"
      assert Collector.last().to == "+212612345677"
    end
  end

  describe "opt-out" do
    test "outranks even a transactional message" do
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"
      assert Notifications.suppression(:login, phone) == nil

      {:ok, _} = Notifications.opt_out(phone, "replied STOP")

      # Consent withdrawn is consent withdrawn: there is no category of message
      # that survives it.
      assert Notifications.suppression(:login, phone) == :opted_out
      assert Notifications.suppression(:booking_confirmed_customer, phone) == :opted_out
    end

    test "is idempotent" do
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"
      assert {:ok, _} = Notifications.opt_out(phone)
      assert {:ok, _} = Notifications.opt_out(phone)
      assert Notifications.opted_out?(phone)

      Notifications.opt_in(phone)
      refute Notifications.opted_out?(phone)
    end

    test "a suppressed message is recorded, not silently dropped" do
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"
      {:ok, _} = Notifications.opt_out(phone)

      assert {:ok, :skipped} = Notifications.deliver(:reminder_24h, phone, assigns: @assigns)

      # An admin asking "why did this person never hear from us?" needs an
      # answer, and "there is no row" is not one.
      assert [log] = Notifications.list_log(limit: 10) |> Enum.filter(&(&1.to == phone))
      assert log.status == "skipped"
      assert log.error == "opted_out"
      assert Collector.delivered() == []
    end
  end

  describe "the send log" do
    test "records what was sent, to whom, and by which provider" do
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"

      assert {:ok, log} =
               Notifications.send_now(:booking_confirmed_customer, phone,
                 locale: "fr",
                 assigns: @assigns
               )

      assert log.status == "sent"
      assert log.to == phone
      assert log.template == "booking_confirmed_customer"
      assert log.body =~ "Le Salon Anfa"
      assert log.sent_at
      assert log.payload["venue"] == "Le Salon Anfa"
    end

    test "but never keeps a one-time code, which is the whole credential" do
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"

      assert {:ok, log} = Notifications.send_now(:login, phone, assigns: %{code: "482913"})

      # The log is readable by every platform admin and survives in every
      # backup. A stored login code is a standing account takeover for anyone
      # who can read the table, and it answers no question the log exists for.
      refute log.body =~ "482913"
      refute log.payload["code"] == "482913"
      assert log.template == "login"
      assert log.status == "sent"

      # The person still gets their code — it is only the durable copy that is
      # redacted.
      assert Collector.last().body =~ "482913"
    end

    test "nor a password reset link, which is a live credential for an hour" do
      assert {:ok, log} =
               Notifications.send_now(:password_reset, "reset@example.com",
                 assigns: %{url: "https://blastek.ma/reset/SECRET"}
               )

      refute log.body =~ "SECRET"
      refute log.payload["url"] =~ "SECRET"
      assert Collector.last().body =~ "SECRET"
    end

    test "nor an invitation link, which grants a role at a venue" do
      assert {:ok, log} =
               Notifications.send_now(:invitation, "invitee@example.com",
                 assigns: %{venue: "Le Salon Anfa", role: "manager", url: "https://x.ma/i/SECRET"}
               )

      refute log.body =~ "SECRET"
      refute log.payload["url"] =~ "SECRET"
      # What is not a credential stays, so the log still says what was offered.
      assert log.payload["venue"] == "Le Salon Anfa"
      assert log.payload["role"] == "manager"
    end

    test "a skipped credential message does not keep the code either" do
      phone = "+212612345666"
      {:ok, _} = Notifications.opt_out(phone)

      Notifications.deliver(:login, phone, assigns: %{code: "999111"})

      assert [log] = Notifications.list_log(limit: 10) |> Enum.filter(&(&1.to == phone))
      refute log.payload["code"] == "999111"
    end

    test "records a failure with its reason" do
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"

      assert {:error, log} =
               TestProvider.with_provider(Blastek.Notifications.FailingProvider, fn ->
                 Notifications.send_now(:login, phone, assigns: @assigns)
               end)

      assert log.status == "failed"
      assert log.error =~ "unreachable"
      assert log.attempts == 1
    end

    test "a delivery receipt promotes sent to delivered" do
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"
      {:ok, log} = Notifications.send_now(:login, phone, assigns: @assigns)

      # The collector returns no id, so give the row one the way a real provider
      # would have.
      Ecto.Changeset.change(log, provider_message_id: "wamid.TEST1") |> Repo.update!()

      assert {:ok, delivered} = Notifications.record_receipt("wamid.TEST1", "delivered")
      assert delivered.status == "delivered"
      assert delivered.delivered_at

      # A receipt for something this deployment never sent is normal — providers
      # retry webhooks — and must not raise.
      assert Notifications.record_receipt("wamid.NEVER-SENT", "delivered") == :ok
    end

    test "filters by venue and status" do
      v = venue_fixture("Log Salon #{System.unique_integer([:positive])}")
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"

      {:ok, _} = Notifications.send_now(:login, phone, venue_id: v.venue.id, assigns: @assigns)

      assert [log] = Notifications.list_log(venue_id: v.venue.id)
      assert log.to == phone
      assert Notifications.count_log(venue_id: v.venue.id, status: "sent") == 1
      assert Notifications.list_log(venue_id: v.venue.id, status: "failed") == []
    end
  end

  describe "the provider chain" do
    test "falls through to the next provider when the first fails" do
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"

      TestProvider.with_provider(
        [Blastek.Notifications.FailingProvider, Collector],
        fn ->
          assert {:ok, log} = Notifications.send_now(:login, phone, assigns: @assigns)
          assert log.status == "sent"
        end
      )

      # The message really did go out on the second provider — WhatsApp being
      # unreachable is the ordinary case, not an outage.
      assert Collector.last_code() == "123456"
    end

    test "reports the last failure when every provider fails" do
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"

      TestProvider.with_provider(
        [Blastek.Notifications.FailingProvider, Blastek.Notifications.FailingProvider],
        fn ->
          assert {:error, log} = Notifications.send_now(:login, phone, assigns: @assigns)
          assert log.error =~ "unreachable"
        end
      )
    end

    test "a provider that raises does not take the message down with it" do
      phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"

      TestProvider.with_provider([Blastek.Notifications.RaisingProvider, Collector], fn ->
        assert {:ok, log} = Notifications.send_now(:login, phone, assigns: @assigns)
        assert log.status == "sent"
      end)
    end

    test "an email address is not offered to an SMS gateway" do
      # `handles?` filters before anything is attempted: sending an email
      # address to a phone gateway is not a fallback, it is a bounce.
      refute Provider.handles?(Blastek.Notifications.Providers.Sms, %{to: "a@example.com"})
      assert Provider.handles?(Blastek.Notifications.Providers.Sms, %{to: "+212600000000"})
    end
  end

  describe "delivering" do
    test "an empty address is a skip, not a crash" do
      assert Notifications.deliver(:login, nil) == {:ok, :skipped}
      assert Notifications.deliver(:login, "") == {:ok, :skipped}
    end

    test "an unknown template is refused rather than queued" do
      assert {:error, {:unknown_template, :nope}} =
               Notifications.deliver(:nope, "+212600000000")
    end
  end
end
