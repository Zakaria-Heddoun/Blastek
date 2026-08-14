defmodule Blastek.Discovery do
  @moduledoc """
  Marketplace search over the venue directory (E8-T3, E8-T4 / F0.6).

  Two responsibilities: keeping each venue's search document current, and turning
  a shopper's filters into one query.

  ## Matching

  Words are ANDed, and each word may match the venue's identity *or* one of its
  treatments — see the migration for why that needs a denormalized document. The
  last word is prefix-matched (`fade:*`) so results narrow while typing rather
  than vanishing on a half-typed word.

  ## Ranking

  `ts_rank` over weighted sections: name (A) beats treatments (B) beats
  city/address (C) beats tagline (D). Without weights a venue that merely
  mentions a treatment in its tagline outranks the salon actually named after it.

  ## Distance

  Haversine in SQL, no PostGIS. The `asin`-based form is used rather than the
  textbook `acos` one because `acos` loses precision at short distances — which
  is the only range that matters when sorting salons in one city.
  """
  import Ecto.Query

  alias Blastek.Repo
  alias Blastek.Salon.{Category, Service}
  alias Blastek.Venues.Venue

  @default_limit 24
  @max_limit 60
  # More words than this is not a search, it is a paste.
  @max_terms 8

  @sorts ~w(relevance distance rating price name)

  def sorts, do: @sorts

  # Great-circle distance in kilometres between a venue's pin and a target
  # point. A macro rather than a helper returning a string, because `fragment/2`
  # requires a literal SQL string at compile time — and because it keeps the
  # WHERE, SELECT and ORDER BY provably identical instead of three copies that
  # can drift.
  #
  # `type(^lat, :float)` is not decoration: without it Postgres cannot infer the
  # parameter type inside the trigonometric call and refuses to plan the query.
  defmacrop distance_km(venue, lat, lng) do
    quote do
      fragment(
        """
        (2 * 6371 * asin(sqrt(
          power(sin(radians(? - ?) / 2), 2) +
          cos(radians(?)) * cos(radians(?)) *
          power(sin(radians(? - ?) / 2), 2)
        )))
        """,
        type(^unquote(lat), :float),
        unquote(venue).lat,
        type(^unquote(lat), :float),
        unquote(venue).lat,
        type(^unquote(lng), :float),
        unquote(venue).lng
      )
    end
  end

  ## ---------- search ----------

  @doc """
  Searches active venues.

  Options: `:q`, `:city`, `:category`, `:women_only`, `:near` (`{lat, lng}`),
  `:within_km`, `:sort`, `:limit`, `:offset`.

  Returns `%{items: [venue], total_count: n}`. `total_count` is the whole
  filtered set, not the page — the UI needs it to say "37 venues".
  """
  def search(opts \\ []) do
    filtered =
      from(v in Venue, as: :venue, where: v.status == "active")
      |> apply_text(opts[:q])
      |> apply_city(opts[:city])
      |> apply_category(opts[:category])
      |> apply_women_only(opts[:women_only])
      |> apply_radius(opts[:near], opts[:within_km])

    # Counted before ordering or paging: ordering by a rank expression the
    # aggregate does not select would not survive the count query.
    total_count = Repo.aggregate(filtered, :count, :id)

    items =
      filtered
      |> select_distance(opts[:near])
      |> apply_sort(opts[:sort], opts[:q], opts[:near])
      |> paginate(opts)
      |> Repo.all()

    %{items: items, total_count: total_count}
  end

  @doc "Cities that currently have listable venues, most venues first."
  def cities do
    Repo.all(
      from v in Venue,
        where: v.status == "active" and v.city != "",
        group_by: v.city,
        order_by: [desc: count(v.id), asc: v.city],
        select: %{city: v.city, venue_count: count(v.id)}
    )
  end

  @doc "Category names offered by at least one listable venue."
  def categories do
    Repo.all(
      from c in Category,
        join: s in Service,
        on: s.category_id == c.id and s.active,
        join: v in Venue,
        on: v.id == s.venue_id and v.status == "active",
        group_by: c.name,
        order_by: [desc: count(s.id), asc: c.name],
        select: %{name: c.name, service_count: count(s.id)}
    )
  end

  ## ---------- filters ----------

  defp apply_text(query, term) do
    case tsquery(term) do
      nil ->
        query

      tsquery ->
        from v in query,
          join: d in "venue_search_documents",
          as: :doc,
          on: d.venue_id == v.id,
          where: fragment("? @@ to_tsquery('simple', unaccent(?))", d.document, ^tsquery)
    end
  end

  @doc """
  Builds a `tsquery` string from user input.

  Public because it is worth testing directly: everything non-alphanumeric is
  dropped, which is both the sanitizer (`to_tsquery` raises on malformed input,
  and this is user-supplied) and the tokenizer.
  """
  def tsquery(term) when is_binary(term) do
    words =
      term
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.take(@max_terms)

    case words do
      [] -> nil
      words -> words |> Enum.map_join(" & ", &"#{&1}:*")
    end
  end

  def tsquery(_), do: nil

  defp apply_city(query, nil), do: query
  defp apply_city(query, ""), do: query

  defp apply_city(query, city) do
    # Compared against the normalized key so "Casablanca" and "casablanca" agree.
    normalized = city |> String.trim() |> String.downcase()

    from v in query,
      where:
        fragment(
          "exists (select 1 from venue_search_documents d where d.venue_id = ? and d.city_key = lower(unaccent(?)))",
          v.id,
          ^normalized
        )
  end

  defp apply_category(query, nil), do: query
  defp apply_category(query, ""), do: query

  defp apply_category(query, category) do
    from v in query,
      where:
        exists(
          from s in Service,
            join: c in Category,
            on: c.id == s.category_id,
            where:
              s.venue_id == parent_as(:venue).id and s.active and
                fragment("lower(unaccent(?)) = lower(unaccent(?))", c.name, ^category),
            select: 1
        )
  end

  defp apply_women_only(query, true) do
    from v in query,
      where: fragment("coalesce((? ->> 'women_only')::boolean, false)", v.settings)
  end

  # Absent or false means "no preference", not "exclude women-only venues".
  defp apply_women_only(query, _), do: query

  defp apply_radius(query, {lat, lng}, km) when is_number(km) and km > 0 do
    # Bounding box first so the (lat, lng) index can exclude most of the table
    # before anything computes a trigonometric distance.
    delta_lat = km / 111.0
    delta_lng = km / max(111.0 * :math.cos(deg_to_rad(lat)), 0.001)

    from v in query,
      where:
        not is_nil(v.lat) and not is_nil(v.lng) and
          v.lat >= ^(lat - delta_lat) and v.lat <= ^(lat + delta_lat) and
          v.lng >= ^(lng - delta_lng) and v.lng <= ^(lng + delta_lng) and
          distance_km(v, lat, lng) <= ^km
  end

  defp apply_radius(query, _near, _km), do: query

  ## ---------- distance ----------

  defp select_distance(query, {lat, lng}) do
    from v in query,
      select: v,
      select_merge: %{distance_km: distance_km(v, lat, lng)}
  end

  defp select_distance(query, _), do: query

  ## ---------- ordering & paging ----------

  defp apply_sort(query, "distance", _q, {lat, lng}) do
    # Venues nobody has pinned sort last rather than dropping out — they are
    # still real salons, just not locatable.
    from v in query,
      order_by: [
        asc_nulls_last: distance_km(v, lat, lng),
        asc: v.name
      ]
  end

  # The denormalized column, not a correlated subquery over `reviews`. The
  # subquery re-averaged every review of every candidate venue on each sorted
  # search, and it counted hidden ones — so a moderated review went on
  # influencing where its venue ranked long after it stopped being readable.
  defp apply_sort(query, "rating", _q, _near) do
    from v in query, order_by: [desc: v.rating_avg, asc: v.name]
  end

  defp apply_sort(query, "price", _q, _near) do
    from v in query,
      order_by: [
        asc_nulls_last:
          fragment(
            "(select min(s.price_cents) from services s where s.venue_id = ? and s.active)",
            v.id
          ),
        asc: v.name
      ]
  end

  defp apply_sort(query, "name", _q, _near), do: from(v in query, order_by: v.name)

  # Relevance is only meaningful with a search term; without one the directory is
  # alphabetical, which at least is stable between page loads.
  defp apply_sort(query, _sort, q, near) do
    case tsquery(q) do
      nil -> apply_sort(query, "name", nil, near)
      tsquery -> order_by_rank(query, tsquery)
    end
  end

  defp order_by_rank(query, tsquery) do
    from [v, doc: d] in query,
      order_by: [
        desc: fragment("ts_rank(?, to_tsquery('simple', unaccent(?)))", d.document, ^tsquery),
        asc: v.name
      ]
  end

  defp paginate(query, opts) do
    limit = opts[:limit] |> normalize_limit()
    offset = opts[:offset] |> normalize_offset()
    from v in query, limit: ^limit, offset: ^offset
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp normalize_limit(_), do: @default_limit

  defp normalize_offset(n) when is_integer(n) and n > 0, do: n
  defp normalize_offset(_), do: 0

  defp deg_to_rad(degrees), do: degrees * :math.pi() / 180.0

  ## ---------- indexing ----------

  @doc """
  Rebuilds one venue's search document.

  Called from every write that can change what a venue matches on. Cheap enough
  to call unconditionally — one statement, no round trip per service.
  """
  def reindex_venue(venue_id) when is_integer(venue_id) do
    Repo.query!(reindex_sql(), [venue_id])
    :ok
  end

  def reindex_venue(%Venue{id: id}), do: reindex_venue(id)
  def reindex_venue(_), do: :ok

  @doc """
  Rebuilds every document.

  The repair for a missed hook or a change to how documents are built; also how
  the seed gets a searchable directory.

  Runs with a long timeout rather than the pool default: this is one statement
  over the entire directory, and it is an operator action — nobody is holding a
  request open waiting for it. `reindex_venue/1` keeps the default, because that
  one *is* on a request path.
  """
  def reindex_all(opts \\ []) do
    %{num_rows: rows} =
      Repo.query!(reindex_sql(), [nil], timeout: Keyword.get(opts, :timeout, 120_000))

    rows
  end

  @doc """
  The upsert behind both reindex functions.

  `$1` is a venue id, or NULL to rebuild everything — one statement serving both
  so the single-venue and full rebuild can never produce different documents.
  """
  def reindex_sql do
    """
    INSERT INTO venue_search_documents (venue_id, document, city_key, updated_at)
    SELECT
      v.id,
      setweight(to_tsvector('simple', unaccent(v.name)), 'A')
        || setweight(to_tsvector('simple', unaccent(coalesce(sv.terms, ''))), 'B')
        || setweight(to_tsvector('simple', unaccent(v.city || ' ' || v.address)), 'C')
        || setweight(to_tsvector('simple', unaccent(v.tagline)), 'D'),
      lower(unaccent(v.city)),
      now()
    FROM venues v
    LEFT JOIN (
      SELECT s.venue_id,
             string_agg(s.name || ' ' || s.description || ' ' || coalesce(c.name, ''), ' ') AS terms
      FROM services s
      LEFT JOIN service_categories c ON c.id = s.category_id
      WHERE s.active
      GROUP BY s.venue_id
    ) sv ON sv.venue_id = v.id
    WHERE ($1::bigint IS NULL OR v.id = $1)
    ON CONFLICT (venue_id) DO UPDATE
      SET document = EXCLUDED.document,
          city_key = EXCLUDED.city_key,
          updated_at = EXCLUDED.updated_at
    """
  end
end
