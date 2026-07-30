defmodule BlastekWeb.VenueSettingsTest do
  @moduledoc """
  Settings, closures, hour templates and onboarding through GraphQL
  (E5 / F0.4, F0.5).

  The domain is covered in `Blastek.ScheduleTest`; this is the contract the
  dashboard and the wizard actually depend on.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Salon
  alias Blastek.Venues
  alias Blastek.Venues.Settings
  alias BlastekWeb.Schema

  setup do
    v = venue_fixture("Settings Salon #{unique()}")
    %{user: owner} = member_fixture(v.venue, "owner", "settings-#{unique()}@example.com")
    %{venue: v.venue, owner: owner, service: v.service}
  end

  defp unique, do: System.unique_integer([:positive])

  defp run(query, user, venue) do
    context =
      case {user, venue} do
        {nil, _} ->
          %{client_ip: "10.0.0.1"}

        {user, nil} ->
          %{
            current_user: user,
            memberships: Venues.list_memberships(user.id),
            client_ip: "10.0.0.1"
          }

        {user, venue} ->
          %{
            current_user: user,
            current_venue: Venues.get_venue(venue.id),
            venue_id: venue.id,
            membership: Venues.get_membership(user.id, venue.id),
            memberships: Venues.list_memberships(user.id),
            client_ip: "10.0.0.1"
          }
      end

    Absinthe.run(query, Schema, context: context)
  end

  defp error_message({:ok, %{errors: [%{message: message} | _]}}), do: message

  describe "settings" do
    test "typed writes land and are readable back", ctx do
      assert {:ok, %{data: %{"updateVenueSettings" => venue}}} =
               run(
                 ~s|mutation { updateVenueSettings(input: {slotStepMin: 30, womenOnly: true,
                   amenities: ["Parking", "Parking", " Wifi "]}) { settingsJson } }|,
                 ctx.owner,
                 ctx.venue
               )

      settings = venue["settingsJson"]
      assert settings["slot_step_min"] == 30
      assert settings["women_only"] == true
      # Trimmed and de-duplicated: an amenities list is rendered as chips.
      assert settings["amenities"] == ["Parking", "Wifi"]
    end

    test "a value outside its range is refused with a readable message", ctx do
      assert error_message(
               run(
                 "mutation { updateVenueSettings(input: {slotStepMin: 7}) { id } }",
                 ctx.owner,
                 ctx.venue
               )
             ) =~ "Slot step must be one of"

      assert error_message(
               run(
                 "mutation { updateVenueSettings(input: {bookingHorizonDays: 5000}) { id } }",
                 ctx.owner,
                 ctx.venue
               )
             ) =~ "between 1 and 365"
    end

    test "sending one setting does not blank the others", ctx do
      run(
        "mutation { updateVenueSettings(input: {slotStepMin: 30}) { id } }",
        ctx.owner,
        ctx.venue
      )

      {:ok, %{data: %{"updateVenueSettings" => venue}}} =
        run(
          "mutation { updateVenueSettings(input: {instantConfirmation: false}) { settingsJson } }",
          ctx.owner,
          ctx.venue
        )

      assert venue["settingsJson"]["slot_step_min"] == 30
      assert venue["settingsJson"]["instant_confirmation"] == false
    end

    test "unknown keys never reach storage", ctx do
      # Not through GraphQL — the schema rejects those — but the context must
      # drop them too, since the column is schemaless.
      {:ok, updated} =
        Venues.update_settings(Venues.get_venue(ctx.venue.id), %{"favourite_colour" => "teal"})

      refute Map.has_key?(updated.settings, "favourite_colour")
    end

    test "reads fall back to a default for a venue that predates a setting", ctx do
      assert Settings.get(%{}, :slot_step_min) == 15
      assert Settings.get(ctx.venue.settings, :booking_horizon_days) == 90
    end
  end

  describe "closures" do
    test "created, listed and deleted", ctx do
      date = Date.utc_today() |> Date.add(10) |> Date.to_iso8601()

      assert {:ok, %{data: %{"createClosure" => created}}} =
               run(
                 ~s|mutation { createClosure(date: "#{date}", reason: "Eid") { id reason } }|,
                 ctx.owner,
                 ctx.venue
               )

      assert created["reason"] == "Eid"

      assert {:ok, %{data: %{"venueClosures" => [listed]}}} =
               run("{ venueClosures { id reason date } }", ctx.owner, ctx.venue)

      assert listed["id"] == created["id"]

      assert {:ok, %{data: %{"deleteClosure" => _}}} =
               run(
                 ~s|mutation { deleteClosure(id: "#{created["id"]}") { id } }|,
                 ctx.owner,
                 ctx.venue
               )

      assert {:ok, %{data: %{"venueClosures" => []}}} =
               run("{ venueClosures { id } }", ctx.owner, ctx.venue)
    end

    test "a half-specified window is refused", ctx do
      date = Date.utc_today() |> Date.add(10) |> Date.to_iso8601()

      assert error_message(
               run(
                 ~s|mutation { createClosure(date: "#{date}", startMin: 720) { id } }|,
                 ctx.owner,
                 ctx.venue
               )
             ) =~ "end time"
    end

    test "conflicts are reported without touching the bookings", ctx do
      date = Date.utc_today() |> Date.add(10)
      appointment = booking(ctx, date)

      assert {:ok, %{data: %{"closureConflicts" => [conflict]}}} =
               run(
                 ~s|{ closureConflicts(date: "#{Date.to_iso8601(date)}") {
                   id client { firstName } } }|,
                 ctx.owner,
                 ctx.venue
               )

      assert conflict["id"] == to_string(appointment.id)
      assert conflict["client"]["firstName"]

      # A dry run: nothing was created and nothing cancelled.
      assert Venues.Schedule.list_closures(ctx.venue.id) == []
      assert Repo.get!(Blastek.Salon.Appointment, appointment.id).status == "booked"
    end
  end

  describe "hour templates" do
    test "saved, listed and switched", ctx do
      assert {:ok, %{data: %{"saveHourTemplate" => _}}} =
               run(
                 ~s|mutation { saveHourTemplate(name: "ramadan", days: [
                   {weekday: 0, working: true, startMin: 1260, endMin: 1470},
                   {weekday: 1, working: true, startMin: 1260, endMin: 1470}
                 ]) { name } }|,
                 ctx.owner,
                 ctx.venue
               )

      assert {:ok, %{data: %{"setHourTemplate" => switched}}} =
               run(
                 ~s|mutation { setHourTemplate(name: "ramadan") { name active } }|,
                 ctx.owner,
                 ctx.venue
               )

      assert switched["active"] == true

      assert {:ok, %{data: %{"venueHourTemplates" => [template]}}} =
               run(
                 "{ venueHourTemplates { name active days { weekday endMin } } }",
                 ctx.owner,
                 ctx.venue
               )

      assert template["name"] == "ramadan"
      # Seven days come back even though two were sent.
      assert length(template["days"]) == 7
      # Past midnight survives the round trip.
      assert Enum.any?(template["days"], &(&1["endMin"] == 1470))
    end

    test "switching schedules changes what the marketplace advertises", ctx do
      venue = Venues.get_venue(ctx.venue.id)
      before = Salon.venue_week(venue.id)

      # A Ramadan evening: every day opens at 21:00 and closes at 00:30.
      days =
        Enum.map_join(0..6, ", ", fn weekday ->
          "{weekday: #{weekday}, working: true, startMin: 1260, endMin: 1470}"
        end)

      run(
        ~s|mutation { saveHourTemplate(name: "ramadan", days: [#{days}]) { name } }|,
        ctx.owner,
        ctx.venue
      )

      run(~s|mutation { setHourTemplate(name: "ramadan") { name } }|, ctx.owner, ctx.venue)

      # The public page, not the dashboard: the venue is open at a different
      # time of day now, and a shopper reading the old hours would turn up to a
      # locked door. The staff rows still say 09:00, so a query that ignores the
      # active template keeps returning `before` here.
      assert {:ok, %{data: %{"venue" => %{"hours" => advertised}}}} =
               run(
                 ~s|{ venue(slug: "#{venue.slug}") { hours { weekday open close } } }|,
                 nil,
                 nil
               )

      refute advertised == before

      assert Enum.all?(advertised, &(&1["open"] == 1260 and &1["close"] == 1470)),
             "expected the Ramadan grid everywhere, got #{inspect(advertised)}"
    end

    test "switching to an unknown schedule says so", ctx do
      assert error_message(
               run(
                 ~s|mutation { setHourTemplate(name: "winter") { name } }|,
                 ctx.owner,
                 ctx.venue
               )
             ) =~ "No schedule called"
    end
  end

  describe "onboarding" do
    # `venue_fixture` creates a live venue; onboarding is about one that is not
    # yet, so these start it back at pending.
    setup ctx do
      {:ok, pending} = Venues.update_venue(Venues.get_venue(ctx.venue.id), %{status: "pending"})
      %{venue: pending}
    end

    test "a signed-in user can create a venue and it starts pending", ctx do
      newcomer = user_fixture("newcomer-#{unique()}@example.com")

      assert {:ok, %{data: %{"createVenue" => venue}}} =
               run(
                 ~s|mutation { createVenue(name: "Salon Nouveau", city: "Rabat") {
                   id slug name status } }|,
                 newcomer,
                 nil
               )

      assert venue["status"] == "pending"
      # The creator owns it, so the dashboard works immediately.
      created = Venues.get_venue(String.to_integer(venue["id"]))
      assert Venues.get_membership(newcomer.id, created.id).role == "owner"
      assert ctx.venue.id != created.id
    end

    test "steps are saved and resumable", ctx do
      run(
        ~s|mutation { updateOnboarding(step: "basics", data: "{\\"name\\":\\"Nouveau\\"}") { id } }|,
        ctx.owner,
        ctx.venue
      )

      assert {:ok, %{data: %{"currentVenue" => venue}}} =
               run(
                 "{ currentVenue { onboarding { currentStep completed submitted data } } }",
                 ctx.owner,
                 ctx.venue
               )

      assert venue["onboarding"]["currentStep"] == "basics"
      assert "basics" in venue["onboarding"]["completed"]
      assert venue["onboarding"]["submitted"] == false
    end

    test "submitting needs at least one service", _ctx do
      bare = venue_fixture_without_services()
      %{user: owner} = member_fixture(bare, "owner", "bare-#{unique()}@example.com")

      assert error_message(run("mutation { submitVenue { id } }", owner, bare)) =~
               "at least one service"
    end

    test "submit then approve puts the venue live and tells the owner", ctx do
      assert {:ok, %{data: %{"submitVenue" => _}}} =
               run("mutation { submitVenue { id status } }", ctx.owner, ctx.venue)

      admin = admin_fixture("approver-#{unique()}@example.com")

      assert {:ok, %{data: %{"approveVenue" => approved}}} =
               run(~s|mutation { approveVenue(id: "#{ctx.venue.id}") { status } }|, admin, nil)

      assert approved["status"] == "active"
      # French is the default locale, so that is what an owner receives.
      assert Blastek.Notifications.Collector.last().body =~ "en ligne sur Blastek"
    end

    test "rejecting requires a reason and keeps it", ctx do
      admin = admin_fixture("rejector-#{unique()}@example.com")

      assert error_message(
               run(
                 ~s|mutation { rejectVenue(id: "#{ctx.venue.id}", reason: "  ") { id } }|,
                 admin,
                 nil
               )
             ) =~ "Give a reason"

      assert {:ok, %{data: %{"rejectVenue" => rejected}}} =
               run(
                 ~s|mutation { rejectVenue(id: "#{ctx.venue.id}", reason: "Photos are blurry") {
                   status rejectedReason } }|,
                 admin,
                 nil
               )

      assert rejected["status"] == "pending"
      assert rejected["rejectedReason"] == "Photos are blurry"
      assert Blastek.Notifications.Collector.last().body =~ "blurry"
    end

    test "the review queue holds only submitted venues", ctx do
      admin = admin_fixture("queue-#{unique()}@example.com")

      assert {:ok, %{data: %{"venueReviewQueue" => before}}} =
               run("{ venueReviewQueue { id } }", admin, nil)

      refute to_string(ctx.venue.id) in Enum.map(before, & &1["id"])

      run("mutation { submitVenue { id } }", ctx.owner, ctx.venue)

      {:ok, %{data: %{"venueReviewQueue" => queued}}} =
        run("{ venueReviewQueue { id } }", admin, nil)

      assert to_string(ctx.venue.id) in Enum.map(queued, & &1["id"])
    end

    test "duplicate detection flags a shared phone", ctx do
      {:ok, _} = Venues.update_venue(Venues.get_venue(ctx.venue.id), %{phone: "+212522334455"})

      twin = venue_fixture("Twin Salon #{unique()}")
      {:ok, twin_venue} = Venues.update_venue(twin.venue, %{phone: "0522 33 44 55"})

      admin = admin_fixture("dupe-#{unique()}@example.com")

      {:ok, %{data: %{"venueDuplicates" => duplicates}}} =
        run(~s|{ venueDuplicates(id: "#{twin_venue.id}") { id name } }|, admin, nil)

      assert to_string(ctx.venue.id) in Enum.map(duplicates, & &1["id"])
    end
  end

  describe "starter catalogs" do
    test "are offered and become real services", ctx do
      assert {:ok, %{data: %{"serviceCatalogs" => catalogs}}} =
               run("{ serviceCatalogs { catalog serviceCount } }", nil, nil)

      assert length(catalogs) == 5

      {:ok, %{data: %{"serviceTemplates" => templates}}} =
        run(~s|{ serviceTemplates(catalog: "barbier") { id name(locale: "ar") } }|, nil, nil)

      assert length(templates) > 0
      # Arabic from the start — the wizard's whole premise.
      assert Enum.any?(templates, &(&1["name"] =~ ~r/\p{Arabic}/u))

      ids =
        templates
        |> Enum.take(2)
        |> Enum.map(& &1["id"])
        |> Enum.map(&~s|"#{&1}"|)
        |> Enum.join(", ")

      assert {:ok, %{data: %{"applyServiceTemplates" => created}}} =
               run(
                 ~s|mutation { applyServiceTemplates(templateIds: [#{ids}], locale: "fr") {
                   id name } }|,
                 ctx.owner,
                 ctx.venue
               )

      assert length(created) == 2
      # Copied, not referenced: the venue's menu is its own from day one.
      assert Enum.all?(created, &is_binary(&1["name"]))
    end
  end

  defp booking(ctx, date) do
    client =
      Repo.one!(from c in Blastek.Salon.Client, where: c.venue_id == ^ctx.venue.id, limit: 1)

    staff = Repo.one!(from s in Blastek.Salon.Staff, where: s.venue_id == ^ctx.venue.id, limit: 1)

    {:ok, appointment} =
      Blastek.Salon.create_appointment(ctx.venue.id, %{
        client_id: client.id,
        staff_id: staff.id,
        service_id: ctx.service.id,
        date: date,
        start_min: 600
      })

    appointment
  end

  defp venue_fixture_without_services do
    {:ok, venue} =
      Venues.create_venue(%{
        name: "Bare Salon #{unique()}",
        status: "pending",
        city: "Casablanca"
      })

    venue
  end
end
