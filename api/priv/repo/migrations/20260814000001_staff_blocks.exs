defmodule Blastek.Repo.Migrations.StaffBlocks do
  @moduledoc """
  Time a staff member is not available, for reasons that are not the weekly
  grid (E9-T1 / F0.7).

  ## Three kinds, one table

  `time_off` is whole days, possibly a range — a holiday. `break` is a time
  range, optionally repeating weekly — lunch every Friday. `blocked` is a
  one-off range — a dentist appointment on Tuesday.

  They share a table because availability asks all three the same question
  ("is this staff member free between these two minutes on this date?") and a
  table per kind would mean three queries and three chances to forget one. The
  shape differences are expressed by which columns are null, which is why none
  of `end_date`, `start_min`, `end_min` or `weekday` is required.

  ## Why this is not a closure

  `venue_closures` (F0.4) shuts the whole salon; this shuts one person. They
  are subtracted at the same point in `Salon.availability/4` and deliberately
  kept apart: a venue closing for Eid and a stylist taking Thursday off are
  different decisions, made by different people, and merging them would mean
  one person's holiday could read as the salon being shut.

  ## Ranges are half-open in minutes, and may pass midnight

  `start_min`/`end_min` are minutes from that day's midnight and follow the
  same convention as shifts and appointments: `end_min` may exceed 1440 for a
  block running past midnight (23:00–01:00 is 1380–1500). Every comparison is
  plain arithmetic, so nothing downstream needs to know about days.
  """
  use Ecto.Migration

  def change do
    create table(:staff_blocks) do
      add :venue_id, references(:venues, on_delete: :delete_all), null: false
      # A block belongs to the person, so it goes when they do.
      add :staff_id, references(:staff, on_delete: :delete_all), null: false

      # time_off | break | blocked
      add :kind, :string, null: false

      # The first day this applies to. For a weekly break it is the day the
      # rule starts, not the only day it applies to.
      add :date, :date, null: false
      # Inclusive last day of a multi-day holiday; null means a single day.
      add :end_date, :date

      # Null for `time_off`, which takes the whole day whatever the shift is.
      add :start_min, :integer
      add :end_min, :integer

      add :weekly, :boolean, null: false, default: false
      # 0 = Sunday, matching `Date.day_of_week(date, :sunday) - 1` and the
      # `weekday` column on `staff_hours`. Only meaningful when `weekly`.
      add :weekday, :integer

      add :note, :string, null: false, default: ""

      timestamps(type: :naive_datetime)
    end

    # Availability asks "this staff member, this date" on every slot query, and
    # that is the hot path of the whole marketplace.
    create index(:staff_blocks, [:staff_id, :date])
    create index(:staff_blocks, [:venue_id, :date])
    # A weekly rule is found by weekday rather than by date, so it needs its
    # own path in; partial, because most rows are not weekly.
    create index(:staff_blocks, [:staff_id, :weekday], where: "weekly")

    create constraint(:staff_blocks, :staff_blocks_kind,
             check: "kind IN ('time_off', 'break', 'blocked')"
           )

    # A range that ends before it starts is not a short block, it is a typo,
    # and one that reaches availability silently removes nothing at all.
    create constraint(:staff_blocks, :staff_blocks_minutes,
             check:
               "(start_min IS NULL AND end_min IS NULL) OR " <>
                 "(start_min IS NOT NULL AND end_min IS NOT NULL AND end_min > start_min)"
           )

    create constraint(:staff_blocks, :staff_blocks_dates,
             check: "end_date IS NULL OR end_date >= date"
           )

    # A weekly rule without a weekday would repeat on no day at all — a block
    # that silently blocks nothing is worse than one that fails to save.
    create constraint(:staff_blocks, :staff_blocks_weekly_weekday,
             check: "NOT weekly OR (weekday IS NOT NULL AND weekday BETWEEN 0 AND 6)"
           )
  end
end
