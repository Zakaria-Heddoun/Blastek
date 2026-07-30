defmodule BlastekWeb.RawBodyReader do
  @moduledoc """
  Keeps the unparsed request body for signature verification (E6-T4 / F0.10).

  A webhook signature is an HMAC of the **exact bytes** that were sent. Decoding
  JSON and re-encoding it does not reproduce them — key order, whitespace and
  number formatting all change — so the signature must be checked against the
  original, and Phoenix has already thrown it away by the time a controller
  runs.

  `Plug.Parsers` offers a `:body_reader` hook for exactly this. The body is
  stashed in `conn.assigns` and only for the endpoints that need it: holding
  every uploaded image in memory a second time would be a memory leak with a
  security rationale.
  """

  @assign :raw_body

  # Only these paths keep their raw body. Everything else is read and dropped as
  # usual.
  @signed_paths ["/api/webhooks/whatsapp"]

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, stash(conn, body)}
      {:more, body, conn} -> {:more, body, stash(conn, body)}
      other -> other
    end
  end

  defp stash(conn, body) do
    if conn.request_path in @signed_paths do
      Plug.Conn.assign(conn, @assign, body)
    else
      conn
    end
  end

  @doc "The raw body, if this request was one of the signed endpoints."
  def raw_body(conn), do: conn.assigns[@assign]
end
