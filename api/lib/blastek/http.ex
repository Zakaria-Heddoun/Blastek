defmodule Blastek.HTTP do
  @moduledoc """
  A small wrapper over OTP's `:httpc`, used by the storage adapter and the
  geocoder.

  Deliberately not a dependency: the two callers make a handful of requests
  between them, and the HTTP clients in the ecosystem have a habit of arriving
  with their own advisories attached. `:httpc` ships with OTP and is patched with
  it.

  TLS verification is requested explicitly rather than left to the default,
  which has changed across OTP releases — an unverified HTTPS request to a
  geocoder is a silent downgrade nobody would notice.
  """

  require Logger

  @default_timeout 8_000

  @type response :: %{status: pos_integer, body: binary, headers: [{String.t(), String.t()}]}

  @doc """
  Performs a request.

  `body` is `nil` for methods without one. Any 2xx is `{:ok, response}`; other
  statuses are returned as `{:error, {:status, code, body}}` so callers can tell
  "the service said no" from "the service was unreachable".
  """
  @spec request(atom, String.t(), [{String.t(), String.t()}], binary | nil, keyword) ::
          {:ok, response} | {:error, term}
  def request(method, url, headers \\ [], body \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    request =
      case body do
        nil -> {to_charlist(url), charlist_headers(headers)}
        body -> {to_charlist(url), charlist_headers(headers), to_charlist(content_type), body}
      end

    http_opts = [timeout: timeout, connect_timeout: timeout, ssl: ssl_opts(url)]

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_version, status, _reason}, headers, response_body}}
      when status >= 200 and status < 300 ->
        {:ok, %{status: status, body: response_body, headers: decode_headers(headers)}}

      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:error, {:status, status, response_body}}

      {:error, reason} ->
        Logger.warning("http #{method} #{sanitize(url)} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ssl_opts(url) do
    if String.starts_with?(url, "https://") do
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    else
      []
    end
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp decode_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k) |> String.downcase(), to_string(v)} end)
  end

  # Presigned URLs carry a signature in the query string; it must not reach logs.
  defp sanitize(url), do: url |> String.split("?") |> hd()
end
