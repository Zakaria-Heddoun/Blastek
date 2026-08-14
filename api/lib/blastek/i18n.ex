defmodule Blastek.I18n do
  @moduledoc """
  Which language to answer in, and how to pick a translated value (E7 / F0.11).

  ## Two kinds of text, one locale

  The interface strings live in the browser — `react-i18next` owns those, and
  the API never sees them. What the API owns is **content somebody typed**: a
  service called "Coupe femme", a category called "Coiffure", a venue's
  tagline. Those get optional per-locale values in a `translations` column and
  are resolved here.

  ## The fallback chain is not a nicety

  `ar → fr → base column`. A salon that has filled in French and not yet Arabic
  must still be bookable by an Arabic-speaking customer, and the failure mode of
  getting this wrong is not a missing translation but an **empty service name**
  — a booking flow with a blank button. So `translate/3` never returns nil for a
  key the base row has, and the base column is always the last link.

  French rather than English is the middle link because French is the default
  locale of the product and the language a Moroccan salon actually types in.
  English is a leaf: it falls back to French, never the other way round.

  ## Locale resolution

  In priority order: an explicit argument (a GraphQL `locale:` arg), then the
  signed-in user's saved preference, then `Accept-Language`, then French.

  The user's preference beats the header on purpose. Somebody who has chosen
  Arabic in the switcher has said so more deliberately than their browser did,
  and phones sold in Morocco very often ship with a French or English system
  locale regardless of what their owner reads.
  """

  @locales ~w(fr ar en)
  @default "fr"

  # Every chain ends at @default and then at the base column. `en` deliberately
  # does not fall back through `ar`.
  @fallbacks %{
    "fr" => ["fr"],
    "ar" => ["ar", "fr"],
    "en" => ["en", "fr"]
  }

  def locales, do: @locales
  def default_locale, do: @default

  @doc "Whether a string names a locale this product speaks."
  def known?(locale), do: locale in @locales

  @doc """
  The locale a value names, or `:error` when it names none.

  Accepts `"ar-MA"`, `:ar`, `"AR"` and nil; only the language subtag matters,
  because there is one Arabic and one French here.

  This is the honest half of the pair. `normalize/1` is total and answers "fr"
  for junk, which is what a *render* wants and is actively wrong anywhere a
  decision depends on whether a locale was really named — storing a
  translations map, say, where treating `"de"` as French means somebody's
  German text silently overwrites their French.
  """
  def parse(nil), do: :error

  def parse(locale) when is_atom(locale), do: locale |> Atom.to_string() |> parse()

  def parse(locale) when is_binary(locale) do
    tag =
      locale
      |> String.trim()
      |> String.downcase()
      |> String.split(["-", "_"], parts: 2)
      |> List.first()

    if known?(tag), do: {:ok, tag}, else: :error
  end

  def parse(_other), do: :error

  @doc """
  Like `parse/1` but total: anything unrecognised becomes French.

  For rendering, where something has to appear.
  """
  def normalize(value) do
    case parse(value) do
      {:ok, tag} -> tag
      :error -> @default
    end
  end

  @doc """
  The locale to answer a request in.

  `opts` may carry `:explicit` (a request argument), `:user` and
  `:accept_language`; the first that names a locale wins.
  """
  def resolve(opts \\ []) do
    with :error <- parse(opts[:explicit]),
         :error <- parse(user_locale(opts[:user])) do
      from_accept_language(opts[:accept_language])
    else
      {:ok, locale} -> locale
    end
  end

  defp user_locale(%{locale: locale}), do: locale
  defp user_locale(_user), do: nil

  @doc """
  The best locale named by an `Accept-Language` header.

  Parses the quality values rather than taking the first entry: a browser
  sending `en;q=0.5, ar;q=0.9` prefers Arabic, and reading left to right gets
  that backwards. Unknown languages are skipped, not defaulted on, so
  `de, ar` finds Arabic instead of stopping at German.
  """
  def from_accept_language(nil), do: @default
  def from_accept_language(""), do: @default

  def from_accept_language(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_language_range/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_tag, quality} -> quality end, :desc)
    |> Enum.find_value(@default, fn {tag, _quality} -> if known?(tag), do: tag end)
  end

  def from_accept_language(_other), do: @default

  defp parse_language_range(range) do
    case String.split(range, ";") do
      [tag] -> {language_of(tag), 1.0}
      [tag | params] -> {language_of(tag), quality_of(params)}
    end
  end

  defp language_of(tag) do
    tag
    |> String.trim()
    |> String.downcase()
    |> String.split(["-", "_"], parts: 2)
    |> List.first()
  end

  defp quality_of(params) do
    params
    |> Enum.find_value(1.0, fn param ->
      case param |> String.trim() |> String.split("=") do
        ["q", value] -> parse_quality(value)
        _ -> nil
      end
    end)
  end

  defp parse_quality(value) do
    case Float.parse(String.trim(value)) do
      {quality, _rest} -> quality
      :error -> 1.0
    end
  end

  ## ---------- content ----------

  @doc """
  A translated field, falling back until something real is found.

      translate(service, :name, "ar")

  Reads `service.translations["ar"]["name"]`, then `["fr"]["name"]`, then
  `service.name`. A blank string counts as absent — an owner who opened the
  Arabic tab and saved without typing has not written a translation, and
  showing them an empty service name would be a strange reward for it.
  """
  def translate(record, field, locale) do
    locale = normalize(locale)
    translations = translations_of(record)

    Enum.find_value(
      chain(locale),
      base_value(record, field),
      fn candidate -> present(get_in(translations, [candidate, to_string(field)])) end
    )
  end

  @doc "The locales `translate/3` will try, in order, before the base column."
  def chain(locale), do: Map.get(@fallbacks, normalize(locale), [@default])

  defp translations_of(%{translations: translations}) when is_map(translations), do: translations
  defp translations_of(_record), do: %{}

  defp base_value(record, field), do: Map.get(record, field)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp present(_value), do: nil

  @doc """
  Cleans a translations map on its way into the database.

  Only known locales, only known fields, only strings — the column is
  schemaless and the same reasoning as `Blastek.Venues.Settings` applies: a typo
  must not write a key nobody reads. Blank values are *removed* rather than
  stored, so clearing an Arabic name in the editor restores the fallback instead
  of pinning an empty string in front of it.

  Values are also **bounded**. The base columns are `varchar` and Postgres
  refuses anything longer; JSONB has no such limit, so without this a manager
  could put a megabyte of text where a service name goes and every venue page
  would carry it forever. Truncated rather than rejected, because the failure
  this guards against is accidental far more often than deliberate.
  """
  @max_length 2_000

  def sanitize(translations, allowed_fields) when is_map(translations) do
    allowed = Enum.map(allowed_fields, &to_string/1)

    translations
    |> Enum.reduce(%{}, fn {locale, values}, acc ->
      # `parse/1`, not `normalize/1`: a locale nobody speaks must be dropped,
      # not quietly filed under French.
      with {:ok, tag} <- parse(locale),
           true <- is_map(values),
           cleaned when cleaned != %{} <- clean_values(values, allowed) do
        Map.put(acc, tag, cleaned)
      else
        _ -> acc
      end
    end)
  end

  def sanitize(_translations, _allowed_fields), do: %{}

  defp clean_values(values, allowed) do
    for {field, value} <- values,
        to_string(field) in allowed,
        trimmed = present(value),
        into: %{},
        do: {to_string(field), trimmed |> String.trim() |> String.slice(0, @max_length)}
  end

  ## ---------- the editor's view ----------
  #
  # An owner editing their catalog thinks in tabs: French, Arabic, English.
  # Storage does not — French lives in the base columns, because it is the
  # fallback every other locale ends at and because every query that does not
  # care about locale reads it. `expose/2` and `split/2` are the two halves of
  # keeping that an implementation detail: the editor sends and receives one
  # uniform per-locale map, and nothing in the UI needs to know that one of the
  # tabs is special.

  @doc """
  Every locale's values for a record, including French from its base columns.

      expose(service, [:name, :description])
      #=> %{"fr" => %{"name" => "Coupe"}, "ar" => %{"name" => "قص"}}

  Only what is actually set: a locale nobody has filled in is absent rather than
  present-and-empty, so the editor can show a blank tab rather than a tab full
  of empty strings that would then be saved.
  """
  def expose(record, fields) do
    base =
      for field <- fields, value = present(base_value(record, field)), into: %{} do
        {to_string(field), value}
      end

    stored = record |> translations_of() |> sanitize(fields)

    case base do
      empty when empty == %{} -> stored
      base -> Map.put(stored, @default, Map.merge(Map.get(stored, @default, %{}), base))
    end
  end

  @doc """
  The inverse: a per-locale map becomes base-column attrs plus the remainder.

      split(%{"fr" => %{"name" => "Coupe"}, "ar" => %{"name" => "قص"}}, [:name])
      #=> {%{name: "Coupe"}, %{"ar" => %{"name" => "قص"}}}

  The French values become ordinary column writes and are *not* duplicated into
  the JSONB — storing them twice is how the two get to disagree.
  """
  def split(translations, fields) do
    clean = sanitize(translations, fields)
    {base, rest} = Map.pop(clean, @default, %{})

    attrs = Map.new(base, fn {field, value} -> {String.to_existing_atom(field), value} end)

    {attrs, rest}
  end

  @doc """
  Changeset step: routes a submitted `translations` map to the right places.

  Put it after `cast/3`. French lands in the base columns and everything else in
  the JSONB, which is what keeps every existing caller — onboarding, fixtures,
  the `name:` argument that predates this epic — working unchanged while the
  editor speaks only in locales.

  A caller sending both `name:` and `translations: %{"fr" => %{"name" => …}}`
  gets the translation, because that is the more specific of the two.
  """
  def cast_translations(changeset, fields) do
    case Ecto.Changeset.get_change(changeset, :translations) do
      nil ->
        changeset

      translations ->
        {base_attrs, rest} = split(translations, fields)

        changeset
        |> Ecto.Changeset.change(base_attrs)
        |> Ecto.Changeset.put_change(:translations, rest)
    end
  end
end
