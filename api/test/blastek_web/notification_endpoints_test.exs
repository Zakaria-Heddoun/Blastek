defmodule BlastekWeb.NotificationEndpointsTest do
  @moduledoc """
  The two HTTP surfaces notifications need (E6-T4, E6-T8 / F0.10): one-tap
  action links, and Meta's webhook.

  Driven through the endpoint rather than the controller, because both are
  defined as much by what the router and the parsers do as by the handler —
  the webhook signature is computed over bytes `Plug.Parsers` would otherwise
  have thrown away.
  """
  use BlastekWeb.ConnCase, async: true

  import Blastek.Fixtures

  alias Blastek.Notifications
  alias Blastek.Notifications.ActionToken
  alias Blastek.Notifications.Providers.WhatsApp
  alias Blastek.Repo
  alias Blastek.Salon

  setup do
    v = venue_fixture("Endpoint Salon #{System.unique_integer([:positive])}")
    %{v: v, appointment: appointment_fixture(v, %{date: Date.add(Date.utc_today(), 4)})}
  end

  describe "one-tap links" do
    test "a cancel link cancels, without anybody signing in", %{conn: conn, appointment: appt} do
      token = ActionToken.sign(appt.id, :cancel)

      assert %{"ok" => true, "status" => "cancelled", "already" => false} =
               conn |> get("/api/a/cancel/#{token}") |> json_response(200)

      assert Repo.get!(Salon.Appointment, appt.id).status == "cancelled"
    end

    test "tapping it twice is not an error", %{conn: conn, appointment: appt} do
      token = ActionToken.sign(appt.id, :cancel)
      get(conn, "/api/a/cancel/#{token}")

      # Link previews and over-eager mail clients fetch URLs. The second visit
      # has to be a no-op rather than a confusing failure.
      assert %{"ok" => true, "already" => true} =
               conn |> get("/api/a/cancel/#{token}") |> json_response(200)
    end

    test "a confirm link confirms", %{conn: conn, v: v, appointment: appt} do
      {:ok, _} = Salon.update_appointment(v.venue.id, appt.id, %{status: "booked"})
      token = ActionToken.sign(appt.id, :confirm)

      assert %{"ok" => true, "status" => "confirmed"} =
               conn |> get("/api/a/confirm/#{token}") |> json_response(200)
    end

    test "a cancel token cannot be replayed as a confirm", %{conn: conn, appointment: appt} do
      cancel_token = ActionToken.sign(appt.id, :cancel)

      # The action in the path is decoration; the token is what authorizes. If
      # the path were trusted, one link would be every link.
      assert %{"ok" => false} =
               conn |> get("/api/a/confirm/#{cancel_token}") |> json_response(200)

      assert Repo.get!(Salon.Appointment, appt.id).status != "confirmed"
    end

    test "a forged or truncated token does nothing", %{conn: conn, appointment: appt} do
      for bad <- ["nonsense", String.slice(ActionToken.sign(appt.id, :cancel), 0, 20)] do
        response = conn |> get("/api/a/cancel/#{bad}") |> json_response(200)
        assert response["ok"] == false
      end

      assert Repo.get!(Salon.Appointment, appt.id).status == "booked"
    end

    test "cancelling through a link notifies the salon, not the customer", %{
      conn: conn,
      v: v,
      appointment: appt
    } do
      member_fixture(v.venue, "owner", "tap-#{System.unique_integer([:positive])}@example.com")
      get(conn, "/api/a/cancel/#{ActionToken.sign(appt.id, :cancel)}")

      templates =
        Notifications.list_log(appointment_id: appt.id)
        |> Enum.map(& &1.template)

      # The person who tapped the link already knows.
      refute "cancelled_by_salon" in templates
    end
  end

  describe "whatsapp webhook verification" do
    test "echoes the challenge when the token matches", %{conn: conn} do
      with_whatsapp_config(fn ->
        response =
          conn
          |> get("/api/webhooks/whatsapp", %{
            "hub.mode" => "subscribe",
            "hub.verify_token" => "test-verify",
            "hub.challenge" => "12345"
          })
          |> response(200)

        assert response == "12345"
      end)
    end

    test "refuses a wrong token", %{conn: conn} do
      with_whatsapp_config(fn ->
        assert conn
               |> get("/api/webhooks/whatsapp", %{
                 "hub.verify_token" => "guessed",
                 "hub.challenge" => "12345"
               })
               |> response(403)
      end)
    end
  end

  describe "whatsapp delivery receipts" do
    test "an unsigned webhook changes nothing", %{conn: conn} do
      {:ok, log} = sent_log()

      body = status_payload(log.provider_message_id, "delivered")

      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/webhooks/whatsapp", Jason.encode!(body))
      |> json_response(200)

      # Answering 200 to an unsigned caller is deliberate — telling them their
      # signature was rejected is a probing oracle — but nothing may change.
      assert Repo.get!(Blastek.Notifications.Notification, log.id).status == "sent"
    end

    test "a correctly signed one promotes the message to delivered", %{conn: conn} do
      {:ok, log} = sent_log()

      with_whatsapp_config(fn ->
        post_signed(conn, status_payload(log.provider_message_id, "delivered"))
      end)

      assert Repo.get!(Blastek.Notifications.Notification, log.id).status == "delivered"
    end

    test "a failure receipt records the reason", %{conn: conn} do
      {:ok, log} = sent_log()

      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "statuses" => [
                    %{
                      "id" => log.provider_message_id,
                      "status" => "failed",
                      "errors" => [%{"title" => "Recipient has no WhatsApp account"}]
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      with_whatsapp_config(fn -> post_signed(conn, payload) end)

      updated = Repo.get!(Blastek.Notifications.Notification, log.id)
      assert updated.status == "failed"
      assert updated.error =~ "no WhatsApp account"
    end

    test "a tampered body is rejected even with a valid-looking signature", %{conn: conn} do
      {:ok, log} = sent_log()

      with_whatsapp_config(fn ->
        real = status_payload(log.provider_message_id, "delivered")
        signature = signature_for(Jason.encode!(real))

        # Signed one payload, sent another.
        tampered = status_payload(log.provider_message_id, "delivered")
        tampered = put_in(tampered, ["entry"], tampered["entry"] ++ [%{"changes" => []}])

        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", signature)
        |> post("/api/webhooks/whatsapp", Jason.encode!(tampered))
        |> json_response(200)
      end)

      assert Repo.get!(Blastek.Notifications.Notification, log.id).status == "sent"
    end
  end

  describe "inbound STOP" do
    test "opts the number out, in any of the three languages", %{conn: conn} do
      for {number, word} <- [
            {"212600111001", "STOP"},
            {"212600111002", "arrêt"},
            {"212600111003", "توقف"}
          ] do
        payload = %{
          "entry" => [
            %{
              "changes" => [
                %{
                  "value" => %{
                    "messages" => [%{"from" => number, "text" => %{"body" => word}}]
                  }
                }
              ]
            }
          ]
        }

        with_whatsapp_config(fn -> post_signed(conn, payload) end)

        assert Notifications.opted_out?("+" <> number),
               "#{word} should have opted #{number} out"
      end
    end

    test "an ordinary reply is not an opt-out", %{conn: conn} do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [%{"from" => "212600111009", "text" => %{"body" => "merci !"}}]
                }
              }
            ]
          }
        ]
      }

      with_whatsapp_config(fn -> post_signed(conn, payload) end)
      refute Notifications.opted_out?("+212600111009")
    end
  end

  ## ---------- helpers ----------

  defp sent_log do
    phone = "+2126#{System.unique_integer([:positive]) |> rem(89_999_999)}"

    {:ok, log} =
      Notifications.send_now(:login, phone, assigns: %{code: "123456"})

    id = "wamid.#{System.unique_integer([:positive])}"
    {:ok, Ecto.Changeset.change(log, provider_message_id: id) |> Repo.update!()}
  end

  defp status_payload(message_id, status) do
    %{
      "entry" => [
        %{
          "changes" => [
            %{"value" => %{"statuses" => [%{"id" => message_id, "status" => status}]}}
          ]
        }
      ]
    }
  end

  # The raw JSON string, not the map: `Phoenix.ConnTest` re-encodes a map and
  # the bytes it produces are not the bytes the signature was computed over —
  # which is the whole reason the endpoint keeps the unparsed body.
  defp post_signed(conn, payload) do
    raw = Jason.encode!(payload)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", signature_for(raw))
    |> post("/api/webhooks/whatsapp", raw)
    |> json_response(200)
  end

  defp signature_for(raw) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, "test-secret", raw), case: :lower)
  end

  # Application env, so this cannot be `async: true` safe on its own — but the
  # values are constant across every test that uses it, so concurrent readers
  # see the same thing rather than each other's.
  defp with_whatsapp_config(fun) do
    previous = Application.get_env(:blastek, WhatsApp)

    Application.put_env(:blastek, WhatsApp,
      app_secret: "test-secret",
      verify_token: "test-verify"
    )

    try do
      fun.()
    after
      if previous, do: Application.put_env(:blastek, WhatsApp, previous)
    end
  end
end
