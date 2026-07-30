defmodule BlastekWeb.LiveUpdates do
  @moduledoc """
  Publishing appointment changes to a venue's open dashboards (E2-T4).

  Lifted out of the GraphQL schema in E6, because the schema stopped being the
  only way an appointment changes. A customer tapping *Cancel* in a WhatsApp
  reminder goes through `BlastekWeb.ActionController`, and until this moved
  their cancellation reached the database, the salon's phone and the send log —
  but not the calendar somebody had open in front of them.

  Still in the web layer rather than in `Blastek.Salon`: publishing happens
  *after the write commits*, and inside `Salon.book/2`'s transaction it has not.
  A subscriber that re-queries on the event would otherwise be able to observe a
  state older than the event itself.
  """

  @doc """
  Announces one appointment to its venue.

  Failures are swallowed: a dropped live update must never fail the booking
  that caused it, and the calendar reloads on its own timer anyway.
  """
  def appointment(%{venue_id: venue_id} = appointment) do
    Absinthe.Subscription.publish(BlastekWeb.Endpoint, appointment,
      appointment_changed: "venue:#{venue_id}"
    )

    :ok
  rescue
    _ -> :ok
  end

  def appointment(_), do: :ok

  @doc "Pipeline form: announces on `{:ok, appointment}` and passes the result through."
  def broadcast({:ok, appointment} = result) do
    appointment(appointment)
    result
  end

  def broadcast(other), do: other

  @doc "A booking creates several appointments under one reference; the calendar needs each."
  def broadcast_booking({:ok, %{appointments: appointments}} = result) do
    Enum.each(appointments, &appointment/1)
    result
  end

  def broadcast_booking(other), do: other
end
