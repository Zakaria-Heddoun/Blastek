defmodule Blastek.Notifications.Reminders do
  @moduledoc """
  Scheduling reminders, and deciding at firing time whether to send (E6-T7 /
  F0.10).

  ## Two offsets, both venue-configurable

  T-24h is the one that changes behaviour — a customer who has forgotten still
  has an evening to say so — and T-3h is the one that stops no-shows. Both come
  from venue settings, so a spa doing three-hour treatments can ask for more
  notice than a barber doing fades.

  ## Cancellation without job bookkeeping

  A reminder is enqueued at booking time and sits for a day. Cancelling an
  appointment tries to delete the pending jobs, but that is an optimisation, not
  the guarantee: a job already fetched by a worker cannot be deleted, and a
  crash between the cancel and the delete would leave one behind. So the
  guarantee is here, in `still_due/2` — every scheduled message re-reads the
  appointment as it fires and declines to send if it is no longer on.

  Doing it the other way round, trusting the delete, is how a customer gets
  reminded about an appointment they cancelled the day before.

  ## Reminders in the past

  Booking at 09:00 for 11:00 the same morning means T-24h is yesterday and T-3h
  is an hour ago. Neither is scheduled: a reminder is a warning, and one that
  arrives after the fact is noise that teaches people to ignore the next.
  """
  import Ecto.Query
  require Logger

  alias Blastek.Notifications
  alias Blastek.Notifications.ActionToken
  alias Blastek.Notifications.Format
  alias Blastek.Repo
  alias Blastek.Salon.Appointment
  alias Blastek.Venues

  @offsets [{:reminder_24h, :reminder_24h_min, 24 * 60}, {:reminder_3h, :reminder_3h_min, 180}]

  # Statuses from which a reminder still makes sense. Anything else — cancelled,
  # no-show, already finished — means the appointment is over.
  @live_statuses ~w(booked confirmed)

  @doc """
  Schedules both reminders for an appointment.

  Returns the jobs actually inserted; an appointment too close to now gets
  fewer, and one already in the past gets none.
  """
  def schedule(%Appointment{} = appointment) do
    venue = Venues.get_venue(appointment.venue_id)
    settings = (venue && venue.settings) || %{}
    starts_at = Format.starts_at(appointment.date, appointment.start_min)
    now = NaiveDateTime.local_now()

    for {template, setting, default} <- @offsets,
        minutes = reminder_offset(settings, setting, default),
        at = NaiveDateTime.add(starts_at, -minutes * 60, :second),
        NaiveDateTime.compare(at, now) == :gt,
        {:ok, job} <- [enqueue(appointment, template, at)] do
      job
    end
  end

  @doc """
  Removes the pending reminders for an appointment.

  Best-effort by design — see the module note. `still_due/2` is what actually
  prevents a reminder for a cancelled appointment.
  """
  def cancel(%Appointment{id: id}), do: cancel(id)

  def cancel(appointment_id) when is_integer(appointment_id) do
    templates = Enum.map(@offsets, fn {template, _, _} -> to_string(template) end)

    from(j in Oban.Job,
      where: j.state in ["available", "scheduled", "retryable"],
      where: fragment("?->>'appointment_id' = ?", j.args, ^to_string(appointment_id)),
      where: fragment("?->>'template'", j.args) in ^templates
    )
    |> Repo.delete_all()
    |> elem(0)
  end

  @doc """
  Re-reads the world for a job about to fire.

  Returns `{:ok, assigns}` to send, or `{:skip, reason}`. Messages that carry no
  appointment — a code, an invitation — pass straight through with the assigns
  they were queued with.
  """
  def still_due(_template, %{"appointment_id" => nil} = args), do: {:ok, atomize(args["assigns"])}

  def still_due(template, %{"appointment_id" => id}) when is_integer(id) do
    case Repo.get(Appointment, id) do
      nil ->
        {:skip, :appointment_gone}

      appointment ->
        cond do
          # Only *reminders* are conditional on the appointment still being on.
          # A cancellation notice is by definition about one that is not, and
          # gating every appointment message on this suppressed exactly the
          # message the customer most needed.
          reminder?(template) and appointment.status not in @live_statuses ->
            {:skip, :not_live}

          reminder?(template) and past?(appointment) ->
            {:skip, :already_started}

          true ->
            # Rendered from the appointment as it stands now, not as it stood
            # when the job was created — a rescheduled appointment must not
            # remind the customer about its old time.
            {:ok, assigns(appointment)}
        end
    end
  end

  def still_due(_template, args), do: {:ok, atomize(args["assigns"])}

  @doc """
  Everything the appointment templates interpolate.

  Built in one place because a confirmation, a reminder and a cancellation
  notice all describe the same appointment and must describe it identically.
  """
  def assigns(%Appointment{} = appointment, opts \\ []) do
    appointment = Repo.preload(appointment, [:client, :service, :staff])
    venue = Venues.get_venue(appointment.venue_id)
    locale = opts[:locale] || venue_locale(venue)

    base = %{
      venue: venue && venue.name,
      phone: (venue && venue.phone) || "",
      service: appointment.service && appointment.service.name,
      staff: appointment.staff && appointment.staff.name,
      client: client_name(appointment.client),
      ref: appointment.booking_ref,
      when: Format.date_time(appointment.date, appointment.start_min, locale),
      time: Format.time(appointment.start_min)
    }

    # Every appointment message can carry the one-tap link; templates that have
    # no business offering it simply do not interpolate it. Passing
    # `cancel_url: false` suppresses it for the salon's own copy, which must not
    # invite a receptionist to cancel by tapping a customer's link.
    case opts[:cancel_url] do
      false -> base
      nil -> Map.put(base, :cancel_url, ActionToken.url(appointment.id, :cancel))
      url -> Map.put(base, :cancel_url, url)
    end
  end

  @doc "The locale a venue's own messages are written in."
  def venue_locale(nil), do: Blastek.Notifications.Templates.default_locale()

  def venue_locale(venue),
    do: Blastek.Venues.Settings.get(venue.settings || %{}, :locale)

  ## ---------- internals ----------

  defp enqueue(appointment, template, at) do
    Notifications.deliver(template, customer_contact(appointment),
      locale: customer_locale(appointment),
      user_id: customer_user_id(appointment),
      venue_id: appointment.venue_id,
      appointment_id: appointment.id,
      assigns: %{},
      scheduled_at: to_utc(at),
      queue: :scheduled
    )
    |> case do
      {:ok, %Oban.Job{} = job} -> {:ok, job}
      _ -> :skip
    end
  end

  # Reminders are local wall-clock ("the evening before"); Oban schedules in
  # UTC. The conversion needs a real timezone database — see `:tz` in mix.exs —
  # because Morocco is UTC+1 for most of the year and UTC+0 through Ramadan,
  # which is exactly when a salon's hours have moved and its customers most need
  # telling at the right moment.
  #
  # A misconfigured deployment used to fall through to "treat local as UTC",
  # which silently shifted every reminder by an hour. Logged loudly instead: a
  # reminder an hour out is a bug worth seeing, and sending it late is still
  # better than not sending it.
  defp to_utc(%NaiveDateTime{} = at) do
    case DateTime.from_naive(at, Format.timezone()) do
      {:ok, local} ->
        DateTime.shift_zone!(local, "Etc/UTC")

      # Ambiguous or skipped local times: the hour a clock change repeats or
      # omits. Either candidate is within an hour of right, and refusing to
      # schedule would be worse.
      {:ambiguous, first, _second} ->
        DateTime.shift_zone!(first, "Etc/UTC")

      {:gap, _before, after_gap} ->
        DateTime.shift_zone!(after_gap, "Etc/UTC")

      {:error, reason} ->
        Logger.error(
          "no timezone database for #{Format.timezone()} (#{inspect(reason)}); " <>
            "reminders will be scheduled against UTC and land at the wrong local time"
        )

        DateTime.from_naive!(at, "Etc/UTC")
    end
  end

  defp reminder_offset(settings, key, default) do
    case Blastek.Venues.Settings.get(settings, key) do
      nil -> default
      0 -> nil
      minutes when is_integer(minutes) -> minutes
      _ -> default
    end
  end

  defp reminder?(template), do: template in [:reminder_24h, :reminder_3h]

  defp past?(%Appointment{date: date, start_min: start_min}) do
    NaiveDateTime.compare(Format.starts_at(date, start_min), NaiveDateTime.local_now()) != :gt
  end

  defp client_name(nil), do: ""
  defp client_name(client), do: String.trim("#{client.first_name} #{client.last_name}")

  @doc "Where to reach the customer: their phone, or their email."
  def customer_contact(%Appointment{} = appointment) do
    client = appointment.client || Repo.preload(appointment, :client).client
    contact_of(client)
  end

  defp contact_of(nil), do: nil

  defp contact_of(client) do
    case String.trim(client.phone || "") do
      "" -> String.trim(client.email || "")
      phone -> phone
    end
  end

  defp customer_user_id(%Appointment{} = appointment) do
    client = appointment.client || Repo.preload(appointment, :client).client
    client && client.user_id
  end

  # A customer's own locale if their account states one, otherwise the venue's.
  defp customer_locale(%Appointment{} = appointment) do
    venue_locale(Venues.get_venue(appointment.venue_id))
  end

  defp atomize(nil), do: %{}

  defp atomize(assigns) when is_map(assigns),
    do: Map.new(assigns, fn {key, value} -> {safe_atom(key), value} end)

  defp safe_atom(key) when is_atom(key), do: key

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :unknown
  end
end
