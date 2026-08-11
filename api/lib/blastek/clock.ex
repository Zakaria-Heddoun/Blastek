defmodule Blastek.Clock do
  @moduledoc """
  What time it is where the salon is.

  ## Why this is not `NaiveDateTime.local_now/0`

  Appointments are stored as a date and a minute-of-day, and both are already
  *local wall clock* — that is what a customer is being told to turn up at, and
  it is what a salon typed into its calendar. Anything comparing against them
  has to be on the same clock.

  `NaiveDateTime.local_now/0` is the clock of whatever machine happens to be
  running, and that machine is a container set to UTC. Morocco is UTC+1 for most
  of the year, so the two are an hour apart, and every comparison between them
  is an hour wrong in the direction that costs something:

    * a T-3h reminder for an appointment two hours away is computed as still in
      the future, scheduled, and fires the moment Oban notices;
    * a two-hour cancellation window lets a customer cancel with one hour's
      notice, which is the case the window exists to prevent;
    * a venue asking two hours' notice for online bookings gets one.

  None of them raise, and all of them are exactly the kind of thing that reads
  as "the software is a bit off" rather than as a bug.

  ## One timezone, for now

  F0.10 fixes Morocco for Phase 0 and `venues` carries a column for when that
  stops being true — a venue argument belongs on these functions the day the
  second country does. Morocco is UTC+1, and UTC+0 through Ramadan, which is
  precisely when a salon's hours have already moved.

  The conversions need a real timezone database (`:tz`); Elixir ships a UTC-only
  one under which every one of these raises.
  """
  require Logger

  @timezone "Africa/Casablanca"

  @doc "The timezone every stored appointment time is expressed in."
  def timezone, do: @timezone

  @doc "Now, on the salon's wall clock, as a `NaiveDateTime`."
  def now do
    case DateTime.now(@timezone) do
      {:ok, local} ->
        local |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

      {:error, reason} ->
        warn(reason, "the server clock is being used instead")
        NaiveDateTime.local_now()
    end
  end

  @doc "Today, on the salon's wall clock. Not `Date.utc_today/0`, which is yesterday until 01:00."
  def today, do: now() |> NaiveDateTime.to_date()

  @doc "Minutes since midnight, on the salon's wall clock."
  def minute_of_day do
    now = now()
    now.hour * 60 + now.minute
  end

  @doc """
  A local wall-clock time as the UTC instant it actually happens at.

  Used for scheduling: Oban stores UTC, and "the evening before" is local.
  """
  def to_utc(%NaiveDateTime{} = at) do
    case DateTime.from_naive(at, @timezone) do
      {:ok, local} ->
        DateTime.shift_zone!(local, "Etc/UTC")

      # The hour a clock change repeats or omits. Either candidate is within an
      # hour of right, and refusing to schedule would be worse than being early.
      {:ambiguous, first, _second} ->
        DateTime.shift_zone!(first, "Etc/UTC")

      {:gap, _before, after_gap} ->
        DateTime.shift_zone!(after_gap, "Etc/UTC")

      {:error, reason} ->
        warn(reason, "scheduled times will land at the wrong local time")
        DateTime.from_naive!(at, "Etc/UTC")
    end
  end

  # Loudly, because the failure mode is a silent hour of drift rather than a
  # crash, and an hour of drift is invisible until a customer misses something.
  defp warn(reason, consequence) do
    Logger.error("no timezone database for #{@timezone} (#{inspect(reason)}); #{consequence}")
  end
end
