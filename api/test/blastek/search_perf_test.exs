defmodule Blastek.SearchPerfTest do
  @moduledoc """
  Search latency at 1 000 venues (E8-T9 / F0.6): p95 under 300 ms.

  `async: false` on purpose. This measures wall-clock time, and letting the rest
  of the suite compete for the same connection pool and CPU would turn a
  performance gate into a coin flip.

  The budget is deliberately far above what the query costs (a GIN lookup over
  1 000 documents is single-digit milliseconds), because the number that matters
  is the one a shared CI runner can honour. The value here is as a **regression
  gate**: reintroduce `LIKE '%term%'`, drop the GIN index, or add an N+1 to the
  card resolvers and this fails long before the budget is reached.
  """
  use Blastek.DataCase, async: false

  # Building a 7 000-row fixture is not what is being measured, but it happens
  # inside the test and so counts against ExUnit's wall clock. Under a loaded
  # Docker host that setup has taken over the default 60 s — turning a slow
  # *machine* into a failed *performance assertion*, which is the most
  # misleading way a gate like this can fail. The budget below is asserted
  # explicitly and precisely; this timeout only has to be out of its way.
  @moduletag timeout: 300_000
  # The sandbox holds its connection for the fixture *and* the measurement, and
  # its own limit is 120 s regardless of the one above. Three CI runs died on
  # that rather than on a slow query.
  @moduletag ownership_timeout: 300_000

  alias Blastek.Discovery
  alias Blastek.Repo

  @venue_count 1_000
  @services_per_venue 4
  @budget_ms 300
  @iterations 20

  # Assembled into venue names, cities and treatment names so searches hit a
  # realistic spread rather than all matching or all missing.
  @cities ~w(Casablanca Rabat Marrakech Tanger Fes Agadir Meknes Oujda)
  @brands ~w(Éclat Anfa Riad Nova Lumière Zenith Medina Atlas Cristal Perle)
  @kinds ~w(Salon Barbershop Spa Studio Institut)
  @treatments [
    "Coupe femme",
    "Coupe homme",
    "Skin fade",
    "Balayage",
    "Brushing",
    "Hammam traditionnel",
    "Gommage corps",
    "Manucure",
    "Pédicure",
    "Épilation sourcils",
    "Barbe traditionnelle",
    "Coloration racines"
  ]

  setup do
    seed_directory()
    :ok
  end

  test "p95 search latency stays within budget at #{@venue_count} venues" do
    assert Repo.aggregate("venues", :count) >= @venue_count

    # One warm-up so the measurement is not dominated by first-call overhead
    # (query planning, connection checkout) that a real user never pays alone.
    Discovery.search(q: "coupe")

    scenarios = [
      {"single term", [q: "fade"]},
      {"two terms ANDed", [q: "coupe femme"]},
      {"prefix match", [q: "hamm"]},
      {"accented term", [q: "epilation"]},
      {"term + city filter", [q: "coupe", city: "Casablanca"]},
      {"city only", [city: "Rabat"]},
      {"category filter", [category: "Coiffure"]},
      {"women-only filter", [women_only: true]},
      {"distance sort", [near: {33.5883, -7.6329}, sort: "distance"]},
      {"radius filter", [near: {33.5883, -7.6329}, within_km: 25.0]},
      {"rating sort", [sort: "rating"]},
      {"price sort", [sort: "price"]},
      {"deep page", [q: "coupe", limit: 24, offset: 240]}
    ]

    results = Enum.map(scenarios, fn {name, opts} -> {name, measure(opts)} end)

    for {name, timings} <- results do
      p95 = percentile(timings, 95)

      assert p95 < @budget_ms,
             """
             #{name}: p95 #{Float.round(p95, 1)} ms exceeds the #{@budget_ms} ms budget.
             median #{Float.round(percentile(timings, 50), 1)} ms, \
             max #{Float.round(Enum.max(timings), 1)} ms
             """
    end

    # Printed rather than asserted: the trend across runs is the useful signal,
    # and a headline number in CI output is how a slow drift gets noticed.
    slowest =
      results
      |> Enum.map(fn {name, timings} -> {name, percentile(timings, 95)} end)
      |> Enum.max_by(&elem(&1, 1))

    IO.puts(
      "\n  search p95 @#{@venue_count} venues — slowest: #{elem(slowest, 0)} " <>
        "#{Float.round(elem(slowest, 1), 1)} ms (budget #{@budget_ms} ms)"
    )

    # Correctness, in the same test rather than its own, because a second test
    # would rebuild the whole 7 000-row fixture to assert one thing. A fast
    # search that has quietly stopped filtering would sail through the timings
    # above, so the gate needs both halves.
    page = Discovery.search(q: "hammam traditionnel", limit: 5)

    assert page.total_count > 0
    assert length(page.items) <= 5
    assert Enum.all?(page.items, &offers?(&1.id, "Hammam traditionnel"))
  end

  defp offers?(venue_id, treatment) do
    Repo.exists?(
      from s in Blastek.Salon.Service,
        where: s.venue_id == ^venue_id and s.active and s.name == ^treatment
    )
  end

  defp measure(opts) do
    for _ <- 1..@iterations do
      {microseconds, _result} = :timer.tc(fn -> Discovery.search(opts) end)
      microseconds / 1000
    end
  end

  defp percentile(timings, p) do
    sorted = Enum.sort(timings)
    index = (p / 100 * (length(sorted) - 1)) |> Float.round() |> trunc()
    Enum.at(sorted, index)
  end

  ## ---------- fixture ----------

  # Built with `insert_all` rather than the contexts: 1 000 venues through
  # `create_venue/1` would be 1 000 reindex statements and slug-uniqueness
  # lookups, which measures the seeding, not the search.
  #
  # Fixture statements get a generous timeout. Building the fixture is not what
  # is under test, and on a loaded CI runner the default pool timeout turns a
  # slow *setup* into a failed *assertion* — which reads as a performance
  # regression that did not happen.
  @fixture_timeout 120_000

  defp seed_directory do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    venues =
      for n <- 1..@venue_count do
        brand = Enum.at(@brands, rem(n, length(@brands)))
        kind = Enum.at(@kinds, rem(n, length(@kinds)))
        city = Enum.at(@cities, rem(n, length(@cities)))

        %{
          slug: "perf-venue-#{n}",
          name: "#{kind} #{brand} #{n}",
          tagline: "Beauté et bien-être à #{city}",
          address: "#{n} Rue de Test",
          city: city,
          phone: "+212500000000",
          status: "active",
          # Spread across Morocco so a radius filter excludes a real majority.
          lat: 33.5 + rem(n, 40) * 0.05,
          lng: -7.6 + rem(n, 40) * 0.05,
          settings: %{"women_only" => rem(n, 4) == 0},
          inserted_at: now,
          updated_at: now
        }
      end

    {_, venue_rows} =
      Repo.insert_all("venues", venues, returning: [:id], timeout: @fixture_timeout)

    venue_ids = Enum.map(venue_rows, & &1.id)

    categories =
      for venue_id <- venue_ids,
          {name, sort} <- Enum.with_index(["Coiffure", "Soins"]) do
        %{name: name, sort: sort, venue_id: venue_id}
      end

    {_, category_rows} =
      Repo.insert_all("service_categories", categories,
        returning: [:id],
        timeout: @fixture_timeout
      )

    # Two categories per venue, in insertion order.
    category_by_venue =
      category_rows
      |> Enum.map(& &1.id)
      |> Enum.chunk_every(2)
      |> Enum.zip(venue_ids)
      |> Map.new(fn {ids, venue_id} -> {venue_id, ids} end)

    services =
      for {venue_id, index} <- Enum.with_index(venue_ids),
          offset <- 0..(@services_per_venue - 1) do
        treatment = Enum.at(@treatments, rem(index + offset, length(@treatments)))
        [first, second] = Map.fetch!(category_by_venue, venue_id)

        %{
          name: treatment,
          description: "#{treatment} par nos spécialistes",
          duration_min: 30 + offset * 15,
          price_cents: 8_000 + offset * 2_500,
          active: true,
          venue_id: venue_id,
          category_id: if(rem(offset, 2) == 0, do: first, else: second)
        }
      end

    # Chunked to stay under Postgres' parameter limit per statement.
    services
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all("services", &1, timeout: @fixture_timeout))

    reviews =
      for {venue_id, index} <- Enum.with_index(venue_ids), rem(index, 3) == 0 do
        %{
          venue_id: venue_id,
          client_name: "Client #{index}",
          rating: rem(index, 5) + 1,
          comment: "",
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all("reviews", reviews, timeout: @fixture_timeout)

    # One statement builds every document — the same one the app uses.
    Discovery.reindex_all(timeout: @fixture_timeout)
  end
end
