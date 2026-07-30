defmodule Blastek.ScheduleTest do
  @moduledoc """
  Closures, seasonal hour templates, and what they do to availability
  (E5-T2, E5-T3, E5-T4 / F0.4).

  The assertions that matter are about *slots*, not about rows: a closure that
  is stored correctly but still offers bookable time is worse than one that was
  never created, because the salon finds out when someone turns up.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Salon
  alias Blastek.Venues.Schedule

  setup do
    v = venue_fixture("Schedule Salon #{System.unique_integer([:positive])}")
    # A Wednesday, comfortably in the future so "today" logic never interferes.
    date = Date.utc_today() |> Date.add(14) |> next_weekday(3)

    %{venue: v.venue, staff: v.staff, service: v.service, date: date}
  end

  defp next_weekday(date, weekday) do
    if Date.day_of_week(date, :sunday) - 1 == weekday,
      do: date,
      else: next_weekday(Date.add(date, 1), weekday)
  end

  defp slots(ctx, date \\ nil) do
    {:ok, %{slots: slots}} =
      Salon.availability(ctx.venue.id, [ctx.service.id], "any", date || ctx.date)

    Enum.map(slots, & &1.start_min)
  end

  describe "closures" do
    test "a whole-day closure removes every slot", ctx do
      assert slots(ctx) != []

      {:ok, _} = Schedule.create_closure(ctx.venue.id, %{date: ctx.date, reason: "Eid"})

      assert slots(ctx) == []
    end

    test "a part-day closure removes only that window", ctx do
      before = slots(ctx)
      assert 600 in before

      # Closed 12:00–14:00.
      {:ok, _} =
        Schedule.create_closure(ctx.venue.id, %{
          date: ctx.date,
          start_min: 720,
          end_min: 840,
          reason: "Lunch"
        })

      after_slots = slots(ctx)

      # The fixture service is 60 minutes, so anything starting from 11:01 to
      # 14:00 would overlap the closed window.
      assert 600 in after_slots
      refute 720 in after_slots
      refute 780 in after_slots
      assert 840 in after_slots
    end

    test "a multi-day closure covers every day in the span", ctx do
      {:ok, _} =
        Schedule.create_closure(ctx.venue.id, %{
          date: ctx.date,
          end_date: Date.add(ctx.date, 2),
          reason: "Eid al-Fitr"
        })

      for offset <- 0..2 do
        assert slots(ctx, Date.add(ctx.date, offset)) == [],
               "day +#{offset} should be closed"
      end

      # And the day after the span is open again.
      assert slots(ctx, Date.add(ctx.date, 3)) != []
    end

    test "a closure elsewhere in the calendar does not leak", ctx do
      {:ok, _} =
        Schedule.create_closure(ctx.venue.id, %{date: Date.add(ctx.date, 30), reason: "Later"})

      assert slots(ctx) != []
    end

    test "one venue's closure does not shut another", ctx do
      other = venue_fixture("Other Schedule #{System.unique_integer([:positive])}")
      {:ok, _} = Schedule.create_closure(other.venue.id, %{date: ctx.date, reason: "Theirs"})

      assert slots(ctx) != []
    end

    test "half a window is refused rather than treated as a whole day", ctx do
      # Silently reading this as "closed all day" would shut the salon by
      # accident.
      assert {:error, changeset} =
               Schedule.create_closure(ctx.venue.id, %{date: ctx.date, start_min: 720})

      assert errors_on(changeset).start_min != []
    end

    test "a backwards span is refused", ctx do
      assert {:error, changeset} =
               Schedule.create_closure(ctx.venue.id, %{
                 date: ctx.date,
                 end_date: Date.add(ctx.date, -1)
               })

      assert errors_on(changeset).end_date != []
    end

    test "list and delete are venue-scoped", ctx do
      {:ok, closure} = Schedule.create_closure(ctx.venue.id, %{date: ctx.date, reason: "Eid"})
      other = venue_fixture("Scoped Schedule #{System.unique_integer([:positive])}")

      assert {:error, "Unknown closure."} = Schedule.delete_closure(other.venue.id, closure.id)
      assert length(Schedule.list_closures(ctx.venue.id)) == 1
      assert Schedule.list_closures(other.venue.id) == []
    end
  end

  describe "hour templates" do
    test "switching templates moves the working day", ctx do
      # Ramadan: 21:00 to 00:30 the next morning.
      {:ok, _} =
        Schedule.upsert_template(ctx.venue.id, "ramadan", ramadan_week())

      {:ok, _} = Schedule.activate_template(ctx.venue.id, "ramadan")

      # The staff fixture works 09:00–18:00 with no Ramadan rows of its own, so
      # the venue template is what decides — otherwise a one-tap switch would
      # appear to do nothing.
      after_switch = slots(ctx)

      assert Enum.all?(after_switch, &(&1 >= 1260)),
             "expected only evening slots, got #{inspect(after_switch)}"

      assert Enum.max(after_switch) + ctx.service.duration_min <= 1470
    end

    test "past-midnight ranges produce slots beyond 1440", ctx do
      {:ok, _} = Schedule.upsert_template(ctx.venue.id, "ramadan", ramadan_week())
      {:ok, _} = Schedule.activate_template(ctx.venue.id, "ramadan")

      # 23:30 start for a 60-minute service ends at 00:30 — the whole point of
      # letting minutes run past 1440.
      assert 1410 in slots(ctx)
    end

    test "a staff member's own rows win over the venue template", ctx do
      {:ok, template} = Schedule.upsert_template(ctx.venue.id, "ramadan", ramadan_week())

      # This stylist works mornings in Ramadan while the venue opens at night.
      Repo.insert!(%Blastek.Salon.StaffHour{
        staff_id: ctx.staff.id,
        template_id: template.id,
        weekday: Date.day_of_week(ctx.date, :sunday) - 1,
        working: true,
        start_min: 600,
        end_min: 720
      })

      {:ok, _} = Schedule.activate_template(ctx.venue.id, "ramadan")

      # Their own morning window, not the venue's evening one: 10:00 to 12:00
      # less the 60-minute service.
      assert slots(ctx) == [600, 615, 630, 645, 660]
    end

    test "only one template can be active at a time", ctx do
      {:ok, _} = Schedule.upsert_template(ctx.venue.id, "default", default_week())
      {:ok, _} = Schedule.upsert_template(ctx.venue.id, "ramadan", ramadan_week())

      {:ok, _} = Schedule.activate_template(ctx.venue.id, "default")
      {:ok, _} = Schedule.activate_template(ctx.venue.id, "ramadan")

      assert Schedule.active_template(ctx.venue.id).name == "ramadan"
      assert Enum.count(Schedule.list_templates(ctx.venue.id), & &1.active) == 1
    end

    test "activating an unknown template says so", ctx do
      assert {:error, message} = Schedule.activate_template(ctx.venue.id, "winter")
      assert message =~ "No schedule called"
    end

    test "a day that ends before it starts is stored as closed", ctx do
      # The seven days arrive together, so one transposed pair must not cost the
      # owner the other six — but storing it as-is would leave the slot engine
      # offering nothing on that day with nothing to show for it.
      {:ok, template} =
        Schedule.upsert_template(ctx.venue.id, "typo", [
          %{weekday: 2, working: true, start_min: 1080, end_min: 540}
        ])

      day = Schedule.week_list(template) |> Enum.find(&(&1["weekday"] == 2))
      refute day["working"]
    end

    test "working_hours reports the precedence directly", ctx do
      weekday = Date.day_of_week(ctx.date, :sunday) - 1

      # No template: the staff member's own default row.
      assert Salon.working_hours(ctx.venue.id, ctx.staff.id, weekday) == {540, 1080}

      {:ok, template} = Schedule.upsert_template(ctx.venue.id, "ramadan", ramadan_week())
      {:ok, _} = Schedule.activate_template(ctx.venue.id, "ramadan")

      # Under a non-default template the venue grid applies, *not* the default
      # staff row — that fallback is what would make a seasonal switch a no-op.
      assert Salon.working_hours(ctx.venue.id, ctx.staff.id, weekday) == {1260, 1470}

      Repo.insert!(%Blastek.Salon.StaffHour{
        staff_id: ctx.staff.id,
        template_id: template.id,
        weekday: weekday,
        working: true,
        start_min: 600,
        end_min: 720
      })

      # Their own row for this template beats the grid.
      assert Salon.working_hours(ctx.venue.id, ctx.staff.id, weekday) == {600, 720}
    end

    test "a partial week is filled in rather than blanking the rest", ctx do
      # A client sending only the day it changed must not close the salon for
      # the other six.
      {:ok, template} =
        Schedule.upsert_template(ctx.venue.id, "partial", [
          %{weekday: 3, working: true, start_min: 600, end_min: 1200}
        ])

      week = Schedule.week_list(template)
      assert length(week) == 7
      assert Enum.map(week, & &1["weekday"]) == Enum.to_list(0..6)
    end

    test "a closure still wins over an active template", ctx do
      {:ok, _} = Schedule.upsert_template(ctx.venue.id, "ramadan", ramadan_week())
      {:ok, _} = Schedule.activate_template(ctx.venue.id, "ramadan")
      {:ok, _} = Schedule.create_closure(ctx.venue.id, %{date: ctx.date, reason: "Eid"})

      # A whole-day closure covers the past-midnight tail too, or a 21:00–00:30
      # template would leak slots on a day the venue is shut.
      assert slots(ctx) == []
    end
  end

  describe "conflict detection" do
    test "lists the appointments a proposed closure would strand", ctx do
      appointment =
        appointment_fixture(
          %{venue: ctx.venue, client: client_of(ctx), staff: ctx.staff, service: ctx.service},
          %{date: ctx.date, start_min: 600}
        )

      conflicts = Salon.appointments_in_window(ctx.venue.id, ctx.date, ctx.date, nil, nil)

      assert Enum.map(conflicts, & &1.id) == [appointment.id]
      # Preloaded, because the owner is about to telephone these people.
      assert hd(conflicts).client.first_name
    end

    test "a part-day window only catches what overlaps it", ctx do
      appointment =
        appointment_fixture(
          %{venue: ctx.venue, client: client_of(ctx), staff: ctx.staff, service: ctx.service},
          %{date: ctx.date, start_min: 600}
        )

      assert Salon.appointments_in_window(ctx.venue.id, ctx.date, ctx.date, 900, 1000) == []

      assert Salon.appointments_in_window(ctx.venue.id, ctx.date, ctx.date, 630, 700)
             |> Enum.map(& &1.id) == [appointment.id]
    end

    test "cancelled appointments are not conflicts", ctx do
      appointment =
        appointment_fixture(
          %{venue: ctx.venue, client: client_of(ctx), staff: ctx.staff, service: ctx.service},
          %{date: ctx.date, start_min: 600}
        )

      {:ok, _} = Salon.update_appointment(ctx.venue.id, appointment.id, %{status: "cancelled"})

      assert Salon.appointments_in_window(ctx.venue.id, ctx.date, ctx.date, nil, nil) == []
    end

    test "creating a closure does not cancel anything on its own", ctx do
      appointment =
        appointment_fixture(
          %{venue: ctx.venue, client: client_of(ctx), staff: ctx.staff, service: ctx.service},
          %{date: ctx.date, start_min: 600}
        )

      {:ok, _} = Schedule.create_closure(ctx.venue.id, %{date: ctx.date, reason: "Eid"})

      # F0.4 is explicit: the owner is shown what they are about to break and
      # decides. A salon closing for a funeral still has to telephone people.
      assert Repo.get!(Blastek.Salon.Appointment, appointment.id).status == "booked"
    end
  end

  defp client_of(ctx) do
    Repo.one!(from c in Blastek.Salon.Client, where: c.venue_id == ^ctx.venue.id, limit: 1)
  end

  defp default_week do
    for weekday <- 0..6,
        do: %{weekday: weekday, working: weekday != 0, start_min: 540, end_min: 1080}
  end

  defp ramadan_week do
    for weekday <- 0..6,
        do: %{weekday: weekday, working: true, start_min: 1260, end_min: 1470}
  end
end
