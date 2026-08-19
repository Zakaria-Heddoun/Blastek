defmodule Blastek.Repo.Migrations.AddUserAvatars do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE attachments ALTER COLUMN venue_id DROP NOT NULL")

    alter table(:attachments) do
      add :user_id, references(:users, on_delete: :delete_all)
    end

    create index(:attachments, [:user_id, :kind, :status])

    create constraint(:attachments, :attachments_exactly_one_owner,
             check: "(venue_id IS NULL) <> (user_id IS NULL)"
           )
  end

  def down do
    execute("DELETE FROM attachments WHERE user_id IS NOT NULL")
    drop constraint(:attachments, :attachments_exactly_one_owner)
    drop index(:attachments, [:user_id, :kind, :status])

    alter table(:attachments) do
      remove :user_id
    end

    execute("ALTER TABLE attachments ALTER COLUMN venue_id SET NOT NULL")
  end
end
