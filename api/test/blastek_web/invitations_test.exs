defmodule BlastekWeb.InvitationsTest do
  @moduledoc """
  Inviting people into a venue, and the audit trail behind it (E4-T1, E4-T6 /
  F0.3).

  Driven through GraphQL, because an invitation is a two-party flow — the owner
  who sends and the stranger who redeems — and the boundary between them is the
  API.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Audit
  alias Blastek.Notifications.Collector
  alias Blastek.Venues
  alias Blastek.Venues.Invitation
  alias Blastek.Venues.Invitations
  alias BlastekWeb.Schema

  setup do
    v = venue_fixture("Invite Salon #{unique()}")
    %{user: owner} = member_fixture(v.venue, "owner", "inv-owner-#{unique()}@example.com")

    %{venue: v.venue, owner: owner, staff: v.staff}
  end

  defp unique, do: System.unique_integer([:positive])

  # Three shapes, because an invitation flow genuinely has three callers: an
  # owner acting in their venue, an invitee who is signed in but belongs to
  # nothing yet, and a stranger holding only a link.
  defp run(query, user, venue) do
    Absinthe.run(query, Schema, context: context_for(user, venue))
  end

  defp context_for(nil, _venue), do: %{client_ip: "10.0.0.1"}

  defp context_for(user, nil) do
    %{
      current_user: user,
      memberships: Venues.list_memberships(user.id),
      client_ip: "10.0.0.1"
    }
  end

  defp context_for(user, venue) do
    user
    |> context_for(nil)
    |> Map.merge(%{
      current_venue: venue,
      venue_id: venue.id,
      membership: Venues.get_membership(user.id, venue.id)
    })
  end

  defp error_message({:ok, %{errors: [%{message: message} | _]}}), do: message

  defp invite!(ctx, args \\ ~s|role: "receptionist", phone: "0611223344"|) do
    {:ok, %{data: %{"inviteMember" => created}}} =
      run(
        ~s|mutation { inviteMember(#{args}) {
          url delivered invitation { id role phone email expiresAt } } }|,
        ctx.owner,
        ctx.venue
      )

    created
  end

  defp token_from(url) do
    %URI{query: query} = URI.parse(url)
    URI.decode_query(query) |> Map.fetch!("token")
  end

  describe "inviteMember" do
    test "creates a pending invitation and texts the link", ctx do
      created = invite!(ctx)

      assert created["invitation"]["role"] == "receptionist"
      # Normalized on the way in, so the invitation is addressed to the same
      # string the account will eventually carry.
      assert created["invitation"]["phone"] == "+212611223344"
      assert created["url"] =~ "token="

      message = Collector.last()
      assert message.to == "+212611223344"
      assert message.body =~ ctx.venue.name
      assert message.body =~ created["url"]
    end

    test "stores only the hash of the token", ctx do
      created = invite!(ctx)
      token = token_from(created["url"])

      stored = Repo.get!(Invitation, created["invitation"]["id"])
      refute stored.token_hash == token
      assert stored.token_hash == :crypto.hash(:sha256, token)
    end

    test "expires in seven days", ctx do
      created = invite!(ctx)
      {:ok, expires_at} = NaiveDateTime.from_iso8601(created["invitation"]["expiresAt"])

      assert_in_delta NaiveDateTime.diff(expires_at, NaiveDateTime.utc_now()),
                      Invitations.ttl_days() * 86_400,
                      10
    end

    test "accepts an email instead of a phone", ctx do
      created = invite!(ctx, ~s|role: "manager", email: "NEW.Manager@Example.com"|)

      # Lower-cased, since that is how the account will be found later.
      assert created["invitation"]["email"] == "new.manager@example.com"
      assert Collector.last().to == "new.manager@example.com"
    end

    test "refuses an invitation nobody can be sent", ctx do
      assert error_message(
               run(~s|mutation { inviteMember(role: "staff") { url } }|, ctx.owner, ctx.venue)
             ) =~ "phone number or an email"
    end

    test "refuses an unusable phone number before creating anything", ctx do
      assert error_message(
               run(
                 ~s|mutation { inviteMember(role: "staff", phone: "0522123456") { url } }|,
                 ctx.owner,
                 ctx.venue
               )
             ) =~ "mobile number"

      assert Repo.aggregate(Invitation, :count) == 0
    end

    test "refuses an unknown role", ctx do
      assert error_message(
               run(
                 ~s|mutation { inviteMember(role: "wizard", phone: "0611223344") { url } }|,
                 ctx.owner,
                 ctx.venue
               )
             ) =~ "Pick a role"
    end

    test "refuses someone already on the team", ctx do
      %{user: existing} =
        member_fixture(ctx.venue, "staff", "already-#{unique()}@example.com")

      assert error_message(
               run(
                 ~s|mutation { inviteMember(role: "manager", email: "#{existing.email}") { url } }|,
                 ctx.owner,
                 ctx.venue
               )
             ) =~ "already on your team"
    end

    test "can attach a calendar column", ctx do
      created = invite!(ctx, ~s|role: "staff", phone: "0611223355", staffId: "#{ctx.staff.id}"|)
      assert Repo.get!(Invitation, created["invitation"]["id"]).staff_id == ctx.staff.id
    end

    test "refuses a calendar column belonging to another venue", ctx do
      # An id from the client is never taken at face value — an unchecked one
      # writes a membership in this venue pointing at another venue's staff row.
      other = venue_fixture("Foreign Salon #{unique()}")

      assert error_message(
               run(
                 ~s|mutation { inviteMember(role: "staff", phone: "0611223377",
                   staffId: "#{other.staff.id}") { url } }|,
                 ctx.owner,
                 ctx.venue
               )
             ) =~ "another venue"

      assert Repo.aggregate(Invitation, :count) == 0
    end

    test "add_member refuses a foreign calendar column directly", ctx do
      # Guarded at the funnel, not only at the one call site that happens to
      # pass a client-supplied id today.
      other = venue_fixture("Foreign Salon B #{unique()}")
      stranger = user_fixture("stranger-add-#{unique()}@example.com")

      assert {:error, message} =
               Venues.add_member(ctx.venue.id, stranger.id, "staff", other.staff.id)

      assert message =~ "another venue"
    end

    test "reports whether the message actually went out", ctx do
      created = invite!(ctx)
      assert created["delivered"] == true

      original = Application.get_env(:blastek, :notifications_provider)

      Application.put_env(
        :blastek,
        :notifications_provider,
        Blastek.Notifications.FailingProvider
      )

      on_exit(fn -> Application.put_env(:blastek, :notifications_provider, original) end)

      failed = invite!(ctx, ~s|role: "staff", phone: "0611229988"|)

      # The invitation still works — the owner has the link — but the UI must
      # not claim it was sent.
      assert failed["delivered"] == false
      assert failed["url"] =~ "token="
    end
  end

  describe "invitation preview" do
    test "says what is on offer without signing anyone in", ctx do
      created = invite!(ctx)
      token = token_from(created["url"])

      # No context at all — the invitee has not signed in yet.
      assert {:ok, %{data: %{"invitation" => preview}}} =
               run(~s|{ invitation(token: "#{token}") { role venueName venueSlug } }|, nil, nil)

      assert preview["role"] == "receptionist"
      assert preview["venueName"] == ctx.venue.name
      assert preview["venueSlug"] == ctx.venue.slug
    end

    test "refuses a token that is not live", _ctx do
      assert error_message(run(~s|{ invitation(token: "nope") { role } }|, nil, nil)) =~
               "no longer valid"
    end
  end

  describe "acceptInvitation" do
    setup ctx do
      invitee = user_fixture("invitee-#{unique()}@example.com")
      %{invitee: invitee}
    end

    test "creates the membership and consumes the invitation", ctx do
      created = invite!(ctx)
      token = token_from(created["url"])

      assert {:ok, %{data: %{"acceptInvitation" => membership}}} =
               run(
                 ~s|mutation { acceptInvitation(token: "#{token}") {
                   role venue { slug } user { email } } }|,
                 ctx.invitee,
                 nil
               )

      assert membership["role"] == "receptionist"
      assert membership["venue"]["slug"] == ctx.venue.slug
      assert membership["user"]["email"] == ctx.invitee.email

      # Really a member now, and the invitation is spent.
      assert Venues.get_membership(ctx.invitee.id, ctx.venue.id).role == "receptionist"
      assert Repo.get!(Invitation, created["invitation"]["id"]).accepted_at
    end

    test "a link works only once", ctx do
      created = invite!(ctx)
      token = token_from(created["url"])

      run(~s|mutation { acceptInvitation(token: "#{token}") { role } }|, ctx.invitee, nil)

      other = user_fixture("second-#{unique()}@example.com")

      # Otherwise the first invitee could forward the link and hand out access.
      assert error_message(
               run(~s|mutation { acceptInvitation(token: "#{token}") { role } }|, other, nil)
             ) =~ "no longer valid"

      assert Venues.get_membership(other.id, ctx.venue.id) == nil
    end

    # True concurrency lives in `Blastek.InvitationRaceTest`: two tasks sharing
    # this test's sandbox connection would serialize, and the assertion would
    # hold against the buggy version too.

    test "a revoked invitation cannot be accepted", ctx do
      created = invite!(ctx)
      token = token_from(created["url"])

      run(
        ~s|mutation { revokeInvitation(id: "#{created["invitation"]["id"]}") { id } }|,
        ctx.owner,
        ctx.venue
      )

      assert error_message(
               run(
                 ~s|mutation { acceptInvitation(token: "#{token}") { role } }|,
                 ctx.invitee,
                 nil
               )
             ) =~ "no longer valid"
    end

    test "an expired invitation cannot be accepted", ctx do
      created = invite!(ctx)
      token = token_from(created["url"])

      Repo.update_all(
        from(i in Invitation, where: i.id == ^created["invitation"]["id"]),
        set: [expires_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)]
      )

      assert error_message(
               run(
                 ~s|mutation { acceptInvitation(token: "#{token}") { role } }|,
                 ctx.invitee,
                 nil
               )
             ) =~ "no longer valid"
    end

    test "requires a session, because a membership belongs to somebody", ctx do
      created = invite!(ctx)
      token = token_from(created["url"])

      assert error_message(
               run(~s|mutation { acceptInvitation(token: "#{token}") { role } }|, nil, nil)
             ) =~ "signed in"
    end

    test "upgrades an existing membership but never downgrades one", ctx do
      %{user: manager} = member_fixture(ctx.venue, "manager", "mgr-#{unique()}@example.com")

      # Invited to something *lower* than they already hold.
      lower = invite!(ctx, ~s|role: "staff", email: "#{manager.email}-x"|)

      # (The team check above only matches on the real address, so invite by a
      # token they can still redeem.)
      run(
        ~s|mutation { acceptInvitation(token: "#{token_from(lower["url"])}") { role } }|,
        manager,
        nil
      )

      # Accepting an offer must not cost someone access they already had.
      assert Venues.get_membership(manager.id, ctx.venue.id).role == "manager"
    end

    test "an invitation with a calendar column links the member to it", ctx do
      created = invite!(ctx, ~s|role: "staff", phone: "0611223366", staffId: "#{ctx.staff.id}"|)

      run(
        ~s|mutation { acceptInvitation(token: "#{token_from(created["url"])}") { role } }|,
        ctx.invitee,
        nil
      )

      assert Venues.get_membership(ctx.invitee.id, ctx.venue.id).staff_id == ctx.staff.id
    end
  end

  describe "pendingInvitations" do
    test "lists outstanding ones and drops them once spent", ctx do
      created = invite!(ctx)

      assert {:ok, %{data: %{"pendingInvitations" => [_one]}}} =
               run("{ pendingInvitations { id role } }", ctx.owner, ctx.venue)

      invitee = user_fixture("pending-#{unique()}@example.com")

      run(
        ~s|mutation { acceptInvitation(token: "#{token_from(created["url"])}") { role } }|,
        invitee,
        nil
      )

      assert {:ok, %{data: %{"pendingInvitations" => []}}} =
               run("{ pendingInvitations { id } }", ctx.owner, ctx.venue)
    end

    test "one venue cannot revoke another's invitation", ctx do
      created = invite!(ctx)

      other = venue_fixture("Other Invite Salon #{unique()}")
      %{user: other_owner} = member_fixture(other.venue, "owner", "oo-#{unique()}@example.com")

      assert error_message(
               run(
                 ~s|mutation { revokeInvitation(id: "#{created["invitation"]["id"]}") { id } }|,
                 other_owner,
                 other.venue
               )
             ) =~ "Unknown invitation"
    end
  end

  describe "audit trail" do
    test "records who invited, who accepted, and who changed a role", ctx do
      created = invite!(ctx)
      invitee = user_fixture("audited-#{unique()}@example.com")

      run(
        ~s|mutation { acceptInvitation(token: "#{token_from(created["url"])}") { role } }|,
        invitee,
        nil
      )

      membership = Venues.get_membership(invitee.id, ctx.venue.id)

      run(
        ~s|mutation { updateMemberRole(id: "#{membership.id}", role: "manager") { role } }|,
        ctx.owner,
        ctx.venue
      )

      actions = Audit.list_for_venue(ctx.venue.id) |> Enum.map(& &1.action)
      assert "invitation.created" in actions
      assert "invitation.accepted" in actions
      assert "member.role_changed" in actions

      change =
        Audit.list_for_venue(ctx.venue.id) |> Enum.find(&(&1.action == "member.role_changed"))

      # Both halves: "the role changed" is nearly useless without "from what".
      assert change.metadata["from"] == "receptionist"
      assert change.metadata["to"] == "manager"
      assert change.actor_user_id == ctx.owner.id
    end

    test "records a removal, and the staff row survives it", ctx do
      %{user: leaver} = member_fixture(ctx.venue, "staff", "leaver-#{unique()}@example.com")
      membership = Venues.get_membership(leaver.id, ctx.venue.id)

      run(
        ~s|mutation { removeMember(id: "#{membership.id}") { id } }|,
        ctx.owner,
        ctx.venue
      )

      assert Venues.get_membership(leaver.id, ctx.venue.id) == nil
      # F0.3 is explicit: access goes, history stays.
      assert Repo.get(Blastek.Salon.Staff, ctx.staff.id)

      entry =
        Audit.list_for_venue(ctx.venue.id) |> Enum.find(&(&1.action == "member.removed"))

      assert entry.metadata["role"] == "staff"
      assert entry.actor_user_id == ctx.owner.id
    end

    test "is owner-only", ctx do
      %{user: manager} = member_fixture(ctx.venue, "manager", "nosy-#{unique()}@example.com")

      assert error_message(run("{ auditLog { id } }", manager, ctx.venue)) =~
               "Your role does not allow"
    end

    test "a failed audit write never breaks the operation being audited" do
      # The log is a record of what happened, not a participant in it.
      assert Audit.record("nonsense.action", %{venue_id: nil, metadata: %{a: :b}}) == :ok
    end
  end

  describe "last-owner protection" do
    test "the only owner cannot be demoted or removed", ctx do
      membership = Venues.get_membership(ctx.owner.id, ctx.venue.id)

      assert error_message(
               run(
                 ~s|mutation { updateMemberRole(id: "#{membership.id}", role: "manager") { role } }|,
                 ctx.owner,
                 ctx.venue
               )
             ) =~ "at least one owner"

      assert error_message(
               run(
                 ~s|mutation { removeMember(id: "#{membership.id}") { id } }|,
                 ctx.owner,
                 ctx.venue
               )
             ) =~ "at least one owner"
    end

    test "a second owner makes the first removable", ctx do
      %{user: second} = member_fixture(ctx.venue, "owner", "second-#{unique()}@example.com")
      membership = Venues.get_membership(ctx.owner.id, ctx.venue.id)

      assert {:ok, %{data: %{"removeMember" => _}}} =
               run(
                 ~s|mutation { removeMember(id: "#{membership.id}") { id } }|,
                 second,
                 ctx.venue
               )
    end
  end
end
