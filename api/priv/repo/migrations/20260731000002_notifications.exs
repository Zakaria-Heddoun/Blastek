defmodule Blastek.Repo.Migrations.Notifications do
  @moduledoc """
  The notification send log and per-user channel preferences (E6-T2 / F0.10).

  ## Why a log at all

  Every message is a promise to somebody: a customer told they will be reminded,
  an owner told they will hear about online bookings. When one does not arrive
  the only useful question is *what happened to it*, and the only way to answer
  is a row per attempt with the provider's own identifier and its error. F0.10
  makes this explicit — an admin has to be able to see delivery status and the
  failure reason.

  `provider_message_id` is what makes delivery receipts possible: WhatsApp tells
  us about a message by its id, hours after we sent it, over a webhook that
  knows nothing about our appointments.

  ## Nullable everything

  `user_id`, `venue_id` and `appointment_id` are all nullable and all
  `ON DELETE` nilify rather than cascade. A send log that disappears when the
  account does cannot answer "did we ever message this number?", which is
  exactly the question a complaint raises. `to` keeps the address the message
  actually went to, so a row remains meaningful after every association is gone.

  ## Preferences

  Stored as JSONB on `users`, like venue settings and for the same reason: the
  set of things a person can opt out of grows every epic, and a column each
  would mean a migration each. Transactional messages are deliberately *not*
  optional — F0.10 says confirmations always send — so preferences only ever
  govern reminders and marketing.
  """
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :venue_id, references(:venues, on_delete: :nilify_all)
      add :appointment_id, references(:appointments, on_delete: :nilify_all)

      # The address as sent: a phone number in E.164, or an email.
      add :to, :string, null: false
      add :template, :string, null: false
      add :channel, :string, null: false
      add :locale, :string, null: false, default: "fr"

      # Rendered body plus whatever the template was given, so a message can be
      # read back exactly as it was sent without re-rendering it against
      # today's copy.
      add :body, :text, null: false, default: ""
      add :payload, :map, null: false, default: %{}

      # queued | sent | delivered | failed | skipped
      add :status, :string, null: false, default: "queued"
      add :provider, :string
      add :provider_message_id, :string
      add :error, :text
      add :attempts, :integer, null: false, default: 0
      add :sent_at, :naive_datetime
      add :delivered_at, :naive_datetime

      timestamps(type: :naive_datetime)
    end

    # The admin log is read newest-first, usually filtered by one venue.
    create index(:notifications, [:inserted_at])
    create index(:notifications, [:venue_id, :inserted_at])
    create index(:notifications, [:user_id, :inserted_at])
    create index(:notifications, [:status])

    # Delivery receipts arrive keyed by the provider's id and nothing else.
    create unique_index(:notifications, [:provider, :provider_message_id],
             where: "provider_message_id IS NOT NULL",
             name: :notifications_provider_message_id_index
           )

    # Reminders are looked up by appointment when one is cancelled.
    create index(:notifications, [:appointment_id])

    alter table(:users) do
      add :notification_prefs, :map, null: false, default: %{}
    end

    # An opt-out has to survive the account it came from: someone who replies
    # STOP has not consented to be messaged again because they signed up twice.
    # Keyed by address, not by user.
    create table(:notification_optouts) do
      add :to, :string, null: false
      add :channel, :string, null: false, default: "any"
      add :reason, :string, null: false, default: ""
      timestamps(type: :naive_datetime, updated_at: false)
    end

    create unique_index(:notification_optouts, [:to, :channel])
  end
end
