defmodule Blastek.TenancyTest do
  @moduledoc """
  Tenant isolation at the context layer: every venue-scoped read must be blind
  to other venues' rows, and every write must refuse to reach across tenants.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Salon
  alias Blastek.Venues

  setup do
    a = venue_fixture("Salon A")
    b = venue_fixture("Salon B")
    %{a: a, b: b}
  end

  describe "reads are scoped to one venue" do
    test "catalog, team and clients never leak", %{a: a, b: b} do
      assert [cat] = Salon.list_categories(a.venue.id)
      assert cat.id == a.category.id

      assert [svc] = Salon.list_services(a.venue.id)
      assert svc.id == a.service.id
      refute svc.id == b.service.id

      assert [staff] = Salon.list_staff(a.venue.id)
      assert staff.id == a.staff.id

      assert [client] = Salon.list_clients(a.venue.id, nil)
      assert client.id == a.client.id
    end

    test "fetching another venue's row by id raises", %{a: a, b: b} do
      assert_raise Ecto.NoResultsError, fn -> Salon.get_service!(a.venue.id, b.service.id) end
      assert_raise Ecto.NoResultsError, fn -> Salon.get_staff!(a.venue.id, b.staff.id) end
      assert_raise Ecto.NoResultsError, fn -> Salon.get_client!(a.venue.id, b.client.id) end
    end

    test "appointments and sales are scoped", %{a: a, b: b} do
      appt_a = appointment_fixture(a)
      _appt_b = appointment_fixture(b)

      from = Date.add(Date.utc_today(), -1)
      to = Date.add(Date.utc_today(), 30)

      assert [only] = Salon.list_appointments(a.venue.id, from, to)
      assert only.id == appt_a.id

      {:ok, _sale} = Salon.checkout(a.venue.id, [appt_a.id], 0, "cash")

      assert [_] = Salon.list_sales(a.venue.id, from)
      assert [] == Salon.list_sales(b.venue.id, from)
    end

    test "reports count only the venue's own data", %{a: a, b: b} do
      appt = appointment_fixture(a)
      {:ok, _} = Salon.checkout(a.venue.id, [appt.id], 1_000, "card")

      report_a = Salon.report_summary(a.venue.id, 30)
      report_b = Salon.report_summary(b.venue.id, 30)

      assert report_a.sales_count == 1
      assert report_b.sales_count == 0
      assert report_b.revenue_cents == 0
    end

    test "client stats are computed per venue", %{a: a} do
      appt = appointment_fixture(a)
      {:ok, _} = Salon.checkout(a.venue.id, [appt.id], 0, "cash")

      stats = Salon.client_stats(a.venue.id, a.client.id)
      assert stats.appt_count == 1
      assert stats.total_spent_cents == 20_000
    end
  end

  describe "writes cannot cross tenants" do
    test "an appointment cannot use another venue's staff or service", %{a: a, b: b} do
      assert {:error, _} =
               Salon.create_appointment(a.venue.id, %{
                 client_id: a.client.id,
                 staff_id: b.staff.id,
                 service_id: a.service.id,
                 date: future_date(),
                 start_min: 600
               })

      assert_raise Ecto.NoResultsError, fn ->
        Salon.create_appointment(a.venue.id, %{
          client_id: a.client.id,
          staff_id: a.staff.id,
          service_id: b.service.id,
          date: future_date(),
          start_min: 600
        })
      end
    end

    test "an appointment cannot use another venue's client", %{a: a, b: b} do
      assert {:error, _} =
               Salon.create_appointment(a.venue.id, %{
                 client_id: b.client.id,
                 staff_id: a.staff.id,
                 service_id: a.service.id,
                 date: future_date(),
                 start_min: 600
               })
    end

    test "updating another venue's appointment raises", %{a: a, b: b} do
      appt_b = appointment_fixture(b)

      assert_raise Ecto.NoResultsError, fn ->
        Salon.update_appointment(a.venue.id, appt_b.id, %{status: "cancelled"})
      end
    end

    test "a service cannot be assigned another venue's staff", %{a: a, b: b} do
      {:ok, service} = Salon.update_service(a.venue.id, a.service.id, %{}, [b.staff.id])
      assert service.staff == []
    end

    test "checkout ignores another venue's appointments", %{a: a, b: b} do
      appt_b = appointment_fixture(b)
      assert {:error, _} = Salon.checkout(a.venue.id, [appt_b.id], 0, "cash")
    end

    test "availability only offers the venue's own staff", %{a: a, b: b} do
      {:ok, %{slots: slots}} =
        Salon.availability(a.venue.id, [a.service.id], "any", future_date(3))

      staff_ids = slots |> Enum.map(& &1.staff_id) |> Enum.uniq()
      assert staff_ids == [a.staff.id]
      refute b.staff.id in staff_ids
    end

    test "a staff id from another venue yields no slots", %{a: a, b: b} do
      {:ok, %{slots: slots}} =
        Salon.availability(a.venue.id, [a.service.id], to_string(b.staff.id), future_date(3))

      assert slots == []
    end

    test "an unknown service is rejected", %{a: a, b: b} do
      assert {:error, "unknown service"} =
               Salon.availability(a.venue.id, [b.service.id], "any", future_date(3))
    end
  end

  describe "unscoped queries are refused" do
    test "a nil venue raises rather than returning every tenant's rows" do
      assert_raise ArgumentError, ~r/venue scope is required/, fn ->
        Salon.list_services(nil)
      end
    end
  end

  describe "customer identity spans venues" do
    test "one account has a separate client record per venue", %{a: a, b: b} do
      user = user_fixture("shared@example.com")

      {:ok, client_a} = Blastek.Accounts.ensure_client(user, a.venue.id)
      {:ok, client_b} = Blastek.Accounts.ensure_client(user, b.venue.id)

      refute client_a == client_b
      assert Enum.sort(Blastek.Accounts.client_ids(user)) == Enum.sort([client_a, client_b])
    end

    test "ensure_client is idempotent per venue", %{a: a} do
      user = user_fixture("repeat@example.com")
      {:ok, first} = Blastek.Accounts.ensure_client(user, a.venue.id)
      {:ok, second} = Blastek.Accounts.ensure_client(user, a.venue.id)
      assert first == second
    end
  end

  describe "venue slugs" do
    test "duplicate names get distinct slugs" do
      one = venue_fixture("Chez Karim")
      {:ok, two} = Venues.create_venue(%{name: "Chez Karim", status: "active"})

      assert one.venue.slug == "chez-karim"
      assert two.slug == "chez-karim-2"
    end

    test "accented names transliterate" do
      assert Venues.slugify("Éclat Spa") == "eclat-spa"
      assert Venues.slugify("Maârif Coiffure") == "maarif-coiffure"
    end

    test "only active venues are publicly resolvable" do
      %{venue: venue} = venue_fixture("Hidden Salon")
      assert {:ok, _} = Venues.get_public_by_slug(venue.slug)

      {:ok, _} = Venues.update_venue(venue, %{status: "suspended"})
      assert {:error, _} = Venues.get_public_by_slug(venue.slug)
    end
  end

  describe "memberships" do
    test "roles rank from staff to owner" do
      assert Venues.role_at_least?("owner", "manager")
      assert Venues.role_at_least?("manager", "manager")
      refute Venues.role_at_least?("receptionist", "manager")
      refute Venues.role_at_least?("staff", "receptionist")
    end

    test "the last owner cannot be demoted or removed", %{a: a} do
      %{member: member} = member_fixture(a.venue, "owner", "solo-owner@example.com")

      assert {:error, msg} = Venues.update_member_role(a.venue.id, member.id, "manager")
      assert msg =~ "at least one owner"
      assert {:error, _} = Venues.remove_member(a.venue.id, member.id)

      # With a second owner present, the first can step down...
      %{member: other} = member_fixture(a.venue, "owner", "second-owner@example.com")
      assert {:ok, _} = Venues.update_member_role(a.venue.id, member.id, "manager")

      # ...which makes the other one the last owner, and protected in turn.
      assert {:error, _} = Venues.remove_member(a.venue.id, other.id)
    end

    test "a non-owner member can always be removed", %{a: a} do
      member_fixture(a.venue, "owner", "keeper@example.com")
      %{member: staff} = member_fixture(a.venue, "staff", "leaver@example.com")

      assert {:ok, _} = Venues.remove_member(a.venue.id, staff.id)
      assert Venues.list_members(a.venue.id) |> Enum.map(& &1.role) == ["owner"]
    end

    test "membership management is venue-scoped", %{a: a, b: b} do
      member_fixture(b.venue, "owner", "b-owner@example.com")
      %{member: b_staff} = member_fixture(b.venue, "staff", "b-staff@example.com")

      # Venue A's owner cannot touch venue B's memberships by id.
      assert {:error, "Unknown member."} =
               Venues.update_member_role(a.venue.id, b_staff.id, "owner")

      assert {:error, "Unknown member."} = Venues.remove_member(a.venue.id, b_staff.id)
      assert Venues.get_membership(b_staff.user_id, b.venue.id).role == "staff"
    end
  end
end
