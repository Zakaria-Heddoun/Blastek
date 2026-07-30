defmodule Blastek.Venues.Closure do
  @moduledoc "A period the venue is shut: a day, a span of days, or a window within one."
  use Ecto.Schema
  import Ecto.Changeset

  schema "venue_closures" do
    field :venue_id, :id
    field :date, :date
    field :end_date, :date
    field :start_min, :integer
    field :end_min, :integer
    field :reason, :string, default: ""
    timestamps(type: :naive_datetime)
  end

  def changeset(closure, attrs) do
    closure
    |> cast(attrs, [:venue_id, :date, :end_date, :start_min, :end_min, :reason])
    |> validate_required([:venue_id, :date])
    |> validate_span()
    |> validate_window()
  end

  defp validate_span(changeset) do
    from = get_field(changeset, :date)
    to = get_field(changeset, :end_date)

    if from && to && Date.compare(to, from) == :lt do
      add_error(changeset, :end_date, "cannot be before the first day")
    else
      changeset
    end
  end

  # Both bounds or neither: half a window has no meaning, and silently treating
  # it as a whole-day closure would shut the salon for a day by accident.
  defp validate_window(changeset) do
    start_min = get_field(changeset, :start_min)
    end_min = get_field(changeset, :end_min)

    cond do
      is_nil(start_min) and is_nil(end_min) ->
        changeset

      is_nil(start_min) or is_nil(end_min) ->
        add_error(changeset, :start_min, "and an end time are both needed for a part-day closure")

      end_min <= start_min ->
        add_error(changeset, :end_min, "must be after the start time")

      true ->
        changeset
    end
  end
end

defmodule Blastek.Venues.HourTemplate do
  @moduledoc """
  A named weekly grid — `default`, `ramadan`, or whatever a venue calls its
  summer hours.

  `hours` is a list of seven maps, one per weekday (0 = Sunday), each
  `%{"working" => bool, "start_min" => int, "end_min" => int}`. Stored as JSONB
  because it is read and written whole and never queried into.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "venue_hour_templates" do
    field :venue_id, :id
    field :name, :string
    field :hours, :map, default: %{}
    field :active, :boolean, default: false
    timestamps(type: :naive_datetime)
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [:venue_id, :name, :hours, :active])
    |> validate_required([:venue_id, :name])
    |> update_change(:name, &(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9 _-]*$/,
      message: "may only contain letters, numbers, spaces, dashes and underscores"
    )
    |> unique_constraint([:venue_id, :name], message: "already exists")
    |> unique_constraint(:active,
      name: :venue_hour_templates_one_active_index,
      message: "— another template is already active"
    )
  end
end

defmodule Blastek.Venues.Schedule do
  @moduledoc """
  When a venue is open: closures and seasonal hour templates (E5-T2, E5-T3 /
  F0.4).

  ## Two different kinds of "closed"

  A **template** says when the venue normally opens — a weekly grid it keeps and
  switches between, because Ramadan moves the working day rather than cancelling
  it. A **closure** is an exception to whatever the grid says: Eid, a family
  emergency, a Tuesday afternoon off.

  Availability needs both, and needs them cheaply: `closed_windows/2` returns
  the minute ranges a date is unavailable, in one query, for the slot engine to
  subtract.

  ## Past midnight

  Minutes run from midnight and may exceed 1440 — Ramadan's 21:00–00:30 is
  1260–1470. Nothing here needs to know about days; a window is a pair of
  integers, and 1470 is simply later than 1260.
  """
  import Ecto.Query

  alias Blastek.Repo
  alias Blastek.Venues.Closure
  alias Blastek.Venues.HourTemplate

  @default_template "default"
  @minutes_in_day 1440

  def default_template_name, do: @default_template
  def minutes_in_day, do: @minutes_in_day

  ## ---------- closures ----------

  @doc "Closures overlapping a date range, soonest first."
  def list_closures(venue_id, opts \\ []) do
    from_date = Keyword.get(opts, :from, Date.utc_today())

    query =
      from c in Closure,
        where: c.venue_id == ^venue_id and coalesce(c.end_date, c.date) >= ^from_date,
        order_by: [asc: c.date, asc: c.id]

    query =
      case Keyword.get(opts, :to) do
        nil -> query
        to_date -> from c in query, where: c.date <= ^to_date
      end

    Repo.all(query)
  end

  def create_closure(venue_id, attrs) do
    %Closure{}
    |> Closure.changeset(Map.put(stringify_keys(attrs), "venue_id", venue_id))
    |> Repo.insert()
  end

  def delete_closure(venue_id, id) do
    case Repo.one(from c in Closure, where: c.id == ^id and c.venue_id == ^venue_id) do
      nil -> {:error, "Unknown closure."}
      closure -> Repo.delete(closure)
    end
  end

  @doc """
  The minute windows a venue is closed on one date.

  A whole-day closure returns the full day *including the past-midnight tail*,
  so a 21:00–00:30 template cannot leak slots on a day the venue is shut.
  Returns `[]` when the venue is open.
  """
  def closed_windows(venue_id, %Date{} = date) do
    Repo.all(
      from c in Closure,
        where:
          c.venue_id == ^venue_id and c.date <= ^date and
            coalesce(c.end_date, c.date) >= ^date,
        select: {c.start_min, c.end_min}
    )
    |> Enum.map(fn
      {nil, _} -> {0, @minutes_in_day * 2}
      {_, nil} -> {0, @minutes_in_day * 2}
      {start_min, end_min} -> {start_min, end_min}
    end)
  end

  @doc "Whether a specific minute window is blocked by a closure."
  def closed?(venue_id, date, start_min, end_min) do
    venue_id
    |> closed_windows(date)
    |> Enum.any?(fn {from, to} -> start_min < to and end_min > from end)
  end

  ## ---------- hour templates ----------

  @doc "A venue's templates, the active one first."
  def list_templates(venue_id) do
    Repo.all(
      from t in HourTemplate,
        where: t.venue_id == ^venue_id,
        order_by: [desc: t.active, asc: t.name]
    )
  end

  @doc """
  The template currently in force.

  `nil` when a venue has none, which is every venue that predates this feature —
  availability then falls back to staff hours alone, exactly as before.
  """
  def active_template(venue_id) do
    Repo.one(from t in HourTemplate, where: t.venue_id == ^venue_id and t.active)
  end

  def get_template(venue_id, name) do
    Repo.one(from t in HourTemplate, where: t.venue_id == ^venue_id and t.name == ^name)
  end

  @doc """
  Creates or replaces a named template.

  Upsert rather than insert: a venue editing its Ramadan hours a second time is
  the normal case, not an error.
  """
  def upsert_template(venue_id, name, hours) do
    name = name |> to_string() |> String.trim() |> String.downcase()

    case get_template(venue_id, name) do
      nil ->
        %HourTemplate{}
        |> HourTemplate.changeset(%{
          venue_id: venue_id,
          name: name,
          hours: %{"week" => normalize_week(hours)}
        })

      existing ->
        HourTemplate.changeset(existing, %{hours: %{"week" => normalize_week(hours)}})
    end
    |> Repo.insert_or_update()
  end

  @doc """
  Switches the venue to a template.

  Deactivating and activating happen in one transaction because the partial
  unique index permits exactly one active row — doing it in two statements
  outside a transaction would briefly violate it and fail.
  """
  def activate_template(venue_id, name) do
    name = name |> to_string() |> String.trim() |> String.downcase()

    case get_template(venue_id, name) do
      nil ->
        {:error, "No schedule called \"#{name}\"."}

      template ->
        Repo.transaction(fn ->
          Repo.update_all(
            from(t in HourTemplate, where: t.venue_id == ^venue_id and t.active),
            set: [active: false]
          )

          # Through the changeset, not `change/2`: two owners switching at once
          # (or one impatient double-click) both clear the flag and both try to
          # set it, and the partial unique index rejects the loser. That has to
          # come back as "try again", not a 500.
          template
          |> HourTemplate.changeset(%{active: true})
          |> Repo.update()
          |> case do
            {:ok, activated} -> activated
            {:error, _changeset} -> Repo.rollback("Another schedule change is in flight.")
          end
        end)
    end
  end

  @doc """
  The weekly grid of the active template, or nil.

  Returned as a map keyed by weekday so callers index rather than search.
  """
  def active_week(venue_id) do
    case active_template(venue_id) do
      nil -> nil
      template -> week_of(template)
    end
  end

  def week_of(%HourTemplate{hours: %{"week" => week}}) when is_list(week) do
    Map.new(week, fn day -> {day["weekday"], day} end)
  end

  def week_of(_), do: nil

  @doc "The seven-day grid a template holds, as a plain list."
  def week_list(%HourTemplate{hours: %{"week" => week}}) when is_list(week), do: week
  def week_list(_), do: []

  ## ---------- internals ----------

  # Accepts the seven days in any order and fills the gaps, so a client sending
  # only the days it changed cannot silently blank the rest of the week.
  defp normalize_week(days) do
    supplied = Map.new(List.wrap(days), fn day -> {day_field(day, :weekday), day} end)

    for weekday <- 0..6 do
      case Map.get(supplied, weekday) do
        nil ->
          %{"weekday" => weekday, "working" => false, "start_min" => 540, "end_min" => 1080}

        day ->
          start_min = clamp_minute(day_field(day, :start_min) || 540)
          end_min = clamp_minute(day_field(day, :end_min) || 1080)

          %{
            "weekday" => weekday,
            # A day that ends before it starts is closed, not a shift running
            # backwards. `Closure` rejects the same shape outright; a template
            # cannot, because the seven days arrive together and one bad row
            # must not cost the owner the other six — but silently storing it
            # would leave the slot engine offering nothing with no explanation.
            "working" => day_field(day, :working) == true and end_min > start_min,
            "start_min" => start_min,
            "end_min" => end_min
          }
      end
    end
  end

  defp day_field(day, key) when is_map(day) do
    Map.get(day, key) || Map.get(day, to_string(key))
  end

  # Up to 06:00 the following morning. Wider than any salon needs, and narrow
  # enough that a typo cannot produce a week-long "day".
  defp clamp_minute(value) when is_integer(value),
    do: value |> max(0) |> min(@minutes_in_day + 360)

  defp clamp_minute(_), do: 540

  # `cast/3` takes either, but not a mixture — so everything becomes a string
  # key. The previous version reached for `String.to_existing_atom`, which turns
  # an unrecognised key from any future caller into a raise rather than the
  # "ignored" that `cast/3` already gives for free.
  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end
end
