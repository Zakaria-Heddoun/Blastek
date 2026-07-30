defmodule Blastek.Notifications.Providers.WhatsApp do
  @moduledoc """
  WhatsApp Cloud API (E6-T4 / F0.10).

  The primary channel, because in Morocco WhatsApp is how people are actually
  reached: it costs the recipient nothing, it works on a weak connection, and it
  is where they already are.

  ## Session messages and template messages

  Meta only permits free-form text inside a 24-hour window opened by the *user*
  messaging the business. Outside it — which is every case here, since we
  message first — the message must be a **pre-approved template**, referenced by
  name and language, with its variables supplied positionally.

  So `Blastek.Notifications.Templates` is not the whole story: the body it
  renders is what SMS carries and what the send log records, while WhatsApp
  needs `{name, language, [params]}`. `template_payload/2` maps between them, and
  `docs/whatsapp-templates.md` is the pack submitted to Meta. A template not yet
  approved simply fails here and the chain falls through to SMS, which is why
  the fallback exists.

  ## Failure is expected, not exceptional

  A number with no WhatsApp account is the ordinary case, and Meta reports it as
  a perfectly ordinary error. Every failure returns `{:error, reason}` so
  `Provider.deliver/1` moves to the next provider rather than treating it as an
  outage.
  """
  @behaviour Blastek.Notifications.Provider

  require Logger

  alias Blastek.HTTP
  alias Blastek.Notifications.Templates

  @api_version "v21.0"

  @impl true
  def channel, do: :whatsapp

  @impl true
  def deliver(%{to: to, body: body, template: template, locale: locale}) do
    with {:ok, config} <- config(),
         {:ok, payload} <- payload(to, body, template, locale) do
      post(config, payload)
    end
  end

  ## ---------- request ----------

  defp post(config, payload) do
    url = "https://graph.facebook.com/#{@api_version}/#{config.phone_number_id}/messages"

    headers = [
      {"authorization", "Bearer " <> config.token},
      {"accept", "application/json"}
    ]

    case HTTP.request(:post, url, headers, Jason.encode!(payload),
           content_type: "application/json"
         ) do
      {:ok, %{body: body}} -> {:ok, message_id(body)}
      {:error, {:status, status, body}} -> {:error, describe(status, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Meta answers with `{"messages":[{"id":"wamid...."}]}`. That id is the only
  # thing a later delivery receipt carries, so losing it means losing the
  # ability to confirm the message ever arrived.
  defp message_id(body) do
    case Jason.decode(body) do
      {:ok, %{"messages" => [%{"id" => id} | _]}} -> id
      _ -> nil
    end
  end

  # Meta's errors are JSON with a human-readable message inside; surfacing the
  # raw body would put a wall of nested objects into the send log an admin has
  # to read.
  defp describe(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> "#{status}: #{message}"
      _ -> "#{status}: #{String.slice(to_string(body), 0, 300)}"
    end
  end

  ## ---------- payload ----------

  defp payload(to, body, template, locale) do
    case template_payload(template, locale) do
      nil ->
        # No approved template: a free-form text message, which Meta accepts
        # only inside an open session window. Attempted anyway — a customer who
        # has just messaged the salon is exactly the case it works for — and the
        # failure falls through to SMS.
        {:ok,
         %{
           messaging_product: "whatsapp",
           recipient_type: "individual",
           to: normalize(to),
           type: "text",
           text: %{preview_url: false, body: body}
         }}

      {name, params} ->
        {:ok,
         %{
           messaging_product: "whatsapp",
           recipient_type: "individual",
           to: normalize(to),
           type: "template",
           template: %{
             name: name,
             language: %{code: language_code(locale)},
             components: [
               %{
                 type: "body",
                 parameters: Enum.map(params, &%{type: "text", text: to_string(&1)})
               }
             ]
           }
         }}
    end
  end

  @doc """
  The approved template name and its positional parameters, or nil.

  Only templates that have been through Meta approval appear here — see
  `docs/whatsapp-templates.md`. Anything else falls back to text, and then to
  SMS.
  """
  def template_payload(template, _locale) do
    Map.get(approved(), template)
  end

  defp approved, do: Application.get_env(:blastek, :whatsapp_templates, %{})

  # Meta wants a bare international number: no plus, no spaces.
  defp normalize(to), do: to |> to_string() |> String.replace(~r/\D/, "")

  # Meta's language codes are not bare ISO-639: Arabic is `ar`, French `fr`,
  # English `en`, but a mismatch with the approved template's language is a
  # rejection, so the mapping is explicit rather than assumed.
  defp language_code(locale) do
    case Templates.locale(locale) do
      "ar" -> "ar"
      "en" -> "en"
      _ -> "fr"
    end
  end

  ## ---------- config ----------

  @doc "Whether the provider has everything it needs to send."
  def configured? do
    match?({:ok, _}, config())
  end

  defp config do
    settings = Application.get_env(:blastek, __MODULE__, [])
    token = settings[:token]
    phone_number_id = settings[:phone_number_id]

    if is_binary(token) and token != "" and is_binary(phone_number_id) and phone_number_id != "" do
      {:ok, %{token: token, phone_number_id: phone_number_id}}
    else
      {:error, :whatsapp_not_configured}
    end
  end

  @doc "The secret a webhook signature is verified against."
  def app_secret, do: Application.get_env(:blastek, __MODULE__, [])[:app_secret]

  @doc "The token Meta echoes back when verifying the webhook subscription."
  def verify_token, do: Application.get_env(:blastek, __MODULE__, [])[:verify_token]
end
