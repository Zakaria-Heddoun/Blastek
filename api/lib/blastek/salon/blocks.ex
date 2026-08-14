defmodule Blastek.Salon.Blocks do
  @moduledoc """
  Time off, breaks and one-off blocks (E9-T1 / F0.7).

  ## The one function that matters

  `windows/3`. Everything else here is CRUD; that is the function
  `Salon.availability/4` subtracts, and getting it wrong means either offering
  a slot the stylist cannot work or hiding one they can.

  It is deliberately shaped like `Venues.Schedule.closed_windows/2` — a list of
  `{start_min, end_min}` pairs per staff member — so the availability engine
  can concatenate blocks, closures and existing appointments and run one
  overlap test over the lot. Three sources of unavailability with three
  different comparison rules is how one of them ends up forgotten.

  ## Weekly repeats are materialized on read

  A break every Friday is one row, not fifty-two. The row carries `weekday`,
  and a query for a given date asks for rows whose weekday matches *or* whose
  date range covers it. Storing the expansion instead would mean deciding how
  far into the future to write rows, and then being wrong about it.

  A weekly rule starts on its own `date` and does not stop: F0.7 has no end
  date for a recurring break, and "my lunch break, from now on" is what a salon
  actually means. Removing it is deleting the row.

  ## Blocks follow the clock, not the shift

  F0.7 is explicit: a 12:00–14:00 break stays at 12:00–14:00 when the Ramadan
  template moves the working day. That falls out of storing minutes rather than
  a position within the shift, and it is why `conflicts_with_hours?/3` exists —
  the owner is *warned* that a break now sits outside the working day, rather
  than having it silently moved for them.
  """
  import Ecto.Query
  import Blastek.Scope

  alias Blastek.Repo
  alias Blastek.Salon.Block

  # A whole-day absence covers any shift, including one running past midnight.
  @all_day {0, 2 * 1440}

  @doc """
  Unavailable windows per staff member on one date.

  `%{staff_id => [{start_min, end_min}]}`, with overlapping blocks merged —
  F0.7 asks for that on read, and a merged list is also a shorter one to test
  every candidate slot against.
  """
  def windows(venue_id, staff_ids, %Date{} = date) when is_list(staff_ids) do
    weekday = Date.day_of_week(date, :sunday) - 1

    from(b in scope(Block, venue_id),
      where: b.staff_id in ^staff_ids,
      where:
        (b.weekly and b.weekday == ^weekday and b.date <= ^date) or
          (not b.weekly and b.date <= ^date and coalesce(b.end_date, b.date) >= ^date),
      select: {b.staff_id, b.kind, b.start_min, b.end_min}
    )
    |> Repo.all()
    |> Enum.group_by(fn {staff_id, _, _, _} -> staff_id end, &to_window/1)
    |> Map.new(fn {staff_id, spans} -> {staff_id, merge(spans)} end)
  end

  def windows(_venue_id, _staff_ids, _date), do: %{}

  defp to_window({_staff_id, "time_off", _start, _end}), do: @all_day
  defp to_window({_staff_id, _kind, nil, _end}), do: @all_day
  defp to_window({_staff_id, _kind, _start, nil}), do: @all_day
  defp to_window({_staff_id, _kind, start_min, end_min}), do: {start_min, end_min}

  @doc """
  Overlapping and touching spans collapsed into the fewest that cover the same
  minutes.
  """
  def merge([]), do: []

  def merge(spans) do
    spans
    |> Enum.sort()
    |> Enum.reduce([], fn
      span, [] ->
        [span]

      {start_min, end_min}, [{open, close} | rest] when start_min <= close ->
        [{open, max(close, end_min)} | rest]

      span, acc ->
        [span | acc]
    end)
    |> Enum.reverse()
  end

  ## ---------- reading ----------

  @doc """
  Blocks for a venue, newest first, optionally narrowed to one staff member and
  a date window.

  A weekly rule is returned whenever its start date is on or before the end of
  the window: it has no end, so "in this window" is only about when it began.
  """
  def list(venue_id, opts \\ []) do
    from(b in scope(Block, venue_id), order_by: [asc: b.date, asc: b.start_min])
    |> filter_staff(opts[:staff_id])
    |> filter_window(opts[:from], opts[:to])
    |> Repo.all()
  end

  defp filter_staff(query, nil), do: query
  defp filter_staff(query, staff_id), do: from(b in query, where: b.staff_id == ^staff_id)

  defp filter_window(query, nil, nil), do: query

  defp filter_window(query, from_date, to_date) do
    query
    |> then(fn q ->
      if to_date, do: from(b in q, where: b.date <= ^to_date), else: q
    end)
    |> then(fn q ->
      if from_date,
        do: from(b in q, where: b.weekly or coalesce(b.end_date, b.date) >= ^from_date),
        else: q
    end)
  end

  def get(venue_id, id), do: get_scoped(Repo, Block, id, venue_id)

  ## ---------- writing ----------

  @doc """
  Creates a block.

  Does **not** check for appointments it would strand — see `conflicts/2`. F0.4
  established the pattern and F0.7 repeats it: the person is shown what they
  are about to break and decides, because a stylist taking Thursday off still
  has to telephone the three people booked that afternoon.
  """
  def create(venue_id, attrs) do
    changeset = Block.changeset(%Block{}, Map.put(attrs, :venue_id, venue_id))

    # The foreign key proves the staff member exists, not that they work here.
    # Without this a manager could write a row against another venue's staff:
    # invisible to both venues' availability, which scopes by venue, but a real
    # row pointing across a tenant boundary — and the next feature to read
    # blocks by `staff_id` alone would honour it.
    if own_staff?(venue_id, Ecto.Changeset.get_field(changeset, :staff_id)) do
      Repo.insert(changeset)
    else
      {:error, Ecto.Changeset.add_error(changeset, :staff_id, "does not work at this venue")}
    end
  end

  defp own_staff?(venue_id, staff_id), do: Blastek.Salon.staff_member?(venue_id, staff_id)

  def delete(venue_id, id) do
    case get(venue_id, id) do
      nil -> {:error, :not_found}
      block -> Repo.delete(block)
    end
  end

  @doc """
  Appointments a proposed block would sit on top of.

  Returned rather than acted on. A weekly repeat is checked only over the next
  eight weeks: far enough to cover everything a salon has actually booked, and
  short enough that the answer arrives while the owner is still looking at the
  form.
  """
  @weekly_horizon_weeks 8

  def conflicts(venue_id, attrs) do
    with {:ok, staff_id} <- fetch_int(attrs, :staff_id),
         {:ok, date} <- fetch_date(attrs, :date) do
      dates = occurrence_dates(attrs, date)
      start_min = attrs[:start_min] || attrs["start_min"]
      end_min = attrs[:end_min] || attrs["end_min"]

      Enum.flat_map(dates, fn {from_date, to_date} ->
        Blastek.Salon.appointments_in_window(venue_id, from_date, to_date, start_min, end_min,
          staff_id: staff_id
        )
      end)
    else
      _ -> []
    end
  end

  # A weekly rule is a list of single days; everything else is one span.
  defp occurrence_dates(attrs, date) do
    if truthy(attrs[:weekly] || attrs["weekly"]) do
      for week <- 0..(@weekly_horizon_weeks - 1) do
        day = Date.add(date, week * 7)
        {day, day}
      end
    else
      [{date, attrs[:end_date] || attrs["end_date"] || date}]
    end
  end

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false

  defp fetch_int(attrs, key) do
    case attrs[key] || attrs[to_string(key)] do
      value when is_integer(value) -> {:ok, value}
      value when is_binary(value) -> Integer.parse(value) |> then(fn {n, _} -> {:ok, n} end)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp fetch_date(attrs, key) do
    case attrs[key] || attrs[to_string(key)] do
      %Date{} = date -> {:ok, date}
      value when is_binary(value) -> Date.from_iso8601(value)
      _ -> :error
    end
  end

  @doc """
  Whether a block falls outside the staff member's working hours that day.

  Not an error — F0.7 asks for a *warning*. A break at 12:00 is still a break
  when a Ramadan template moves the working day to 20:00–01:00; it simply no
  longer does anything, and the owner is the one who should decide whether that
  matters.
  """
  def outside_hours?(nil, _start_min, _end_min), do: false
  def outside_hours?(_hours, nil, _end_min), do: false
  def outside_hours?(_hours, _start_min, nil), do: false

  def outside_hours?({open_min, close_min}, start_min, end_min) do
    start_min >= close_min or end_min <= open_min
  end
end
