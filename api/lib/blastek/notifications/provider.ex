defmodule Blastek.Notifications.Provider do
  @moduledoc """
  How a message gets onto a phone (E6-T3, E6-T5 / F0.10).

  A provider takes a rendered message and returns `{:ok, provider_message_id}`
  or `{:error, reason}`. The id matters as much as the success: WhatsApp reports
  delivery hours later over a webhook that knows nothing but that id, so a
  provider that cannot say what it sent cannot have its delivery confirmed.

  ## The chain

  Configuration is a **list**, tried in order until one succeeds:

      config :blastek, :notifications_provider, [
        Blastek.Notifications.Providers.WhatsApp,
        Blastek.Notifications.Providers.Sms
      ]

  A single module is accepted too, which is what dev and test use. F0.10 asks
  for WhatsApp with automatic SMS fallback, and a list is the whole mechanism:
  a number with no WhatsApp account is the ordinary case in Morocco, not an
  exception worth branching on at every call site.

  Each provider declares the channels it can carry. An email address handed to
  an SMS gateway is not a fallback, it is a bounce, so `handles?/2` filters the
  chain before anything is attempted.
  """

  @type message :: %{
          required(:to) => String.t(),
          required(:body) => String.t(),
          required(:template) => atom,
          required(:locale) => String.t(),
          optional(:channel) => atom,
          optional(any) => any
        }

  @doc "Delivers, returning the provider's own id for the message."
  @callback deliver(message) :: {:ok, String.t()} | :ok | {:error, term}

  @doc "Which channel this provider carries — `:whatsapp`, `:sms`, `:email`."
  @callback channel() :: atom

  @optional_callbacks channel: 0

  @process_override :blastek_notifications_provider

  @doc """
  The configured chain, always as a list.

  A process-local override takes precedence over the application env. That
  exists for the test suite and is worth the one line: swapping
  `:notifications_provider` globally, as the obvious approach does, changes the
  provider for every *other* test running concurrently — and the resulting
  failure looks like "an unrelated OTP test occasionally delivers nothing",
  which is exactly as fun to diagnose as it sounds. The same per-process shape
  is what `Blastek.Geocode.Stub` and the test collector already use.
  """
  def chain do
    (Process.get(@process_override) ||
       Application.get_env(:blastek, :notifications_provider, Blastek.Notifications.DevLogger))
    |> List.wrap()
  end

  @doc "Overrides the chain for the calling process only. Returns the previous value."
  def put_override(providers) do
    previous = Process.get(@process_override)
    Process.put(@process_override, providers)
    previous
  end

  def clear_override, do: Process.delete(@process_override)

  @doc """
  Tries each provider that can carry this address until one succeeds.

  Returns `{:ok, provider, channel, id}`, or `{:error, reason}` carrying the
  *last* failure — the one from the provider that had the best claim to the
  message.
  """
  def deliver(message) do
    case Enum.filter(chain(), &handles?(&1, message)) do
      [] -> {:error, :no_provider}
      providers -> attempt(providers, message, :no_provider)
    end
  end

  defp attempt([], _message, last_error), do: {:error, last_error}

  defp attempt([provider | rest], message, _last_error) do
    channel = channel_of(provider, message)

    case safely(provider, Map.put(message, :channel, channel)) do
      {:ok, id} -> {:ok, provider, channel, id}
      :ok -> {:ok, provider, channel, nil}
      {:error, reason} -> attempt(rest, message, reason)
    end
  end

  # A provider that raises must fall through to the next one rather than take
  # the job down: an SMS that still arrives is worth more than a clean stack
  # trace about WhatsApp.
  defp safely(provider, message) do
    provider.deliver(message)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, "provider exited: #{inspect(reason)}"}
  end

  @doc """
  Whether a provider can carry this message.

  Email addresses and phone numbers are not interchangeable, and a provider
  that declares no channel (the dev logger, the test collector) carries
  everything.
  """
  def handles?(provider, message) do
    case declared_channel(provider) do
      nil -> true
      :email -> email?(message.to)
      _phone_channel -> not email?(message.to)
    end
  end

  defp channel_of(provider, message) do
    declared_channel(provider) || Map.get(message, :channel) || default_channel(message.to)
  end

  # `Code.ensure_loaded?` first, because `function_exported?/3` answers false for
  # a module that simply has not been loaded yet. Without it the very first
  # message of a boot would see no declared channel on any provider and offer an
  # email address to the SMS gateway — a bug that disappears the moment you look
  # for it, since inspecting the module loads it.
  defp declared_channel(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :channel, 0) do
      provider.channel()
    end
  end

  defp default_channel(to), do: if(email?(to), do: :email, else: :sms)

  defp email?(to), do: String.contains?(to, "@")
end

defmodule Blastek.Notifications.DevLogger do
  @moduledoc """
  Prints messages to the log instead of sending them.

  The default everywhere except production. It logs the **full body, including
  any one-time code** — that is the entire point in development, and it is why
  this provider must never be the configured one in production.
  """
  @behaviour Blastek.Notifications.Provider

  require Logger

  @impl true
  def deliver(%{to: to, body: body} = message) do
    channel = Map.get(message, :channel, :sms)

    Logger.info("""

    ┌─ #{String.upcase(to_string(channel))} → #{to}
    │  #{body}
    └─ (Blastek.Notifications.DevLogger — not actually sent)
    """)

    {:ok, "dev-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}
  end
end
