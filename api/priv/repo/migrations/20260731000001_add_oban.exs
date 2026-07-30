defmodule Blastek.Repo.Migrations.AddOban do
  @moduledoc """
  Oban's job tables (E6-T1 / F0.10).

  Jobs live in Postgres rather than a second datastore because of what they
  are: a WhatsApp confirmation that must survive a provider outage, and a
  reminder scheduled for 20:00 tomorrow that must survive a deploy at 19:00.
  Both are rows in the database we already run and already back up.
  """
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  # Down to 1 rather than 0: Oban's version 1 is the base table, and dropping
  # to 0 removes it entirely along with any job still queued.
  def down, do: Oban.Migration.down(version: 1)
end
