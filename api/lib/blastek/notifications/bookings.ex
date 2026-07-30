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
      confirmed? = first.status == "confirmed"
      assigns = Reminders.assigns(first, cancel_url: opts[:cancel_url])

      customer(
        first,
        if(confirmed?, do: :booking_confirmed_customer, else: :booking_requested_customer),
        assigns
      )

      salon(
        first,
        if(confirmed?, do: :booking_confirmed_salon, else: :booking_requested_salon),
        Reminders.assigns(first, cancel_url: false)
      )

      # Reminders for the first appointment only: a cut-and-colour is two rows
      # but one arrival, and two reminders for it read as a mistake.
      Reminders.schedule(first)
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
    salon(appointment, :cancelled_by_customer, Reminders.assigns(appointment, cancel_url: false))
    Reminders.cancel(appointment)
  end

  defp cancelled(appointment, _staff) do
    customer(appointment, :cancelled_by_salon, Reminders.assigns(appointment))
    Reminders.cancel(appointment)
  end

  defp rescheduled(appointment) do
    customer(appointment, :rescheduled, Reminders.assigns(appointment))
    # The old reminders name the old time, so they are replaced rather than
    # kept — `still_due/2` would re-render them correctly, but a reminder timed
    # against a slot that moved by two days would fire on the wrong evening.
    Reminders.cancel(appointment)
    Reminders.schedule(appointment)
  end

  defp cancelled?(before, now),
    do: before.status not in ~w(cancelled no_show) and now.status in ~w(cancelled no_show)

  defp moved?(before, now) do
    now.status not in ~w(cancelled no_show) and
      (before.date != now.date or before.start_min != now.start_min)
  end

  ## ---------- addressing ----------

  defp customer(appointment, template, assigns) do
    Notifications.deliver(template, Reminders.customer_contact(appointment),
      locale: Reminders.venue_locale(Venues.get_venue(appointment.venue_id)),
      user_id: customer_user_id(appointment),
      venue_id: appointment.venue_id,
      appointment_id: appointment.id,
      assigns: assigns
    )
  end

  defp salon(appointment, template, assigns) do
    Notifications.deliver(template, Venues.owner_contact(appointment.venue_id),
      locale: Reminders.venue_locale(Venues.get_venue(appointment.venue_id)),
      user_id: Venues.owner_user_id(appointment.venue_id),
      venue_id: appointment.venue_id,
      appointment_id: appointment.id,
      assigns: assigns
    )
  end

  defp customer_user_id(%Appointment{} = appointment) do
    case Blastek.Repo.preload(appointment, :client).client do
      nil -> nil
      client -> client.user_id
    end
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
