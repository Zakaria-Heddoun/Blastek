defmodule BlastekWeb.AuthorizationTest do
  @moduledoc """
  The GraphQL authorization matrix: which role may run which operation, and the
  guarantee that a member of one venue cannot address another venue's data
  through the API.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Venues
  alias BlastekWeb.Schema

  setup do
    a = venue_fixture("Auth Salon A")
    b = venue_fixture("Auth Salon B")
    %{a: a, b: b}
  end

  # Mirrors what BlastekWeb.AuthContext builds for a signed-in dashboard user.
  defp context_for(user) do
    memberships = Venues.list_memberships(user.id)

    case memberships do
      [m | _] ->
        %{current_user: user, memberships: memberships, membership: m,
          current_venue: m.venue, venue_id: m.venue_id}

      [] ->
        %{current_user: user, memberships: []}
    end
  end

  defp run(query, context, variables \\ %{}) do
    Absinthe.run(query, Schema, context: context, variables: variables)
  end

  defp error_message({:ok, %{errors: [%{message: msg} | _]}}), do: msg
  defp error_message(other), do: flunk("expected an error, got: #{inspect(other)}")

  describe "signed-out callers" do
    test "cannot read dashboard data" do
      assert {:ok, %{errors: [%{message: msg}]}} = run("{ clients { id } }", %{})
      assert msg =~ "signed in"
    end

    test "can read a public venue page", %{a: a} do
      assert {:ok, %{data: %{"venue" => venue}}} =
               run(~s|{ venue(slug: "#{a.venue.slug}") { slug settings { businessName } } }|, %{})

      assert venue["slug"] == a.venue.slug
      assert venue["settings"]["businessName"] == "Auth Salon A"
    end

    test "cannot book", %{a: a} do
      query = ~s"""
      mutation { book(venueSlug: "#{a.venue.slug}", serviceIds: ["#{a.service.id}"],
        date: "#{Date.add(Date.utc_today(), 2)}", startMin: 600) { bookingRef } }
      """

      assert error_message(run(query, %{})) =~ "signed in"
    end
  end

  describe "a customer with no membership" do
    setup do
      %{user: user_fixture("nobody@example.com")}
    end

    test "is refused every dashboard field", %{user: user} do
      ctx = context_for(user)

      for query <- [
            "{ clients { id } }",
            "{ services { id } }",
            "{ staff { id } }",
            "{ sales(from: \"2020-01-01\") { id } }",
            "{ reportSummary { revenue } }",
            "{ appointments(from: \"2020-01-01\", to: \"2030-01-01\") { id } }"
          ] do
        assert error_message(run(query, ctx)) =~ ~r/do not manage a venue|signed in/,
               "expected #{query} to be refused"
      end
    end

    test "sees no venues", %{user: user} do
      assert {:ok, %{data: %{"myVenues" => []}}} = run("{ myVenues { id } }", context_for(user))
    end
  end

  describe "role gates" do
    test "staff cannot read clients, sales or reports", %{a: a} do
      %{user: user} = member_fixture(a.venue, "staff", "staff@example.com")
      ctx = context_for(user)

      assert error_message(run("{ clients { id } }", ctx)) =~ "role does not allow"
      assert error_message(run("{ sales(from: \"2020-01-01\") { id } }", ctx)) =~ "role does not allow"
      assert error_message(run("{ reportSummary { revenue } }", ctx)) =~ "role does not allow"
    end

    test "staff can read the calendar", %{a: a} do
      %{user: user} = member_fixture(a.venue, "staff", "staff2@example.com")

      assert {:ok, %{data: %{"appointments" => _}}} =
               run("{ appointments(from: \"2020-01-01\", to: \"2030-01-01\") { id } }",
                 context_for(user))
    end

    test "a staff member linked to a calendar column sees only their own appointments", %{a: a} do
      {:ok, second_staff} =
        Blastek.Salon.create_staff(
          a.venue.id,
          %{name: "Second Stylist", color: "#111111"},
          for(wd <- 0..6, do: %{weekday: wd, working: true, start_min: 540, end_min: 1080}),
          [a.service.id]
        )

      own = appointment_fixture(a)
      _other = appointment_fixture(%{a | staff: second_staff})

      user = user_fixture("column-staff@example.com")
      {:ok, _} = Venues.add_member(a.venue.id, user.id, "staff", a.staff.id)

      assert {:ok, %{data: %{"appointments" => appts}}} =
               run("{ appointments(from: \"2020-01-01\", to: \"2030-01-01\") { id staff { id } } }",
                 context_for(user))

      assert Enum.map(appts, & &1["id"]) == [to_string(own.id)]
    end

    test "receptionists can read clients but not reports or the catalog", %{a: a} do
      %{user: user} = member_fixture(a.venue, "receptionist", "recep@example.com")
      ctx = context_for(user)

      assert {:ok, %{data: %{"clients" => _}}} = run("{ clients { id } }", ctx)
      assert error_message(run("{ reportSummary { revenue } }", ctx)) =~ "role does not allow"

      mutation = ~s|mutation { createCategory(name: "New") { id } }|
      assert error_message(run(mutation, ctx)) =~ "role does not allow"
    end

    test "managers can manage the catalog but not the venue itself", %{a: a} do
      %{user: user} = member_fixture(a.venue, "manager", "manager@example.com")
      ctx = context_for(user)

      assert {:ok, %{data: %{"createCategory" => %{"id" => _}}}} =
               run(~s|mutation { createCategory(name: "Nails") { id } }|, ctx)

      assert error_message(run(~s|mutation { updateVenue(input: {name: "Hijack"}) { id } }|, ctx)) =~
               "role does not allow"
    end

    test "owners can rename their venue", %{a: a} do
      %{user: user} = member_fixture(a.venue, "owner", "owner@example.com")

      assert {:ok, %{data: %{"updateVenue" => %{"name" => "Renamed"}}}} =
               run(~s|mutation { updateVenue(input: {name: "Renamed"}) { id name } }|,
                 context_for(user))
    end
  end

  describe "cross-tenant access through the API" do
    setup %{a: a} do
      %{user: user} = member_fixture(a.venue, "owner", "tenant-owner@example.com")
      %{ctx: context_for(user)}
    end

    test "reads return only the caller's venue", %{ctx: ctx, a: a, b: b} do
      assert {:ok, %{data: %{"services" => services}}} = run("{ services { id name } }", ctx)
      ids = Enum.map(services, & &1["id"])

      assert to_string(a.service.id) in ids
      refute to_string(b.service.id) in ids
    end

    test "a foreign client id is not readable", %{ctx: ctx, b: b} do
      query = ~s|{ client(id: "#{b.client.id}") { id firstName } }|
      assert {:ok, result} = run(query, ctx)
      # Scoped lookups raise NoResultsError, surfaced as a GraphQL error.
      assert result[:errors] != nil or result.data["client"] == nil
    end

    test "a foreign appointment cannot be modified", %{ctx: ctx, b: b} do
      appt = appointment_fixture(b)
      query = ~s|mutation { updateAppointment(id: "#{appt.id}", status: "cancelled") { id } }|

      assert {:ok, result} = run(query, ctx)
      assert result[:errors] != nil

      assert Blastek.Repo.get!(Blastek.Salon.Appointment, appt.id).status == "booked"
    end

    test "the venue is taken from the session, not from arguments", %{ctx: ctx, b: b} do
      # There is no venue argument to forge on dashboard fields; confirm that
      # supplying one is a schema error rather than an access path.
      assert {:ok, %{errors: errors}} = run(~s|{ services(venueId: "#{b.venue.id}") { id } }|, ctx)
      assert Enum.any?(errors, &(&1.message =~ "Unknown argument"))
    end
  end

  describe "customer bookings" do
    test "a customer books at a venue and sees it in myAppointments", %{a: a} do
      user = user_fixture("buyer@example.com")
      ctx = context_for(user)
      date = Date.add(Date.utc_today(), 2)

      book = ~s"""
      mutation { book(venueSlug: "#{a.venue.slug}", serviceIds: ["#{a.service.id}"],
        date: "#{date}", startMin: 600) { bookingRef appointments { id } } }
      """

      assert {:ok, %{data: %{"book" => %{"bookingRef" => ref}}}} = run(book, ctx)
      assert ref =~ "BK-"

      assert {:ok, %{data: %{"myAppointments" => [appt]}}} =
               run("{ myAppointments { id venue { slug name } } }", ctx)

      assert appt["venue"]["slug"] == a.venue.slug
    end

    test "a customer cannot cancel someone else's appointment", %{a: a} do
      other = appointment_fixture(a)
      user = user_fixture("stranger@example.com")

      query = ~s|mutation { cancelMyAppointment(id: "#{other.id}") { id status } }|
      assert error_message(run(query, context_for(user))) =~ "no longer be cancelled"
    end

    test "booking a suspended venue is refused", %{a: a} do
      {:ok, _} = Venues.update_venue(a.venue, %{status: "suspended"})
      user = user_fixture("late@example.com")

      query = ~s"""
      mutation { book(venueSlug: "#{a.venue.slug}", serviceIds: ["#{a.service.id}"],
        date: "#{Date.add(Date.utc_today(), 2)}", startMin: 600) { bookingRef } }
      """

      assert error_message(run(query, context_for(user))) =~ "not found"
    end
  end

  describe "platform admin" do
    test "adminVenues lists every venue regardless of status; others are refused", %{a: a, b: b} do
      {:ok, _} = Venues.update_venue(b.venue, %{status: "suspended"})

      admin = admin_fixture("admin@blastek.ma")

      assert {:ok, %{data: %{"adminVenues" => venues}}} =
               run("{ adminVenues { slug status } }", %{current_user: admin, memberships: []})

      slugs = Enum.map(venues, & &1["slug"])
      assert a.venue.slug in slugs
      assert b.venue.slug in slugs

      customer = user_fixture("pleb@example.com")

      assert error_message(
               run("{ adminVenues { slug } }", %{current_user: customer, memberships: []})
             ) =~ "Not authorized"
    end
  end

  describe "venue selection" do
    test "a member of two venues acts on the one they selected", %{a: a, b: b} do
      %{user: user} = member_fixture(a.venue, "owner", "multi@example.com")
      {:ok, _} = Venues.add_member(b.venue.id, user.id, "owner")

      memberships = Venues.list_memberships(user.id)
      pick = fn slug -> Enum.find(memberships, &(&1.venue.slug == slug)) end

      for venue <- [a.venue, b.venue] do
        m = pick.(venue.slug)

        ctx = %{current_user: user, memberships: memberships, membership: m,
          current_venue: m.venue, venue_id: m.venue_id}

        assert {:ok, %{data: %{"services" => [service]}}} = run("{ services { id } }", ctx)

        expected =
          if venue.id == a.venue.id, do: a.service.id, else: b.service.id

        assert service["id"] == to_string(expected)
      end
    end
  end
end
