defmodule Blastek.RateLimit do
  @moduledoc """
  Fixed-window rate limiting on an ETS counter table (E2-T5 / F0.13).

  Counters live in a single `:set` table keyed by `{bucket, window}`, bumped
  with `:ets.update_counter/4` so concurrent requests cannot lose an increment.
  Expired windows are swept periodically rather than on read, keeping the hot
  path to one atomic operation.

  Scope: this limiter is **per node**. That is the whole deployment today; a
  multi-node setup needs a shared store (Redis) or sticky routing, and the
  buckets below would move there unchanged.
  """
  use GenServer

  @table :blastek_rate_limit
  @sweep_every :timer.minutes(2)

  ## ---------- API ----------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one hit against `bucket`.

  Returns `:ok` while under `limit` within `window_ms`, or
  `{:error, retry_after_seconds}` once the window is full.
  """
  def hit(bucket, limit, window_ms) do
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    key = {bucket, window_ms, window}
    expires_at = (window + 1) * window_ms

    # Rows carry their own expiry so the sweep works across mixed window sizes.
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0, expires_at})

    if count <= limit,
      do: :ok,
      else: {:error, max(1, div(expires_at - now + 999, 1000))}
  rescue
    # No table yet (e.g. a unit test that does not start the app): fail open
    # rather than break the request.
    ArgumentError -> :ok
  end

  @doc "Clears all counters. Test support."
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  ## ---------- server ----------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)
end
