defmodule Blastek.Repo.Migrations.MoneyAsCentimes do
  @moduledoc """
  Money moves from `float` to integer centimes (E2-T2 / F0.13 B5).

  Floats cannot represent 0.10 exactly, so sums drift: a day of 20.10 MAD sales
  does not add up to 402.00. That is tolerable for a demo dashboard and illegal
  for a fiscal document, so this lands before invoicing (F1.6) and payments
  (F1.1) are built on top.

  Columns are renamed with an explicit unit (`price_cents`) rather than reusing
  the old names — a silent change of scale under the same name is exactly the
  kind of thing that ships a 100x pricing bug.
  """
  use Ecto.Migration

  # {table, [{old_float_column, new_cents_column}]}
  @money [
    {:services, [{:price, :price_cents}]},
    {:appointments, [{:price, :price_cents}]},
    {:sales, [{:subtotal, :subtotal_cents}, {:tip, :tip_cents}, {:total, :total_cents}]},
    {:sale_items, [{:amount, :amount_cents}]}
  ]

  def up do
    for {table, columns} <- @money do
      alter table(table) do
        for {_old, new} <- columns, do: add(new, :integer)
      end
    end

    flush()

    for {table, columns} <- @money, {old, new} <- columns do
      execute "UPDATE #{table} SET #{new} = ROUND(#{old}::numeric * 100)"

      # Reconciliation: every row must round-trip within half a centime.
      # Raises (aborting the migration) rather than silently restating money.
      execute """
      DO $$
      DECLARE bad integer;
      BEGIN
        SELECT COUNT(*) INTO bad FROM #{table}
        WHERE #{new} IS NULL AND #{old} IS NOT NULL
           OR ABS(#{new}::numeric / 100 - #{old}::numeric) > 0.005;

        IF bad > 0 THEN
          RAISE EXCEPTION 'centime conversion mismatch on #{table}.#{old}: % row(s)', bad;
        END IF;
      END $$;
      """

      execute "ALTER TABLE #{table} ALTER COLUMN #{new} SET NOT NULL"
    end

    for {table, columns} <- @money do
      alter table(table) do
        for {old, _new} <- columns, do: remove(old)
      end
    end
  end

  def down do
    for {table, columns} <- @money do
      alter table(table) do
        for {old, _new} <- columns, do: add(old, :float)
      end
    end

    flush()

    for {table, columns} <- @money, {old, new} <- columns do
      execute "UPDATE #{table} SET #{old} = #{new} / 100.0"
      execute "ALTER TABLE #{table} ALTER COLUMN #{old} SET NOT NULL"
    end

    for {table, columns} <- @money do
      alter table(table) do
        for {_old, new} <- columns, do: remove(new)
      end
    end
  end
end
