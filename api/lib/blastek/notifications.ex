defmodule Blastek.Notifications do
  @moduledoc """
  Outbound messages: templated, localized, logged, retried (E6-T2 / F0.10).

  ## The shape

  Every send is a row in `notifications` written **before** the provider is
  called, then updated with what happened. A message that vanished because the
  node died mid-send is exactly the one worth being able to see, and a row
  created only on success cannot record a failure to create it.

  Delivery is asynchronous, through Oban: a customer's confirmation must not
  make them wait on Meta's API inside their booking request, and a provider
  outage must cost a retry rather than a lost message. `deliver/2` enqueues;
  `Blastek.Notifications.Worker` renders, sends and records.

  ## What can be turned off

  Only reminders. F0.10 is explicit that transactional messages — the
  confirmation for a booking somebody just made, the code they asked for — are
  not optional, because suppressing them leaves the person with no record of
  their own action. `Templates.category/1` decides, not the caller.

  An **opt-out** is different from a preference and outranks it: someone who
  replied STOP has withdrawn consent for the address, and that survives them
  signing up again with a second account.

  ## Compatibility

  `deliver_otp/4` and friends stay synchronous. Auth cannot enqueue a code and
  tell the user to check their phone — if the send fails, the flow has to say
  so, and E3 built the return value that says it.
  """
  import Ecto.Query

  alias Blastek.Notifications.Notification
  alias Blastek.Notifications.OptOut
  alias Blastek.Notifications.Provider
  alias Blastek.Notifications.Templates
  alias Blastek.Notifications.Worker
  alias Blastek.Repo

  @default_prefs %{"reminders" => true, "marketing" => false}

  def default_prefs, do: @default_prefs

  ## ---------- sending ----------

  @doc """
  Queues a message.

  `opts` carries `:user_id`, `:venue_id`, `:appointment_id`, `:locale`, `:to`
  and the template's own assigns under `:assigns`. Returns `{:ok, job}`,
  or `{:ok, :skipped}` when the recipient has opted out or turned this category
  off — a skip is a success from the caller's point of view, and it is recorded
  in the log either way.
  """
  def deliver(template, to, opts \\ []) do
    cond do
      to in [nil, ""] ->
        {:ok, :skipped}

      not Templates.known?(template) ->
        {:error, {:unknown_template, template}}

      true ->
        case suppression(template, to, opts[:user]) do
          nil -> enqueue(template, to, opts)
          reason -> record_skip(template, to, opts, reason)
        end
    end
  end

  defp enqueue(template, to, opts) do
    %{
      "template" => to_string(template),
      "to" => to,
      "locale" => Templates.locale(opts[:locale]),
      "assigns" => stringify(opts[:assigns] || %{}),
      "user_id" => opts[:user_id],
      "venue_id" => opts[:venue_id],
      "appointment_id" => opts[:appointment_id]
    }
    |> Worker.new(scheduled_at: opts[:scheduled_at], queue: opts[:queue] || :notifications)
    |> Oban.insert()
  end

  @doc """
  Renders and sends one message now, recording the attempt.

  Called by the worker. Public so a test — and an admin retrying a failure —
  can drive the same path the queue does.
  """
  def send_now(template, to, opts \\ []) do
    locale = Templates.locale(opts[:locale])
    assigns = opts[:assigns] || %{}
    body = Templates.render(template, locale, assigns)

    {:ok, log} =
      %Notification{}
      |> Notification.changeset(%{
        user_id: opts[:user_id],
        venue_id: opts[:venue_id],
        appointment_id: opts[:appointment_id],
        to: to,
        template: to_string(template),
        channel: to_string(opts[:channel] || :sms),
        locale: locale,
        body: body,
        payload: stringify(assigns),
        status: "queued"
      })
      |> Repo.insert()

    case Provider.deliver(%{to: to, body: body, template: template, locale: locale}) do
      {:ok, provider, channel, id} ->
        {:ok,
         update_log(log, %{
           status: "sent",
           channel: to_string(channel),
           provider: inspect(provider),
           provider_message_id: id,
           attempts: log.attempts + 1,
           sent_at: now()
         })}

      {:error, reason} ->
        {:error,
         update_log(log, %{
           status: "failed",
           error: inspect(reason),
           attempts: log.attempts + 1
         })}
    end
  end

  defp update_log(log, attrs) do
    log |> Notification.changeset(attrs) |> Repo.update!()
  end

  defp record_skip(template, to, opts, reason) do
    %Notification{}
    |> Notification.changeset(%{
      user_id: opts[:user_id],
      venue_id: opts[:venue_id],
      appointment_id: opts[:appointment_id],
      to: to,
      template: to_string(template),
      channel: "inapp",
      locale: Templates.locale(opts[:locale]),
      body: "",
      payload: stringify(opts[:assigns] || %{}),
      status: "skipped",
      error: to_string(reason)
    })
    |> Repo.insert!()

    {:ok, :skipped}
  end

  ## ---------- suppression ----------

  @doc """
  Why this message must not be sent, or nil.

  Order matters: an opt-out is a withdrawal of consent and outranks everything,
  including the caller's belief that a message is transactional.
  """
  def suppression(template, to, user \\ nil) do
    cond do
      opted_out?(to) -> :opted_out
      Templates.category(template) == :transactional -> nil
      not allows?(user, Templates.category(template)) -> :prefs
      true -> nil
    end
  end

  @doc "Whether a user permits a category of message. Unknown user → default."
  def allows?(nil, category), do: Map.get(@default_prefs, to_string(category), true)

  def allows?(%{notification_prefs: prefs}, category) when is_map(prefs) do
    case Map.fetch(prefs, to_string(category)) do
      {:ok, value} -> value == true
      :error -> Map.get(@default_prefs, to_string(category), true)
    end
  end

  def allows?(_user, category), do: Map.get(@default_prefs, to_string(category), true)

  def opted_out?(to) do
    Repo.exists?(from o in OptOut, where: o.to == ^to)
  end

  @doc "Records a STOP. Idempotent — a second STOP is not an error."
  def opt_out(to, reason \\ "user request", channel \\ "any") do
    %OptOut{}
    |> OptOut.changeset(%{to: to, channel: channel, reason: reason})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:to, :channel])
  end

  def opt_in(to) do
    Repo.delete_all(from o in OptOut, where: o.to == ^to)
    :ok
  end

  ## ---------- preferences ----------

  @doc """
  Merges preference changes for a user.

  Only known categories are stored, and only booleans — the column is
  schemaless, and the same reasoning as `Venues.Settings` applies: a typo must
  not write a key nobody reads.
  """
  def update_prefs(user, changes) do
    known = Map.keys(@default_prefs)

    clean =
      changes
      |> stringify()
      |> Map.take(known)
      |> Map.new(fn {key, value} -> {key, value == true} end)

    user
    |> Ecto.Changeset.change(%{notification_prefs: Map.merge(prefs(user), clean)})
    |> Repo.update()
  end

  @doc "A user's preferences, with defaults filled in."
  def prefs(%{notification_prefs: prefs}) when is_map(prefs), do: Map.merge(@default_prefs, prefs)
  def prefs(_user), do: @default_prefs

  ## ---------- the log ----------

  @doc """
  The send log, newest first (F0.12 admin view).

  Filters: `:venue_id`, `:user_id`, `:status`, `:template`, `:appointment_id`.
  """
  def list_log(opts \\ []) do
    limit = min(Keyword.get(opts, :limit, 50), 200)

    Notification
    |> filter(:venue_id, opts[:venue_id])
    |> filter(:user_id, opts[:user_id])
    |> filter(:status, opts[:status])
    |> filter(:appointment_id, opts[:appointment_id])
    |> filter(:template, opts[:template] && to_string(opts[:template]))
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> offset(^Keyword.get(opts, :offset, 0))
    |> Repo.all()
  end

  def count_log(opts \\ []) do
    Notification
    |> filter(:venue_id, opts[:venue_id])
    |> filter(:user_id, opts[:user_id])
    |> filter(:status, opts[:status])
    |> filter(:appointment_id, opts[:appointment_id])
    |> filter(:template, opts[:template] && to_string(opts[:template]))
    |> Repo.aggregate(:count)
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, field, value), do: from(n in query, where: field(n, ^field) == ^value)

  @doc """
  Marks a message delivered, from a provider webhook.

  Keyed by the provider's own id because that is all a delivery receipt carries.
  Unknown ids are ignored rather than raising: providers retry their webhooks,
  and receipts for messages this deployment never sent are normal.
  """
  def record_receipt(provider_message_id, status, error \\ nil)

  def record_receipt(nil, _status, _error), do: :ok

  def record_receipt(provider_message_id, status, error) when status in ["delivered", "failed"] do
    attrs =
      case status do
        "delivered" -> %{status: "delivered", delivered_at: now()}
        "failed" -> %{status: "failed", error: error}
      end

    case Repo.one(from n in Notification, where: n.provider_message_id == ^provider_message_id) do
      nil -> :ok
      log -> {:ok, update_log(log, attrs)}
    end
  end

  def record_receipt(_id, _status, _error), do: :ok

  ## ---------- synchronous senders (E3, E4, E5) ----------
  #
  # These predate the queue and stay synchronous on purpose: an OTP flow that
  # enqueues a code and tells the user to check their phone has no way to say
  # "that number is unreachable", which is the one thing it must be able to say.

  @doc "Sends a one-time code. `purpose` selects the wording."
  def deliver_otp(phone, code, purpose, opts \\ []) do
    sync(purpose, phone, %{code: code}, opts)
  end

  @doc "Sends a password-reset link."
  def deliver_password_reset(email, url, opts \\ []) do
    sync(:password_reset, email, %{url: url}, opts)
  end

  @doc "Sends a venue invitation link (E4-T1)."
  def deliver_invitation(to, venue_name, role, url, opts \\ []) do
    locale = Templates.locale(opts[:locale])
    assigns = %{venue: venue_name, role: role_name(role, locale), url: url}
    sync(:invitation, to, assigns, Keyword.put(opts, :locale, locale))
  end

  @doc "Tells an owner whether their venue was approved (E5-T8)."
  def deliver_venue_decision(to, venue_name, decision, reason, opts \\ []) do
    template = if decision == :approved, do: :venue_approved, else: :venue_rejected
    sync(template, to, %{venue: venue_name, reason: reason}, opts)
  end

  # The synchronous path still writes a log row and still honours opt-outs —
  # only the queue is skipped.
  defp sync(template, to, assigns, opts) do
    opts = Keyword.merge(opts, assigns: assigns)

    cond do
      to in [nil, ""] ->
        {:error, :no_address}

      suppression(template, to, opts[:user]) ->
        {:ok, :skipped} = record_skip(template, to, opts, suppression(template, to, opts[:user]))
        :ok

      true ->
        case send_now(template, to, opts) do
          {:ok, _log} -> :ok
          {:error, log} -> {:error, log.error}
        end
    end
  end

  # Roles are stored in English; the invitation is read by the invitee.
  defp role_name(role, "fr") do
    %{
      "owner" => "propriétaire",
      "manager" => "responsable",
      "receptionist" => "réception",
      "staff" => "praticien"
    }[role] || role
  end

  defp role_name(role, "ar") do
    %{"owner" => "مالك", "manager" => "مدير", "receptionist" => "استقبال", "staff" => "موظف"}[
      role
    ] ||
      role
  end

  defp role_name(role, _en), do: role

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify(other), do: other
end
