defmodule Blastek.ReviewInvitesTest do
  @moduledoc """
  Asking for the review, and knowing when to stop (E10-T3 / F0.8).

  Two claims are load-bearing here and neither is obvious from reading the
  scheduler: that a three-service visit produces **one** pair of messages rather
  than three, and that the T+24h nag re-checks at firing time whether the
  customer has already answered. Both are about not making the salon a nuisance,
  which is the constraint F0.8 actually places on this feature.
  """
  use Blastek.DataCase, async: true
  use Oban.Testing, repo: Blastek.Repo

  import Blastek.Fixtures

  alias Blastek.Clock
  alias Blastek.Notifications.ActionToken
  alias Blastek.Notifications.Reminders
  alias Blastek.Notifications.ReviewInvites
  alias Blastek.Notifications.Worker
  alias Blastek.Repo
  alias Blastek.Salon
  alias Blastek.Salon.Reviews
  alias Blastek.Venues

  setup do
    v = venue_fixture("Invite Salon #{System.unique_integer([:positive])}")
    {:ok, client} = Salon.update_client(v.venue.id, v.client.id, %{phone: "0612345678"})
    %{v: %{v | client: client}}
  end

  defp checkout(v, opts \\ []) do
    ref = "BK-I#{System.unique_integer([:positive])}"
    service_ids = opts[:service_ids] || [v.service.id]

    {appointments, _} =
      Enum.map_reduce(service_ids, 600, fn service_id, cursor ->
        service = Salon.get_service!(v.venue.id, service_id)

        appointment =
          Repo.insert!(%Salon.Appointment{
            venue_id: v.venue.id,
            booking_ref: ref,
            client_id: opts[:client_id] || v.client.id,
            staff_id: v.staff.id,
            service_id: service_id,
            date: opts[:date] || Date.add(Clock.today(), -1),
            start_min: cursor,
            end_min: cursor + service.duration_min,
            price_cents: service.price_cents,
            status: "confirmed"
          })

        {appointment, cursor + service.duration_min}
      end)

    {:ok, _} = Salon.checkout(v.venue.id, Enum.map(appointments, & &1.id), 0, "cash")
    %{ref: ref, appointments: appointments}
  end

  defp review_jobs do
    templates = Enum.map(ReviewInvites.templates(), &to_string/1)

    all_enqueued(worker: Worker)
    |> Enum.filter(&(&1.args["template"] in templates))
  end

  describe "scheduling" do
    test "checkout queues the invite and one reminder", ctx do
      checkout(ctx.v)

      assert Enum.map(review_jobs(), & &1.args["template"]) |> Enum.sort() ==
               ["review_invite", "review_reminder"]
    end

    test "at T+2h and T+24h", ctx do
      before = DateTime.utc_now()
      checkout(ctx.v)

      offsets =
        review_jobs()
        |> Map.new(fn job ->
          {job.args["template"], round(DateTime.diff(job.scheduled_at, before) / 3600)}
        end)

      assert offsets["review_invite"] == 2
      assert offsets["review_reminder"] == 24
    end

    test "a three-service visit is still one afternoon and one pair of messages", ctx do
      {:ok, second} =
        Salon.create_service(
          ctx.v.venue.id,
          %{category_id: ctx.v.category.id, name: "Beard", duration_min: 30, price_cents: 5_000},
          nil
        )

      {:ok, third} =
        Salon.create_service(
          ctx.v.venue.id,
          %{category_id: ctx.v.category.id, name: "Wash", duration_min: 15, price_cents: 3_000},
          nil
        )

      checkout(ctx.v, service_ids: [ctx.v.service.id, second.id, third.id])

      assert length(review_jobs()) == 2
    end

    test "a client with no phone and no email gets nothing", ctx do
      {:ok, silent} = Salon.create_client(ctx.v.venue.id, %{first_name: "Walk", last_name: "In"})

      checkout(ctx.v, client_id: silent.id)

      assert review_jobs() == []
    end

    test "the message carries a working review link", ctx do
      %{appointments: [appointment]} = checkout(ctx.v)

      job = Enum.find(review_jobs(), &(&1.args["template"] == "review_invite"))
      url = job.args["assigns"]["review_url"]

      assert url =~ "/review/"
      token = url |> String.split("/review/") |> List.last()
      assert {:ok, id, :review} = ActionToken.verify(token)
      assert id == appointment.id
    end
  end

  describe "the re-check as the job fires" do
    test "a booking already reviewed is not asked about again", ctx do
      %{ref: ref, appointments: [appointment]} = checkout(ctx.v)

      assert {:ok, _assigns} =
               Reminders.still_due(:review_reminder, %{"appointment_id" => appointment.id})

      {:ok, _} = Reviews.create(ctx.v.client.id, ref, %{rating: 5})

      assert {:skip, :already_reviewed} =
               Reminders.still_due(:review_reminder, %{"appointment_id" => appointment.id})
    end

    test "a suspended venue stops asking", ctx do
      %{appointments: [appointment]} = checkout(ctx.v)
      {:ok, _} = Venues.update_venue(ctx.v.venue, %{status: "suspended"})

      assert {:skip, :venue_frozen} =
               Reminders.still_due(:review_invite, %{"appointment_id" => appointment.id})
    end

    test "the venue name is re-read as the job fires, not frozen at checkout", ctx do
      %{appointments: [appointment]} = checkout(ctx.v)
      {:ok, _} = Venues.update_venue(ctx.v.venue, %{name: "Renamed Salon"})

      assert {:ok, assigns} =
               Reminders.still_due(:review_invite, %{"appointment_id" => appointment.id})

      assert assigns.venue == "Renamed Salon"
    end
  end

  describe "cancelling" do
    test "a review drops the pending nag", ctx do
      %{ref: ref} = checkout(ctx.v)
      assert length(review_jobs()) == 2

      assert ReviewInvites.cancel(ref) == 2
      assert review_jobs() == []
    end

    test "cancelling one booking leaves another's alone", ctx do
      %{ref: first} = checkout(ctx.v)
      checkout(ctx.v, date: Date.add(Clock.today(), -2))

      assert ReviewInvites.cancel(first) == 2
      assert length(review_jobs()) == 2
    end
  end
end
