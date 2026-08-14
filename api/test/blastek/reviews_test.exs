defmodule Blastek.ReviewsTest do
  @moduledoc """
  Verified reviews, replies and moderation (E10 / F0.8).

  The tests worth reading here are the ones about *what stays visible*.
  Eligibility is a set of rules and rules are easy to assert; the interesting
  claims are that flagging does not conceal, that hiding removes a review from
  the rating as well as from the page, and that the denormalized average is the
  same number as counting by hand.
  """
  use Blastek.DataCase, async: true
  use Oban.Testing, repo: Blastek.Repo

  import Blastek.Fixtures

  alias Blastek.Clock
  alias Blastek.Notifications
  alias Blastek.Repo
  alias Blastek.Salon
  alias Blastek.Salon.Review
  alias Blastek.Salon.Reviews
  alias Blastek.Venues

  setup do
    v = venue_fixture("Review Salon #{System.unique_integer([:positive])}")
    %{v: v}
  end

  # A visit that actually happened, and the reason it is written by hand.
  #
  # `Salon.book/2` goes through `availability/4`, which will not offer a date in
  # the past — correctly. A review is about a visit that has already happened,
  # so every fixture here needs a booking the public flow cannot create. The
  # rows are the same rows; only the path to them differs.
  #
  # `checkout/4` is real, though, and used on purpose: the review invite hangs
  # off it, and a fixture that set `status: "completed"` directly would not
  # notice the hook coming loose.
  defp visit(v, opts \\ []) do
    date = opts[:date] || Date.add(Clock.today(), -1)
    service_ids = opts[:service_ids] || [v.service.id]
    ref = "BK-T#{System.unique_integer([:positive])}"
    client_id = opts[:client_id] || v.client.id

    {appointments, _} =
      Enum.map_reduce(service_ids, opts[:start_min] || 600, fn service_id, cursor ->
        service = Salon.get_service!(v.venue.id, service_id)

        appointment =
          Repo.insert!(%Salon.Appointment{
            venue_id: v.venue.id,
            booking_ref: ref,
            client_id: client_id,
            staff_id: v.staff.id,
            service_id: service_id,
            date: date,
            start_min: cursor,
            end_min: cursor + service.duration_min,
            price_cents: service.price_cents,
            status: "confirmed",
            source: "online"
          })

        {appointment, cursor + service.duration_min}
      end)

    {:ok, _sale} =
      Salon.checkout(v.venue.id, Enum.map(appointments, & &1.id), 0, "cash")

    ref
  end

  defp review!(v, ref, rating, opts \\ []) do
    {:ok, review} =
      Reviews.create(opts[:client_id] || v.client.id, ref, %{
        rating: rating,
        comment: opts[:comment] || "",
        locale: opts[:locale] || "fr"
      })

    review
  end

  defp rating_of(venue_id) do
    venue = Repo.get(Venues.Venue, venue_id)
    {venue.rating_avg, venue.rating_count}
  end

  describe "eligibility" do
    test "a completed visit of your own, within the fortnight, is reviewable", ctx do
      ref = visit(ctx.v)
      assert {:ok, appointment} = Reviews.eligibility(ctx.v.client.id, ref)
      assert appointment.booking_ref == ref
    end

    test "somebody else's booking is not yours to review", ctx do
      ref = visit(ctx.v)

      {:ok, other} =
        Salon.create_client(ctx.v.venue.id, %{first_name: "Someone", last_name: "Else"})

      assert {:error, :not_found} = Reviews.eligibility(other.id, ref)
    end

    test "an appointment that has not happened cannot be reviewed", ctx do
      appointment = appointment_fixture(ctx.v)

      assert {:error, :not_completed} =
               Reviews.eligibility(ctx.v.client.id, appointment.booking_ref)
    end

    test "the window closes 14 days after the visit", ctx do
      ref = visit(ctx.v, date: Date.add(Clock.today(), -15))
      assert {:error, :too_old} = Reviews.eligibility(ctx.v.client.id, ref)
    end

    test "on the fourteenth day it is still open", ctx do
      ref = visit(ctx.v, date: Date.add(Clock.today(), -14))
      assert {:ok, _} = Reviews.eligibility(ctx.v.client.id, ref)
    end

    test "one review per booking", ctx do
      ref = visit(ctx.v)
      review!(ctx.v, ref, 5)
      assert {:error, :already_reviewed} = Reviews.eligibility(ctx.v.client.id, ref)
      assert {:error, :already_reviewed} = Reviews.create(ctx.v.client.id, ref, %{rating: 1})
    end

    test "a suspended venue's reviews are frozen", ctx do
      ref = visit(ctx.v)
      {:ok, _} = Venues.update_venue(ctx.v.venue, %{status: "suspended"})
      assert {:error, :frozen} = Reviews.eligibility(ctx.v.client.id, ref)
    end

    test "a multi-service visit is one booking and so one review", ctx do
      {:ok, second} =
        Salon.create_service(
          ctx.v.venue.id,
          %{
            category_id: ctx.v.category.id,
            name: "Blow dry",
            duration_min: 30,
            price_cents: 8_000
          },
          nil
        )

      {:ok, _} =
        Salon.update_staff(ctx.v.venue.id, ctx.v.staff.id, %{}, nil, [
          ctx.v.service.id,
          second.id
        ])

      ref = visit(ctx.v, service_ids: [ctx.v.service.id, second.id])

      assert Repo.aggregate(
               from(a in Salon.Appointment, where: a.booking_ref == ^ref),
               :count
             ) == 2

      review!(ctx.v, ref, 4)
      assert {:error, :already_reviewed} = Reviews.eligibility(ctx.v.client.id, ref)
    end
  end

  describe "creating" do
    test "the venue comes from the visit, not from the caller", ctx do
      other = venue_fixture("Other Salon #{System.unique_integer([:positive])}")
      ref = visit(ctx.v)

      review = review!(ctx.v, ref, 5)

      assert review.venue_id == ctx.v.venue.id
      refute review.venue_id == other.venue.id
      assert review.client_id == ctx.v.client.id
      assert review.status == "visible"
    end

    test "a rating with no comment is allowed", ctx do
      review = review!(ctx.v, visit(ctx.v), 4)
      assert review.rating == 4
      assert review.comment == ""
    end

    test "the comment's own language is stored, not the reader's", ctx do
      review = review!(ctx.v, visit(ctx.v), 5, comment: "ممتاز", locale: "ar")
      assert review.locale == "ar"
    end

    test "a rating outside 1..5 is refused", ctx do
      ref = visit(ctx.v)
      assert {:error, %Ecto.Changeset{}} = Reviews.create(ctx.v.client.id, ref, %{rating: 6})
    end
  end

  describe "the denormalized rating" do
    test "is the mean of the visible reviews, maintained on write", ctx do
      assert rating_of(ctx.v.venue.id) == {0.0, 0}

      review!(ctx.v, visit(ctx.v, start_min: 600), 5)
      assert rating_of(ctx.v.venue.id) == {5.0, 1}

      {:ok, second} =
        Salon.create_client(ctx.v.venue.id, %{first_name: "Nadia", last_name: "Alaoui"})

      ref = visit(ctx.v, client_id: second.id, start_min: 700)
      review!(ctx.v, ref, 2, client_id: second.id)

      assert rating_of(ctx.v.venue.id) == {3.5, 2}
    end

    test "recompute converges — running it twice changes nothing", ctx do
      review!(ctx.v, visit(ctx.v), 3)
      first = Reviews.recompute(ctx.v.venue.id)
      assert Reviews.recompute(ctx.v.venue.id) == first
      assert first == {3.0, 1}
    end

    test "a hidden review stops counting", ctx do
      review = review!(ctx.v, visit(ctx.v), 1)
      assert rating_of(ctx.v.venue.id) == {1.0, 1}

      {:ok, _} = Reviews.moderate(review.id, "hide", "abusive")
      assert rating_of(ctx.v.venue.id) == {0.0, 0}
    end

    test "keeping a hidden review puts it back", ctx do
      review = review!(ctx.v, visit(ctx.v), 4)
      {:ok, _} = Reviews.moderate(review.id, "hide", "spam")
      assert rating_of(ctx.v.venue.id) == {0.0, 0}

      {:ok, restored} = Reviews.moderate(review.id, "keep")
      assert restored.status == "visible"
      assert restored.hidden_reason == ""
      assert rating_of(ctx.v.venue.id) == {4.0, 1}
    end
  end

  describe "flagging does not conceal" do
    test "a flagged review stays on the page and in the rating", ctx do
      review = review!(ctx.v, visit(ctx.v), 1, comment: "Terrible")

      {:ok, flagged} = Reviews.flag(ctx.v.venue.id, review.id, "abusive")

      assert flagged.status == "flagged"
      assert flagged.flagged_reason == "abusive"
      # The whole point: reporting queues it, it does not remove it.
      assert [%Review{id: id}] = Reviews.list(ctx.v.venue.id)
      assert id == review.id
      assert rating_of(ctx.v.venue.id) == {1.0, 1}
      assert [%Review{id: ^id}] = Reviews.flagged_queue()
    end

    test "a hidden review is excluded from the public list", ctx do
      review = review!(ctx.v, visit(ctx.v), 2)
      {:ok, _} = Reviews.moderate(review.id, "hide", "off_topic")

      assert Reviews.list(ctx.v.venue.id) == []
      assert Reviews.count(ctx.v.venue.id) == 0
      # Still there for the venue's own records and for an appeal.
      assert length(Reviews.list(ctx.v.venue.id, statuses: :all)) == 1
    end

    test "a venue cannot flag another venue's review", ctx do
      other = venue_fixture("Nosy Salon #{System.unique_integer([:positive])}")
      review = review!(ctx.v, visit(ctx.v), 1)

      assert {:error, :not_found} = Reviews.flag(other.venue.id, review.id, "abusive")
      assert Repo.get(Review, review.id).status == "visible"
    end

    test "hiding tells the author which rule they broke, not the moderator's note", ctx do
      {:ok, _} = Salon.update_client(ctx.v.venue.id, ctx.v.client.id, %{phone: "0612345678"})

      review = review!(ctx.v, visit(ctx.v), 1)
      {:ok, _} = Reviews.moderate(review.id, "hide", "abusive")

      job =
        all_enqueued(worker: Notifications.Worker)
        |> Enum.find(&(&1.args["template"] == "review_hidden"))

      assert job, "the author was not told their review came down"
      # The category, not the note. A moderator writing "owner says she is a
      # competitor" must not have that sent to the person they wrote it about.
      assert job.args["assigns"]["reason"] == "propos injurieux"
      refute job.args["assigns"]["reason"] == "abusive"
    end
  end

  describe "the owner's reply" do
    test "shows under the review and can be corrected for 48 hours", ctx do
      review = review!(ctx.v, visit(ctx.v), 3, comment: "Long wait")

      {:ok, replied} = Reviews.reply(ctx.v.venue.id, review.id, "Sorry — we were short-staffed.")
      assert replied.reply == "Sorry — we were short-staffed."
      assert replied.reply_at

      {:ok, edited} = Reviews.reply(ctx.v.venue.id, review.id, "Sorry. We have hired since.")
      assert edited.reply == "Sorry. We have hired since."
    end

    test "locks 48 hours after the reply was written", ctx do
      review = review!(ctx.v, visit(ctx.v), 3)
      {:ok, replied} = Reviews.reply(ctx.v.venue.id, review.id, "Thank you.")

      # Backdated: what a customer read two days ago must not be rewritten into
      # something they never saw.
      replied
      |> Ecto.Changeset.change(reply_at: NaiveDateTime.add(Clock.now(), -49 * 3600, :second))
      |> Repo.update!()

      assert {:error, :reply_locked} = Reviews.reply(ctx.v.venue.id, review.id, "Actually, no.")
      assert Repo.get(Review, review.id).reply == "Thank you."
    end

    test "a venue cannot reply to another venue's review", ctx do
      other = venue_fixture("Rival Salon #{System.unique_integer([:positive])}")
      review = review!(ctx.v, visit(ctx.v), 5)

      assert {:error, :not_found} = Reviews.reply(other.venue.id, review.id, "You are welcome.")
    end
  end

  describe "the published author name" do
    test "is a first name and a last initial, never the full name", ctx do
      {:ok, client} =
        Salon.create_client(ctx.v.venue.id, %{first_name: "Sara", last_name: "Benali"})

      ref = visit(ctx.v, client_id: client.id)
      review = review!(ctx.v, ref, 5, client_id: client.id)

      assert Reviews.author_name(Repo.preload(review, :client)) == "Sara B."
    end

    test "falls back rather than publishing an empty byline", _ctx do
      # `create_client` requires a first name; a row with neither is what an
      # import or an older record can still look like.
      assert Reviews.author_name(%Salon.Client{first_name: "", last_name: ""}) == "Client"
      assert Reviews.author_name(%Salon.Client{first_name: "Yassine", last_name: ""}) == "Yassine"
      assert Reviews.author_name(nil) == "Client"
    end
  end

  describe "prompts on the account page" do
    test "one entry per booking, newest first, with its venue", ctx do
      ref = visit(ctx.v, date: Date.add(Clock.today(), -2))

      assert [%{appointment: appointment, venue: venue}] = Reviews.reviewable([ctx.v.client.id])
      assert appointment.booking_ref == ref
      assert venue.id == ctx.v.venue.id
    end

    test "a reviewed visit stops being offered", ctx do
      ref = visit(ctx.v)
      assert length(Reviews.reviewable([ctx.v.client.id])) == 1

      review!(ctx.v, ref, 5)
      assert Reviews.reviewable([ctx.v.client.id]) == []
    end

    test "a visit past the window stops being offered", ctx do
      visit(ctx.v, date: Date.add(Clock.today(), -20))
      assert Reviews.reviewable([ctx.v.client.id]) == []
    end
  end

  describe "seeded reviews" do
    test "are purged when the venue goes live, and the rating with them", ctx do
      # What the seeds leave behind: a rating with no visit attached to it.
      Repo.insert!(%Review{
        venue_id: ctx.v.venue.id,
        rating: 5,
        comment: "Superbe salon !",
        status: "visible"
      })

      Reviews.recompute(ctx.v.venue.id)
      assert rating_of(ctx.v.venue.id) == {5.0, 1}

      real = review!(ctx.v, visit(ctx.v), 3)

      assert Reviews.purge_seeded(ctx.v.venue.id) == 1
      assert [%Review{id: id}] = Reviews.list(ctx.v.venue.id)
      assert id == real.id
      assert rating_of(ctx.v.venue.id) == {3.0, 1}
    end

    test "approving a venue purges them", ctx do
      admin = admin_fixture("purge-#{System.unique_integer([:positive])}@example.com")
      {:ok, pending} = Venues.update_venue(ctx.v.venue, %{status: "pending"})

      Repo.insert!(%Review{venue_id: pending.id, rating: 5, comment: "Fake", status: "visible"})

      {:ok, _} = Venues.Onboarding.approve(pending.id, admin)

      assert Reviews.list(pending.id, statuses: :all) == []
      assert rating_of(pending.id) == {0.0, 0}
    end
  end
end
