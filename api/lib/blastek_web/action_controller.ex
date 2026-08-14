defmodule BlastekWeb.ActionController do
  @moduledoc """
  Acting on an appointment from a message, without signing in (E6-T8 / F0.10).

  HTTP rather than GraphQL because the caller is a WhatsApp tap-through: the
  link is opened by the phone's browser, and anything that needs a JavaScript
  client to construct a POST is not a one-tap link.

  ## GET that changes state

  Deliberate, and the reason is the medium. A link in a message is a GET; there
  is no other verb available. The usual objection — that a crawler or a link
  preview will fire it — is answered by the token being single-purpose and by
  the operations being idempotent: cancelling a cancelled appointment is a
  no-op, and confirming a confirmed one is too. Nothing here is destructive in a
  way a second visit could compound.

  The web app owns the page a customer actually sees; this returns JSON and the
  SPA at `/a/:action/:token` renders it.
  """
  use BlastekWeb, :controller

  alias Blastek.Notifications.ActionToken
  alias Blastek.Repo
  alias Blastek.Salon
  alias Blastek.Salon.Appointment
  alias BlastekWeb.LiveUpdates

  def act(conn, %{"action" => action, "token" => token}) do
    with {:ok, id, signed_action} <- ActionToken.verify(token),
         # The action in the path is decoration; the token is what authorizes.
         # Trusting the path would let a cancel link be replayed as a confirm.
         true <- to_string(signed_action) == action,
         %Appointment{} = appointment <- Repo.get(Appointment, id) do
      apply_action(conn, appointment, signed_action)
    else
      _ -> json(conn, %{ok: false, error: "This link is no longer valid."})
    end
  end

  # `ActionToken` also signs `:review`, which is not a one-tap action — it opens
  # a page with a form (see `ActionToken.review_url/1`). Without this clause a
  # review token replayed against this route would be a FunctionClauseError and
  # a 500; it is simply a link that does not work here.
  defp apply_action(conn, _appointment, action) when action not in [:cancel, :confirm] do
    json(conn, %{ok: false, error: "This link is no longer valid."})
  end

  defp apply_action(conn, appointment, :cancel) do
    cond do
      appointment.status in ~w(cancelled no_show) ->
        json(conn, %{ok: true, status: appointment.status, already: true})

      appointment.status == "completed" ->
        json(conn, %{ok: false, error: "That appointment has already happened."})

      true ->
        # `actor: :customer` so the salon is the one told about it — the person
        # tapping the link already knows.
        case Salon.update_appointment(appointment.venue_id, appointment.id, %{
               status: "cancelled",
               actor: :customer
             })
             |> LiveUpdates.broadcast() do
          {:ok, updated} -> json(conn, %{ok: true, status: updated.status, already: false})
          _ -> json(conn, %{ok: false, error: "We could not cancel that. Please call the salon."})
        end
    end
  end

  defp apply_action(conn, appointment, :confirm) do
    cond do
      appointment.status == "confirmed" ->
        json(conn, %{ok: true, status: "confirmed", already: true})

      appointment.status != "booked" ->
        json(conn, %{ok: false, error: "That appointment can no longer be confirmed."})

      true ->
        case Salon.update_appointment(appointment.venue_id, appointment.id, %{
               status: "confirmed",
               actor: :customer
             })
             |> LiveUpdates.broadcast() do
          {:ok, updated} -> json(conn, %{ok: true, status: updated.status, already: false})
          _ -> json(conn, %{ok: false, error: "We could not confirm that."})
        end
    end
  end
end
