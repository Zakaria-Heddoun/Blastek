defmodule Blastek.Notifications.Bookings do
  @moduledoc """
  What gets sent when an appointment changes (E6-T6 / F0.10).

  Kept out of `Blastek.Salon` so the domain stays about appointments and calls
  one function per transition. The coupling runs one way: notifications know
  about bookings, bookings do not know what a WhatsApp template is.

  ## Nothing here may fail a booking

  Every entry point swallows its own errors, for the same reason `Blastek.Audit`
  does: a customer who has just paid attention long enough to pick a slot must
  not lose it because Meta returned a 502. A message that could not be *queued*
  is worth a log line, never an exception into the caller.

  One honest caveat: `booked/2` runs inside `Salon.book/2`'s transaction, so
  this catches the exception but cannot un-abort a transaction that Postgres has
  already marked failed. A *database* error in here would still surface at
  commit. Nothing here talks to a provider — the actual sending is a queued job,
  and this only writes rows — so the errors worth catching are the ones this
  does catch. It is not a promise the rescue alone can keep.

  ## Which message

  `instant_confirmation` decides. A venue that vets its bookings gets a
  "request to confirm" and its customer gets "the salon will confirm shortly";
  a venue that does not gets "new online booking" and its customer gets a
  confirmation. Saying "confirmed" to somebody whose appointment is still
  pending is the kind of small lie that produces a phone call.
  """
  require Logger

  alias Blastek.Notifications
  alias Blastek.Notifications.Reminders
  alias Blastek.Salon.Appointment
  alias Blastek.Venues

  @doc """
  A booking has just been made online.

  Notifies the customer and the salon, and schedules the reminders. Called with
  the appointments of one booking — a multi-service booking is one message, not
  one per service.
  """
  def booked(appointments, opts \\ [])

  def booked([], _opts), do: :ok

  def booked([first | _], opts) do
    safely(fn ->
      ctx = context(first)
      confirmed? = first.status == "confirmed"
      assigns = Reminders.assigns(first, venue: ctx.venue, cancel_url: opts[:cancel_url])

      customer(
        ctx,
        if(confirmed?, do: :booking_confirmed_customer, else: :booking_requested_customer),
        assigns
      )

      # The salon's own copy, minus the link — a receptionist reading it must
      # not be one tap away from cancelling a customer's appointment. Derived
      # rather than rebuilt: the two messages describe the same booking and
      # rebuilding is four more queries inside the booking's advisory lock.
      salon(
        ctx,
        if(confirmed?, do: :booking_confirmed_salon, else: :booking_requested_salon),
        Map.delete(assigns, :cancel_url)
      )

      # Reminders for the first appointment only: a cut-and-colour is two rows
      # but one arrival, and two reminders for it read as a mistake.
      Reminders.schedule(first, venue: ctx.venue)
      :ok
    end)
  end

  @doc """
  An appointment changed. Sends whatever that change means to whom.

  `actor` is `:customer` or `:staff` — a cancellation reads completely
  differently depending on who did it, and only the person who did *not* do it
  needs telling.
  """
  def changed(%Appointment{} = before, %Appointment{} = now, actor \\ :staff) do
    safely(fn ->
      cond do
        cancelled?(before, now) -> cancelled(now, actor)
        moved?(before, now) -> rescheduled(now)
        true -> :ok
      end
    end)
  end

  ## ---------- transitions ----------

  defp cancelled(appointment, :customer) do
    # The customer knows; the salon has a hole in its afternoon.
    ctx = context(appointment)

    salon(
      ctx,
      :cancelled_by_customer,
      Reminders.assigns(appointment, venue: ctx.venue, cancel_url: false)
    )

    Reminders.cancel(appointment)
  end

  defp cancelled(appointment, _staff) do
    ctx = context(appointment)
    customer(ctx, :cancelled_by_salon, Reminders.assigns(appointment, venue: ctx.venue))
    Reminders.cancel(appointment)
  end

  defp rescheduled(appointment) do
    ctx = context(appointment)
    customer(ctx, :rescheduled, Reminders.assigns(appointment, venue: ctx.venue))
    # The old reminders name the old time, so they are replaced rather than
    # kept — `still_due/2` would re-render them correctly, but a reminder timed
    # against a slot that moved by two days would fire on the wrong evening.
    Reminders.cancel(appointment)
    Reminders.schedule(appointment, venue: ctx.venue)
  end

  defp cancelled?(before, now),
    do: before.status not in ~w(cancelled no_show) and now.status in ~w(cancelled no_show)

  defp moved?(before, now) do
    now.status not in ~w(cancelled no_show) and
      (before.date != now.date or before.start_min != now.start_min)
  end

  ## ---------- addressing ----------

  # Everything both messages need, looked up once. `booked/2` runs inside
  # `Salon.book/2`'s transaction, which holds an advisory lock on the staff
  # member's day: each repeated `get_venue` there is contention on the one thing
  # concurrent bookings actually queue for.
  defp context(%Appointment{} = appointment) do
    appointment = Blastek.Repo.preload(appointment, :client)
    venue = Venues.get_venue(appointment.venue_id)
    owner = Venues.owner(appointment.venue_id)

    %{
      appointment: appointment,
      venue: venue,
      locale: Reminders.venue_locale(venue),
      owner: owner
    }
  end

  defp customer(ctx, template, assigns) do
    Notifications.deliver(template, Reminders.customer_contact(ctx.appointment),
      locale: ctx.locale,
      user_id: ctx.appointment.client && ctx.appointment.client.user_id,
      venue_id: ctx.appointment.venue_id,
      appointment_id: ctx.appointment.id,
      assigns: assigns
    )
  end

  defp salon(ctx, template, assigns) do
    Notifications.deliver(template, ctx.owner.contact,
      locale: ctx.locale,
      user_id: ctx.owner.user_id,
      venue_id: ctx.appointment.venue_id,
      appointment_id: ctx.appointment.id,
      assigns: assigns
    )
  end

  defp safely(work) do
    work.()
    :ok
  rescue
    error ->
      Logger.error("notification dispatch failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.error("notification dispatch exited: #{inspect(reason)}")
      :ok
  end
end
