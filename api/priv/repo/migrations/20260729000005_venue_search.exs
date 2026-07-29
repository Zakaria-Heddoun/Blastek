defmodule Blastek.Repo.Migrations.VenueSearch do
  @moduledoc """
  Full-text search over the venue directory (E8-T3 / F0.6).

  Replaces a `LIKE '%word%'` scan. A leading wildcard cannot use an index, so
  that approach degrades linearly with the directory and was never going to meet
  the search budget.

  ## Why a separate document table

  A shopper types what they want ("skin fade"), where they are ("Rabat"), or who
  they want ("Barber Corner") — often in one box, in any order. Words must be
  ANDed, but each word may match the venue *or* one of its treatments: "fade
  rabat" has to find the Rabat barber whose service list contains "fade". That
  cannot be expressed as a per-table match, because no single row holds both
  facts.

  So each venue gets one denormalized `tsvector` combining its own identity with
  the treatments it offers. One GIN index, one `@@`, and AND semantics fall out
  for free.

  The cost is a document that can go stale, which is why every write path funnels
  through `Blastek.Discovery.reindex_venue/1` and `reindex_all/0` exists as the
  repair.

  ## Why `simple` rather than `french`

  A stemmer helps only in the language it was built for. This catalog mixes
  French, Arabic and English ("balayage", "hammam", "fade") and a French stemmer
  mangles the other two. `simple` plus `unaccent` gets the win that actually
  matters here — "Éclat" found by typing "eclat" — with no language guess.
  Prefix matching (`fade:*`) covers the rest.
  """
  use Ecto.Migration

  def up do
    # Accent-insensitive matching: Moroccan salon names are full of them
    # (Éclat, Maârif) and nobody types them into a search box.
    execute "CREATE EXTENSION IF NOT EXISTS unaccent"

    create table(:venue_search_documents, primary_key: false) do
      add :venue_id, references(:venues, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :document, :tsvector, null: false
      # Normalized at write time so the city filter needs no function index —
      # `unaccent` is only STABLE and cannot be indexed directly.
      add :city_key, :string, null: false, default: ""
      add :updated_at, :naive_datetime, null: false
    end

    create index(:venue_search_documents, [:document], using: :gin)
    create index(:venue_search_documents, [:city_key])

    # Serves the bounding-box prefilter of radius search ("near me"), which is a
    # primary discovery path rather than an occasional report.
    create index(:venues, [:lat, :lng])

    flush()

    # Backfill every existing venue.
    #
    # Inlined rather than calling `Blastek.Discovery.reindex_sql/0`: a migration
    # has to keep doing what it did the day it ran, and borrowing a module that
    # is still evolving would let a later refactor silently rewrite history. The
    # live version of this statement is in that module.
    execute """
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
    ON CONFLICT (venue_id) DO UPDATE
      SET document = EXCLUDED.document,
          city_key = EXCLUDED.city_key,
          updated_at = EXCLUDED.updated_at
    """
  end

  def down do
    drop index(:venues, [:lat, :lng])
    drop table(:venue_search_documents)
    # The extension is left in place: other things may have come to depend on
    # it, and dropping a shared extension on rollback is a rude surprise.
  end
end
