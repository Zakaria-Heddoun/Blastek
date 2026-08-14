defmodule Blastek.Repo.Migrations.RebuildReviews do
  @moduledoc """
  Reviews become evidence of a visit rather than free text (E10-T1 / F0.8).

  The old table was a demo prop: a name typed as a string, a rating, and no way
  to tell whether the person had ever set foot in the salon. F0.8's premise is
  the opposite — "ratings I read reflect real visits only" — so a review now
  points at the client who wrote it and at the booking it is about.

  ## The seeded rows are deleted, not migrated

  All fourteen existing rows are invented, with no client and no booking to
  attach them to. Keeping them would mean a table whose entire purpose is
  verified reviews shipping with unverifiable ones in it, inflating exactly the
  average customers are told to trust. F0.8 asks for them to be purged at
  activation; the venues in this database are already active, so they go now.
  `Blastek.Salon.Reviews.purge_seeded/1` handles the ones written between now
  and a venue's activation.

  ## booking_ref, not appointment_id

  A booking of three services is three appointment rows sharing one
  `booking_ref` — that is the visit, and the visit is what somebody reviews.
  The unique index is therefore on the ref, which is what "one review per
  booking" means in the acceptance criteria.
  """
  use Ecto.Migration

  def up do
    execute("DELETE FROM reviews")

    alter table(:reviews) do
      add :client_id, references(:clients, on_delete: :nilify_all)
      add :booking_ref, :string
      add :status, :string, null: false, default: "visible"
      add :locale, :string, null: false, default: "fr"
      add :reply, :text, null: false, default: ""
      add :reply_at, :naive_datetime
      # Why a review was hidden, so the author can be told which rule it broke
      # rather than watching it vanish.
      add :hidden_reason, :string, null: false, default: ""
      add :flagged_reason, :string, null: false, default: ""

      remove :client_name
    end

    # Partial: rows predating the ref, and any future row without one, must not
    # collide with each other on NULL-vs-NULL. Postgres would allow that anyway;
    # being explicit says the constraint is about real bookings.
    create unique_index(:reviews, [:booking_ref], where: "booking_ref is not null")
    create index(:reviews, [:client_id])
    create index(:reviews, [:venue_id, :status])

    create constraint(:reviews, :reviews_status,
             check: "status in ('visible', 'flagged', 'hidden')"
           )

    create constraint(:reviews, :reviews_rating, check: "rating between 1 and 5")

    alter table(:venues) do
      add :rating_avg, :float, null: false, default: 0.0
      add :rating_count, :integer, null: false, default: 0
    end
  end

  def down do
    alter table(:venues) do
      remove :rating_avg
      remove :rating_count
    end

    drop constraint(:reviews, :reviews_rating)
    drop constraint(:reviews, :reviews_status)
    drop index(:reviews, [:venue_id, :status])
    drop index(:reviews, [:client_id])
    drop unique_index(:reviews, [:booking_ref], where: "booking_ref is not null")

    alter table(:reviews) do
      add :client_name, :string, null: false, default: ""

      remove :flagged_reason
      remove :hidden_reason
      remove :reply_at
      remove :reply
      remove :locale
      remove :status
      remove :booking_ref
      remove :client_id
    end
  end
end
