defmodule Blastek.Fixtures do
  @moduledoc "Builders for multi-tenant test data: two venues that must never see each other."

  alias Blastek.Accounts
  alias Blastek.Repo
  alias Blastek.Salon
  alias Blastek.Venues

  @doc """
  Creates a venue with one category, one service, one staff member (working
  every day 09:00–18:00 and able to perform the service) and one client.
  """
  def venue_fixture(name) do
    slug = Venues.slugify(name)

    {:ok, venue} =
      Venues.create_venue(%{name: name, slug: slug, status: "active", city: "Casablanca"})

    {:ok, category} = Salon.create_category(venue.id, %{name: "Hair", sort: 1})

    {:ok, service} =
      Salon.create_service(
        venue.id,
        %{category_id: category.id, name: "#{name} cut", duration_min: 60, price_cents: 20_000},
        nil
      )

    {:ok, staff} =
      Salon.create_staff(
        venue.id,
        %{name: "#{name} stylist", color: "#000000"},
        for(wd <- 0..6, do: %{weekday: wd, working: true, start_min: 540, end_min: 1080}),
        [service.id]
      )

    {:ok, client} =
      Salon.create_client(venue.id, %{
        first_name: "Client",
        last_name: name,
        email: "client-#{slug}@example.com"
      })

    %{venue: venue, category: category, service: service, staff: staff, client: client}
  end

  @doc "A user account with no venue access."
  def user_fixture(email, attrs \\ %{}) do
    {:ok, user} =
      Accounts.sign_up(
        Map.merge(%{email: email, password: "blastek123", first_name: "Test"}, attrs)
      )

    user
  end

  @doc "A user account that is a member of `venue` with `role`."
  def member_fixture(venue, role, email) do
    user = user_fixture(email)
    {:ok, member} = Venues.add_member(venue.id, user.id, role)
    %{user: user, member: member}
  end

  def admin_fixture(email) do
    user_fixture(email)
    |> Ecto.Changeset.change(role: "admin")
    |> Repo.update!()
  end

  @doc "An appointment tomorrow at 10:00 for the given venue fixture."
  def appointment_fixture(v, attrs \\ %{}) do
    {:ok, appt} =
      Salon.create_appointment(v.venue.id, %{
        client_id: v.client.id,
        staff_id: v.staff.id,
        service_id: v.service.id,
        date: Map.get(attrs, :date, Date.add(Date.utc_today(), 1)),
        start_min: Map.get(attrs, :start_min, 600)
      })

    appt
  end

  @doc "The next date on which the venue's staff works, at least `days` ahead."
  def future_date(days \\ 1), do: Date.add(Date.utc_today(), days)
end
