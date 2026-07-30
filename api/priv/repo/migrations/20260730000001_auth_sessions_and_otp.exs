defmodule Blastek.Repo.Migrations.AuthSessionsAndOtp do
  @moduledoc """
  Phone-first identity: server-side sessions and one-time codes (E3-T1 / F0.2).

  ## Why sessions replace a stateless token

  Auth was a signed `Phoenix.Token` carrying a user id. Nothing was stored, which
  is cheap and completely unrevocable: "log out the phone I lost" and "revoke a
  compromised account" are both impossible when the server has no record a token
  exists. Sessions are that record.

  Only the **hashes** are stored. A leaked database must not hand over working
  bearer tokens, and the server never needs the original — it hashes what it is
  given and looks that up.

  ## Why a verified phone is unique but a phone is not

  Anyone can type any number into a profile field. Once a number has been proven
  by OTP it becomes an identity, and two accounts cannot share one. Hence the
  partial unique index: unverified duplicates are fine, verified ones are not.

  ## Why email and password_hash become nullable

  Both were NOT NULL because until now every account came from the email form. A
  phone-first account has neither. Empty string will not do for email — the
  unique index is on `lower(email)`, so the second passwordless account would
  collide with the first. NULL is the correct absence, and Postgres permits many
  NULLs in a unique index.
  """
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # SHA-256 of the bearer tokens. Never the tokens themselves.
      add :token_hash, :binary, null: false
      add :refresh_hash, :binary, null: false

      # Free text from the User-Agent so the sessions list reads as "Chrome on
      # Android" rather than a row of opaque ids.
      add :device, :string, null: false, default: ""
      add :ip, :string, null: false, default: ""

      add :expires_at, :naive_datetime, null: false
      add :refresh_expires_at, :naive_datetime, null: false
      add :last_used_at, :naive_datetime
      add :revoked_at, :naive_datetime

      timestamps(type: :naive_datetime)
    end

    # Every authenticated request looks a session up by hash, so this index is
    # on the hottest path in the application.
    create unique_index(:sessions, [:token_hash])
    create unique_index(:sessions, [:refresh_hash])
    create index(:sessions, [:user_id])

    create table(:otp_codes) do
      add :phone, :string, null: false
      add :code_hash, :string, null: false
      add :purpose, :string, null: false

      add :attempts, :integer, null: false, default: 0
      add :expires_at, :naive_datetime, null: false
      add :consumed_at, :naive_datetime

      timestamps(type: :naive_datetime)
    end

    # Codes are always looked up as "the live one for this phone and purpose",
    # newest first — a login code must not be consumed by a password reset.
    create index(:otp_codes, [:phone, :purpose, :inserted_at])

    alter table(:users) do
      add :phone_verified_at, :naive_datetime
    end

    create unique_index(:users, [:phone],
             where: "phone_verified_at IS NOT NULL AND phone <> ''",
             name: :users_verified_phone_index
           )

    # The paired statements below are ordered so that `mix ecto.rollback` runs
    # them in a workable sequence: Ecto reverses the list, so each backfill that
    # a `SET NOT NULL` depends on is written *after* it here in order to run
    # *before* it on the way down.

    execute "ALTER TABLE users ALTER COLUMN email DROP NOT NULL",
            "ALTER TABLE users ALTER COLUMN email SET NOT NULL"

    execute "UPDATE users SET email = NULL WHERE email = ''",
            # A reserved `.invalid` domain (RFC 2606) can never collide with a
            # real address, so rolling back is lossless rather than destructive.
            "UPDATE users SET email = 'phone-' || id || '@blastek.invalid' WHERE email IS NULL"

    execute "ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL",
            "ALTER TABLE users ALTER COLUMN password_hash SET NOT NULL"

    # No-op going up — every existing account has a password. Going down it
    # gives the phone-only accounts an unusable hash, which is what they
    # effectively had anyway.
    execute "SELECT 1",
            "UPDATE users SET password_hash = '!' WHERE password_hash IS NULL"
  end
end
