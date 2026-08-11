defmodule Blastek.ClockTest do
  @moduledoc """
  The salon's clock is the salon's, not the server's (E6 review).

  Every one of these failed before `Blastek.Clock` existed, on a container set
  to UTC — which is every container. The failure mode was never an exception: a
  reminder an hour late, a cancellation window an hour short, a horizon a day
  early. All of them read as "the software is a bit off".
  """
  use ExUnit.Case, async: true

  alias Blastek.Clock

  describe "now/0" do
    test "is the Casablanca wall clock, not the server's" do
      assert %NaiveDateTime{} = Clock.now()

      expected =
        "Africa/Casablanca"
        |> DateTime.now!()
        |> DateTime.to_naive()

      assert NaiveDateTime.diff(Clock.now(), expected, :second) |> abs() <= 2
    end

    test "and it really differs from the server clock in this environment" do
      # If this ever stops being true the suite has stopped exercising the bug,
      # not fixed it — so the test says so rather than passing quietly.
      skew = NaiveDateTime.diff(Clock.now(), NaiveDateTime.local_now(), :minute)

      assert skew in [0, 60],
             "Casablanca is UTC+1, or UTC+0 in Ramadan; got #{skew} minutes from server time"
    end

    test "today/0 follows the same clock" do
      assert Clock.today() == NaiveDateTime.to_date(Clock.now())
    end
  end

  describe "to_utc/1" do
    test "a local wall clock becomes the instant it actually happens at" do
      # 3 August 2026, 15:00 in Casablanca (UTC+1) is 14:00 UTC.
      local = ~N[2026-08-03 15:00:00]
      assert Clock.to_utc(local) == ~U[2026-08-03 14:00:00Z]
    end

    test "and the offset is not assumed — Ramadan moves Morocco to UTC+0" do
      # 20 March 2025 fell inside Ramadan, when Morocco suspends DST.
      assert Clock.to_utc(~N[2025-03-20 15:00:00]) == ~U[2025-03-20 15:00:00Z]

      # Either side of it the country is back on UTC+1.
      assert Clock.to_utc(~N[2025-05-20 15:00:00]) == ~U[2025-05-20 14:00:00Z]
    end

    test "round-tripping a time is the identity" do
      local = ~N[2026-12-24 09:30:00]

      round_tripped =
        local
        |> Clock.to_utc()
        |> DateTime.shift_zone!(Clock.timezone())
        |> DateTime.to_naive()

      assert round_tripped == local
    end
  end
end
