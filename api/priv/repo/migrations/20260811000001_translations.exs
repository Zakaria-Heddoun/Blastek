defmodule Blastek.Repo.Migrations.Translations do
  @moduledoc """
  Per-locale values for owner-written content, and a locale on the account
  (E7-T6 / F0.11).

  ## Why a JSONB column rather than a translations table

  The alternative — `service_translations(service_id, locale, name, description)`
  — is the textbook answer and the wrong one here. Every read of a service would
  gain a join whose only purpose is picking one row, the fallback chain
  (`ar → fr → base`) would become a `COALESCE` across three outer joins, and
  the write path would need an upsert per locale. A salon has three locales and
  will never have thirty.

  The shape is `{"ar": {"name": "...", "description": "..."}}`. The **base
  columns stay authoritative**: `services.name` is what the owner typed first
  and is the last link in every fallback chain, so a venue that never touches
  the translation tabs behaves exactly as it did before this migration. That is
  also why these columns are nullable-by-default-empty rather than backfilled —
  there is nothing to backfill, absence already means "use the base value".

  ## Search

  `search_tsv` on venues is generated from the base columns only. Indexing the
  Arabic name too is a real improvement and a real piece of work — Postgres has
  no Arabic stemmer configured here and `unaccent` does nothing useful for it —
  so it is deliberately out of scope; F0.6's search keeps working unchanged.

  ## `users.locale`

  Nullable, not defaulted to "fr". A null means "nobody has chosen", which is
  what lets the `Accept-Language` header win for a visitor who has never touched
  the switcher — a default would make every account claim French from the moment
  it was created.
  """
  use Ecto.Migration

  def change do
    alter table(:services) do
      add :translations, :map, null: false, default: %{}
    end

    alter table(:service_categories) do
      add :translations, :map, null: false, default: %{}
    end

    alter table(:venues) do
      add :translations, :map, null: false, default: %{}
    end

    alter table(:users) do
      add :locale, :string
    end
  end
end
