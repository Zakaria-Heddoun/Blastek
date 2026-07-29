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
    # Carried into resolvers so per-IP limits can be applied per operation.
    base = %{client_ip: conn.remote_ip |> :inet.ntoa() |> to_string()}

    case current_user(conn) do
      nil -> base
      user -> base |> Map.put(:current_user, user) |> put_membership(user, venue_slug(conn))
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
      _ -> BlastekWeb.Schema.Deny.deny(resolution, "You must be signed in.", "unauthenticated")
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
        Deny.deny(resolution, "You must be signed in.", "unauthenticated")

      Blastek.Accounts.admin?(context.current_user) and Map.has_key?(context, :venue_id) ->
        resolution

      not Map.has_key?(context, :membership) ->
        Deny.deny(resolution, no_venue_message(context), "no_venue")

      Venues.role_at_least?(context.membership.role, minimum) ->
        resolution

      true ->
        Deny.deny(resolution, "Your role does not allow this action.", "forbidden")
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
          else: BlastekWeb.Schema.Deny.deny(resolution, "Not authorized.", "forbidden")

      _ ->
        BlastekWeb.Schema.Deny.deny(resolution, "You must be signed in.", "unauthenticated")
    end
  end
end

defmodule BlastekWeb.Schema.RateLimitAuth do
  @moduledoc """
  Strict budget for credential-checking mutations (login, sign-up).

  Two buckets, because they defend against different attacks: per-identity
  stops someone grinding one account's password, per-IP stops spraying one
  password across many accounts. Both must pass.

  Counted before the credentials are checked, so a wrong guess costs the same
  as a right one — otherwise the limiter is trivial to evade.
  """
  @behaviour Absinthe.Middleware

  alias Blastek.RateLimit
  alias BlastekWeb.Schema.Deny

  @per_identity 8
  @per_identity_window :timer.minutes(15)
  @per_ip 40
  @per_ip_window :timer.hours(1)

  def call(resolution, _opts) do
    identity = resolution.arguments |> Map.get(:email, "") |> to_string() |> String.downcase()
    ip = resolution.context[:client_ip] || "unknown"

    with :ok <- RateLimit.hit({:auth_identity, identity}, @per_identity, @per_identity_window),
         :ok <- RateLimit.hit({:auth_ip, ip}, @per_ip, @per_ip_window) do
      resolution
    else
      {:error, retry_after} ->
        Deny.deny(
          resolution,
          "Too many attempts. Try again in #{retry_seconds(retry_after)}.",
          "rate_limited"
        )
    end
  end

  defp retry_seconds(seconds) when seconds >= 60, do: "#{div(seconds, 60)} minute(s)"
  defp retry_seconds(seconds), do: "#{seconds} second(s)"
end

defmodule BlastekWeb.Schema.Deny do
  @moduledoc false

  @doc "Rejects a resolution with a message and a machine-readable code."
  def deny(resolution, msg, code) do
    Absinthe.Resolution.put_result(resolution, {:error, %{message: msg, code: code}})
  end
end
