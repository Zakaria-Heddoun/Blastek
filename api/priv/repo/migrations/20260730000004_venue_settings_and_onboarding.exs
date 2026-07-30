defmodule Blastek.Repo.Migrations.VenueSettingsAndOnboarding do
  @moduledoc """
  Closures, seasonal hour templates, and self-serve onboarding (E5 / F0.4, F0.5).

  ## Closures

  One row covers "Eid, the 10th to the 12th" as easily as "closed Tuesday
  afternoon": `date`..`end_date` gives the span, and a null `start_min`/`end_min`
  means the whole day. Two shapes in one table rather than two tables, because
  availability has to subtract both and a single query is the difference between
  one join and two.

  ## Hour templates

  Ramadan moves the working day: 10:00–16:00, then 21:00–00:30. A venue keeps
  named weekly grids and switches between them, so the seasonal change is one
  tap rather than fourteen edits that have to be undone a month later.

  `staff_hours.template_id` lets one stylist work different hours in Ramadan
  from the rest of the year. NULL means the default template, which is what
  every existing row is — so the whole feature arrives without touching a
  single one of them.

  A partial unique index rather than a plain one: only **one** template per venue
  may be active, and that is a database invariant rather than something the
  application remembers to enforce.

  ## Past midnight

  `end_min` is minutes from midnight and may now exceed 1440 — 00:30 is 1470.
  The availability engine is pure arithmetic on these, so the range simply gets
  wider; nothing needs to learn about days.

  ## Onboarding

  `venues.onboarding` holds the wizard's step state so a phone that dies at step
  three resumes at step three. It is deliberately schemaless: the wizard's shape
  will change more often than the database should.
  """
  use Ecto.Migration

  def change do
    create table(:venue_closures) do
      add :venue_id, references(:venues, on_delete: :delete_all), null: false

      add :date, :date, null: false
      # Null means a single day. A span stores its last day here.
      add :end_date, :date

      # Null means the whole day; otherwise the closed window within it.
      add :start_min, :integer
      add :end_min, :integer

      add :reason, :string, null: false, default: ""

      timestamps(type: :naive_datetime)
    end

    # Availability asks "anything closing this date?" on every slot lookup.
    create index(:venue_closures, [:venue_id, :date])

    create table(:venue_hour_templates) do
      add :venue_id, references(:venues, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :hours, :map, null: false, default: %{}
      add :active, :boolean, null: false, default: false

      timestamps(type: :naive_datetime)
    end

    create unique_index(:venue_hour_templates, [:venue_id, :name])

    # At most one active template per venue, enforced where it cannot be
    # forgotten.
    create unique_index(:venue_hour_templates, [:venue_id],
             where: "active",
             name: :venue_hour_templates_one_active_index
           )

    alter table(:staff_hours) do
      add :template_id, references(:venue_hour_templates, on_delete: :delete_all)
    end

    # Existing rows keep `template_id` NULL and go on meaning "the default
    # week", so no backfill is needed.
    create index(:staff_hours, [:template_id])

    # The original index was `unique (staff_id, weekday)`, which allowed a
    # stylist exactly one row per weekday — and so made per-template variants
    # impossible. It is replaced by the pair below, which together say "one row
    # per weekday *per template*":
    #
    #   * a plain unique index covering the templated rows, and
    #   * a partial one for the default week, because Postgres treats NULLs as
    #     distinct and `(staff_id, weekday, NULL)` would not conflict with
    #     itself.
    drop unique_index(:staff_hours, [:staff_id, :weekday])

    create unique_index(:staff_hours, [:staff_id, :weekday, :template_id],
             where: "template_id IS NOT NULL",
             name: :staff_hours_template_weekday_index
           )

    create unique_index(:staff_hours, [:staff_id, :weekday],
             where: "template_id IS NULL",
             name: :staff_hours_default_weekday_index
           )

    alter table(:venues) do
      add :onboarding, :map, null: false, default: %{}
      # Why an admin turned a venue down, so the owner can be told something
      # more useful than "rejected".
      add :rejected_reason, :string, null: false, default: ""
    end

    create table(:service_templates) do
      # Which starter catalog this belongs to: "coiffure_femme", "barbier"…
      add :catalog, :string, null: false
      add :category, :string, null: false

      # {"fr": "Coupe femme", "ar": "…", "en": "Women's cut"} — the wizard is
      # used in Arabic, so names are translated from the start rather than
      # retrofitted by E7.
      add :name_i18n, :map, null: false, default: %{}

      add :duration_min, :integer, null: false
      add :price_hint_cents, :integer, null: false, default: 0
      add :sort, :integer, null: false, default: 0
    end

    create index(:service_templates, [:catalog, :sort])
  end
end
