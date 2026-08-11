defmodule BlastekWeb.WhatsAppWebhookController do
  @moduledoc """
  What Meta tells us after we have sent something (E6-T4 / F0.10).

  Two jobs, both of which arrive at the same URL:

    * **Delivery receipts.** `sent → delivered → read`, or `failed` with a
      reason, keyed by the `wamid` returned when we sent. Without this the send
      log can only say "we handed it over", which is not the same as "it
      arrived" and is exactly the distinction an admin is asking about.
    * **Inbound STOP.** A person replying STOP has withdrawn consent, and the
      only lawful response is to record it before the next message goes out.
      Recognised in French, Arabic and English, because the instruction to
      write it was in one of those.

  ## Verification

  `GET` handles Meta's subscription handshake, echoing `hub.challenge` only when
  `hub.verify_token` matches ours.

  `POST` is verified by `X-Hub-Signature-256`, an HMAC of the **raw** body. That
  requires the unparsed bytes, which Phoenix discards after decoding JSON — so
  `BlastekWeb.RawBodyReader` stashes them during parsing. An unverified webhook
  is an open endpoint for writing to the send log and opting arbitrary numbers
  out of their own reminders.

  Always answers 200. Meta retries anything else with escalating urgency, and a
  payload this endpoint cannot parse will not parse any better in ten minutes.
  """
  use BlastekWeb, :controller

  require Logger

  alias Blastek.Notifications
  alias Blastek.Notifications.Providers.WhatsApp

  @stop_words ~w(stop arret arrêt stopper unsubscribe desabonner désabonner توقف الغاء إلغاء)

  def verify(conn, params) do
    expected = WhatsApp.verify_token()

    if is_binary(expected) and expected != "" and params["hub.verify_token"] == expected do
      conn |> put_resp_content_type("text/plain") |> send_resp(200, params["hub.challenge"] || "")
    else
      send_resp(conn, 403, "")
    end
  end

  def receive(conn, params) do
    if verified?(conn) do
      params |> entries() |> Enum.each(&handle_change/1)
    else
      Logger.warning("whatsapp webhook: bad or missing signature")
    end

    # 200 either way. Telling an unauthenticated caller whether their signature
    # was accepted is a probing oracle, and Meta only needs the acknowledgement.
    json(conn, %{ok: true})
  end

  ## ---------- signature ----------

  defp verified?(conn) do
    secret = WhatsApp.app_secret()
    raw = BlastekWeb.RawBodyReader.raw_body(conn)

    with true <- is_binary(secret) and secret != "",
         true <- is_binary(raw),
         [signature] <- get_req_header(conn, "x-hub-signature-256") do
      expected =
        "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw), case: :lower)

      # Constant-time: a byte-by-byte comparison leaks how much of a forged
      # signature was right, one request at a time.
      Plug.Crypto.secure_compare(signature, expected)
    else
      _ -> false
    end
  end

  ## ---------- payload ----------

  defp entries(%{"entry" => entries}) when is_list(entries) do
    for entry <- entries,
        change <- List.wrap(entry["changes"]),
        value = change["value"],
        is_map(value) do
      value
    end
  end

  defp entries(_), do: []

  defp handle_change(value) do
    Enum.each(List.wrap(value["statuses"]), &handle_status/1)
    Enum.each(List.wrap(value["messages"]), &handle_message/1)
  end

  defp handle_status(%{"id" => id, "status" => status} = payload) do
    case status do
      s when s in ["delivered", "read"] ->
        Notifications.record_receipt(id, "delivered")

      "failed" ->
        Notifications.record_receipt(id, "failed", error_text(payload))

      _ ->
        # `sent` tells us what we already recorded when the API accepted it.
        :ok
    end
  end

  defp handle_status(_), do: :ok

  defp error_text(%{"errors" => [%{"title" => title} | _]}), do: title
  defp error_text(%{"errors" => [error | _]}), do: inspect(error)
  defp error_text(_), do: "delivery failed"

  # An inbound message is only interesting if it is somebody asking to be left
  # alone. Everything else is a conversation this system does not have.
  # Meta reports the sender as bare digits — `212612345678` — while an account
  # holds `+212612345678`. `Notifications.opt_out/3` canonicalizes, so one call
  # withdraws consent for every spelling of the number rather than only the one
  # the person happened to reply from.
  defp handle_message(%{"from" => from, "text" => %{"body" => body}}) do
    if stop?(body), do: Notifications.opt_out(from, "replied STOP", "any")
  end

  defp handle_message(_), do: :ok

  defp stop?(body) do
    normalized = body |> to_string() |> String.trim() |> String.downcase()
    normalized in @stop_words
  end
end
