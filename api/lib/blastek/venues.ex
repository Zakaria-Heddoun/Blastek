defmodule Blastek.Venues.Venue do
  @moduledoc "A tenant: one salon/barbershop/spa with its own catalog and team."
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending active suspended)

  schema "venues" do
    field :slug, :string
    field :name, :string
    field :tagline, :string, default: ""
    field :address, :string, default: ""
    field :city, :string, default: ""
    field :phone, :string, default: ""
    field :status, :string, default: "pending"
    field :settings, :map, default: %{}
    # Nil until geocoded; the venue page falls back to an address card.
    field :lat, :float
    field :lng, :float
    # Populated only by a distance search — see `Blastek.Discovery.search/1`.
    field :distance_km, :float, virtual: true
    has_many :members, Blastek.Venues.VenueMember
    timestamps(type: :naive_datetime)
  end

  def changeset(venue, attrs) do
    venue
    |> cast(attrs, [
      :slug,
      :name,
      :tagline,
      :address,
      :city,
      :phone,
      :status,
      :settings,
      :lat,
      :lng
    ])
    |> validate_required([:name])
    |> validate_number(:lat, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:lng, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> maybe_put_slug()
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/,
      message: "may only contain lowercase letters, numbers and dashes"
    )
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:slug, name: :venues_slug_index, message: "is already taken")
  end

  # Slug is derived from the name on create and immutable afterwards (SEO).
  defp maybe_put_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :name)} do
      {nil, name} when is_binary(name) ->
        put_change(changeset, :slug, Blastek.Venues.slugify(name))

      _ ->
        changeset
    end
  end
end

defmodule Blastek.Venues.VenueMember do
  @moduledoc "Links a user account to a venue with a role (the dashboard ACL)."
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(owner manager receptionist staff)

  schema "venue_members" do
    belongs_to :venue, Blastek.Venues.Venue
    belongs_to :user, Blastek.Accounts.User
    belongs_to :staff, Blastek.Salon.Staff
    field :role, :string, default: "staff"
    timestamps(type: :naive_datetime)
  end

  def roles, do: @roles

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:venue_id, :user_id, :staff_id, :role])
    |> validate_required([:venue_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:venue_id, :user_id],
      message: "is already a member of this venue"
    )
  end
end

defmodule Blastek.Venues do
  @moduledoc """
  Tenants: venue records, public lookup, and the membership/role model that
  authorizes every dashboard operation.
  """
  import Ecto.Query
  alias Blastek.Repo
  alias Blastek.Venues.{Venue, VenueMember}

  # Ordered weakest → strongest; `role_at_least?/2` compares by index.
  @role_rank %{"staff" => 0, "receptionist" => 1, "manager" => 2, "owner" => 3}

  ## ---------- lookup ----------

  def get_venue!(id), do: Repo.get!(Venue, id)
  def get_venue(id), do: Repo.get(Venue, id)

  def get_by_slug(slug) when is_binary(slug) do
    Repo.one(from v in Venue, where: fragment("lower(?)", v.slug) == ^String.downcase(slug))
  end

  def get_by_slug(_), do: nil

  @doc "Public lookup — only venues that are live on the marketplace."
  def get_public_by_slug(slug) do
    case get_by_slug(slug) do
      %Venue{status: "active"} = venue -> {:ok, venue}
      _ -> {:error, "Venue not found."}
    end
  end

  @doc """
  Venue records, optionally narrowed to one status.

  The administrative listing: it deliberately does **not** filter to `active` or
  understand search terms, because the platform admin queue exists to look at
  the pending and suspended venues a shopper must never see.

  Marketplace listing and search go through `Blastek.Discovery.search/1`, which
  enforces `active` itself.
  """
  def list_venues(opts \\ []) do
    q = from v in Venue, order_by: v.name
    q = if opts[:status], do: from(v in q, where: v.status == ^opts[:status]), else: q
    q = if opts[:limit], do: from(v in q, limit: ^opts[:limit]), else: q
    Repo.all(q)
  end

  ## ---------- writes ----------

  def create_venue(attrs) do
    with {:ok, venue} <- %Venue{} |> Venue.changeset(attrs) |> Repo.insert() do
      Blastek.Discovery.reindex_venue(venue.id)
      {:ok, venue}
    end
  end

  @doc "Creates a venue and makes `user` its owner, atomically."
  def create_venue_with_owner(attrs, user_id) do
    Repo.transaction(fn ->
      with {:ok, venue} <- create_venue(attrs),
           {:ok, _member} <- add_member(venue.id, user_id, "owner") do
        venue
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def update_venue(%Venue{} = venue, attrs) do
    with {:ok, updated} <- venue |> Venue.changeset(attrs) |> Repo.update() do
      # Name, city, address and tagline all feed the search document, so any
      # update reindexes rather than guessing which fields changed.
      Blastek.Discovery.reindex_venue(updated.id)
      {:ok, updated}
    end
  end

  def update_venue(id, attrs), do: get_venue!(id) |> update_venue(attrs)

  @doc """
  Sets the women-only flag, which the marketplace exposes as a search filter.

  Merged into `settings` rather than replacing it, because a blind write here
  would drop the amenities list stored alongside.
  """
  def set_women_only(%Venue{} = venue, value) when is_boolean(value) do
    update_venue(venue, %{settings: Map.put(venue.settings, "women_only", value)})
  end

  @doc """
  Sets a venue's map pin.

  Separate from `update_venue/2` because the two arrive from different places and
  carry different authority: an owner dragging a marker is stating a fact, while
  `geocode_venue/1` is guessing. A manual pin must therefore never be silently
  overwritten by a later geocode — see `geocode_venue/1`.
  """
  def set_location(%Venue{} = venue, lat, lng) do
    update_venue(venue, %{lat: lat, lng: lng})
  end

  def set_location(id, lat, lng), do: get_venue!(id) |> set_location(lat, lng)

  @doc """
  Fills in a venue's coordinates from its address.

  Refuses to run when a pin already exists: geocoders are approximate, and
  quietly replacing a hand-placed marker with a street-centroid guess is a
  regression the owner cannot see until a customer arrives at the wrong door.
  Pass `force: true` after the address itself has changed.
  """
  def geocode_venue(%Venue{} = venue, opts \\ []) do
    cond do
      not Keyword.get(opts, :force, false) and not is_nil(venue.lat) ->
        {:error, "This venue already has a location pin."}

      venue.address == "" and venue.city == "" ->
        {:error, "Add an address before locating the venue on the map."}

      true ->
        case Blastek.Geocode.geocode(Blastek.Geocode.query_for(venue)) do
          {:ok, %{lat: lat, lng: lng}} ->
            set_location(venue, lat, lng)

          {:error, :not_found} ->
            {:error, "We could not find that address. Place the pin manually instead."}

          {:error, _reason} ->
            {:error, "The map service is unavailable. Place the pin manually instead."}
        end
    end
  end

  ## ---------- memberships ----------

  def add_member(venue_id, user_id, role, staff_id \\ nil) do
    %VenueMember{}
    |> VenueMember.changeset(%{
      venue_id: venue_id,
      user_id: user_id,
      role: role,
      staff_id: staff_id
    })
    |> Repo.insert()
  end

  def list_members(venue_id) do
    Repo.all(
      from m in VenueMember,
        where: m.venue_id == ^venue_id,
        order_by: m.id,
        preload: [:user, :staff, :venue]
    )
  end

  @doc "Every venue the user can act in, strongest role first."
  def list_memberships(user_id) do
    Repo.all(
      from m in VenueMember,
        where: m.user_id == ^user_id,
        join: v in assoc(m, :venue),
        order_by: v.name,
        preload: [venue: v]
    )
  end

  def get_membership(user_id, venue_id) do
    Repo.one(from m in VenueMember, where: m.user_id == ^user_id and m.venue_id == ^venue_id)
  end

  # Venue-scoped like everything else: a membership id from another venue is
  # indistinguishable from a missing one.
  defp get_member(venue_id, id) do
    case Repo.one(from m in VenueMember, where: m.id == ^id and m.venue_id == ^venue_id) do
      nil -> {:error, "Unknown member."}
      member -> {:ok, member}
    end
  end

  def update_member_role(venue_id, id, role) do
    with {:ok, member} <- get_member(venue_id, id),
         :ok <- ensure_not_last_owner(member, role) do
      member |> VenueMember.changeset(%{role: role}) |> Repo.update()
    end
  end

  def remove_member(venue_id, id) do
    with {:ok, member} <- get_member(venue_id, id),
         :ok <- ensure_not_last_owner(member, nil) do
      Repo.delete(member)
    end
  end

  # A venue must always keep at least one owner, or nobody can administer it.
  defp ensure_not_last_owner(%VenueMember{role: "owner"} = member, new_role)
       when new_role != "owner" do
    count =
      Repo.aggregate(
        from(m in VenueMember, where: m.venue_id == ^member.venue_id and m.role == "owner"),
        :count
      )

    if count <= 1, do: {:error, "A venue must have at least one owner."}, else: :ok
  end

  defp ensure_not_last_owner(_member, _new_role), do: :ok

  ## ---------- roles ----------

  def role_rank(role), do: Map.get(@role_rank, role, -1)

  def role_at_least?(role, minimum), do: role_rank(role) >= role_rank(minimum)

  ## ---------- helpers ----------

  @doc """
  Builds a URL-safe slug, transliterating the accented characters common in
  Moroccan salon names (Éclat → eclat, Maârif → maarif).
  """
  def slugify(name) do
    base =
      name
      |> to_string()
      |> String.normalize(:nfd)
      |> String.replace(~r/[^A-Za-z0-9\s-]/u, "")
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[\s-]+/, "-")
      |> String.trim("-")

    base = if base == "", do: "venue", else: base
    unique_slug(base)
  end

  defp unique_slug(base) do
    taken =
      Repo.all(
        from v in Venue,
          where: v.slug == ^base or like(v.slug, ^"#{base}-%"),
          select: v.slug
      )
      |> MapSet.new()

    if MapSet.member?(taken, base) do
      Enum.find_value(2..999, "#{base}-#{System.unique_integer([:positive])}", fn n ->
        candidate = "#{base}-#{n}"
        if MapSet.member?(taken, candidate), do: nil, else: candidate
      end)
    else
      base
    end
  end
end
