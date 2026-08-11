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
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    case known_template(args["template"]) do
      # A job enqueued by a build that has since been rolled back. Discard it
      # rather than retry it five times.
      :error -> {:cancel, "unknown template"}
      {:ok, template} -> render_and_send(template, args, attempt)
    end
  end

  # Scoped to the one expression that can raise it. A `rescue ArgumentError`
  # around the whole of `perform/1` also catches anything the rendering or the
  # send raises, and reports it as an unknown template — which both discards a
  # message that deserved a retry and puts a false reason in the job.
  defp known_template(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  defp known_template(_name), do: :error

  defp render_and_send(template, args, attempt) do
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
          appointment_id: args["appointment_id"],
          attempt: attempt
        ]

        case Notifications.send_now(template, args["to"], opts) do
          {:ok, log} -> {:ok, log.id}
          # Returned as an error so Oban retries; the log row already records
          # the attempt, so a retry appends rather than overwrites.
          {:error, log} -> {:error, log.error || "delivery failed"}
        end
    end
  end
end
