defmodule Blastek.Media.Attachment do
  @moduledoc "One uploaded image plus the keys of its derived variants."
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(cover gallery avatar)
  @statuses ~w(pending ready failed)

  schema "attachments" do
    field :venue_id, :id
    field :user_id, :id
    field :kind, :string, default: "gallery"
    field :key, :string
    field :content_type, :string, default: ""
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :variants, :map, default: %{}
    field :status, :string, default: "pending"
    field :sort, :integer, default: 0
    field :alt, :string, default: ""
    timestamps(type: :naive_datetime)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :venue_id,
      :user_id,
      :kind,
      :key,
      :content_type,
      :byte_size,
      :width,
      :height,
      :variants,
      :status,
      :sort,
      :alt
    ])
    |> validate_required([:key, :kind, :status])
    |> validate_owner()
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:key)
    |> check_constraint(:venue_id, name: :attachments_exactly_one_owner)
  end

  defp validate_owner(changeset) do
    venue_id = get_field(changeset, :venue_id)
    user_id = get_field(changeset, :user_id)

    if is_nil(venue_id) == is_nil(user_id) do
      add_error(changeset, :venue_id, "must have exactly one owner")
    else
      changeset
    end
  end
end
