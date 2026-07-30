defmodule Blastek.Venues.Invitation do
  @moduledoc "A pending membership: a role held open for a phone or an email."
  use Ecto.Schema
  import Ecto.Changeset

  schema "venue_invitations" do
    field :venue_id, :id
    field :role, :string
    field :phone, :string, default: ""
    field :email, :string, default: ""
    field :token_hash, :binary
    field :invited_by_id, :id
    field :staff_id, :id
    field :expires_at, :naive_datetime
    field :accepted_at, :naive_datetime
    field :accepted_by_id, :id
    field :revoked_at, :naive_datetime
    timestamps(type: :naive_datetime)
  end

  @fields [
    :venue_id,
    :role,
    :phone,
    :email,
    :token_hash,
    :invited_by_id,
    :staff_id,
    :expires_at
  ]

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, @fields)
    |> validate_required([:venue_id, :role, :token_hash, :expires_at])
    |> validate_inclusion(:role, Blastek.Venues.VenueMember.roles())
    |> validate_contact()
  end

  # An invitation nobody can be sent is not an invitation. The token is what
  # grants access, but without a contact there is no way to deliver it.
  defp validate_contact(changeset) do
    phone = get_field(changeset, :phone) || ""
    email = get_field(changeset, :email) || ""

    if String.trim(phone) == "" and String.trim(email) == "" do
      add_error(changeset, :phone, "or an email address is required")
    else
      changeset
    end
  end
end

defmodule Blastek.Venues.Invitations do
  @moduledoc """
  Inviting people into a venue (E4-T1 / F0.3).

  An invitation reserves a role for a contact and hands out a one-time link. It
  is a bearer credential, so it follows the same rules as a session token: 32
  random bytes, only the SHA-256 stored, and a bounded lifetime (7 days).

  ## Why the token grants, not the contact

  Accepting checks the **token**, not whether the signed-in account matches the
  phone the invitation was addressed to. Requiring a match sounds safer and is
  not: the invitee frequently signs up with a different number than the one the
  owner had for them, and an invitation that cannot be accepted by the person
  holding the link is just a support ticket. The link is the secret; sending it
  to the wrong contact is the same mistake as emailing a password reset to the
  wrong address, and is bounded by the same short expiry.

  ## Accepting is idempotent-ish, not idempotent

  A second acceptance of the same token fails. It has to: the alternative is a
  link that keeps working, and a role that can be claimed by anyone the first
  invitee forwards it to.
  """
  import Ecto.Query

  alias Blastek.Accounts.Phone
  alias Blastek.Accounts.User
  alias Blastek.Audit
  alias Blastek.Notifications
  alias Blastek.Repo
  alias Blastek.Venues
  alias Blastek.Venues.Invitation
  alias Blastek.Venues.VenueMember

  @ttl_days 7
  @token_bytes 32

  def ttl_days, do: @ttl_days

  @doc """
  Creates an invitation and sends the link.

  Returns the invitation and the raw token — the only moment it exists. The
  caller may show the link directly, which matters when delivery fails or the
  owner would rather hand it over in person.
  """
  def invite(venue, attrs, invited_by) do
    with {:ok, role} <- validate_role(attrs[:role]),
         {:ok, contact} <- normalize_contact(attrs),
         :ok <- ensure_staff_column(venue.id, attrs[:staff_id]),
         :ok <- ensure_not_already_member(venue.id, contact) do
      token = random_token()

      %Invitation{}
      |> Invitation.changeset(%{
        venue_id: venue.id,
        role: role,
        phone: contact.phone,
        email: contact.email,
        token_hash: hash(token),
        invited_by_id: invited_by && invited_by.id,
        staff_id: attrs[:staff_id],
        expires_at: days_from_now(@ttl_days)
      })
      |> Repo.insert()
      |> case do
        {:ok, invitation} ->
          delivered? = deliver(invitation, venue, token, attrs[:locale]) == :ok

          Audit.record("invitation.created", %{
            venue_id: venue.id,
            actor: invited_by,
            subject_type: "invitation",
            subject_id: invitation.id,
            metadata: %{role: role, phone: contact.phone, email: contact.email}
          })

          # `delivered?` is reported rather than swallowed: the invitation is
          # perfectly usable either way — the owner has the link — but telling
          # them "sent" when nothing was sent leaves them waiting for a message
          # that is not coming.
          {:ok,
           %{
             invitation: invitation,
             token: token,
             url: accept_url(token),
             delivered: delivered?
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  The link an invitee follows.

  One function so the URL the API returns and the URL in the message can never
  disagree — a mismatch there is a link that silently does nothing.
  """
  def accept_url(token), do: "#{accept_base_url()}?token=#{token}"

  @doc "Outstanding invitations for a venue — neither accepted nor revoked nor expired."
  def list_pending(venue_id) do
    now = now()

    Repo.all(
      from i in Invitation,
        where:
          i.venue_id == ^venue_id and is_nil(i.accepted_at) and is_nil(i.revoked_at) and
            i.expires_at > ^now,
        order_by: [desc: i.inserted_at]
    )
  end

  @doc """
  Describes an invitation without accepting it.

  The accept page needs to say which venue and which role *before* asking
  someone to sign in — a bare "accept?" with no context is how people click
  through things they should not.
  """
  def preview(token) do
    case live_invitation(token) do
      nil -> {:error, "That invitation link is no longer valid."}
      invitation -> {:ok, %{invitation: invitation, venue: Venues.get_venue(invitation.venue_id)}}
    end
  end

  @doc """
  Redeems an invitation for the given user, creating the membership.

  Already a member of that venue? The invitation is consumed and the existing
  membership is **upgraded if the invited role is higher**, never downgraded —
  an invitation is an offer, and accepting one should not cost someone access
  they already had.
  """
  def accept(token, %User{} = user) do
    case live_invitation(token) do
      nil ->
        {:error, "That invitation link is no longer valid."}

      invitation ->
        Repo.transaction(fn ->
          # Claim the invitation *before* creating anything. The conditional
          # UPDATE takes a row lock, so a second accept of the same link blocks
          # here and then matches zero rows — which is what makes "single use"
          # true when two people click at once, and not merely in sequence.
          # Reading `live_invitation` first and consuming afterwards would let
          # both callers past the read and hand out two memberships.
          case claim(invitation, user) do
            0 ->
              Repo.rollback("That invitation link is no longer valid.")

            1 ->
              membership = apply_membership(invitation, user)

              Audit.record("invitation.accepted", %{
                venue_id: invitation.venue_id,
                actor: user,
                subject_type: "membership",
                subject_id: membership.id,
                metadata: %{role: membership.role, invitation_id: invitation.id}
              })

              membership
          end
        end)
    end
  end

  defp claim(invitation, user) do
    {count, _} =
      Repo.update_all(
        from(i in Invitation,
          where: i.id == ^invitation.id and is_nil(i.accepted_at) and is_nil(i.revoked_at)
        ),
        set: [accepted_at: now(), accepted_by_id: user.id]
      )

    count
  end

  @doc "Withdraws an invitation that has not been accepted."
  def revoke(venue_id, id, actor) do
    case Repo.one(from i in Invitation, where: i.id == ^id and i.venue_id == ^venue_id) do
      nil ->
        {:error, "Unknown invitation."}

      %Invitation{accepted_at: accepted} when not is_nil(accepted) ->
        {:error, "That invitation has already been accepted."}

      invitation ->
        {:ok, revoked} =
          invitation |> Ecto.Changeset.change(%{revoked_at: now()}) |> Repo.update()

        Audit.record("invitation.revoked", %{
          venue_id: venue_id,
          actor: actor,
          subject_type: "invitation",
          subject_id: invitation.id,
          metadata: %{role: invitation.role}
        })

        {:ok, revoked}
    end
  end

  @doc "Deletes invitations that expired long ago."
  def purge_expired(older_than_days \\ 30) do
    cutoff = days_from_now(-older_than_days)
    {count, _} = Repo.delete_all(from i in Invitation, where: i.expires_at < ^cutoff)
    count
  end

  ## ---------- internals ----------

  defp apply_membership(invitation, user) do
    case Venues.get_membership(user.id, invitation.venue_id) do
      nil ->
        {:ok, member} =
          Venues.add_member(invitation.venue_id, user.id, invitation.role, invitation.staff_id)

        member

      existing ->
        if Venues.role_at_least?(invitation.role, existing.role) and
             invitation.role != existing.role do
          {:ok, member} =
            existing
            |> VenueMember.changeset(%{role: invitation.role})
            |> Repo.update()

          member
        else
          existing
        end
    end
  end

  # Neither accepted, revoked, nor expired.
  defp live_invitation(token) when is_binary(token) and token != "" do
    now = now()

    Repo.one(
      from i in Invitation,
        where:
          i.token_hash == ^hash(token) and is_nil(i.accepted_at) and is_nil(i.revoked_at) and
            i.expires_at > ^now
    )
  end

  defp live_invitation(_), do: nil

  defp validate_role(role) do
    role = to_string(role || "")

    if role in VenueMember.roles(),
      do: {:ok, role},
      else: {:error, "Pick a role: owner, manager, receptionist or staff."}
  end

  # A phone is normalized so the invitation is addressed to the same string the
  # account will eventually carry; an unusable number is caught here rather than
  # at delivery.
  defp normalize_contact(attrs) do
    phone = to_string(attrs[:phone] || "") |> String.trim()
    email = to_string(attrs[:email] || "") |> String.trim() |> String.downcase()

    cond do
      phone == "" and email == "" ->
        {:error, "Enter a phone number or an email address."}

      phone == "" ->
        {:ok, %{phone: "", email: email}}

      true ->
        case Phone.normalize_mobile(phone) do
          {:ok, normalized} -> {:ok, %{phone: normalized, email: email}}
          {:error, reason} -> {:error, Phone.message(reason)}
        end
    end
  end

  # Inviting someone who is already on the team is a mistake worth naming,
  # rather than silently creating an invitation that changes nothing.
  defp ensure_not_already_member(venue_id, %{phone: phone, email: email}) do
    existing =
      cond do
        phone != "" -> Blastek.Accounts.get_by_verified_phone(phone)
        email != "" -> Blastek.Accounts.get_by_email(email)
        true -> nil
      end

    case existing && Venues.get_membership(existing.id, venue_id) do
      nil -> :ok
      _member -> {:error, "That person is already on your team."}
    end
  end

  defp deliver(invitation, venue, token, locale) do
    to = if invitation.phone != "", do: invitation.phone, else: invitation.email

    Notifications.deliver_invitation(to, venue.name, invitation.role, accept_url(token),
      locale: locale
    )
  end

  defp accept_base_url,
    do: Application.get_env(:blastek, :invitation_accept_url, "http://localhost:5173/join")

  defp ensure_staff_column(venue_id, staff_id) do
    if Venues.staff_in_venue?(venue_id, staff_id),
      do: :ok,
      else: {:error, "That calendar column belongs to another venue."}
  end

  defp random_token,
    do: :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  defp days_from_now(days), do: NaiveDateTime.add(now(), days * 86_400, :second)
end
