defmodule Blastek.Notifications.Notification do
  @moduledoc """
  One attempt to reach one person: the send log row (E6-T2 / F0.10).

  Written before the provider is called, not after. A message that vanished
  because the node died mid-send is exactly the one worth being able to see, and
  a row created only on success cannot record a failure to create it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued sent delivered failed skipped)
  @channels ~w(whatsapp sms email inapp)

  schema "notifications" do
    field :user_id, :id
    field :venue_id, :id
    field :appointment_id, :id

    field :to, :string
    field :template, :string
    field :channel, :string
    field :locale, :string, default: "fr"
    field :body, :string, default: ""
    field :payload, :map, default: %{}

    field :status, :string, default: "queued"
    field :provider, :string
    field :provider_message_id, :string
    field :error, :string
    field :attempts, :integer, default: 0
    field :sent_at, :naive_datetime
    field :delivered_at, :naive_datetime

    timestamps(type: :naive_datetime)
  end

  def statuses, do: @statuses
  def channels, do: @channels

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [
      :user_id,
      :venue_id,
      :appointment_id,
      :to,
      :template,
      :channel,
      :locale,
      :body,
      :payload,
      :status,
      :provider,
      :provider_message_id,
      :error,
      :attempts,
      :sent_at,
      :delivered_at
    ])
    |> validate_required([:to, :template, :channel])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:channel, @channels)
    # Truncated rather than rejected: a provider returning a wall of HTML must
    # not be the reason a send log row fails to save.
    |> update_change(:error, &String.slice(to_string(&1), 0, 2000))
  end
end

defmodule Blastek.Notifications.OptOut do
  @moduledoc """
  A refusal to be contacted, keyed by address rather than by account.

  Someone who replies STOP has not consented to be messaged again because they
  later signed up with a second account, and the number is what the provider
  actually knows about them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "notification_optouts" do
    field :to, :string
    field :channel, :string, default: "any"
    field :reason, :string, default: ""
    timestamps(type: :naive_datetime, updated_at: false)
  end

  def changeset(optout, attrs) do
    optout
    |> cast(attrs, [:to, :channel, :reason])
    |> validate_required([:to])
    |> unique_constraint([:to, :channel])
  end
end
