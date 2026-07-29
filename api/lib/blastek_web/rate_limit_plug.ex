defmodule BlastekWeb.RateLimitPlug do
  @moduledoc """
  Per-IP request ceiling for the API (E2-T5).

  This is the blunt outer limit that stops a single client saturating the node.
  Credential-guessing is a different problem with a different budget, and is
  handled per-operation by `BlastekWeb.Schema.RateLimitAuth`.

  The client address is taken from the socket, not from `X-Forwarded-For`:
  behind a proxy that header is trivially spoofed, so trusting it would let an
  attacker mint a fresh budget per request. Deployments that terminate TLS at a
  proxy should configure it to rewrite the peer address instead.
  """
  @behaviour Plug
  import Plug.Conn

  alias Blastek.RateLimit

  # 300 requests/minute is far above what the dashboard does while browsing
  # (a page load is a handful of queries) and well below what a scraper wants.
  @limit 300
  @window :timer.minutes(1)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case RateLimit.hit({:ip, client_ip(conn)}, @limit, @window) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", to_string(retry_after))
        |> send_resp(
          429,
          Jason.encode!(%{
            errors: [%{message: "Too many requests. Try again in #{retry_after}s."}]
          })
        )
        |> halt()
    end
  end

  defp client_ip(%Plug.Conn{remote_ip: ip}), do: :inet.ntoa(ip) |> to_string()
end
