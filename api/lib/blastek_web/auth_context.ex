defmodule BlastekWeb.AuthContext do
  @moduledoc """
  Builds the Absinthe context from the request: the bearer token identifies the
  user, and the `x-venue-slug` header (sent only by users who belong to more
  than one venue) selects which venue a dashboard request acts on.

  The active venue is always resolved from the caller's own memberships —
  never from an argument — so a client cannot address a venue it has no access
  to by passing an id.
  """
  @behaviour Plug
  import Plug.Conn

  alias Blastek.Venues

  def init(opts), do: opts

  def call(conn, _opts) do
    Absinthe.Plug.put_options(conn, context: build_context(conn))
  end

  defp build_context(conn) do
    case current_user(conn) do
      nil -> %{}
      user -> %{current_user: user} |> put_membership(user, venue_slug(conn))
    end
  end

  defp current_user(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user_id} <- Blastek.Accounts.verify_token(token),
         user when not is_nil(user) <- Blastek.Accounts.get_user(user_id) do
      user
    else
      _ -> nil
    end
  end

  defp venue_slug(conn) do
    case get_req_header(conn, "x-venue-slug") do
      [slug | _] when slug != "" -> slug
      _ -> nil
    end
  end

  # Resolves the venue this request acts in: the requested one when the user is
  # a member, otherwise their only membership. Users with several memberships
  # and no header get none, and must pick — the dashboard sends the header.
  defp put_membership(context, user, slug) do
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

defmodule BlastekWeb.Schema.RequireAuth do
  @moduledoc "Absinthe middleware: the caller must be signed in."
  @behaviour Absinthe.Middleware

  def call(resolution, _opts) do
    case resolution.context do
      %{current_user: _} -> resolution
      _ -> BlastekWeb.Schema.Deny.deny(resolution, "You must be signed in.")
    end
  end
end

defmodule BlastekWeb.Schema.RequireMember do
  @moduledoc """
  Absinthe middleware for dashboard fields: the caller must be a member of the
  active venue with at least the given role.

      middleware(RequireMember, "manager")

  Roles rank staff < receptionist < manager < owner. Platform admins pass any
  check, but only when they have explicitly selected a venue.
  """
  @behaviour Absinthe.Middleware

  alias Blastek.Venues
  alias BlastekWeb.Schema.Deny

  def call(resolution, minimum) do
    context = resolution.context

    cond do
      not Map.has_key?(context, :current_user) ->
        Deny.deny(resolution, "You must be signed in.")

      Blastek.Accounts.admin?(context.current_user) and Map.has_key?(context, :venue_id) ->
        resolution

      not Map.has_key?(context, :membership) ->
        Deny.deny(resolution, no_venue_message(context))

      Venues.role_at_least?(context.membership.role, minimum) ->
        resolution

      true ->
        Deny.deny(resolution, "Your role does not allow this action.")
    end
  end

  defp no_venue_message(%{memberships: []}), do: "You do not manage a venue yet."
  defp no_venue_message(_), do: "Select which venue to manage."
end

defmodule BlastekWeb.Schema.RequireAdmin do
  @moduledoc "Absinthe middleware: platform staff only."
  @behaviour Absinthe.Middleware

  def call(resolution, _opts) do
    case resolution.context do
      %{current_user: user} ->
        if Blastek.Accounts.admin?(user),
          do: resolution,
          else: BlastekWeb.Schema.Deny.deny(resolution, "Not authorized.")

      _ ->
        BlastekWeb.Schema.Deny.deny(resolution, "You must be signed in.")
    end
  end
end

defmodule BlastekWeb.Schema.Deny do
  @moduledoc false
  def deny(resolution, msg), do: Absinthe.Resolution.put_result(resolution, {:error, msg})
end
