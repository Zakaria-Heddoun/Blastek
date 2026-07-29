defmodule BlastekWeb.DiscoveryTest do
  @moduledoc """
  Marketplace discovery: searching the venue directory and the stats shown on a
  listing card.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Salon
  alias Blastek.Venues
  alias BlastekWeb.Schema

  defp run(query), do: Absinthe.run(query, Schema, context: %{})

  defp names(query) do
    {:ok, %{data: %{"venues" => venues}}} = run(query)
    Enum.map(venues, & &1["name"])
  end

  setup do
    anfa = venue_fixture("Salon Anfa")
    {:ok, _} = Venues.update_venue(anfa.venue, %{city: "Casablanca", address: "12 Rue Gauthier"})

    corner = venue_fixture("Barber Corner")
    {:ok, _} = Venues.update_venue(corner.venue, %{city: "Rabat", address: "5 Avenue Agdal"})

    %{anfa: anfa, corner: corner}
  end

  describe "venue search" do
    test "no term returns every active venue" do
      found = names("{ venues { name } }")
      assert "Salon Anfa" in found
      assert "Barber Corner" in found
    end

    test "matches on venue name" do
      assert names(~s|{ venues(q: "barber") { name } }|) == ["Barber Corner"]
    end

    test "matches on city" do
      assert names(~s|{ venues(q: "rabat") { name } }|) == ["Barber Corner"]
    end

    test "matches on address" do
      assert names(~s|{ venues(q: "gauthier") { name } }|) == ["Salon Anfa"]
    end

    test "is case-insensitive and ignores surrounding space" do
      assert names(~s|{ venues(q: "  CASABLANCA  ") { name } }|) == ["Salon Anfa"]
    end

    test "an empty term is treated as no filter" do
      assert length(names(~s|{ venues(q: "") { name } }|)) >= 2
    end

    test "a term matching nothing returns an empty list" do
      assert names(~s|{ venues(q: "zzzznope") { name } }|) == []
    end

    test "suspended venues never appear", %{corner: corner} do
      {:ok, _} = Venues.update_venue(corner.venue, %{status: "suspended"})
      refute "Barber Corner" in names("{ venues { name } }")
    end

    test "matches on the treatments a venue offers", %{corner: corner} do
      {:ok, category} = Blastek.Salon.create_category(corner.venue.id, %{name: "Cuts", sort: 1})

      {:ok, _} =
        Blastek.Salon.create_service(
          corner.venue.id,
          %{category_id: category.id, name: "Skin fade", duration_min: 45, price_cents: 13_000},
          nil
        )

      # The shopper types what they want, not who provides it.
      assert names(~s|{ venues(q: "skin fade") { name } }|) == ["Barber Corner"]
    end

    test "a venue offering several matching treatments is listed once", %{corner: corner} do
      {:ok, category} = Blastek.Salon.create_category(corner.venue.id, %{name: "Cuts", sort: 1})

      for name <- ["Skin fade", "Low fade", "Taper fade"] do
        {:ok, _} =
          Blastek.Salon.create_service(
            corner.venue.id,
            %{category_id: category.id, name: name, duration_min: 30, price_cents: 10_000},
            nil
          )
      end

      assert names(~s|{ venues(q: "fade") { name } }|) == ["Barber Corner"]
    end

    test "words are ANDed, so extra words narrow the result", %{corner: corner} do
      {:ok, category} = Blastek.Salon.create_category(corner.venue.id, %{name: "Cuts", sort: 1})

      {:ok, _} =
        Blastek.Salon.create_service(
          corner.venue.id,
          %{category_id: category.id, name: "Skin fade", duration_min: 45, price_cents: 13_000},
          nil
        )

      assert names(~s|{ venues(q: "fade rabat") { name } }|) == ["Barber Corner"]
      # The treatment exists, but not in that city.
      assert names(~s|{ venues(q: "fade tangier") { name } }|) == []
    end

    test "inactive treatments do not make a venue findable", %{corner: corner} do
      {:ok, category} = Blastek.Salon.create_category(corner.venue.id, %{name: "Cuts", sort: 1})

      {:ok, service} =
        Blastek.Salon.create_service(
          corner.venue.id,
          %{
            category_id: category.id,
            name: "Hammam ritual",
            duration_min: 60,
            price_cents: 30_000
          },
          nil
        )

      assert names(~s|{ venues(q: "hammam") { name } }|) == ["Barber Corner"]

      {:ok, _} = Blastek.Salon.update_service(corner.venue.id, service.id, %{active: false}, nil)
      assert names(~s|{ venues(q: "hammam") { name } }|) == []
    end
  end

  describe "listing card stats" do
    test "a venue with no reviews reports zero rather than null", %{anfa: anfa} do
      {:ok, %{data: %{"venues" => venues}}} =
        run("{ venues { slug rating reviewCount priceFromCents } }")

      card = Enum.find(venues, &(&1["slug"] == anfa.venue.slug))

      assert card["rating"] == 0.0
      assert card["reviewCount"] == 0
      # The fixture's single service is the cheapest.
      assert card["priceFromCents"] == 20_000
    end

    test "rating is the mean of the venue's own reviews", %{anfa: anfa, corner: corner} do
      for rating <- [5, 4] do
        Blastek.Repo.insert!(%Blastek.Salon.Review{
          venue_id: anfa.venue.id,
          client_name: "R",
          rating: rating,
          comment: ""
        })
      end

      # Another venue's reviews must not bleed into this average.
      Blastek.Repo.insert!(%Blastek.Salon.Review{
        venue_id: corner.venue.id,
        client_name: "R",
        rating: 1,
        comment: ""
      })

      {:ok, %{data: %{"venues" => venues}}} = run("{ venues { slug rating reviewCount } }")
      card = Enum.find(venues, &(&1["slug"] == anfa.venue.slug))

      assert card["rating"] == 4.5
      assert card["reviewCount"] == 2
    end

    test "price comes from the cheapest active service", %{anfa: anfa} do
      {:ok, category} = Blastek.Salon.create_category(anfa.venue.id, %{name: "Quick", sort: 2})

      {:ok, cheap} =
        Blastek.Salon.create_service(
          anfa.venue.id,
          %{category_id: category.id, name: "Fringe trim", duration_min: 15, price_cents: 5_000},
          nil
        )

      {:ok, %{data: %{"venues" => venues}}} = run("{ venues { slug priceFromCents } }")
      assert Enum.find(venues, &(&1["slug"] == anfa.venue.slug))["priceFromCents"] == 5_000

      # An inactive service should stop counting.
      {:ok, _} = Blastek.Salon.update_service(anfa.venue.id, cheap.id, %{active: false}, nil)

      {:ok, %{data: %{"venues" => after_venues}}} = run("{ venues { slug priceFromCents } }")
      assert Enum.find(after_venues, &(&1["slug"] == anfa.venue.slug))["priceFromCents"] == 20_000
    end
  end

  describe "searchVenues filters" do
    test "by city", %{anfa: anfa} do
      assert search_names(~s|city: "Rabat"|) == ["Barber Corner"]
      # Accent- and case-insensitive, since nobody types a city carefully.
      assert search_names(~s|city: "casablanca"|) == [anfa.venue.name]
    end

    test "by treatment category", %{corner: corner} do
      {:ok, category} = Salon.create_category(corner.venue.id, %{name: "Beards", sort: 1})

      {:ok, _} =
        Salon.create_service(
          corner.venue.id,
          %{category_id: category.id, name: "Beard trim", duration_min: 20, price_cents: 6_000},
          nil
        )

      assert search_names(~s|category: "Beards"|) == ["Barber Corner"]
      # Every fixture venue has a "Hair" category.
      assert length(search_names(~s|category: "Hair"|)) == 2
    end

    test "women-only is a filter, not a flag on the results", %{anfa: anfa} do
      {:ok, _} = Venues.update_venue(anfa.venue, %{settings: %{"women_only" => true}})

      assert search_names("womenOnly: true") == [anfa.venue.name]
      # False and null both mean "no preference" — they must not exclude anyone.
      assert length(search_names("womenOnly: false")) == 2
      assert length(search_names("")) == 2
    end

    test "filters compose, narrowing rather than widening", %{corner: corner} do
      {:ok, category} = Salon.create_category(corner.venue.id, %{name: "Cuts", sort: 1})

      {:ok, _} =
        Salon.create_service(
          corner.venue.id,
          %{category_id: category.id, name: "Skin fade", duration_min: 45, price_cents: 13_000},
          nil
        )

      assert search_names(~s|q: "fade", city: "Rabat"|) == ["Barber Corner"]
      assert search_names(~s|q: "fade", city: "Casablanca"|) == []
    end
  end

  describe "searchVenues paging" do
    setup do
      # Enough venues to page through, on top of the two from the outer setup.
      for n <- 1..6, do: venue_fixture("Paging Salon #{n}")
      :ok
    end

    test "totalCount describes the whole set, not the page" do
      {:ok, %{data: %{"searchVenues" => page}}} =
        run("{ searchVenues(limit: 3) { items { name } totalCount } }")

      assert length(page["items"]) == 3
      assert page["totalCount"] == 8
    end

    test "offset walks the set without repeating or skipping" do
      first = search_names("limit: 4, offset: 0")
      second = search_names("limit: 4, offset: 4")

      assert length(first) == 4
      assert length(second) == 4
      assert first -- second == first
      assert length(Enum.uniq(first ++ second)) == 8
    end

    test "an absurd limit is clamped rather than honoured" do
      {:ok, %{data: %{"searchVenues" => page}}} =
        run("{ searchVenues(limit: 5000) { items { name } totalCount } }")

      # The cap, not the request.
      assert length(page["items"]) == 8
      assert page["totalCount"] == 8
    end
  end

  describe "searchVenues sorting" do
    test "by price puts the cheapest first, unpriced venues last", %{anfa: anfa, corner: corner} do
      {:ok, category} = Salon.create_category(corner.venue.id, %{name: "Quick", sort: 1})

      {:ok, _} =
        Salon.create_service(
          corner.venue.id,
          %{category_id: category.id, name: "Fringe", duration_min: 10, price_cents: 3_000},
          nil
        )

      assert search_names(~s|sort: "price"|) == ["Barber Corner", anfa.venue.name]
    end

    test "by rating puts the best-reviewed first", %{anfa: anfa, corner: corner} do
      review!(corner.venue.id, 5)
      review!(anfa.venue.id, 2)

      assert search_names(~s|sort: "rating"|) == ["Barber Corner", anfa.venue.name]
    end

    test "relevance ranks a name match above a mere treatment mention", %{corner: corner} do
      # Give the other venue a service whose name contains the search term, so
      # both match and only the weighting can separate them.
      {:ok, category} = Salon.create_category(corner.venue.id, %{name: "Styling", sort: 1})

      {:ok, _} =
        Salon.create_service(
          corner.venue.id,
          %{category_id: category.id, name: "Anfa blowout", duration_min: 30, price_cents: 9_000},
          nil
        )

      # "Salon Anfa" is named it; Barber Corner merely sells it.
      assert search_names(~s|q: "anfa"|) == ["Salon Anfa", "Barber Corner"]
    end
  end

  describe "searchVenues distance" do
    setup %{anfa: anfa, corner: corner} do
      # Gauthier, Casablanca and Agdal, Rabat — about 85 km apart.
      {:ok, _} = Venues.set_location(anfa.venue, 33.5883, -7.6329)
      {:ok, _} = Venues.set_location(corner.venue, 33.9905, -6.8498)
      :ok
    end

    test "reports kilometres from the search point" do
      {:ok, %{data: %{"searchVenues" => page}}} =
        run("""
        { searchVenues(near: {lat: 33.5883, lng: -7.6329}, sort: "distance") {
            items { name distanceKm }
        } }
        """)

      [nearest, farthest] = page["items"]

      assert nearest["name"] == "Salon Anfa"
      assert_in_delta nearest["distanceKm"], 0.0, 0.5
      assert farthest["name"] == "Barber Corner"
      assert_in_delta farthest["distanceKm"], 85.0, 5.0
    end

    test "withinKm excludes what is out of range" do
      near_casablanca = ~s|near: {lat: 33.5883, lng: -7.6329}, withinKm: 20.0|
      assert search_names(near_casablanca) == ["Salon Anfa"]

      # Widen it and the Rabat venue comes back.
      assert length(search_names(~s|near: {lat: 33.5883, lng: -7.6329}, withinKm: 200.0|)) == 2
    end

    test "distanceKm is null without a search point" do
      {:ok, %{data: %{"searchVenues" => page}}} =
        run("{ searchVenues { items { distanceKm } } }")

      assert Enum.all?(page["items"], &is_nil(&1["distanceKm"]))
    end

    test "an unpinned venue sorts last but is not dropped", %{corner: corner} do
      {:ok, _} = Venues.update_venue(corner.venue, %{lat: nil, lng: nil})

      names = search_names(~s|near: {lat: 33.5883, lng: -7.6329}, sort: "distance"|)
      assert names == ["Salon Anfa", "Barber Corner"]
    end
  end

  describe "facets" do
    test "cities lists only cities with listable venues", %{corner: corner} do
      {:ok, %{data: %{"venueCities" => cities}}} =
        run("{ venueCities { city venueCount } }")

      assert %{"city" => "Casablanca", "venueCount" => 1} in cities
      assert %{"city" => "Rabat", "venueCount" => 1} in cities

      {:ok, _} = Venues.update_venue(corner.venue, %{status: "suspended"})
      {:ok, %{data: %{"venueCities" => after_cities}}} = run("{ venueCities { city } }")
      refute %{"city" => "Rabat"} in after_cities
    end

    test "categories lists what is actually offered", %{corner: corner} do
      {:ok, category} = Salon.create_category(corner.venue.id, %{name: "Hammam", sort: 9})

      {:ok, service} =
        Salon.create_service(
          corner.venue.id,
          %{category_id: category.id, name: "Gommage", duration_min: 45, price_cents: 15_000},
          nil
        )

      names = fn ->
        {:ok, %{data: %{"venueCategories" => cats}}} = run("{ venueCategories { name } }")
        Enum.map(cats, & &1["name"])
      end

      assert "Hammam" in names.()

      # A category whose only service is inactive is not on offer.
      {:ok, _} = Salon.update_service(corner.venue.id, service.id, %{active: false}, nil)
      refute "Hammam" in names.()
    end
  end

  describe "search index maintenance" do
    test "renaming a treatment changes what the venue is found by", %{corner: corner} do
      {:ok, category} = Salon.create_category(corner.venue.id, %{name: "Cuts", sort: 1})

      {:ok, service} =
        Salon.create_service(
          corner.venue.id,
          %{category_id: category.id, name: "Buzz cut", duration_min: 20, price_cents: 7_000},
          nil
        )

      assert names(~s|{ venues(q: "buzz") { name } }|) == ["Barber Corner"]

      {:ok, _} = Salon.update_service(corner.venue.id, service.id, %{name: "Crew cut"}, nil)

      assert names(~s|{ venues(q: "buzz") { name } }|) == []
      assert names(~s|{ venues(q: "crew") { name } }|) == ["Barber Corner"]
    end

    test "renaming the venue changes what it is found by", %{anfa: anfa} do
      # The fixture names the service after the venue, so neutralize it first —
      # otherwise the old term survives through the treatment, not the name.
      {:ok, _} = Salon.update_service(anfa.venue.id, anfa.service.id, %{name: "Coupe"}, nil)
      {:ok, _} = Venues.update_venue(anfa.venue, %{name: "Studio Lumiere"})

      assert names(~s|{ venues(q: "lumiere") { name } }|) == ["Studio Lumiere"]
      assert names(~s|{ venues(q: "anfa") { name } }|) == []
    end

    test "accents are ignored in both directions" do
      accented = venue_fixture("Éclat Beauté")
      {:ok, _} = Venues.update_venue(accented.venue, %{city: "Marrakech"})

      assert "Éclat Beauté" in names(~s|{ venues(q: "eclat") { name } }|)
      assert "Éclat Beauté" in names(~s|{ venues(q: "beauté") { name } }|)
    end

    test "reindex_all rebuilds a document that was wiped behind the API's back" do
      Repo.delete_all("venue_search_documents")
      assert names(~s|{ venues(q: "barber") { name } }|) == []

      assert Blastek.Discovery.reindex_all() >= 2
      assert names(~s|{ venues(q: "barber") { name } }|) == ["Barber Corner"]
    end
  end

  defp search_names(args) do
    query =
      case String.trim(args) do
        "" -> "{ searchVenues { items { name } } }"
        args -> "{ searchVenues(#{args}) { items { name } } }"
      end

    {:ok, %{data: %{"searchVenues" => page}}} = run(query)
    Enum.map(page["items"], & &1["name"])
  end

  defp review!(venue_id, rating) do
    Repo.insert!(%Blastek.Salon.Review{
      venue_id: venue_id,
      client_name: "R",
      rating: rating,
      comment: ""
    })
  end
end
