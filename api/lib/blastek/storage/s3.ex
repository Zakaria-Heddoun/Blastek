defmodule Blastek.Storage.S3 do
  @moduledoc """
  S3-compatible storage: MinIO in dev (`docker-compose.yml`), any S3 bucket in
  production. Selected by setting `S3_BUCKET` — see `config/runtime.exs`.

  Signing is delegated to `ExAws` rather than hand-rolled: SigV4 is easy to get
  subtly wrong, and a wrong signature fails closed at upload time in a way that
  is tedious to debug.

  Transport, however, is `Blastek.HTTP`. Every operation here is expressible as
  a presigned URL, so the server's own reads and writes take the same signed
  path the browser does — one signing code path to be correct instead of two,
  and no HTTP client dependency.

  MinIO is addressed **path-style** (`host/bucket/key`). Virtual-host style
  needs per-bucket DNS, which a compose service does not have.
  """
  @behaviour Blastek.Storage

  require Logger

  alias Blastek.HTTP

  # Server-side operations are signed for a short window; they are used
  # immediately, never handed out.
  @internal_expiry 60

  @impl true
  def put(key, body, content_type) do
    with {:ok, url} <- presign(:put, key, headers: [{"content-type", content_type}]),
         {:ok, _response} <-
           HTTP.request(:put, url, [], body, content_type: content_type, timeout: 30_000) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key) do
    with {:ok, url} <- presign(:get, key),
         {:ok, %{body: body}} <- HTTP.request(:get, url, [], nil, timeout: 30_000) do
      {:ok, body}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    with {:ok, url} <- presign(:delete, key),
         result <- HTTP.request(:delete, url) do
      case result do
        {:ok, _} -> :ok
        # S3 reports deleting a missing object as 204; a 404 from a
        # non-conforming implementation is the same desired end state.
        {:error, {:status, 404, _}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def public_url(key), do: "#{public_base_url()}/#{bucket()}/#{key}"

  @impl true
  def presign_put(key, content_type, expires_in) do
    # The signature covers the content type, binding the upload to the declared
    # kind; the client must send the identical header back.
    #
    # `public: true` is essential, not a nicety: SigV4 signs the Host header, so
    # a URL signed for the in-cluster address is invalid at the public one — and
    # `minio:9000` does not resolve in a browser at all.
    case presign(:put, key,
           headers: [{"content-type", content_type}],
           expires_in: expires_in,
           public: true
         ) do
      {:ok, url} -> {:ok, %{url: url, headers: %{"content-type" => content_type}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp presign(method, key, opts \\ []) do
    opts
    |> Keyword.get(:public, false)
    |> aws_config()
    |> ExAws.S3.presigned_url(method, bucket(), key,
      expires_in: Keyword.get(opts, :expires_in, @internal_expiry),
      headers: Keyword.get(opts, :headers, []),
      virtual_host: false
    )
  end

  # Two addresses for one bucket: the API reaches MinIO at `minio:9000` inside
  # the compose network, while a browser reaches it at `localhost:9000`. A URL
  # must be signed for whichever host will actually receive the request.
  defp aws_config(false), do: ExAws.Config.new(:s3)

  defp aws_config(true) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(public_base_url())
    ExAws.Config.new(:s3, scheme: "#{scheme}://", host: host, port: port)
  end

  defp config, do: Application.get_env(:blastek, __MODULE__, [])

  defp bucket, do: Keyword.get(config(), :bucket, "blastek-media")

  # Browsers read images from the outside address, which differs from the
  # in-cluster endpoint the API talks to (`minio:9000` vs `localhost:9000`).
  defp public_base_url do
    Keyword.get(config(), :public_base_url) ||
      Keyword.get(config(), :endpoint_url, "http://localhost:9000")
  end
end
