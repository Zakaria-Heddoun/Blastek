defmodule Blastek.GeocodeTest do
  @moduledoc """
  Locating a venue on the map.

  The rule under test throughout: a hand-placed pin outranks a geocoder's guess.
  Getting that backwards sends customers to the wrong door, and the owner cannot
  see that it happened.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Geocode
  alias Blastek.Geocode.Stub
  alias Blastek.Venues

  setup do
    %{venue: venue} = venue_fixture("Locate Salon")
    {:ok, venue} = Venues.update_venue(venue, %{address: "12 Rue Gauthier", city: "Casablanca"})
    %{venue: venue}
  end

  describe "query building" do
    test "combines address and city, and anchors the country" do
      query = Geocode.query_for(%{address: "5 Avenue Agdal", city: "Rabat"})
      assert query == "5 Avenue Agdal, Rabat, Morocco"
    end

    test "skips the parts a new venue has not filled in" do
      assert Geocode.query_for(%{address: "", city: "Rabat"}) == "Rabat, Morocco"
      assert Geocode.query_for(%{address: "", city: ""}) == "Morocco"
    end

    test "does not repeat a city already written into the address" do
      query = Geocode.query_for(%{address: "Casablanca", city: "Casablanca"})
      assert query == "Casablanca, Morocco"
    end
  end

  describe "geocode/1" do
    test "refuses an empty query without calling the provider" do
      assert {:error, :empty} = Geocode.geocode("   ")
      assert Stub.last_query() == nil
    end

    test "passes the trimmed query through" do
      Stub.stub(33.5, -7.6)
      assert {:ok, %{lat: 33.5, lng: -7.6}} = Geocode.geocode("  Rabat  ")
      assert Stub.last_query() == "Rabat"
    end
  end

  describe "geocode_venue/2" do
    test "fills in coordinates from the address", %{venue: venue} do
      Stub.stub(33.5883, -7.6329)

      assert {:ok, located} = Venues.geocode_venue(venue)
      assert located.lat == 33.5883
      assert located.lng == -7.6329
      assert Stub.last_query() == "12 Rue Gauthier, Casablanca, Morocco"
    end

    test "will not overwrite a pin the owner placed", %{venue: venue} do
      {:ok, pinned} = Venues.set_location(venue, 33.1111, -7.1111)
      Stub.stub(33.9999, -6.9999)

      assert {:error, message} = Venues.geocode_venue(pinned)
      assert message =~ "already has a location pin"

      # Unchanged, and the provider was never consulted.
      assert Venues.get_venue!(venue.id).lat == 33.1111
      assert Stub.last_query() == nil
    end

    test "force: true is how a changed address gets re-located", %{venue: venue} do
      {:ok, pinned} = Venues.set_location(venue, 33.1111, -7.1111)
      Stub.stub(33.9905, -6.8498)

      assert {:ok, moved} = Venues.geocode_venue(pinned, force: true)
      assert moved.lat == 33.9905
    end

    test "asks for an address rather than geocoding the country", %{venue: venue} do
      {:ok, addressless} = Venues.update_venue(venue, %{address: "", city: ""})

      assert {:error, message} = Venues.geocode_venue(addressless)
      assert message =~ "Add an address"
      assert Stub.last_query() == nil
    end

    test "an unknown address leaves the venue pinless with actionable advice", %{venue: venue} do
      Stub.stub(:not_found)

      assert {:error, message} = Venues.geocode_venue(venue)
      assert message =~ "could not find that address"
      assert message =~ "manually"
      assert Venues.get_venue!(venue.id).lat == nil
    end

    test "a provider outage is reported as an outage, not a bad address", %{venue: venue} do
      Stub.stub(:boom)

      assert {:error, message} = Venues.geocode_venue(venue)
      assert message =~ "map service is unavailable"
    end
  end

  describe "set_location/3" do
    test "rejects coordinates that are not on Earth", %{venue: venue} do
      assert {:error, changeset} = Venues.set_location(venue, 91.0, 0.0)
      assert "must be less than or equal to 90" in errors_on(changeset).lat

      assert {:error, changeset} = Venues.set_location(venue, 0.0, -181.0)
      assert "must be greater than or equal to -180" in errors_on(changeset).lng
    end

    test "accepts the extremes", %{venue: venue} do
      assert {:ok, _} = Venues.set_location(venue, -90.0, 180.0)
    end
  end
end
