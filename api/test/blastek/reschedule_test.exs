defmodule Blastek.RescheduleTest do
  @moduledoc """
  A customer moving their own booking (E9-T4 / F0.9).

  The dashboard has always been able to move an appointment; this is the
  customer-facing flow, and the difference is entirely in what it refuses —
  ownership, the venue's window, the chain limit — and in doing the move under
  the same lock `book/2` uses, because two people can pick the same slot in the
  same second.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Repo
  alias Blastek.Salon

  setup do
    v = venue_fixture("Reschedule Salon #{System.unique_integer([:positive])}")
    date = Date.add(Blastek.Clock.today(), 3)

    {:ok, %{slots: [%{start_min: start_min} | _]}} =
      Salon.availability(v.venue.id, [v.service.id], "any", date)

    {:ok, booking} =
      Salon.book(v.venue.id, %{
        client_id: v.client.id,
        service_ids: [v.service.id],
        staff_id: "any",
        date: date,
        start_min: start_min
      })

    %{v: v, date: date, start_min: start_min, booking: booking, clients: [v.client.id]}
  end

  defp free_slot(ctx, date, exclude \\ []) do
    {:ok, %{slots: slots}} =
      Salon.availability(ctx.v.venue.id, [ctx.v.service.id], "any", date, exclude: exclude)

    slots |> Enum.map(& &1.start_min) |> Enum.reject(&(&1 == ctx.start_min)) |> List.first()
  end

  describe "moving a booking" do
    test "lands on the new slot and frees the old one", ctx do
      later = Date.add(ctx.date, 1)
      target = free_slot(ctx, later)

      assert {:ok, result} =
               Salon.reschedule_booking(ctx.v.venue.id, ctx.booking.booking_ref, ctx.clients, %{
                 date: later,
                 start_min: target
               })

      assert result.date == later
      assert result.start_min == target

      moved = Repo.get(Salon.Appointment, hd(ctx.booking.appointments).id)
      assert moved.date == later
      assert moved.start_min == target

      # The original slot is bookable again.
      {:ok, %{slots: slots}} =
        Salon.availability(ctx.v.venue.id, [ctx.v.service.id], "any", ctx.date)

      assert ctx.start_min in Enum.map(slots, & &1.start_min)
    end

    test "can move within the same day without colliding with itself", ctx do
      # The classic off-by-one-booking bug: the appointment being moved is still
      # in the table, so a naive availability check reports its own slot busy
      # and a 15-minute shift becomes impossible.
      target = free_slot(ctx, ctx.date, [hd(ctx.booking.appointments).id])
      refute is_nil(target), "there should be another slot on the same day"

      assert {:ok, result} =
               Salon.reschedule_booking(ctx.v.venue.id, ctx.booking.booking_ref, ctx.clients, %{
                 date: ctx.date,
                 start_min: target
               })

      assert result.start_min == target
    end

    test "moves every row of a multi-service booking, contiguously", ctx do
      {:ok, second} =
        Salon.create_service(
          ctx.v.venue.id,
          %{
            category_id: ctx.v.category.id,
            name: "Colour",
            duration_min: 30,
            price_cents: 15_000
          },
          [ctx.v.staff.id]
        )

      date = Date.add(ctx.date, 2)

      {:ok, %{slots: [%{start_min: start_min} | _]}} =
        Salon.availability(ctx.v.venue.id, [ctx.v.service.id, second.id], "any", date)

      {:ok, booking} =
        Salon.book(ctx.v.venue.id, %{
          client_id: ctx.v.client.id,
          service_ids: [ctx.v.service.id, second.id],
          staff_id: "any",
          date: date,
          start_min: start_min
        })

      assert length(booking.appointments) == 2

      later = Date.add(date, 1)

      {:ok, %{slots: [%{start_min: target} | _]}} =
        Salon.availability(ctx.v.venue.id, [ctx.v.service.id, second.id], "any", later)

      assert {:ok, result} =
               Salon.reschedule_booking(ctx.v.venue.id, booking.booking_ref, ctx.clients, %{
                 date: later,
                 start_min: target
               })

      # One arrival: the two rows stay back to back, in order, on one day.
      [first, last] = Enum.sort_by(result.appointments, & &1.start_min)
      assert first.date == later and last.date == later
      assert first.start_min == target
      assert last.start_min == first.end_min
    end
  end

  describe "what it refuses" do
    test "somebody else's booking", ctx do
      stranger = venue_fixture("Stranger #{System.unique_integer([:positive])}")

      assert {:error, :not_found} =
               Salon.reschedule_booking(
                 ctx.v.venue.id,
                 ctx.booking.booking_ref,
                 [stranger.client.id],
                 %{date: Date.add(ctx.date, 1), start_min: ctx.start_min}
               )
    end

    test "a booking inside the cancellation window", ctx do
      # Two hours from now, with the venue's default three-hour window.
      soon = Blastek.Clock.today()
      minute_now = Blastek.Clock.minute_of_day()

      {:ok, _} =
        Repo.update_all(
          from(a in Salon.Appointment, where: a.booking_ref == ^ctx.booking.booking_ref),
          set: [date: soon, start_min: minute_now + 120, end_min: minute_now + 180]
        )
        |> then(fn {n, _} -> {:ok, n} end)

      assert {:error, message} =
               Salon.reschedule_booking(ctx.v.venue.id, ctx.booking.booking_ref, ctx.clients, %{
                 date: Date.add(soon, 4),
                 start_min: 600
               })

      assert message =~ "call the salon"
    end

    test "a booking already moved three times", ctx do
      Repo.update_all(
        from(a in Salon.Appointment, where: a.booking_ref == ^ctx.booking.booking_ref),
        set: [reschedule_count: 3]
      )

      assert {:error, message} =
               Salon.reschedule_booking(ctx.v.venue.id, ctx.booking.booking_ref, ctx.clients, %{
                 date: Date.add(ctx.date, 1),
                 start_min: ctx.start_min
               })

      assert message =~ "too many times"
    end

    test "a cancelled booking", ctx do
      Repo.update_all(
        from(a in Salon.Appointment, where: a.booking_ref == ^ctx.booking.booking_ref),
        set: [status: "cancelled"]
      )

      assert {:error, message} =
               Salon.reschedule_booking(ctx.v.venue.id, ctx.booking.booking_ref, ctx.clients, %{
                 date: Date.add(ctx.date, 1),
                 start_min: ctx.start_min
               })

      assert message =~ "no longer be changed"
    end

    test "a slot that is not actually free", ctx do
      later = Date.add(ctx.date, 1)

      # 03:00 is outside the 09:00–18:00 week, so it is never on offer.
      assert {:error, _} =
               Salon.reschedule_booking(ctx.v.venue.id, ctx.booking.booking_ref, ctx.clients, %{
                 date: later,
                 start_min: 180
               })
    end

    test "a slot a staff block has removed", ctx do
      later = Date.add(ctx.date, 1)
      target = free_slot(ctx, later)

      {:ok, _} =
        Salon.Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "time_off",
          date: later
        })

      # The whole point of E9-T1 meeting E9-T4: a holiday has to close the
      # reschedule path as firmly as it closes the booking path.
      assert {:error, _} =
               Salon.reschedule_booking(ctx.v.venue.id, ctx.booking.booking_ref, ctx.clients, %{
                 date: later,
                 start_min: target
               })
    end
  end

  describe "counting" do
    test "each move increments the chain, so the cap is reachable", ctx do
      ref = ctx.booking.booking_ref

      for step <- 1..3 do
        day = Date.add(ctx.date, step)

        {:ok, %{slots: [%{start_min: target} | _]}} =
          Salon.availability(ctx.v.venue.id, [ctx.v.service.id], "any", day)

        assert {:ok, _} =
                 Salon.reschedule_booking(ctx.v.venue.id, ref, ctx.clients, %{
                   date: day,
                   start_min: target
                 })
      end

      counted = Repo.one(from a in Salon.Appointment, where: a.booking_ref == ^ref, limit: 1)
      assert counted.reschedule_count == 3

      # And the fourth is refused.
      assert {:error, message} =
               Salon.reschedule_booking(ctx.v.venue.id, ref, ctx.clients, %{
                 date: Date.add(ctx.date, 5),
                 start_min: ctx.start_min
               })

      assert message =~ "too many times"
    end
  end

  describe "notifications" do
    test "the customer is told, and the reminders follow the new time", ctx do
      later = Date.add(ctx.date, 1)
      target = free_slot(ctx, later)

      {:ok, _} =
        Salon.reschedule_booking(ctx.v.venue.id, ctx.booking.booking_ref, ctx.clients, %{
          date: later,
          start_min: target
        })

      appointment_id = hd(ctx.booking.appointments).id

      jobs =
        Oban.Job
        |> Repo.all()
        |> Enum.filter(&(&1.args["appointment_id"] == appointment_id))

      templates = jobs |> Enum.map(& &1.args["template"]) |> Enum.sort() |> Enum.uniq()

      # The move itself, and reminders re-timed against the new slot rather
      # than left pointing at the old one.
      assert "rescheduled" in templates
      assert "reminder_24h" in templates
    end
  end
end
