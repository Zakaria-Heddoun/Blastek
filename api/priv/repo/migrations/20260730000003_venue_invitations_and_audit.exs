defmodule Blastek.Repo.Migrations.VenueInvitationsAndAudit do
  @moduledoc """
  Inviting people into a venue, and a record of who changed whose access
  (E4-T1, E4-T6 / F0.3).

  ## Invitations

  An invitation is a pending membership: a role reserved for a phone number or
  an email address, redeemable once, by whoever holds the link.

  Like every other bearer credential here, only the **hash** of the token is
  stored — a leaked table must not yield working invitation links. The
  invitation is addressed to a contact, but the token is what grants; requiring
  the recipient to already have an account would make the common case (a
  receptionist who has never heard of Blastek) impossible.

  `staff_id` lets an invitation carry a calendar column, so a stylist arrives
  already attached to the appointments the venue has been booking for them.

  ## Audit

  F0.3 asks for membership changes to be auditable, and E11 will want a general
  admin log. Rather than build a narrow `membership_events` table now and
  migrate it later, this is the general shape with a deliberately narrow set of
  writers: only membership and invitation events are recorded today.

  `actor_user_id` is nullable and `ON DELETE SET NULL` on purpose — the log
  outlives the account that acted, and "who removed this person?" must not be
  answerable only while that person still works here.
  """
  use Ecto.Migration

  def change do
    create table(:venue_invitations) do
      add :venue_id, references(:venues, on_delete: :delete_all), null: false
      add :role, :string, null: false

      # One of these identifies the invitee; both are optional individually
      # because an owner may know only a phone number or only an email.
      add :phone, :string, null: false, default: ""
      add :email, :string, null: false, default: ""

      add :token_hash, :binary, null: false
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :staff_id, references(:staff, on_delete: :nilify_all)

      add :expires_at, :naive_datetime, null: false
      add :accepted_at, :naive_datetime
      add :accepted_by_id, references(:users, on_delete: :nilify_all)
      add :revoked_at, :naive_datetime

      timestamps(type: :naive_datetime)
    end

    create unique_index(:venue_invitations, [:token_hash])
    # The team page lists a venue's outstanding invitations.
    create index(:venue_invitations, [:venue_id, :accepted_at])

    create table(:audit_log) do
      add :venue_id, references(:venues, on_delete: :delete_all)
      add :actor_user_id, references(:users, on_delete: :nilify_all)

      # e.g. "member.role_changed". Free text rather than an enum: the set grows
      # with every epic, and a migration per new action would be absurd.
      add :action, :string, null: false
      add :subject_type, :string, null: false, default: ""
      add :subject_id, :integer

      add :metadata, :map, null: false, default: %{}

      # Only inserted, never updated — an audit row that can change is not one.
      timestamps(type: :naive_datetime, updated_at: false)
    end

    create index(:audit_log, [:venue_id, :inserted_at])
    create index(:audit_log, [:actor_user_id])
  end
end
