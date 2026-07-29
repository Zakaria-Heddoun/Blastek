defmodule Blastek.Repo.Migrations.CreateAttachments do
  @moduledoc """
  Uploaded media (E8-T1 / F0.6).

  One row per original upload; the derived thumb/card/hero live in `variants` as
  `%{"thumb" => key, ...}` rather than in their own table. They are not
  independently addressable — they are created together, deleted together, and
  never queried on their own — so a table would buy nothing but a join.

  `status` exists because a presigned upload is a two-step handshake: the row is
  written before the bytes land, so `pending` rows are expected and a sweep can
  reclaim the ones the browser abandoned.
  """
  use Ecto.Migration

  def change do
    create table(:attachments) do
      add :venue_id, references(:venues, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "gallery"
      add :key, :string, null: false
      add :content_type, :string, null: false, default: ""
      add :byte_size, :integer
      add :width, :integer
      add :height, :integer
      add :variants, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :sort, :integer, null: false, default: 0
      add :alt, :string, null: false, default: ""
      timestamps(type: :naive_datetime)
    end

    create unique_index(:attachments, [:key])
    # The gallery read path: one venue's ready photos in display order.
    create index(:attachments, [:venue_id, :kind, :sort])
    # Lets the abandoned-upload sweep find stale rows without scanning.
    create index(:attachments, [:status, :inserted_at])
  end
end
