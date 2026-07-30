defmodule Blastek.Notifications.Worker do
  @moduledoc """
  Renders and sends one queued message (E6-T2 / F0.10).

  Retries are Oban's: a provider that is down for ninety seconds costs a delay,
  not a lost confirmation. The backoff is the default exponential one, which
  reaches roughly an hour by the last attempt — past that a message is stale
  enough that arriving is worse than not.

  ## Re-checking on the way out

  A scheduled job carries only ids, and it may run a day after it was created.
  Everything it needs is re-read at run time, and a reminder for an appointment
  that has since been cancelled is **discarded rather than sent** — which is how
  F0.10's "cancelled appointments never remind" is actually kept. Cancelling the
  Oban job as well is a cheap optimisation; the correctness lives here, because
  a job that escaped cancellation must still not fire.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 5

  alias Blastek.Notifications
  alias Blastek.Notifications.Reminders

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    template = String.to_existing_atom(args["template"])

    case Reminders.still_due(template, args) do
      {:skip, reason} ->
        # `:ok` rather than an error: a reminder for a cancelled appointment is
        # a job that did its job.
        {:ok, {:skipped, reason}}

      {:ok, assigns} ->
        opts = [
          locale: args["locale"],
          assigns: assigns,
          user_id: args["user_id"],
          venue_id: args["venue_id"],
          appointment_id: args["appointment_id"]
        ]

        case Notifications.send_now(template, args["to"], opts) do
          {:ok, log} -> {:ok, log.id}
          # Returned as an error so Oban retries; the log row already records
          # the attempt, so a retry appends rather than overwrites.
          {:error, log} -> {:error, log.error || "delivery failed"}
        end
    end
  rescue
    ArgumentError ->
      # An unknown template name — a job enqueued by a build that has since been
      # rolled back. Discard it rather than retry it five times.
      {:cancel, "unknown template"}
  end
end
