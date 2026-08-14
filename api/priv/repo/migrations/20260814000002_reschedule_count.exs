defmodule Blastek.Repo.Migrations.RescheduleCount do
  @moduledoc """
  How many times a booking has been moved online (E9-T4 / F0.9).

  F0.9 caps the chain at three "to prevent abuse", and a cap needs somewhere to
  count. On the appointment rather than in a separate table because every row
  of a booking moves together and carries the same number — reading it costs
  nothing extra on a query that already has the rows in hand.

  Dashboard reschedules deliberately do **not** increment it: the limit exists
  to stop a customer walking a slot around the calendar, and a receptionist
  moving somebody at the salon's own request is not that.
  """
  use Ecto.Migration

  def change do
    alter table(:appointments) do
      add :reschedule_count, :integer, null: false, default: 0
    end
  end
end
