defmodule Blastek.Repo.Migrations.CreateCore do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :string, null: false
      add :value, :string, null: false
    end

    create unique_index(:settings, [:key])

    create table(:service_categories) do
      add :name, :string, null: false
      add :sort, :integer, null: false, default: 0
    end

    create table(:services) do
      add :category_id, references(:service_categories), null: false
      add :name, :string, null: false
      add :description, :string, null: false, default: ""
      add :duration_min, :integer, null: false
      add :price, :float, null: false
      add :active, :boolean, null: false, default: true
    end

    create table(:staff) do
      add :name, :string, null: false
      add :role, :string, null: false, default: ""
      add :color, :string, null: false, default: "#D8B88A"
      add :active, :boolean, null: false, default: true
    end

    create table(:staff_services, primary_key: false) do
      add :staff_id, references(:staff), null: false
      add :service_id, references(:services), null: false
    end

    create unique_index(:staff_services, [:staff_id, :service_id])

    create table(:staff_hours) do
      add :staff_id, references(:staff), null: false
      add :weekday, :integer, null: false
      add :working, :boolean, null: false, default: false
      add :start_min, :integer, null: false, default: 540
      add :end_min, :integer, null: false, default: 1080
    end

    create unique_index(:staff_hours, [:staff_id, :weekday])

    create table(:clients) do
      add :first_name, :string, null: false
      add :last_name, :string, null: false, default: ""
      add :email, :string, null: false, default: ""
      add :phone, :string, null: false, default: ""
      add :allergies, :string, null: false, default: ""
      add :notes, :text, null: false, default: ""
      timestamps(type: :naive_datetime)
    end

    create table(:appointments) do
      add :booking_ref, :string, null: false, default: ""
      add :client_id, references(:clients), null: false
      add :staff_id, references(:staff), null: false
      add :service_id, references(:services), null: false
      add :date, :date, null: false
      add :start_min, :integer, null: false
      add :end_min, :integer, null: false
      add :status, :string, null: false, default: "booked"
      add :price, :float, null: false
      add :notes, :text, null: false, default: ""
      add :source, :string, null: false, default: "walk-in"
      timestamps(type: :naive_datetime)
    end

    create index(:appointments, [:date])
    create index(:appointments, [:staff_id, :date])

    create table(:sales) do
      add :client_id, references(:clients), null: false
      add :subtotal, :float, null: false
      add :tip, :float, null: false, default: 0.0
      add :total, :float, null: false
      add :payment_method, :string, null: false, default: "card"
      timestamps(type: :naive_datetime)
    end

    create index(:sales, [:inserted_at])

    create table(:sale_items) do
      add :sale_id, references(:sales), null: false
      add :appointment_id, references(:appointments)
      add :description, :string, null: false
      add :amount, :float, null: false
    end

    create table(:reviews) do
      add :client_name, :string, null: false
      add :rating, :integer, null: false
      add :comment, :text, null: false, default: ""
      timestamps(type: :naive_datetime)
    end
  end
end
