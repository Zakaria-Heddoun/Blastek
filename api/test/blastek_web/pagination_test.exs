defmodule BlastekWeb.PaginationTest do
  @moduledoc """
  Paging contracts (E2-T1): a client cannot ask for an unbounded result set,
  and `totalCount` describes the whole filtered set rather than the page.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Salon
  alias Blastek.Venues
  alias BlastekWeb.Schema

  setup do
    v = venue_fixture("Paged Salon")
    %{user: user} = member_fixture(v.venue, "owner", "pager@example.com")

    for i <- 1..12 do
      {:ok, _} =
        Salon.create_client(v.venue.id, %{
          first_name: "Client#{String.pad_leading(to_string(i), 2, "0")}",
          last_name: "Test",
          email: "paged#{i}@example.com"
        })
    end

    memberships = Venues.list_memberships(user.id)
    m = hd(memberships)

    ctx = %{
      current_user: user,
      memberships: memberships,
      membership: m,
      current_venue: m.venue,
      venue_id: m.venue_id
    }

    %{v: v, ctx: ctx}
  end

  defp run(query, ctx), do: Absinthe.run(query, Schema, context: ctx)

  test "a page carries the total of the whole set", %{ctx: ctx} do
    assert {:ok, %{data: %{"clients" => page}}} =
             run("{ clients(limit: 5, offset: 0) { totalCount items { firstName } } }", ctx)

    # 12 created + 1 from the venue fixture.
    assert page["totalCount"] == 13
    assert length(page["items"]) == 5
  end

  test "offset walks the set without repeats", %{ctx: ctx} do
    names = fn offset ->
      {:ok, %{data: %{"clients" => page}}} =
        run("{ clients(limit: 5, offset: #{offset}) { items { firstName } } }", ctx)

      Enum.map(page["items"], & &1["firstName"])
    end

    first = names.(0)
    second = names.(5)
    third = names.(10)

    assert length(first) == 5
    assert length(second) == 5
    assert length(third) == 3
    assert Enum.uniq(first ++ second ++ third) == first ++ second ++ third
  end

  test "an oversized limit is clamped rather than honoured", %{ctx: ctx} do
    assert {:ok, %{data: %{"clients" => page}}} =
             run("{ clients(limit: 99999) { items { id } } }", ctx)

    assert length(page["items"]) <= 200
  end

  test "a negative offset does not crash the query", %{ctx: ctx} do
    assert {:ok, %{data: %{"clients" => page}}} =
             run("{ clients(limit: 5, offset: -10) { items { id } } }", ctx)

    assert length(page["items"]) == 5
  end

  test "totalCount respects the search filter", %{ctx: ctx} do
    assert {:ok, %{data: %{"clients" => page}}} =
             run(~s|{ clients(q: "Client01") { totalCount items { firstName } } }|, ctx)

    assert page["totalCount"] == 1
    assert [%{"firstName" => "Client01"}] = page["items"]
  end

  test "sales are paginated the same way", %{v: v, ctx: ctx} do
    for start <- [540, 600, 660] do
      appt = appointment_fixture(v, %{start_min: start})
      {:ok, _} = Salon.checkout(v.venue.id, [appt.id], 0, "cash")
    end

    assert {:ok, %{data: %{"sales" => page}}} =
             run(~s|{ sales(from: "2020-01-01", limit: 2) { totalCount items { id } } }|, ctx)

    assert page["totalCount"] == 3
    assert length(page["items"]) == 2
  end

  describe "calendar range" do
    test "a range wider than a quarter is refused", %{ctx: ctx} do
      assert {:ok, %{errors: [%{message: msg}]}} =
               run(~s|{ appointments(from: "2020-01-01", to: "2030-01-01") { id } }|, ctx)

      assert msg =~ "too wide"
    end

    test "an inverted range is refused", %{ctx: ctx} do
      assert {:ok, %{errors: [%{message: msg}]}} =
               run(~s|{ appointments(from: "2026-03-01", to: "2026-01-01") { id } }|, ctx)

      assert msg =~ "must not be after"
    end

    test "a normal week is allowed", %{ctx: ctx} do
      today = Date.utc_today()

      assert {:ok, %{data: %{"appointments" => _}}} =
               run(
                 ~s|{ appointments(from: "#{today}", to: "#{Date.add(today, 7)}") { id } }|,
                 ctx
               )
    end
  end
end
