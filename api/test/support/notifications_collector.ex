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
  @behaviour Blastek.Notifications

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
  @behaviour Blastek.Notifications

  @impl true
  def deliver(_message), do: {:error, :unreachable}
end
