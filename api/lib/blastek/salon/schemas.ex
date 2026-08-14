# Ecto schemas for the salon domain. Kept in one file for easy reading;
# each module is small and maps 1:1 to a table.
#
# Every schema here is venue-scoped: `venue_id` is required and all queries go
# through `Blastek.Scope` so a tenant can never read another tenant's rows.

defmodule Blastek.Salon.Category do
  use Ecto.Schema
  import Ecto.Changeset

  # Per-locale overrides for `name`; `name` itself stays the fallback. See
  # `Blastek.I18n`.
  @translatable [:name]

  schema "service_categories" do
    field :name, :string
    field :translations, :map, default: %{}
    field :sort, :integer, default: 0
    field :venue_id, :id
    has_many :services, Blastek.Salon.Service, foreign_key: :category_id
  end

  def translatable_fields, do: @translatable

  def changeset(cat, attrs) do
    cat
    |> cast(attrs, [:name, :translations, :sort, :venue_id])
    |> validate_required([:name, :venue_id])
    |> Blastek.I18n.cast_translations(@translatable)
  end
end

defmodule Blastek.Salon.Service do
  use Ecto.Schema
  import Ecto.Changeset

  @translatable [:name, :description]

  schema "services" do
    field :name, :string
    field :description, :string, default: ""
    field :translations, :map, default: %{}
    field :duration_min, :integer
    field :price_cents, :integer
    field :active, :boolean, default: true
    field :venue_id, :id
    belongs_to :category, Blastek.Salon.Category

    many_to_many :staff, Blastek.Salon.Staff,
      join_through: "staff_services",
      on_replace: :delete
  end

  def translatable_fields, do: @translatable

  def changeset(service, attrs) do
    service
    |> cast(attrs, [
      :name,
      :description,
      :translations,
      :duration_min,
      :price_cents,
      :active,
      :category_id,
      :venue_id
    ])
    |> validate_required([:name, :duration_min, :price_cents, :category_id, :venue_id])
    |> Blastek.I18n.cast_translations(@translatable)
    |> validate_number(:duration_min, greater_than: 0)
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
    # Without this, a category id that does not exist raises out of the resolver
    # as an unhandled `Ecto.ConstraintError` — an HTTP 500 for what is an
    # ordinary bad argument. Same failure the E1 review fixed for cross-tenant
    # reads, in the opposite direction.
    |> foreign_key_constraint(:category_id, message: "does not exist")
  end
end

defmodule Blastek.Salon.Staff do
  use Ecto.Schema
  import Ecto.Changeset

  schema "staff" do
    field :name, :string
    field :role, :string, default: ""
    field :color, :string, default: "#D8B88A"
    field :active, :boolean, default: true
    field :venue_id, :id
    has_many :hours, Blastek.Salon.StaffHour, foreign_key: :staff_id, preload_order: [:weekday]

    many_to_many :services, Blastek.Salon.Service,
      join_through: "staff_services",
      on_replace: :delete
  end

  def changeset(staff, attrs) do
    staff
    |> cast(attrs, [:name, :role, :color, :active, :venue_id])
    |> validate_required([:name, :venue_id])
  end
end

defmodule Blastek.Salon.StaffHour do
  use Ecto.Schema
  import Ecto.Changeset

  # Not venue-scoped directly: always reached through its staff member.
  schema "staff_hours" do
    belongs_to :staff, Blastek.Salon.Staff
    field :weekday, :integer
    field :working, :boolean, default: false
    field :start_min, :integer, default: 540
    # May exceed 1440 for a shift running past midnight — 00:30 is 1470.
    field :end_min, :integer, default: 1080
    # Which seasonal template these hours belong to. NULL is the default week,
    # which is what every row predating F0.4 means.
    field :template_id, :id
  end

  def changeset(hour, attrs),
    do: cast(hour, attrs, [:weekday, :working, :start_min, :end_min, :staff_id, :template_id])
end

defmodule Blastek.Salon.Client do
  use Ecto.Schema
  import Ecto.Changeset

  schema "clients" do
    field :first_name, :string
    field :last_name, :string, default: ""
    field :email, :string, default: ""
    field :phone, :string, default: ""
    field :allergies, :string, default: ""
    field :notes, :string, default: ""
    field :venue_id, :id
    # Set when this client record belongs to a marketplace account. One user
    # has at most one client record per venue.
    field :user_id, :id
    has_many :appointments, Blastek.Salon.Appointment
    timestamps(type: :naive_datetime)
  end

  def changeset(client, attrs) do
    client
    |> cast(attrs, [
      :first_name,
      :last_name,
      :email,
      :phone,
      :allergies,
      :notes,
      :venue_id,
      :user_id
    ])
    |> validate_required([:first_name, :venue_id])
    # A receptionist types "06 12 34 56 78"; a gateway needs "+212612345678".
    # Canonicalized on the way in rather than on the way out, so the number a
    # STOP is keyed against is the number stored here — see
    # `Blastek.Notifications.canonical/1`. Unparseable numbers (a foreign one,
    # say) are kept as typed rather than mangled.
    |> update_change(:phone, &Blastek.Notifications.canonical/1)
    |> unique_constraint([:venue_id, :user_id],
      name: :clients_venue_user_index,
      message: "already has a client record at this venue"
    )
  end
end

defmodule Blastek.Salon.Appointment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "appointments" do
    field :booking_ref, :string, default: ""
    field :date, :date
    field :start_min, :integer
    field :end_min, :integer
    field :status, :string, default: "booked"
    field :price_cents, :integer
    field :notes, :string, default: ""
    field :source, :string, default: "walk-in"
    field :venue_id, :id
    belongs_to :client, Blastek.Salon.Client
    belongs_to :staff, Blastek.Salon.Staff
    belongs_to :service, Blastek.Salon.Service
    timestamps(type: :naive_datetime)
  end

  @fields [
    :booking_ref,
    :date,
    :start_min,
    :end_min,
    :status,
    :price_cents,
    :notes,
    :source,
    :client_id,
    :staff_id,
    :service_id,
    :venue_id
  ]
  def changeset(appt, attrs) do
    appt
    |> cast(attrs, @fields)
    |> validate_required([
      :date,
      :start_min,
      :end_min,
      :price_cents,
      :client_id,
      :staff_id,
      :service_id,
      :venue_id
    ])
    |> validate_inclusion(:status, ~w(booked confirmed started completed cancelled no_show))
    |> unique_constraint(:booking_ref, name: :appointments_booking_ref_index)
    |> exclusion_constraint(:start_min,
      name: :appointments_no_overlap,
      message: "That time was just taken — please pick another slot."
    )
  end
end

defmodule Blastek.Salon.Sale do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sales" do
    field :subtotal_cents, :integer
    field :tip_cents, :integer, default: 0
    field :total_cents, :integer
    field :payment_method, :string, default: "card"
    field :venue_id, :id
    belongs_to :client, Blastek.Salon.Client
    has_many :items, Blastek.Salon.SaleItem, foreign_key: :sale_id
    timestamps(type: :naive_datetime)
  end

  def changeset(sale, attrs) do
    sale
    |> cast(attrs, [
      :subtotal_cents,
      :tip_cents,
      :total_cents,
      :payment_method,
      :client_id,
      :venue_id
    ])
    |> validate_required([:subtotal_cents, :total_cents, :venue_id])
    |> validate_number(:tip_cents, greater_than_or_equal_to: 0)
  end
end

defmodule Blastek.Salon.SaleItem do
  use Ecto.Schema

  # Reached only through its sale, which carries the venue.
  schema "sale_items" do
    belongs_to :sale, Blastek.Salon.Sale
    belongs_to :appointment, Blastek.Salon.Appointment
    field :description, :string
    field :amount_cents, :integer
  end
end

defmodule Blastek.Salon.Review do
  use Ecto.Schema
  import Ecto.Changeset

  schema "reviews" do
    field :client_name, :string
    field :rating, :integer
    field :comment, :string, default: ""
    field :venue_id, :id
    timestamps(type: :naive_datetime)
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [:client_name, :rating, :comment, :venue_id])
    |> validate_required([:client_name, :rating, :venue_id])
    |> validate_inclusion(:rating, 1..5)
  end
end
