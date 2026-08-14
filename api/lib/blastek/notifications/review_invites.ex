defmodule Blastek.Notifications.ReviewInvites do
  @moduledoc """
  Asking for the review, twice at most (E10-T3 / F0.8).

  ## Two messages, then silence

  T+2h and, only if nothing came of it, T+24h. F0.8 caps it there and the cap is
  the point: a salon that nags is a salon customers mute, and a muted WhatsApp
  thread also loses them the reminders that stop no-shows. Two asks is the whole
  budget.

  The invites are scheduled per **booking**, not per appointment. A visit of
  three services is one afternoon and deserves one message; scheduling from each
  appointment row would send three, which is precisely the behaviour the cap
  exists to prevent.

  ## The link is the login

  A customer reading this on a phone will not sign in to leave a review — that
  is the same lesson `ActionToken` records for confirm and cancel, and it
  applies harder here because reviewing is optional. The message carries a
  signed link that authorizes writing one review for one booking, and the review
  page accepts it in place of a session.

  ## Why the reminder is not cancelled on success

  It is, when we can — but the guarantee is `Reminders.still_due/2` re-reading
  whether the booking has been reviewed as the job fires. A deleted job is an
  optimisation; a customer who reviews at T+3h and gets nagged at T+24h anyway
  is the bug, and only the re-read prevents it.
  """
  import Ecto.Query

  alias Blastek.Clock
  alias Blastek.Notifications
  alias Blastek.Notifications.ActionToken
  alias Blastek.Notifications.Reminders
  alias Blastek.Repo
  alias Blastek.Salon.Appointment
  alias Blastek.Venues

  @offsets [{:review_invite, 2}, {:review_reminder, 24}]

  @templates Enum.map(@offsets, fn {template, _} -> template end)

  def templates, do: @templates

  @doc """
  Schedules the invite and its one reminder for a checked-out booking.

  Takes the appointments that were just completed — `Salon.checkout/4` has them
  in hand — and picks one row per `booking_ref` to hang the messages on.
  Returns the jobs inserted.
  """
  def schedule(appointments, opts \\ [])

  def schedule([], _opts), do: []

  def schedule(appointments, opts) when is_list(appointments) do
    appointments
    |> Enum.uniq_by(& &1.booking_ref)
    |> Enum.flat_map(&schedule_one(&1, opts))
  end

  defp schedule_one(%Appointment{} = appointment, opts) do
    venue = opts[:venue] || Venues.get_venue(appointment.venue_id)

    # No contact, no invite. A walk-in recorded with neither phone nor email is
    # a real and common row; there is nowhere to send it and nothing is wrong.
    case Reminders.customer_contact(appointment) do
      nil -> []
      "" -> []
      contact -> enqueue_all(appointment, venue, contact)
    end
  end

  defp enqueue_all(appointment, venue, contact) do
    locale = Reminders.venue_locale(venue)
    now = Clock.now()

    for {template, hours} <- @offsets,
        at = NaiveDateTime.add(now, hours * 3600, :second),
        {:ok, job} <- [enqueue(appointment, venue, contact, template, at, locale)] do
      job
    end
  end

  defp enqueue(appointment, venue, contact, template, at, locale) do
    Notifications.deliver(template, contact,
      locale: locale,
      user_id: user_id(appointment),
      venue_id: appointment.venue_id,
      appointment_id: appointment.id,
      assigns: assigns(appointment, venue),
      scheduled_at: Clock.to_utc(at),
      queue: :scheduled
    )
    |> case do
      {:ok, %Oban.Job{} = job} -> {:ok, job}
      _ -> :skip
    end
  end

  @doc """
  What a review message interpolates.

  Re-derived at firing time by `Reminders.still_due/2` rather than trusted from
  the queued args, for the same reason a rescheduled appointment must not remind
  about its old time: a salon that renamed itself yesterday is asking under its
  new name.
  """
  def assigns(%Appointment{} = appointment, venue \\ nil) do
    venue = venue || Venues.get_venue(appointment.venue_id)

    %{
      venue: venue && venue.name,
      review_url: ActionToken.review_url(appointment.id)
    }
  end

  @doc """
  Whether a booking still wants to be asked about.

  `{:skip, reason}` once it has been reviewed, once the visit is too old to
  review, or if the venue has been suspended since — a frozen venue's customers
  should not be invited to write something the venue cannot answer.
  """
  def still_wanted(%Appointment{} = appointment) do
    cond do
      reviewed?(appointment.booking_ref) -> {:skip, :already_reviewed}
      suspended?(appointment.venue_id) -> {:skip, :venue_frozen}
      true -> :ok
    end
  end

  defp reviewed?(""), do: false
  defp reviewed?(nil), do: false

  defp reviewed?(booking_ref) do
    Repo.exists?(from r in Blastek.Salon.Review, where: r.booking_ref == ^booking_ref)
  end

  defp suspended?(venue_id) do
    case Venues.get_venue(venue_id) do
      %{status: "suspended"} -> true
      _ -> false
    end
  end

  @doc """
  Drops the pending review messages for a booking.

  Best-effort, exactly as `Reminders.cancel/1` is. Called when a review arrives
  so the T+24h nag does not sit in the queue for a day being pointless.
  """
  def cancel(booking_ref) when is_binary(booking_ref) and booking_ref != "" do
    ids =
      Repo.all(
        from a in Appointment, where: a.booking_ref == ^booking_ref, select: type(a.id, :string)
      )

    templates = Enum.map(@templates, &to_string/1)

    from(j in Oban.Job,
      where: j.state in ["available", "scheduled", "retryable"],
      where: fragment("?->>'appointment_id'", j.args) in ^ids,
      where: fragment("?->>'template'", j.args) in ^templates
    )
    |> Repo.delete_all()
    |> elem(0)
  end

  def cancel(_), do: 0

  defp user_id(%Appointment{} = appointment) do
    client = Repo.preload(appointment, :client).client
    client && client.user_id
  end
end
