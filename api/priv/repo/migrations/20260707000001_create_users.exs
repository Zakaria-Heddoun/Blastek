defmodule Blastek.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :password_hash, :string, null: false
      add :role, :string, null: false, default: "customer"
      add :first_name, :string, null: false, default: ""
      add :last_name, :string, null: false, default: ""
      add :phone, :string, null: false, default: ""
      add :client_id, references(:clients)
      timestamps(type: :naive_datetime)
    end

    create unique_index(:users, ["lower(email)"], name: :users_email_index)
  end
end
