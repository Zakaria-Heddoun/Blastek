defmodule Blastek.Repo.Migrations.IndexAudit do
  @moduledoc """
  Index pass over the hot paths (E2-T6 / F0.13 B6).

  Added, after `EXPLAIN` showed the plans:

    * `sale_items.sale_id` — the reports join (`sale_items` → `sales`) was a
      sequential scan over every sale line the venue has ever recorded. This is
      the single worst plan in the app: it grows with total history, not with
      the reporting window.
    * `sale_items.appointment_id` — same shape, used when tracing a sale back
      to its appointment.
    * `clients.user_id` — `list_client_ids_for_user/1` runs on every customer
      request. It was scraping the `(venue_id, user_id)` composite because the
      leading column is absent from the query.

  Dropped as redundant: single-column indexes whose queries always also filter
  by venue, and are therefore already served by a `(venue_id, …)` composite.
  Every redundant index is write amplification on the busiest tables.
  """
  use Ecto.Migration

  def up do
    create index(:sale_items, [:sale_id])
    create index(:sale_items, [:appointment_id])
    create index(:clients, [:user_id], where: "user_id IS NOT NULL")

    # Covered by appointments_venue_id_date_index / _venue_id_staff_id_date_index.
    drop_if_exists index(:appointments, [:date])
    drop_if_exists index(:appointments, [:staff_id, :date])
    # Covered by sales_venue_id_inserted_at_index.
    drop_if_exists index(:sales, [:inserted_at])
  end

  def down do
    create index(:appointments, [:date])
    create index(:appointments, [:staff_id, :date])
    create index(:sales, [:inserted_at])

    drop_if_exists index(:clients, [:user_id])
    drop_if_exists index(:sale_items, [:appointment_id])
    drop_if_exists index(:sale_items, [:sale_id])
  end
end
