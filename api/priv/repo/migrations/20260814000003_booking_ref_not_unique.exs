defmodule Blastek.Repo.Migrations.BookingRefNotUnique do
  @moduledoc """
  A booking reference identifies a *booking*, not a row (found during E9-T4).

  `appointments_booking_ref_index` was created UNIQUE in E1. A cut-and-colour
  is two appointments under one reference — that is the whole reason the column
  exists — so the second insert of every multi-service booking violated it.

  The failure was invisible for two reasons. `Salon.insert_booking/3` maps any
  `{:error, changeset}` to `Repo.rollback(slot_taken())`, so a schema violation
  came back as **"That time was just taken — please pick another slot."**: a
  plausible, self-explaining message that blames another customer for a
  constraint. And no test had ever booked more than one service, so the suite
  agreed with it.

  The index is kept, without the uniqueness: looking an appointment up by its
  reference is exactly what the reschedule flow and every support conversation
  does.
  """
  use Ecto.Migration

  def up do
    drop index(:appointments, [:booking_ref], name: :appointments_booking_ref_index)

    create index(:appointments, [:booking_ref],
             name: :appointments_booking_ref_index,
             where: "booking_ref <> ''"
           )
  end

  def down do
    drop index(:appointments, [:booking_ref], name: :appointments_booking_ref_index)

    create unique_index(:appointments, [:booking_ref],
             name: :appointments_booking_ref_index,
             where: "booking_ref <> ''"
           )
  end
end
