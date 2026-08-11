defmodule Blastek.BookingSettingsTest do
  @moduledoc """
  The venue settings that govern booking actually govern it (E5-T1 / F0.4).

  A settings panel whose values are stored, validated, echoed back and then
  ignored is worse than no panel at all: the owner believes they have configured
  something. Every test here changes one setting and asserts the *booking
  engine* behaves differently — none of them touch `Venues.Settings` directly,
  because that module was already green while all five settings were dead.

  Dates come from `Blastek.Clock`, not from `Date.utc_today/0`: horizons and
  lead times are counted in the salon's days, and for the hour between midnight
  in Casablanca and midnight in UTC the two disagree — which is a real off-by-a-
  day in the rule, not a quirk of the test.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Clock
  alias Blastek.Salon
  alias Blastek.Venues

  setup do
    v = venue_fixture("Rules Salon #{System.unique_integer([:positive])}")
    %{v: v}
  end

  defp set(v, settings) do
    {:ok, _} = Venues.update_settings(Venues.get_venue(v.venue.id), settings)
    :ok
  end

  defp slots(v, date) do
    {:ok, %{slots: slots}} = Salon.availability(v.venue.id, [v.service.id], "any", date)
    Enum.map(slots, & &1.start_min)
  end

  # Far enough out that "today" logic and lead times never interfere.
  defp far_date, do: Date.add(Clock.today(), 7)

  describe "slot_step_min" do
    test "sets the spacing of the offered grid", %{v: v} do
      assert [540, 555, 570 | _] = slots(v, far_date())

      :ok = set(v, %{"slot_step_min" => 30})
      thirty = slots(v, far_date())
      assert [540, 570, 600 | _] = thirty

      :ok = set(v, %{"slot_step_min" => 60})
      hourly = slots(v, far_date())

      # The fixture works 09:00–18:00 and its service runs 60 minutes, so an
      # hourly grid is exactly 09:00 through 17:00 — not merely "fewer".
      assert hourly == Enum.to_list(540..1020//60)
      assert length(hourly) < length(thirty)
    end
  end

  describe "booking_horizon_days" do
    test "nothing is offered beyond the horizon", %{v: v} do
      :ok = set(v, %{"booking_horizon_days" => 30})

      refute slots(v, Date.add(Clock.today(), 29)) == []
      assert slots(v, Date.add(Clock.today(), 31)) == []
    end

    test "the boundary day itself is still bookable", %{v: v} do
      :ok = set(v, %{"booking_horizon_days" => 10})
      refute slots(v, Date.add(Clock.today(), 10)) == []
      assert slots(v, Date.add(Clock.today(), 11)) == []
    end
  end

  describe "booking_lead_min" do
    test "a venue wanting notice does not offer the next few hours", %{v: v} do
      today = Clock.today()
      # Two full days of notice: every hour of tomorrow is inside it, whatever
      # time this test runs.
      :ok = set(v, %{"booking_lead_min" => 2 * 24 * 60})

      assert slots(v, Date.add(today, 1)) == []
      refute slots(v, Date.add(today, 3)) == []
    end

    test "with no lead time the far future is unaffected", %{v: v} do
      :ok = set(v, %{"booking_lead_min" => 0})
      refute slots(v, Date.add(Clock.today(), 1)) == []
    end
  end

  describe "instant_confirmation" do
    test "a venue that vets bookings gets them pending", %{v: v} do
      :ok = set(v, %{"instant_confirmation" => false})

      {:ok, %{appointments: [appt]}} = book(v)
      assert appt.status == "booked"
    end

    test "a venue that does not gets them confirmed", %{v: v} do
      :ok = set(v, %{"instant_confirmation" => true})

      {:ok, %{appointments: [appt]}} = book(v)
      assert appt.status == "confirmed"
    end
  end

  describe "cancellation_window_hours" do
    test "a client may cancel outside the window", %{v: v} do
      :ok = set(v, %{"cancellation_window_hours" => 24})
      appt = appointment_fixture(v, %{date: Date.add(Clock.today(), 5)})

      assert Salon.cancellable_by_client?(appt)
    end

    test "and may not inside it", %{v: v} do
      :ok = set(v, %{"cancellation_window_hours" => 48})
      # Tomorrow morning is inside a 48-hour window from any moment today.
      appt = appointment_fixture(v, %{date: Date.add(Clock.today(), 1), start_min: 600})

      refute Salon.cancellable_by_client?(appt)
    end

    test "a window of zero lets a client cancel right up to the appointment", %{v: v} do
      :ok = set(v, %{"cancellation_window_hours" => 0})
      appt = appointment_fixture(v, %{date: Date.add(Clock.today(), 1), start_min: 600})

      assert Salon.cancellable_by_client?(appt)
    end

    test "an appointment already cancelled cannot be cancelled again", %{v: v} do
      :ok = set(v, %{"cancellation_window_hours" => 0})
      appt = appointment_fixture(v, %{date: Date.add(Clock.today(), 5)})
      {:ok, cancelled} = Salon.update_appointment(v.venue.id, appt.id, %{status: "cancelled"})

      refute Salon.cancellable_by_client?(cancelled)
    end
  end

  describe "defaults" do
    test "a venue that has never opened the settings page still books", %{v: v} do
      # `venue_fixture` writes no settings at all, so this exercises the
      # every-key-missing path the whole of E1's data takes.
      assert Venues.get_venue(v.venue.id).settings == %{}
      assert [540, 555 | _] = slots(v, far_date())
    end
  end

  defp book(v) do
    date = far_date()
    [start_min | _] = slots(v, date)

    Salon.book(v.venue.id, %{
      client_id: v.client.id,
      service_ids: [v.service.id],
      staff_id: "any",
      date: date,
      start_min: start_min
    })
  end
end
