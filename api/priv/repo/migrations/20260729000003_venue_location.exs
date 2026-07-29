defmodule Blastek.Repo.Migrations.VenueLocation do
  @moduledoc """
  Coordinates for the venue page map.

  Nullable on purpose: a venue is listable before anyone has geocoded it, and
  the page falls back to an address card. Full geocoding on onboarding plus
  distance search lands with discovery (F0.6) — these columns are what it will
  populate.
  """
  use Ecto.Migration

  def change do
    alter table(:venues) do
      add :lat, :float
      add :lng, :float
    end
  end
end
