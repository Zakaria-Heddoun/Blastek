defmodule Blastek.InvitationRaceTest do
  @moduledoc """
  Two people redeeming one invitation link at the same instant (E4-T1 / F0.3).

  Its own file because it cannot run inside the sandbox. Tasks sharing a test's
  sandbox connection serialize, so a "concurrent" test written that way passes
  against buggy code — which is exactly what the first version of this test did.
  Real contention needs real connections, so this runs **unboxed**: writes are
  committed for other connections to see, and `on_exit` cleans up after itself.

  The property under test is that `accept/2` claims the invitation with a
  conditional `UPDATE … WHERE accepted_at IS NULL` and checks the row count.
  Reading first and consuming afterwards lets both callers past the read and
  hands out two memberships from one link.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Blastek.Accounts.User
  alias Blastek.Repo
  alias Blastek.Venues
  alias Blastek.Venues.Invitation
  alias Blastek.Venues.Invitations

  # Everything this test writes is prefixed, so it can be found and removed by
  # name. Committed rows are not rolled back for us.
  @venue_prefix "Race Salon "
  @email_prefix "race-"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    # Swept before as well as after. An `on_exit` that does not complete — a
    # crashed run, an interrupted suite — would otherwise leave committed rows
    # behind, and the next run of *other* tests would see a stray venue in the
    # search results. Cleaning on the way in makes that self-healing rather than
    # something a human has to notice.
    purge()

    on_exit(fn ->
      purge()
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  defp purge do
    Repo.delete_all(from v in Blastek.Venues.Venue, where: like(v.name, ^"#{@venue_prefix}%"))
    Repo.delete_all(from u in User, where: like(u.email, ^"#{@email_prefix}%"))
  end

  defp unique, do: System.unique_integer([:positive])

  # Committed rather than rolled back, so the racing connections can see them.
  defp seed do
    tag = unique()

    {:ok, venue} =
      Venues.create_venue(%{name: "Race Salon #{tag}", status: "active", city: "Casablanca"})

    {:ok, owner} =
      Blastek.Accounts.sign_up(%{
        email: "race-owner-#{tag}@example.com",
        password: "blastek123",
        first_name: "Owner"
      })

    {:ok, _} = Venues.add_member(venue.id, owner.id, "owner")

    contenders =
      for n <- 1..2 do
        {:ok, user} =
          Blastek.Accounts.sign_up(%{
            email: "race-#{n}-#{tag}@example.com",
            password: "blastek123",
            first_name: "Contender"
          })

        user
      end

    phone =
      "06" <> (tag |> rem(100_000_000) |> Integer.to_string() |> String.pad_leading(8, "0"))

    {:ok, created} = Invitations.invite(venue, %{role: "receptionist", phone: phone}, owner)

    %{venue: venue, contenders: contenders, token: created.token, invitation: created.invitation}
  end

  test "two simultaneous accepts of one link produce exactly one membership" do
    %{venue: venue, contenders: contenders, token: token, invitation: invitation} = seed()

    results =
      contenders
      |> Enum.map(fn user -> Task.async(fn -> Invitations.accept(token, user) end) end)
      |> Enum.map(&Task.await(&1, 15_000))

    accepted = Enum.count(results, &match?({:ok, _}, &1))
    refused = Enum.count(results, &match?({:error, _}, &1))

    assert accepted == 1, "expected exactly one winner, got #{accepted}: #{inspect(results)}"
    assert refused == 1

    # The decisive assertion: one link, one membership. Without the conditional
    # claim both callers pass the read and both are let in.
    memberships =
      Repo.aggregate(
        from(m in Blastek.Venues.VenueMember, where: m.venue_id == ^venue.id),
        :count
      )

    # The owner, plus exactly one contender.
    assert memberships == 2

    # And the loser is told the link is spent, not handed a second membership.
    assert Enum.any?(results, fn
             {:error, message} when is_binary(message) -> message =~ "no longer valid"
             _ -> false
           end)

    reloaded = Repo.get!(Invitation, invitation.id)
    assert reloaded.accepted_at
    assert reloaded.accepted_by_id in Enum.map(contenders, & &1.id)
  end
end
