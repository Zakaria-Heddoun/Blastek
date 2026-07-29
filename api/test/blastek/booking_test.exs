defmodule Blastek.BookingTest do
  @moduledoc """
  Booking correctness: the slot check and the insert must be atomic, or two
  customers can win the same slot.
  """
  use Blastek.DataCase, async: false

  import Blastek.Fixtures

  alias Blastek.Repo
  alias Blastek.Salon

  setup do
    v = venue_fixture("Race Salon")
    user = user_fixture("racer@example.com")
    {:ok, client_id} = Blastek.Accounts.ensure_client(user, v.venue.id)
    %{v: v, client_id: client_id, date: Date.add(Date.utc_today(), 3)}
  end

  test "a booking occupies the slot", %{v: v, client_id: client_id, date: date} do
    {:ok, booking} =
      Salon.book(v.venue.id, %{
        service_ids: [v.service.id],
        staff_id: "any",
        date: date,
        start_min: 600,
        client_id: client_id
      })

    assert booking.booking_ref =~ ~r/^BK-[A-Z2-7]{6}$/
    assert booking.start_min == 600
    assert booking.end_min == 660
    assert [appt] = booking.appointments
    assert appt.venue_id == v.venue.id
    assert appt.source == "online"

    # The slot is gone from availability afterwards.
    {:ok, %{slots: slots}} = Salon.availability(v.venue.id, [v.service.id], "any", date)
    refute Enum.any?(slots, &(&1.start_min == 600))
  end

  test "booking the same slot twice is refused", %{v: v, client_id: client_id, date: date} do
    args = %{
      service_ids: [v.service.id],
      staff_id: "any",
      date: date,
      start_min: 600,
      client_id: client_id
    }

    assert {:ok, _} = Salon.book(v.venue.id, args)
    assert {:error, msg} = Salon.book(v.venue.id, args)
    assert msg =~ "just taken"
  end

  @tag :concurrency
  test "concurrent bookings for one slot produce exactly one appointment",
       %{v: v, client_id: client_id, date: date} do
    # The sandbox connection is shared so spawned tasks see the same data.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    args = %{
      service_ids: [v.service.id],
      staff_id: "any",
      date: date,
      start_min: 600,
      client_id: client_id
    }

    results =
      1..20
      |> Task.async_stream(fn _ -> Salon.book(v.venue.id, args) end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    successes = Enum.count(results, &match?({:ok, _}, &1))
    assert successes == 1, "expected exactly 1 winner, got #{successes}"

    booked =
      Repo.aggregate(
        from(a in Blastek.Salon.Appointment,
          where: a.venue_id == ^v.venue.id and a.date == ^date and a.start_min == 600
        ),
        :count
      )

    assert booked == 1
  end

  test "the database rejects an overlap even without the availability check",
       %{v: v, date: date} do
    # Belt and braces: the exclusion constraint is the real guarantee.
    base = %{
      venue_id: v.venue.id,
      client_id: v.client.id,
      staff_id: v.staff.id,
      service_id: v.service.id,
      date: date,
      price_cents: 20_000
    }

    assert {:ok, _} =
             %Blastek.Salon.Appointment{}
             |> Blastek.Salon.Appointment.changeset(
               Map.merge(base, %{start_min: 600, end_min: 660})
             )
             |> Repo.insert()

    assert {:error, changeset} =
             %Blastek.Salon.Appointment{}
             |> Blastek.Salon.Appointment.changeset(
               Map.merge(base, %{start_min: 630, end_min: 690})
             )
             |> Repo.insert()

    assert "That time was just taken — please pick another slot." in errors_on(changeset).start_min
  end

  test "a cancelled appointment frees its slot", %{v: v, date: date} do
    appt = appointment_fixture(v, %{date: date, start_min: 600})
    {:ok, _} = Salon.update_appointment(v.venue.id, appt.id, %{status: "cancelled"})

    {:ok, %{slots: slots}} = Salon.availability(v.venue.id, [v.service.id], "any", date)
    assert Enum.any?(slots, &(&1.start_min == 600))
  end

  test "reactivating a cancelled appointment re-checks the slot", %{v: v, date: date} do
    first = appointment_fixture(v, %{date: date, start_min: 600})
    {:ok, _} = Salon.update_appointment(v.venue.id, first.id, %{status: "cancelled"})

    # The freed slot is taken by someone else...
    _second = appointment_fixture(v, %{date: date, start_min: 600})

    # ...so bringing the first appointment back must be refused, not 500.
    assert {:error, msg} = Salon.update_appointment(v.venue.id, first.id, %{status: "booked"})
    assert msg =~ "overlaps"

    # Reactivating into a free moment still works.
    {:ok, _} = Salon.update_appointment(v.venue.id, first.id, %{status: "booked", start_min: 720})
  end

  test "an appointment cannot be checked out twice", %{v: v, date: date} do
    appt = appointment_fixture(v, %{date: date, start_min: 600})

    assert {:ok, sale} = Salon.checkout(v.venue.id, [appt.id], 1_000, "cash")
    assert sale.total_cents == 21_000

    assert {:error, msg} = Salon.checkout(v.venue.id, [appt.id], 0, "cash")
    assert msg =~ "already been checked out"

    assert Repo.aggregate(
             from(s in Blastek.Salon.Sale, where: s.venue_id == ^v.venue.id),
             :count
           ) == 1
  end

  test "booking refs are unique across many bookings", %{v: v, client_id: client_id, date: date} do
    refs =
      for start <- [540, 600, 660, 720, 780] do
        {:ok, booking} =
          Salon.book(v.venue.id, %{
            service_ids: [v.service.id],
            staff_id: "any",
            date: date,
            start_min: start,
            client_id: client_id
          })

        booking.booking_ref
      end

    assert length(Enum.uniq(refs)) == 5
  end
end
