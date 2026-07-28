defmodule Blastek.Repo.Migrations.CreateVenues do
  @moduledoc """
  Multi-tenancy (Epic 1 / F0.1).

  Introduces `venues` as the tenant root and scopes every salon-domain table to
  a venue. Existing rows are absorbed into venue #1 so the demo salon keeps
  working. Dashboard access moves from the global `users.role = "professional"`
  flag to per-venue memberships.

  Also fixes two correctness issues that only bite once tenants exist:
    * appointments gain an exclusion constraint so two bookings can never
      occupy the same staff/time (the availability check alone is racy);
    * clients link to user accounts per venue (`clients.user_id`) instead of
      one global `users.client_id`.
  """
  use Ecto.Migration

  # Tables that become venue-scoped.
  @scoped [:service_categories, :services, :staff, :clients, :appointments, :sales, :reviews]

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist"

    create table(:venues) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :tagline, :string, null: false, default: ""
      add :address, :string, null: false, default: ""
      add :city, :string, null: false, default: ""
      add :phone, :string, null: false, default: ""
      add :status, :string, null: false, default: "pending"
      add :settings, :map, null: false, default: %{}
      timestamps(type: :naive_datetime)
    end

    create unique_index(:venues, ["lower(slug)"], name: :venues_slug_index)
    create index(:venues, [:status])

    # ---- adopt existing data into venue #1 -------------------------------
    # Built from the old key/value settings table so the demo salon keeps its
    # identity. Skipped entirely on a fresh database — there the seed creates
    # the venues, and a phantom tenant here would make it think it had already
    # run. `HAVING` is what suppresses the all-NULL row an aggregate over an
    # empty table would otherwise produce.
    execute """
    INSERT INTO venues (slug, name, tagline, address, city, phone, status, settings,
                        inserted_at, updated_at)
    SELECT
      'le-salon-anfa',
      COALESCE(MAX(CASE WHEN key = 'business_name' THEN value END), 'My salon'),
      COALESCE(MAX(CASE WHEN key = 'business_tagline' THEN value END), ''),
      COALESCE(MAX(CASE WHEN key = 'business_address' THEN value END), ''),
      'Casablanca',
      COALESCE(MAX(CASE WHEN key = 'business_phone' THEN value END), ''),
      'active',
      '{}'::jsonb,
      NOW()::timestamp(0),
      NOW()::timestamp(0)
    FROM settings
    HAVING COUNT(*) > 0
        OR EXISTS (SELECT 1 FROM staff)
        OR EXISTS (SELECT 1 FROM services)
        OR EXISTS (SELECT 1 FROM clients)
    """

    for table <- @scoped do
      alter table(table) do
        add :venue_id, references(:venues, on_delete: :delete_all)
      end
    end

    flush()

    for table <- @scoped do
      execute "UPDATE #{table} SET venue_id = (SELECT MIN(id) FROM venues)"
      execute "ALTER TABLE #{table} ALTER COLUMN venue_id SET NOT NULL"
    end

    # ---- hot-path indexes ------------------------------------------------
    create index(:service_categories, [:venue_id])
    create index(:services, [:venue_id])
    create index(:staff, [:venue_id])
    create index(:clients, [:venue_id])
    create index(:appointments, [:venue_id, :date])
    create index(:appointments, [:venue_id, :staff_id, :date])
    create index(:appointments, [:venue_id, :client_id])
    create index(:sales, [:venue_id, :inserted_at])
    create index(:reviews, [:venue_id])

    # Booking refs are customer-facing; make them unique and non-guessable.
    # The previous timestamp-derived refs could collide, so clear duplicates
    # before the index is enforced (keeping the earliest of each group).
    execute """
    UPDATE appointments SET booking_ref = ''
    WHERE booking_ref <> '' AND id NOT IN (
      SELECT MIN(id) FROM appointments WHERE booking_ref <> '' GROUP BY booking_ref
    )
    """

    create unique_index(:appointments, [:booking_ref], name: :appointments_booking_ref_index,
      where: "booking_ref <> ''")

    # ---- double-booking invariant (B4) -----------------------------------
    # The availability check is advisory; this is the guarantee. Cancelled and
    # no-show appointments free their slot.
    execute """
    ALTER TABLE appointments ADD CONSTRAINT appointments_no_overlap
    EXCLUDE USING gist (
      staff_id WITH =,
      date WITH =,
      int4range(start_min, end_min) WITH &&
    ) WHERE (status NOT IN ('cancelled', 'no_show'))
    """

    # ---- memberships replace the global professional role ----------------
    create table(:venue_members) do
      add :venue_id, references(:venues, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "staff"
      add :staff_id, references(:staff, on_delete: :nilify_all)
      timestamps(type: :naive_datetime)
    end

    create unique_index(:venue_members, [:venue_id, :user_id])
    create index(:venue_members, [:user_id])

    # Every existing professional becomes an owner of the seeded venue.
    execute """
    INSERT INTO venue_members (venue_id, user_id, role, inserted_at, updated_at)
    SELECT (SELECT MIN(id) FROM venues), id, 'owner', NOW()::timestamp(0), NOW()::timestamp(0)
    FROM users WHERE role = 'professional'
    """

    execute "UPDATE users SET role = 'customer' WHERE role = 'professional'"

    # ---- client identity: per-venue record, one login (B12) --------------
    alter table(:clients) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    flush()

    execute "UPDATE clients c SET user_id = u.id FROM users u WHERE u.client_id = c.id"

    create unique_index(:clients, [:venue_id, :user_id], name: :clients_venue_user_index,
      where: "user_id IS NOT NULL")

    alter table(:users) do
      remove :client_id
    end

    # The key/value settings table is superseded by venue columns + JSONB.
    drop table(:settings)
  end

  def down do
    create table(:settings) do
      add :key, :string, null: false
      add :value, :string, null: false
    end

    create unique_index(:settings, [:key])

    alter table(:users) do
      add :client_id, references(:clients)
    end

    flush()

    # Restore the single-tenant identity from venue #1 so a rollback does not
    # come back with a nameless business.
    execute """
    INSERT INTO settings (key, value)
    SELECT s.key, s.value
    FROM venues v,
         LATERAL (VALUES ('business_name', v.name), ('business_tagline', v.tagline),
                         ('business_address', v.address), ('business_phone', v.phone)) AS s(key, value)
    WHERE v.id = (SELECT MIN(id) FROM venues)
    """

    execute "UPDATE users u SET client_id = c.id FROM clients c WHERE c.user_id = u.id"

    execute """
    UPDATE users SET role = 'professional'
    WHERE id IN (SELECT user_id FROM venue_members WHERE role IN ('owner', 'manager'))
    """

    drop unique_index(:clients, [:venue_id, :user_id], name: :clients_venue_user_index)

    alter table(:clients) do
      remove :user_id
    end

    drop table(:venue_members)

    execute "ALTER TABLE appointments DROP CONSTRAINT appointments_no_overlap"
    drop unique_index(:appointments, [:booking_ref], name: :appointments_booking_ref_index)

    drop index(:service_categories, [:venue_id])
    drop index(:services, [:venue_id])
    drop index(:staff, [:venue_id])
    drop index(:clients, [:venue_id])
    drop index(:appointments, [:venue_id, :date])
    drop index(:appointments, [:venue_id, :staff_id, :date])
    drop index(:appointments, [:venue_id, :client_id])
    drop index(:sales, [:venue_id, :inserted_at])
    drop index(:reviews, [:venue_id])

    for table <- @scoped do
      alter table(table) do
        remove :venue_id
      end
    end

    drop table(:venues)
  end
end
