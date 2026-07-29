defmodule BlastekWeb.UserSocket do
  @moduledoc """
  Socket for GraphQL subscriptions (E2-T4 / F0.13 B9).

  Authentication mirrors the HTTP path: the bearer token arrives as a connect
  param and the resulting context is what subscription resolvers see. A socket
  is long-lived, so this is the only point where the caller is identified —
  getting it wrong would leave an unauthenticated channel able to subscribe to
  a venue's calendar.
  """
  use Phoenix.Socket
  use Absinthe.Phoenix.Socket, schema: BlastekWeb.Schema

  alias Blastek.Accounts
  alias Blastek.Venues

  @impl true
  def connect(params, socket, _connect_info) do
    context =
      case authenticate(params["token"]) do
        nil -> %{}
        user -> venue_context(%{current_user: user}, user, params["venue"])
      end

    {:ok, Absinthe.Phoenix.Socket.put_options(socket, context: context)}
  end

  # Anonymous sockets are allowed to connect; every subscription field still
  # authorizes on its own, so an unauthenticated socket can simply reach nothing.
  @impl true
  def id(_socket), do: nil

  defp authenticate(token) when is_binary(token) do
    with {:ok, user_id} <- Accounts.verify_token(token) do
      Accounts.get_user(user_id)
    else
      _ -> nil
    end
  end

  defp authenticate(_), do: nil

  defp venue_context(context, user, slug) do
    memberships = Venues.list_memberships(user.id)

    membership =
      case {slug, memberships} do
        {nil, [only]} -> only
        {nil, _} -> nil
        {slug, _} -> Enum.find(memberships, &(&1.venue.slug == slug))
      end

    case membership do
      nil ->
        Map.put(context, :memberships, memberships)

      m ->
        context
        |> Map.put(:memberships, memberships)
        |> Map.put(:membership, m)
        |> Map.put(:current_venue, m.venue)
        |> Map.put(:venue_id, m.venue_id)
    end
  end
end
