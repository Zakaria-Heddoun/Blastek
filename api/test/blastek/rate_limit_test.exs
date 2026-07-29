defmodule Blastek.RateLimitTest do
  @moduledoc "Rate limiting (E2-T5): budgets, isolation between buckets, and expiry."
  use ExUnit.Case, async: false

  alias Blastek.RateLimit

  setup do
    RateLimit.reset()
    :ok
  end

  test "allows up to the limit then denies" do
    for _ <- 1..3 do
      assert :ok = RateLimit.hit({:test, "a"}, 3, :timer.minutes(1))
    end

    assert {:error, retry_after} = RateLimit.hit({:test, "a"}, 3, :timer.minutes(1))
    assert retry_after > 0 and retry_after <= 60
  end

  test "buckets are independent" do
    for _ <- 1..3, do: RateLimit.hit({:test, "a"}, 3, :timer.minutes(1))

    assert {:error, _} = RateLimit.hit({:test, "a"}, 3, :timer.minutes(1))
    # A different key has its own untouched budget.
    assert :ok = RateLimit.hit({:test, "b"}, 3, :timer.minutes(1))
  end

  test "the same key under different window sizes does not share a counter" do
    for _ <- 1..3, do: RateLimit.hit({:test, "c"}, 3, 1_000)

    assert {:error, _} = RateLimit.hit({:test, "c"}, 3, 1_000)
    assert :ok = RateLimit.hit({:test, "c"}, 3, :timer.minutes(5))
  end

  test "the budget refreshes when the window rolls over" do
    # A 1-second window makes the rollover observable without a long sleep.
    for _ <- 1..2, do: RateLimit.hit({:test, "d"}, 2, 1_000)
    assert {:error, _} = RateLimit.hit({:test, "d"}, 2, 1_000)

    Process.sleep(1_100)
    assert :ok = RateLimit.hit({:test, "d"}, 2, 1_000)
  end

  test "concurrent hits are counted exactly once each" do
    limit = 50

    results =
      1..100
      |> Task.async_stream(fn _ -> RateLimit.hit({:test, "race"}, limit, :timer.minutes(1)) end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, r} -> r end)

    # No lost increments: exactly `limit` allowed, the rest denied.
    assert Enum.count(results, &(&1 == :ok)) == limit
  end
end
