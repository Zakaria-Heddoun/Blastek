defmodule Blastek.Notifications.Collector do
  @moduledoc """
  Test notification provider: keeps messages instead of sending them.

  Per-process, like `Blastek.Geocode.Stub`, so the suite can stay `async: true`
  without one test reading another's codes.

  `last_code/0` exists because the alternative is worse. A test needs the code
  to type it back, and the two other ways to get it are to have the API return
  it (a hole that would eventually reach production) or to stop hashing it
  (defeating the point). Reading it from the delivered message is exactly what a
  real user does.
  """
  @behaviour Blastek.Notifications.Provider

  @key :notifications_collector

  @impl true
  def deliver(message) do
    Process.put(@key, [message | delivered()])
    :ok
  end

  @doc "Every message delivered in this process, oldest first."
  def delivered, do: Process.get(@key, []) |> Enum.reverse()

  @doc "The most recent message, or nil."
  def last, do: delivered() |> List.last()

  @doc "The six-digit code in the most recent message, or nil."
  def last_code do
    case last() do
      %{body: body} ->
        case Regex.run(~r/\b(\d{6})\b/, body) do
          [_, code] -> code
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc "Messages delivered to one recipient."
  def delivered_to(to), do: Enum.filter(delivered(), &(&1.to == to))

  def clear, do: Process.delete(@key)
end

defmodule Blastek.Notifications.FailingProvider do
  @moduledoc "Test provider that always fails, for the undeliverable-OTP path."
  @behaviour Blastek.Notifications.Provider

  @impl true
  def deliver(_message), do: {:error, :unreachable}
end

defmodule Blastek.Notifications.TestProvider do
  @moduledoc """
  Swapping the provider for one test, without affecting the others.

  `Application.put_env` is global: while a test that swaps in a failing provider
  runs, every concurrent test sending a notification gets it too. That produced
  a genuinely nasty flake — an unrelated OTP test intermittently receiving no
  code — so the override is per-process instead.
  """
  alias Blastek.Notifications.Provider

  @doc "Runs `fun` with `providers` in force for this process only."
  def with_provider(providers, fun) do
    previous = Provider.put_override(providers)

    try do
      fun.()
    after
      if previous, do: Provider.put_override(previous), else: Provider.clear_override()
    end
  end
end

defmodule Blastek.Notifications.RaisingProvider do
  @moduledoc "Test provider that blows up, for the chain's crash isolation."
  @behaviour Blastek.Notifications.Provider

  @impl true
  def deliver(_message), do: raise("provider exploded")
end
