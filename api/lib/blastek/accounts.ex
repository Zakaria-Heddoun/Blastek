defmodule Blastek.Accounts.User do
  @moduledoc """
  A login. `role` is global and only distinguishes platform staff from
  everyone else — dashboard access comes from venue memberships, not from here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :role, :string, default: "customer"
    field :first_name, :string, default: ""
    field :last_name, :string, default: ""
    field :phone, :string, default: ""
    has_many :memberships, Blastek.Venues.VenueMember
    timestamps(type: :naive_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :role, :first_name, :last_name, :phone])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:email, :first_name])
    |> validate_format(:email, ~r/@/, message: "must be a valid email")
    |> validate_inclusion(:role, ~w(customer admin))
    |> unique_constraint(:email, name: :users_email_index, message: "is already registered")
  end
end

defmodule Blastek.Accounts do
  @moduledoc "User accounts: sign-up, login, and stateless token auth."
  import Ecto.Query
  alias Blastek.Repo
  alias Blastek.Accounts.User
  alias Blastek.Salon
  alias Blastek.Venues

  @token_salt "blastek user auth"
  @token_max_age 60 * 60 * 24 * 30

  def get_user(id), do: Repo.get(User, id)

  def get_by_email(email) do
    email = email |> to_string() |> String.trim() |> String.downcase()
    Repo.one(from u in User, where: fragment("lower(?)", u.email) == ^email, limit: 1)
  end

  def sign_up(attrs) do
    password = to_string(attrs[:password] || "")

    if String.length(password) < 8 do
      {:error, "Password must be at least 8 characters."}
    else
      # `role` is not accepted from sign-up input: a caller cannot make itself
      # an admin, and venue access is granted through memberships.
      attrs = Map.drop(attrs, [:role])

      %User{}
      |> User.changeset(attrs)
      |> Ecto.Changeset.put_change(:password_hash, Pbkdf2.hash_pwd_salt(password))
      |> Repo.insert()
    end
  end

  @doc """
  Signs a user up and gives them a venue they own — the "create a business
  account" path. The venue is created in one transaction with its owner
  membership so a half-registered business can never exist.
  """
  def sign_up_with_venue(attrs, business_name) do
    Repo.transaction(fn ->
      with {:ok, user} <- sign_up(attrs),
           {:ok, venue} <-
             Venues.create_venue_with_owner(
               %{name: business_name, status: "active", city: attrs[:city] || ""},
               user.id
             ) do
        %{user: user, venue: venue}
      else
        {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def authenticate(email, password) do
    user = get_by_email(email)

    cond do
      user && Pbkdf2.verify_pass(to_string(password), user.password_hash) ->
        {:ok, user}

      true ->
        # constant-time-ish failure regardless of whether the email exists
        Pbkdf2.no_user_verify()
        {:error, "Invalid email or password."}
    end
  end

  def admin?(%User{role: "admin"}), do: true
  def admin?(_), do: false

  ## ---------- client records ----------

  @doc """
  Returns this user's client record at a venue, creating it on first contact.

  A customer has one client record per venue: their notes, allergies and
  history belong to the salon they visit, not to the platform.
  """
  def ensure_client(%User{} = user, venue_id) do
    case Salon.find_or_create_client(venue_id, %{
           first_name: user.first_name,
           last_name: user.last_name,
           email: user.email,
           phone: user.phone,
           user_id: user.id
         }) do
      {:ok, client} -> {:ok, client.id}
      {:error, _} -> {:error, "could not resolve client record"}
    end
  end

  @doc "Ids of every client record this account owns, across venues."
  def client_ids(%User{} = user), do: Salon.list_client_ids_for_user(user.id)

  ## ---------- tokens ----------

  def token_for(%User{id: id}),
    do: Phoenix.Token.sign(BlastekWeb.Endpoint, @token_salt, id)

  def verify_token(token),
    do: Phoenix.Token.verify(BlastekWeb.Endpoint, @token_salt, token, max_age: @token_max_age)
end
