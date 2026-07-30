defmodule Blastek.Notifications.Providers.Sms do
  @moduledoc """
  SMS, the fallback when WhatsApp cannot reach somebody (E6-T5 / F0.10).

  ## Why the gateway is configuration, not a dependency

  Moroccan SMS gateways are small, regional, and all speak the same shape:
  an HTTP POST with a number, a body and a key. Committing to one vendor's SDK
  would mean a rewrite when the contract changes, so this speaks a generic
  form-encoded POST described entirely by config:

      config :blastek, Blastek.Notifications.Providers.Sms,
        url: "https://gateway.example.ma/send",
        api_key: "…",
        sender: "Blastek",
        # Which parameter names this particular gateway expects.
        params: %{to: "msisdn", body: "text", key: "apikey", sender: "from"}

  Swapping vendors is then a config change, which is the same bargain
  `Blastek.Storage` makes with S3-compatible object stores.

  ## Cost is a feature of the fallback

  SMS costs money per message and WhatsApp does not, which is the entire reason
  the chain is ordered the way it is. This provider is deliberately last.
  """
  @behaviour Blastek.Notifications.Provider

  alias Blastek.HTTP

  @default_params %{to: "to", body: "message", key: "api_key", sender: "sender"}

  @impl true
  def channel, do: :sms

  @impl true
  def deliver(%{to: to, body: body}) do
    with {:ok, config} <- config() do
      post(config, to, body)
    end
  end

  defp post(config, to, body) do
    params = Map.merge(@default_params, config[:params] || %{})

    form =
      %{
        params.to => normalize(to),
        params.body => body,
        params.key => config[:api_key]
      }
      |> maybe_put(params.sender, config[:sender])
      |> URI.encode_query()

    case HTTP.request(:post, config[:url], [{"accept", "application/json"}], form,
           content_type: "application/x-www-form-urlencoded"
         ) do
      {:ok, %{body: response}} -> {:ok, message_id(response)}
      {:error, {:status, status, response}} -> {:error, "#{status}: #{excerpt(response)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Gateways disagree about what they call the id; any of these is better than
  # none, and none is survivable — an SMS with no id simply has no delivery
  # receipt, which is the norm for the cheaper gateways anyway.
  defp message_id(response) do
    case Jason.decode(response) do
      {:ok, map} when is_map(map) ->
        map["message_id"] || map["id"] || map["messageId"] || map["sid"]

      _ ->
        nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # E.164 with the plus: the opposite of WhatsApp's preference, and the reason
  # normalization lives with each provider rather than in the context.
  defp normalize(to) do
    digits = to |> to_string() |> String.replace(~r/\D/, "")
    "+" <> digits
  end

  defp excerpt(body), do: body |> to_string() |> String.slice(0, 300)

  def configured?, do: match?({:ok, _}, config())

  defp config do
    settings = Application.get_env(:blastek, __MODULE__, [])

    if is_binary(settings[:url]) and settings[:url] != "" do
      {:ok, settings}
    else
      {:error, :sms_not_configured}
    end
  end
end
