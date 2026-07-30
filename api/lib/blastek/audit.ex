defmodule Blastek.Audit.Entry do
  @moduledoc "One recorded action. Append-only: there is no changeset to update."
  use Ecto.Schema

  schema "audit_log" do
    field :venue_id, :id
    field :actor_user_id, :id
    field :action, :string
    field :subject_type, :string, default: ""
    field :subject_id, :integer
    field :metadata, :map, default: %{}
    timestamps(type: :naive_datetime, updated_at: false)
  end
end

defmodule Blastek.Audit do
  @moduledoc """
  Append-only record of who changed what (E4-T6 / F0.3).

  Written for membership and invitation changes today. F0.3 wants those
  auditable; E11 wants a general admin log — so this is the general shape with a
  narrow set of writers, rather than a `membership_events` table that E11 would
  have to migrate away from.

  ## Recording never breaks the thing being recorded

  `record/2` cannot fail the caller's operation. Losing an audit row is bad;
  failing a member removal because the log was unavailable is worse, and would
  make the log a new way for the app to break. Failures are logged and dropped.

  What goes in `metadata` is the *before and after* — an entry saying a role
  changed is nearly useless without saying from what.
  """
  import Ecto.Query
  require Logger

  alias Blastek.Audit.Entry
  alias Blastek.Repo

  @doc """
  Records an action.

  `actor` is the user who did it, or `nil` for something the system did on its
  own. Always returns `:ok`.
  """
  def record(action, attrs) when is_binary(action) do
    Repo.insert!(%Entry{
      action: action,
      venue_id: attrs[:venue_id],
      actor_user_id: actor_id(attrs[:actor]),
      subject_type: to_string(attrs[:subject_type] || ""),
      subject_id: attrs[:subject_id],
      metadata: stringify(attrs[:metadata] || %{})
    })

    :ok
  rescue
    error ->
      Logger.error("audit write failed for #{action}: #{Exception.message(error)}")
      :ok
  end

  @doc "A venue's audit entries, newest first."
  def list_for_venue(venue_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(200)

    Repo.all(
      from e in Entry,
        where: e.venue_id == ^venue_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(id) when is_integer(id), do: id
  defp actor_id(_), do: nil

  # JSONB keys come back as strings whatever went in, so they go in as strings
  # too — otherwise a round trip silently changes the shape of `metadata`.
  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp stringify_value(value), do: value
end
