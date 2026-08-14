defmodule BlastekWeb.LocalizedContentTest do
  @moduledoc """
  Owner-written content, resolved for the reader (E7-T1, E7-T6 / F0.11).

  `Blastek.I18nTest` covers the fallback chain as a pure function. This covers
  the wiring around it, which is where it can actually break: the header has to
  reach the plug, the plug has to put a locale in the Absinthe context, and
  every resolver that returns copy has to read it. Each of those is a link that
  can be perfect on its own while the customer still sees French.
  """
  use BlastekWeb.ConnCase, async: true

  import Blastek.Fixtures

  alias Blastek.Repo
  alias Blastek.Salon

  @query """
  query($slug: String!) {
    venue(slug: $slug) {
      settings { businessTagline }
      categories { id name }
      services { id name description }
    }
  }
  """

  setup do
    v = venue_fixture("Localized Salon #{System.unique_integer([:positive])}")

    {:ok, _} =
      Salon.update_service(
        v.venue.id,
        v.service.id,
        %{
          translations: %{
            "fr" => %{"name" => "Coupe femme", "description" => "Shampoing inclus"},
            "ar" => %{"name" => "قص شعر نسائي"}
          }
        },
        nil
      )

    {:ok, _} =
      Salon.update_category(v.venue.id, v.category.id, %{
        translations: %{"fr" => %{"name" => "Coiffure"}, "ar" => %{"name" => "حلاقة"}}
      })

    {:ok, _} =
      v.venue
      |> Blastek.Venues.Venue.changeset(%{
        tagline: "Beauté au cœur d'Anfa",
        translations: %{"ar" => %{"tagline" => "الجمال في قلب أنفا"}}
      })
      |> Repo.update()

    %{v: v}
  end

  defp ask(conn, slug, headers \\ []) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)

    conn
    |> post("/api/graphql", %{query: @query, variables: %{"slug" => slug}})
    |> json_response(200)
    |> get_in(["data", "venue"])
  end

  describe "Accept-Language reaches the resolvers" do
    test "an Arabic browser gets Arabic names", %{conn: conn, v: v} do
      venue = ask(conn, v.venue.slug, [{"accept-language", "ar-MA,ar;q=0.9,fr;q=0.8"}])

      assert hd(venue["services"])["name"] == "قص شعر نسائي"
      assert hd(venue["categories"])["name"] == "حلاقة"
      assert venue["settings"]["businessTagline"] == "الجمال في قلب أنفا"
    end

    test "a French browser gets French", %{conn: conn, v: v} do
      venue = ask(conn, v.venue.slug, [{"accept-language", "fr-FR,fr;q=0.9"}])

      assert hd(venue["services"])["name"] == "Coupe femme"
      assert venue["settings"]["businessTagline"] == "Beauté au cœur d'Anfa"
    end

    test "no header at all is French, not a crash and not a blank", %{conn: conn, v: v} do
      venue = ask(conn, v.venue.slug)
      assert hd(venue["services"])["name"] == "Coupe femme"
    end

    test "quality values are honoured, not document order", %{conn: conn, v: v} do
      venue = ask(conn, v.venue.slug, [{"accept-language", "en;q=0.4, ar;q=0.9"}])
      assert hd(venue["services"])["name"] == "قص شعر نسائي"
    end

    test "a language nobody speaks here falls back rather than blanking", %{conn: conn, v: v} do
      venue = ask(conn, v.venue.slug, [{"accept-language", "de-DE,de;q=0.9"}])
      assert hd(venue["services"])["name"] == "Coupe femme"
    end
  end

  describe "the fallback chain, over the wire" do
    test "a field with no Arabic falls through to French rather than emptying",
         %{conn: conn, v: v} do
      # The service has an Arabic *name* but no Arabic description. A blank
      # description is survivable; the same gap on `name` would be an unlabelled
      # button in the booking flow, and it is the same code path.
      venue = ask(conn, v.venue.slug, [{"accept-language", "ar"}])

      assert hd(venue["services"])["name"] == "قص شعر نسائي"
      assert hd(venue["services"])["description"] == "Shampoing inclus"
    end

    test "a venue that has never touched a translation still reads", %{conn: conn} do
      plain = venue_fixture("Untranslated #{System.unique_integer([:positive])}")

      for locale <- ~w(fr ar en) do
        venue = ask(build_conn(), plain.venue.slug, [{"accept-language", locale}])
        name = hd(venue["services"])["name"]

        assert is_binary(name) and name != "",
               "#{locale} produced #{inspect(name)} for an untranslated venue"
      end

      _ = conn
    end
  end

  describe "a signed-in reader's saved locale" do
    test "beats the browser header", %{conn: conn, v: v} do
      # Phones sold in Morocco often ship set to French whatever their owner
      # reads, so a deliberate choice has to outrank the header.
      user = user_fixture("ar-reader-#{System.unique_integer([:positive])}@example.com")
      {:ok, user} = Blastek.Accounts.update_locale(user, "ar")
      {:ok, %{token: token}} = Blastek.Accounts.start_session(user)

      venue =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> ask(v.venue.slug, [{"accept-language", "fr-FR,fr;q=0.9"}])

      assert hd(venue["services"])["name"] == "قص شعر نسائي"
    end

    test "and a user who never chose lets the header decide", %{conn: conn, v: v} do
      user = user_fixture("no-choice-#{System.unique_integer([:positive])}@example.com")
      assert user.locale == nil
      {:ok, %{token: token}} = Blastek.Accounts.start_session(user)

      venue =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> ask(v.venue.slug, [{"accept-language", "ar"}])

      assert hd(venue["services"])["name"] == "قص شعر نسائي"
    end
  end

  describe "writes" do
    test "French goes to the base column, everything else to the JSONB", %{v: v} do
      service = Repo.get(Salon.Service, v.service.id)

      # The column is what every locale-blind query reads and what the search
      # index is built from, so French living anywhere else would be a silent
      # regression in F0.6.
      assert service.name == "Coupe femme"
      assert service.translations == %{"ar" => %{"name" => "قص شعر نسائي"}}
    end

    test "an unknown locale is dropped, not filed under French", %{v: v} do
      {:ok, updated} =
        Salon.update_service(
          v.venue.id,
          v.service.id,
          %{translations: %{"de" => %{"name" => "Damenhaarschnitt"}}},
          nil
        )

      assert updated.name == "Coupe femme"
      refute Map.has_key?(updated.translations, "de")
      refute Map.has_key?(updated.translations, "fr")
    end

    test "a very long value is bounded rather than stored whole", %{v: v} do
      {:ok, updated} =
        Salon.update_service(
          v.venue.id,
          v.service.id,
          %{translations: %{"ar" => %{"name" => String.duplicate("ا", 5_000)}}},
          nil
        )

      assert String.length(updated.translations["ar"]["name"]) == 2_000
    end
  end
end
