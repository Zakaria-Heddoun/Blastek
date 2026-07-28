defmodule Blastek.Scope do
  @moduledoc """
  Tenant scoping for every venue-owned query.

  Multi-tenancy here is row-scoped in a single schema: each salon-domain table
  carries `venue_id` and every read/write filters on it. That only holds if the
  filter is never forgotten, so all scoped queries funnel through `scope/2` —
  one greppable call site instead of an `where:` clause copy-pasted per query.

  Anything that reaches a venue-owned row indirectly (staff hours via staff,
  sale items via sales) is scoped through its parent.
  """
  import Ecto.Query

  @doc """
  Restricts a queryable to one venue.

      from(s in Service) |> Scope.scope(venue_id)

  Raises on a nil venue rather than silently returning every tenant's rows —
  a missing scope is a bug, never a wildcard.
  """
  def scope(queryable, venue_id) when is_integer(venue_id) do
    from q in queryable, where: q.venue_id == ^venue_id
  end

  def scope(queryable, venue_id) when is_binary(venue_id) do
    scope(queryable, String.to_integer(venue_id))
  end

  def scope(_queryable, nil) do
    raise ArgumentError, "venue scope is required (got nil) — refusing to run an unscoped query"
  end

  @doc """
  Fetches one venue-owned row by id, or nil when it belongs to another tenant.
  Cross-tenant reads look exactly like missing rows.
  """
  def get_scoped(repo, schema, id, venue_id) do
    schema |> scope(venue_id) |> repo.get(id)
  end

  @doc "Same as `get_scoped/4` but raises `Ecto.NoResultsError` when absent."
  def get_scoped!(repo, schema, id, venue_id) do
    case get_scoped(repo, schema, id, venue_id) do
      nil -> raise Ecto.NoResultsError, queryable: schema
      row -> row
    end
  end
end
