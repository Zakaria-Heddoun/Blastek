defmodule Blastek.RemindersTest do
  @moduledoc """
  What gets scheduled when a booking is made, and what fires when it comes due
  (E6-T6, E6-T7 / F0.10).

  Oban runs in `:manual` mode, so these assert on the *jobs* — which is the
  honest thing to assert on anyway: a reminder for tomorrow evening is a row,
  and whether it eventually sends is `still_due/2`'s business, tested
  separately.
  """
  use Blastek.DataCase, async: true
  use Oban.Testing, repo: Blastek.Repo

  import Blastek.Fixtures

  alias Blastek.Notifications.Reminders
  alias Blastek.Notifications.Worker
  alias Blastek.Salon
  alias Blastek.Venues

  setup do
    v = venue_fixture("Reminder Salon #{System.unique_integer([:positive])}")

    %{user: owner} =
      member_fixture(v.venue, "owner", "rem-#{System.unique_integer([:positive])}@example.com")

    %{v: v, owner: owner}
  end

  defp book(v, days_ahead \\ 5) do
    date = Date.add(Date.utc_today(), days_ahead)

    {:ok, %{slots: [%{start_min: start_min} | _]}} =
      Salon.availability(v.venue.id, [v.service.id], "any", date)

    {:ok, result} =
      Salon.book(v.venue.id, %{
        client_id: v.client.id,
        service_ids: [v.service.id],
        staff_id: "any",
        date: date,
        start_min: start_min
      })

    hd(result.appointments)
  end

  defp jobs_for(appointment) do
    all_enqueued(worker: Worker)
    |> Enum.filter(&(&1.args["appointment_id"] == appointment.id))
  end

  defp templates_for(appointment) do
    appointment |> jobs_for() |> Enum.map(& &1.args["template"]) |> Enum.sort()
  end

  describe "booking" do
    test "tells the customer and the salon, and schedules both reminders", ctx do
      appointment = book(ctx.v)

      assert templates_for(appointment) == [
               "booking_confirmed_customer",
               "booking_confirmed_salon",
               "reminder_24h",
               "reminder_3h"
             ]
    end

    test "a venue that vets its bookings sends a request, not a confirmation", ctx do
      {:ok, _} =
        Venues.update_settings(Venues.get_venue(ctx.v.venue.id), %{
          "instant_confirmation" => false
        })

      appointment = book(ctx.v)

      # Telling somebody their appointment is "confirmed" while the salon has
      # not looked at it is the small lie that produces a phone call.
      assert "booking_requested_customer" in templates_for(appointment)
      assert "booking_requested_salon" in templates_for(appointment)
      refute "booking_confirmed_customer" in templates_for(appointment)
    end

    test "the customer's message carries a one-tap cancel link, the salon's does not", ctx do
      appointment = book(ctx.v)
      jobs = jobs_for(appointment)

      customer = Enum.find(jobs, &(&1.args["template"] == "booking_confirmed_customer"))
      salon = Enum.find(jobs, &(&1.args["template"] == "booking_confirmed_salon"))

      assert customer.args["assigns"]["cancel_url"] =~ "/a/cancel/"
      refute Map.has_key?(salon.args["assigns"], "cancel_url")
    end

    test "reminders already in the past are not scheduled", ctx do
      # Booked for later today: T-24h was yesterday, and a reminder that arrives
      # after the fact teaches people to ignore the next one.
      today = Date.utc_today()

      case Salon.availability(ctx.v.venue.id, [ctx.v.service.id], "any", today) do
        {:ok, %{slots: [%{start_min: start_min} | _]}} ->
          {:ok, result} =
            Salon.book(ctx.v.venue.id, %{
              client_id: ctx.v.client.id,
              service_ids: [ctx.v.service.id],
              staff_id: "any",
              date: today,
              start_min: start_min
            })

          appointment = hd(result.appointments)
          refute "reminder_24h" in templates_for(appointment)

        _ ->
          # Nothing bookable left today; the past-reminder path is covered by
          # `schedule/1` returning [] below.
          past = appointment_fixture(ctx.v, %{date: Date.add(Date.utc_today(), -3)})
          assert Reminders.schedule(past) == []
      end
    end

    test "a venue can turn a reminder off entirely", ctx do
      {:ok, _} =
        Venues.update_settings(Venues.get_venue(ctx.v.venue.id), %{"reminder_3h_min" => 0})

      appointment = book(ctx.v)

      assert "reminder_24h" in templates_for(appointment)
      refute "reminder_3h" in templates_for(appointment)
    end

    test "a venue can move the offsets", ctx do
      {:ok, _} =
        Venues.update_settings(Venues.get_venue(ctx.v.venue.id), %{"reminder_24h_min" => 48 * 60})

      appointment = book(ctx.v)
      job = jobs_for(appointment) |> Enum.find(&(&1.args["template"] == "reminder_24h"))

      starts_at =
        Blastek.Notifications.Format.starts_at(appointment.date, appointment.start_min)

      # Two days before, not one.
      hours_before = NaiveDateTime.diff(starts_at, DateTime.to_naive(job.scheduled_at), :hour)
      assert hours_before in 46..49
    end
  end

  describe "cancellation" do
    test "removes the pending reminders", ctx do
      appointment = book(ctx.v)
      assert length(jobs_for(appointment)) == 4

      {:ok, _} =
        Salon.update_appointment(ctx.v.venue.id, appointment.id, %{
          status: "cancelled",
          actor: :customer
        })

      refute "reminder_24h" in templates_for(appointment)
      refute "reminder_3h" in templates_for(appointment)
    end

    test "tells the salon when the customer cancels", ctx do
      appointment = book(ctx.v)

      {:ok, _} =
        Salon.update_appointment(ctx.v.venue.id, appointment.id, %{
          status: "cancelled",
          actor: :customer
        })

      assert "cancelled_by_customer" in templates_for(appointment)
      refute "cancelled_by_salon" in templates_for(appointment)
    end

    test "tells the customer when the salon cancels", ctx do
      appointment = book(ctx.v)

      {:ok, _} =
        Salon.update_appointment(ctx.v.venue.id, appointment.id, %{status: "cancelled"})

      assert "cancelled_by_salon" in templates_for(appointment)
      refute "cancelled_by_customer" in templates_for(appointment)
    end

    test "a reminder that escaped deletion still refuses to fire", ctx do
      # The delete is an optimisation; this is the guarantee. A job already
      # fetched by a worker cannot be deleted, so the check has to be at firing
      # time or a cancelled customer gets reminded anyway.
      appointment = book(ctx.v)

      {:ok, _} =
        Salon.update_appointment(ctx.v.venue.id, appointment.id, %{status: "cancelled"})

      assert {:skip, :not_live} =
               Reminders.still_due(:reminder_24h, %{"appointment_id" => appointment.id})
    end

    test "and a reminder for an appointment that is still on does fire", ctx do
      appointment = book(ctx.v)

      assert {:ok, assigns} =
               Reminders.still_due(:reminder_24h, %{"appointment_id" => appointment.id})

      assert assigns.venue == ctx.v.venue.name
      assert assigns.cancel_url =~ "/a/cancel/"
    end
  end

  describe "rescheduling" do
    test "tells the customer and re-times the reminders", ctx do
      appointment = book(ctx.v, 5)
      moved_to = Date.add(Date.utc_today(), 9)

      {:ok, _} =
        Salon.update_appointment(ctx.v.venue.id, appointment.id, %{date: moved_to})

      assert "rescheduled" in templates_for(appointment)

      # The old reminders named the old evening, so they are replaced rather
      # than left to fire against a slot that moved four days.
      job = jobs_for(appointment) |> Enum.find(&(&1.args["template"] == "reminder_24h"))
      assert DateTime.to_date(job.scheduled_at) == Date.add(moved_to, -1)
    end

    test "a reminder renders the new time, not the time it was queued with", ctx do
      appointment = book(ctx.v, 5)
      moved_to = Date.add(Date.utc_today(), 9)

      {:ok, moved} = Salon.update_appointment(ctx.v.venue.id, appointment.id, %{date: moved_to})

      {:ok, assigns} = Reminders.still_due(:reminder_24h, %{"appointment_id" => moved.id})

      assert assigns.when ==
               Blastek.Notifications.Format.date_time(moved_to, moved.start_min, "fr")
    end
  end

  describe "the worker" do
    test "discards a reminder for a cancelled appointment without sending", ctx do
      appointment = book(ctx.v)
      {:ok, _} = Salon.update_appointment(ctx.v.venue.id, appointment.id, %{status: "cancelled"})

      job = %Oban.Job{
        args: %{
          "template" => "reminder_24h",
          "to" => "+212600000000",
          "locale" => "fr",
          "assigns" => %{},
          "appointment_id" => appointment.id
        }
      }

      assert {:ok, {:skipped, :not_live}} = Worker.perform(job)
      assert Blastek.Notifications.Collector.delivered() == []
    end

    test "sends one that is still due", ctx do
      appointment = book(ctx.v)

      job = %Oban.Job{
        args: %{
          "template" => "reminder_24h",
          "to" => "+212600000001",
          "locale" => "fr",
          "assigns" => %{},
          "appointment_id" => appointment.id
        }
      }

      assert {:ok, _log_id} = Worker.perform(job)
      assert Blastek.Notifications.Collector.last().body =~ ctx.v.venue.name
    end

    test "still sends a cancellation notice for a cancelled appointment", ctx do
      # The gate that stops reminders firing for a cancelled booking must not
      # also stop the message *announcing* that cancellation — which is the one
      # the other party has no other way of learning.
      appointment = book(ctx.v)
      {:ok, _} = Salon.update_appointment(ctx.v.venue.id, appointment.id, %{status: "cancelled"})

      job = %Oban.Job{
        args: %{
          "template" => "cancelled_by_salon",
          "to" => "+212600000003",
          "locale" => "fr",
          "assigns" => %{},
          "appointment_id" => appointment.id
        }
      }

      assert {:ok, log_id} = Worker.perform(job)
      assert is_integer(log_id)

      body = Blastek.Notifications.Collector.last().body
      assert body =~ ctx.v.venue.name
      assert body =~ "annuler"
    end

    test "cancels rather than retries a template that no longer exists" do
      job = %Oban.Job{
        args: %{
          "template" => "a_template_from_a_rolled_back_build",
          "to" => "+212600000002",
          "locale" => "fr",
          "assigns" => %{},
          "appointment_id" => nil
        }
      }

      assert {:cancel, "unknown template"} = Worker.perform(job)
    end
  end
end
