defmodule Blastek.I18nTest do
  @moduledoc """
  Locale resolution and the content fallback chain (E7-T1, E7-T6 / F0.11).

  The single most important property here is that `translate/3` **never returns
  nothing**. A missing Arabic name must produce the French one, and a missing
  French one the column the owner typed — because the failure mode of getting
  it wrong is not a missing translation, it is a booking flow with an
  unlabelled button.
  """
  use ExUnit.Case, async: true

  alias Blastek.I18n

  describe "normalize/1" do
    test "takes the language subtag and ignores the region" do
      assert I18n.normalize("ar-MA") == "ar"
      assert I18n.normalize("fr_FR") == "fr"
      assert I18n.normalize("AR") == "ar"
      assert I18n.normalize(:en) == "en"
    end

    test "anything unknown is French, because something has to render" do
      assert I18n.normalize("de") == "fr"
      assert I18n.normalize("") == "fr"
      assert I18n.normalize(nil) == "fr"
      assert I18n.normalize(42) == "fr"
    end
  end

  describe "from_accept_language/1" do
    test "honours quality values rather than document order" do
      # Reading left to right gets this exactly backwards.
      assert I18n.from_accept_language("en;q=0.5, ar;q=0.9") == "ar"
      assert I18n.from_accept_language("ar;q=0.2, fr;q=0.8") == "fr"
    end

    test "skips languages this product does not speak instead of giving up" do
      assert I18n.from_accept_language("de, ar") == "ar"
      assert I18n.from_accept_language("es-ES, de;q=0.9") == "fr"
    end

    test "a bare header, a region tag and junk all resolve" do
      assert I18n.from_accept_language("ar") == "ar"
      assert I18n.from_accept_language("ar-MA,ar;q=0.9,fr;q=0.8") == "ar"
      assert I18n.from_accept_language("*") == "fr"
      assert I18n.from_accept_language(nil) == "fr"
    end
  end

  describe "resolve/1" do
    test "an explicit argument wins over everything" do
      assert I18n.resolve(explicit: "en", user: %{locale: "ar"}, accept_language: "fr") == "en"
    end

    test "a saved preference beats the browser header" do
      # Phones sold in Morocco very often ship with a French or English system
      # locale whatever their owner reads, so a deliberate choice outranks it.
      assert I18n.resolve(user: %{locale: "ar"}, accept_language: "fr-FR,fr;q=0.9") == "ar"
    end

    test "a user who has never chosen lets the header decide" do
      assert I18n.resolve(user: %{locale: nil}, accept_language: "ar-MA") == "ar"
    end

    test "and with neither, French" do
      assert I18n.resolve() == "fr"
      assert I18n.resolve(user: nil, accept_language: nil) == "fr"
    end
  end

  describe "translate/3 — the fallback chain" do
    setup do
      %{
        service: %{
          name: "Coupe femme",
          description: "Shampoing inclus",
          translations: %{
            "ar" => %{"name" => "قص شعر نسائي"},
            "en" => %{"name" => "Women's cut"}
          }
        }
      }
    end

    test "returns the requested locale when it exists", %{service: service} do
      assert I18n.translate(service, :name, "ar") == "قص شعر نسائي"
      assert I18n.translate(service, :name, "en") == "Women's cut"
    end

    test "falls back to the base column, never to nothing", %{service: service} do
      # No Arabic description was ever written. An empty service description is
      # survivable; an empty *name* is a blank button, and the chain is the same.
      assert I18n.translate(service, :description, "ar") == "Shampoing inclus"
      assert I18n.translate(service, :name, "fr") == "Coupe femme"
    end

    test "English falls back through French, not through Arabic" do
      service = %{name: "Coupe", translations: %{"ar" => %{"name" => "قص"}}}
      assert I18n.translate(service, :name, "en") == "Coupe"
    end

    test "a blank translation counts as absent" do
      # Somebody opened the Arabic tab and saved without typing. Showing them an
      # empty name would be a strange reward for it.
      service = %{name: "Coupe", translations: %{"ar" => %{"name" => "   "}}}
      assert I18n.translate(service, :name, "ar") == "Coupe"
    end

    test "a record with no translations column at all still resolves" do
      assert I18n.translate(%{name: "Coupe"}, :name, "ar") == "Coupe"
      assert I18n.translate(%{name: "Coupe", translations: nil}, :name, "ar") == "Coupe"
    end
  end

  describe "sanitize/2" do
    test "keeps only known locales and known fields" do
      cleaned =
        I18n.sanitize(
          %{
            "ar" => %{"name" => "قص", "price_cents" => 9999, "sneaky" => "x"},
            "de" => %{"name" => "Schnitt"},
            "en" => %{"name" => "Cut"}
          },
          [:name]
        )

      assert cleaned == %{"ar" => %{"name" => "قص"}, "en" => %{"name" => "Cut"}}
    end

    test "drops blanks rather than storing them" do
      # Clearing the Arabic name in the editor must restore the fallback, not
      # pin an empty string in front of it.
      assert I18n.sanitize(%{"ar" => %{"name" => ""}}, [:name]) == %{}

      assert I18n.sanitize(%{"ar" => %{"name" => "  قص  "}}, [:name]) == %{
               "ar" => %{"name" => "قص"}
             }
    end

    test "junk is not a crash" do
      assert I18n.sanitize(nil, [:name]) == %{}
      assert I18n.sanitize("nope", [:name]) == %{}
      assert I18n.sanitize(%{"ar" => "not a map"}, [:name]) == %{}
    end
  end

  describe "expose/2 and split/2 — the editor's uniform view" do
    test "expose folds the base columns in as French" do
      service = %{name: "Coupe", description: "", translations: %{"ar" => %{"name" => "قص"}}}

      assert I18n.expose(service, [:name, :description]) == %{
               "fr" => %{"name" => "Coupe"},
               "ar" => %{"name" => "قص"}
             }
    end

    test "a locale nobody has filled in is absent, not present-and-empty" do
      service = %{name: "Coupe", description: "", translations: %{}}
      exposed = I18n.expose(service, [:name, :description])

      refute Map.has_key?(exposed, "ar")
      refute Map.has_key?(exposed["fr"], "description")
    end

    test "split routes French to columns and leaves the rest as JSONB" do
      {attrs, rest} =
        I18n.split(
          %{"fr" => %{"name" => "Coupe"}, "ar" => %{"name" => "قص"}},
          [:name, :description]
        )

      assert attrs == %{name: "Coupe"}
      # Not duplicated into the JSONB — storing it twice is how the two get to
      # disagree.
      assert rest == %{"ar" => %{"name" => "قص"}}
    end

    test "and the two round-trip" do
      original = %{"fr" => %{"name" => "Coupe"}, "ar" => %{"name" => "قص"}}
      {attrs, rest} = I18n.split(original, [:name])
      stored = Map.merge(attrs, %{translations: rest})

      assert I18n.expose(stored, [:name]) == original
    end
  end
end
