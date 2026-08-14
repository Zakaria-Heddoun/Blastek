defmodule Blastek.Salon.Reviews do
  @moduledoc """
  Verified reviews, owner replies and moderation (E10-T2 / F0.8).

  ## What "verified" buys, and what it costs

  A review may only be written by the client who kept the appointment, about
  the booking they kept, once. That is three separate checks and all three are
  enforced here rather than in the GraphQL layer, because the same rule has to
  hold for a signed WhatsApp link, a logged-in customer on the account page,
  and anything added later.

  The cost is that reviews are rarer than on a site that lets anyone type. That
  is the trade F0.8 makes deliberately: "ratings I read reflect real visits
  only" is the feature.

  ## Flagged is still public

  `flagged` means an owner has reported a review, not that it has gone. It
  stays visible and keeps counting towards the rating until an admin hides it.

  Doing it the other way — flag hides pending review — would hand every owner a
  button that removes any review they dislike for as long as the moderation
  queue is backed up. The queue is the salon's remedy; concealment is not.

  ## The rating is denormalized, and this module owns it

  `venues.rating_avg` / `rating_count` are recomputed from scratch after every
  write that could move them. Recomputing rather than incrementing is a
  deliberate choice: an increment has to be right on create, hide, unhide,
  moderate and delete, and being wrong once leaves a number that never
  self-corrects. A recompute is one aggregate over a handful of rows, indexed
  by `(venue_id, status)`, and it is *idempotent* — running it twice, or after
  a crash, converges.
  """
  import Ecto.Query
  import Blastek.Scope

  alias Blastek.Clock
  alias Blastek.Repo
  alias Blastek.Salon.Appointment
  alias Blastek.Salon.Client
  alias Blastek.Salon.Review
  alias Blastek.Venues.Venue

  @public ~w(visible flagged)

  @doc "Statuses a customer reading a venue page can see."
  def public_statuses, do: @public

  # F0.8: a review has to arrive while the visit is still fresh in mind, and a
  # fortnight is long enough to cover a holiday.
  @window_days 14

  ## ---------- eligibility ----------

  @doc """
  Whether `client_id` may review the booking `booking_ref`, and why not.

  Returns `{:ok, appointment}` — one of the appointments in the booking, for
  the venue and the date — or `{:error, reason}` where reason is one of
  `:not_found`, `:not_completed`, `:too_old`, `:already_reviewed`, `:frozen`.

  Separate from `create/2` because both the review page and the account list
  need the answer *before* anybody types a comment. Being told a review is too
  late after writing it is the kind of thing that loses a customer twice.
  """
  def eligibility(client_id, booking_ref) when is_binary(booking_ref) do
    appointments =
      Repo.all(
        from a in Appointment,
          where: a.booking_ref == ^booking_ref,
          order_by: [asc: a.start_min]
      )

    with {:ok, appointment} <- one_of(appointments),
         :ok <- owned_by(appointment, client_id),
         :ok <- completed(appointments),
         :ok <- recent(appointment),
         :ok <- unreviewed(booking_ref),
         :ok <- venue_live(appointment.venue_id) do
      {:ok, appointment}
    end
  end

  def eligibility(_client_id, _booking_ref), do: {:error, :not_found}

  defp one_of([]), do: {:error, :not_found}
  defp one_of([appointment | _]), do: {:ok, appointment}

  # The client on the appointment, not the user session: a receptionist booking
  # on the phone creates a client row, and it is that client's visit.
  defp owned_by(%Appointment{client_id: client_id}, client_id) when not is_nil(client_id), do: :ok
  defp owned_by(_appointment, _client_id), do: {:error, :not_found}

  # Every appointment in the booking, because a visit where two of three
  # services were done and one was cancelled is still a visit that happened.
  defp completed(appointments) do
    if Enum.any?(appointments, &(&1.status == "completed")),
      do: :ok,
      else: {:error, :not_completed}
  end

  defp recent(%Appointment{date: date}) do
    if Date.diff(Clock.today(), date) <= @window_days, do: :ok, else: {:error, :too_old}
  end

  defp unreviewed(booking_ref) do
    if Repo.exists?(from r in Review, where: r.booking_ref == ^booking_ref),
      do: {:error, :already_reviewed},
      else: :ok
  end

  # F0.8 edge case: a suspended venue's reviews are frozen. Nothing is hidden —
  # what is already there stays readable — but the venue is not in a position to
  # reply, and a one-sided record is worse than none.
  defp venue_live(venue_id) do
    case Repo.get(Venue, venue_id) do
      %Venue{status: "suspended"} -> {:error, :frozen}
      %Venue{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Bookings this client could review right now, newest visit first.

  Drives the "leave a review" prompts on the account page. One row per booking,
  not per appointment, each with its venue attached — the prompt says which
  salon, and a card per service of a three-service visit would ask for three
  reviews of one afternoon.
  """
  def reviewable(client_ids) when is_list(client_ids) do
    cutoff = Date.add(Clock.today(), -@window_days)

    candidates =
      Repo.all(
        from a in Appointment,
          where: a.client_id in ^client_ids,
          where: a.status == "completed",
          where: a.date >= ^cutoff,
          where: a.booking_ref != "",
          order_by: [desc: a.date, desc: a.start_min],
          preload: [:service]
      )

    refs = Enum.map(candidates, & &1.booking_ref)

    reviewed =
      from(r in Review, where: r.booking_ref in ^refs, select: r.booking_ref)
      |> Repo.all()
      |> MapSet.new()

    candidates
    |> Enum.reject(&MapSet.member?(reviewed, &1.booking_ref))
    |> Enum.uniq_by(& &1.booking_ref)
    |> with_venues()
  end

  def reviewable(_), do: []

  # `Appointment` has no `belongs_to :venue` — venue_id is a bare field, because
  # every other query in the salon context reaches venues through the scope.
  # One query for the handful of venues involved, rather than teaching the
  # schema a new association for one screen.
  defp with_venues([]), do: []

  defp with_venues(appointments) do
    venues =
      from(v in Venue, where: v.id in ^Enum.map(appointments, & &1.venue_id))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(appointments, &%{appointment: &1, venue: Map.get(venues, &1.venue_id)})
  end

  ## ---------- reading ----------

  @doc """
  Public reviews for a venue, newest first.

  Hidden ones are excluded here rather than by every caller — F0.8 says
  "hidden reviews excluded everywhere", and a filter each caller has to
  remember is one a caller will eventually forget.
  """
  def list(venue_id, opts \\ []) do
    limit = min(opts[:limit] || 20, 100)

    from(r in scope(Review, venue_id),
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit,
      offset: ^(opts[:offset] || 0),
      preload: [:client]
    )
    |> apply_status(opts[:statuses] || @public)
    |> Repo.all()
  end

  def count(venue_id, opts \\ []) do
    scope(Review, venue_id)
    |> apply_status(opts[:statuses] || @public)
    |> Repo.aggregate(:count)
  end

  defp apply_status(query, :all), do: query
  defp apply_status(query, statuses), do: from(r in query, where: r.status in ^statuses)

  def get(venue_id, id), do: get_scoped(Repo, Review, id, venue_id)

  @doc "Every flagged review across the platform, for the admin queue (F0.12)."
  def flagged_queue do
    Repo.all(
      from r in Review,
        where: r.status == "flagged",
        order_by: [asc: r.updated_at],
        preload: [:client]
    )
  end

  @doc """
  The name to publish alongside a review.

  First name and a last initial. The full name is not ours to publish — a
  review is a public document and "Sara Benali came here on Tuesday" is more
  than the customer agreed to say.
  """
  def author_name(%Review{client: %Client{} = client}), do: author_name(client)

  def author_name(%Client{first_name: first, last_name: last}) do
    initial =
      case String.trim(last || "") do
        "" -> ""
        name -> " " <> String.first(name) <> "."
      end

    case String.trim("#{String.trim(first || "")}#{initial}") do
      "" -> "Client"
      name -> name
    end
  end

  def author_name(_), do: "Client"

  ## ---------- writing ----------

  @doc """
  Writes a review for a completed booking.

  `attrs` carries `:rating` and optionally `:comment` and `:locale`; everything
  that identifies the visit comes from the eligibility check, not from the
  caller. Passing a venue_id in would be an invitation to review one salon in
  another's name.
  """
  def create(client_id, booking_ref, attrs) do
    with {:ok, appointment} <- eligibility(client_id, booking_ref) do
      %Review{}
      |> Review.changeset(%{
        rating: attrs[:rating],
        comment: attrs[:comment] || "",
        locale: Blastek.I18n.normalize(attrs[:locale]),
        venue_id: appointment.venue_id,
        client_id: client_id,
        booking_ref: booking_ref,
        status: "visible"
      })
      |> Repo.insert()
      |> recompute_after()
      |> drop_pending_invite(booking_ref)
    end
  end

  # The T+24h nag has no business firing at somebody who has just answered.
  # `Reminders.still_due/2` would decline to send it anyway — that is the
  # guarantee — but leaving the job in the queue for a day to be discarded is
  # untidy rather than harmless: it is a row, and it is one more thing to reason
  # about when reading the queue.
  defp drop_pending_invite({:ok, _review} = result, booking_ref) do
    Blastek.Notifications.ReviewInvites.cancel(booking_ref)
    result
  end

  defp drop_pending_invite(other, _booking_ref), do: other

  @doc """
  The owner's public reply.

  One per review — the column is a single text field, so a second reply
  replaces the first rather than accumulating a thread. F0.8 allows editing
  within 48 hours of the reply being written, which is what `editable_until`
  measures: long enough to fix a typo or think better of a sharp sentence,
  short enough that the version a customer read yesterday cannot be rewritten
  next month into something they never saw.
  """
  @reply_edit_hours 48

  def reply(venue_id, review_id, text) do
    case get(venue_id, review_id) do
      nil ->
        {:error, :not_found}

      review ->
        if reply_editable?(review) do
          review
          |> Review.changeset(%{reply: text, reply_at: Clock.now()})
          |> Repo.update()
        else
          {:error, :reply_locked}
        end
    end
  end

  @doc "Whether the owner may still write or change their reply."
  def reply_editable?(%Review{reply_at: nil}), do: true

  def reply_editable?(%Review{reply_at: at}) do
    NaiveDateTime.diff(Clock.now(), at, :second) <= @reply_edit_hours * 3600
  end

  @doc """
  The owner reports a review for moderation.

  Does not hide it — see the module note. The review is queued for an admin and
  goes on counting until one acts.
  """
  def flag(venue_id, review_id, reason) do
    case get(venue_id, review_id) do
      nil ->
        {:error, :not_found}

      %Review{status: "hidden"} ->
        {:error, :already_hidden}

      review ->
        review
        |> Review.changeset(%{status: "flagged", flagged_reason: String.trim(reason || "")})
        |> Repo.update()
    end
  end

  @doc """
  An admin's verdict on a flagged review (F0.12).

  `"hide"` takes it down and tells the author which category it fell foul of;
  `"keep"` restores it. Not venue-scoped — this is the platform acting, and it
  is the one operation in this module that is.
  """
  def moderate(review_id, verdict, reason \\ "")

  def moderate(review_id, "hide", reason) do
    with %Review{} = review <- Repo.get(Review, review_id) do
      review
      |> Review.changeset(%{status: "hidden", hidden_reason: String.trim(reason || "")})
      |> Repo.update()
      |> recompute_after()
      |> notify_hidden()
    else
      nil -> {:error, :not_found}
    end
  end

  def moderate(review_id, "keep", _reason) do
    with %Review{} = review <- Repo.get(Review, review_id) do
      review
      |> Review.changeset(%{status: "visible", flagged_reason: "", hidden_reason: ""})
      |> Repo.update()
      |> recompute_after()
    else
      nil -> {:error, :not_found}
    end
  end

  def moderate(_review_id, _verdict, _reason), do: {:error, :unknown_verdict}

  @doc """
  Deletes every review a venue has that was not written by a verified client.

  Called when a venue goes live (E10-T5 / F0.8). Demo and seed data exists to
  make an empty salon look plausible during onboarding; the moment the venue is
  real, an invented five-star review is a lie told to its first customer.

  Keyed on the absence of a `booking_ref` rather than on a flag, because that is
  the actual property that matters: no booking, no visit, no review.
  """
  def purge_seeded(venue_id) do
    {count, _} =
      Repo.delete_all(from r in scope(Review, venue_id), where: is_nil(r.booking_ref))

    recompute(venue_id)
    count
  end

  ## ---------- the denormalized rating ----------

  @doc """
  Recomputes `venues.rating_avg` and `rating_count` from the venue's public
  reviews.

  Idempotent; see the module note on why this is a recompute and not a counter.
  """
  def recompute(venue_id) do
    {avg, count} =
      Repo.one(
        from r in scope(Review, venue_id),
          where: r.status in ^@public,
          select: {avg(r.rating), count(r.id)}
      ) || {nil, 0}

    rating = if avg, do: avg |> Decimal.to_float() |> Float.round(2), else: 0.0

    Repo.update_all(from(v in Venue, where: v.id == ^venue_id),
      set: [rating_avg: rating, rating_count: count]
    )

    {rating, count}
  end

  defp recompute_after({:ok, %Review{venue_id: venue_id} = review}) do
    recompute(venue_id)
    {:ok, review}
  end

  defp recompute_after(other), do: other

  # The author is told their review came down and which rule it broke — F0.8
  # asks for the reason category, not silence. Best-effort: a moderation
  # decision must not fail because a message could not be queued.
  defp notify_hidden({:ok, %Review{} = review}) do
    review = Repo.preload(review, :client)

    if review.client && contact_of(review.client) do
      Blastek.Notifications.deliver(:review_hidden, contact_of(review.client),
        locale: review.locale,
        user_id: review.client.user_id,
        venue_id: review.venue_id,
        assigns: %{reason: reason_label(review.hidden_reason, review.locale)}
      )
    end

    {:ok, review}
  end

  defp notify_hidden(other), do: other

  defp contact_of(%Client{phone: phone, email: email}) do
    case String.trim(phone || "") do
      "" -> presence(String.trim(email || ""))
      value -> value
    end
  end

  # A category, not free text: the admin's internal note may name the customer
  # or quote the owner's complaint, and neither belongs in a message to the
  # person being moderated.
  @reason_labels %{
    "abusive" => %{
      "fr" => "propos injurieux",
      "ar" => "لغة مسيئة",
      "en" => "abusive language"
    },
    "spam" => %{"fr" => "spam", "ar" => "رسائل مزعجة", "en" => "spam"},
    "off_topic" => %{
      "fr" => "hors sujet",
      "ar" => "خارج الموضوع",
      "en" => "off topic"
    },
    "personal_data" => %{
      "fr" => "données personnelles",
      "ar" => "بيانات شخصية",
      "en" => "personal data"
    }
  }

  @default_reason %{
    "fr" => "non conforme à nos règles",
    "ar" => "مخالف لقواعدنا",
    "en" => "against our guidelines"
  }

  def reason_categories, do: Map.keys(@reason_labels)

  def reason_label(category, locale) do
    locale = Blastek.I18n.normalize(locale)

    @reason_labels
    |> Map.get(category, @default_reason)
    |> Map.get(locale, @default_reason["fr"])
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
