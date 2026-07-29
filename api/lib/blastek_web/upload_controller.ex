defmodule BlastekWeb.UploadController do
  @moduledoc """
  Receiving end of a presigned PUT for `Blastek.Storage.Local`.

  Only the local adapter needs this: with MinIO or S3 the browser PUTs straight
  at the object store and never touches Phoenix. It exists so the upload flow
  works — and is testable — without an object store running.

  The signed token *is* the authorization. It names the key and the content
  type, so there is nothing to look up and no session to check; a request
  without a valid token cannot address a key at all.
  """
  use BlastekWeb, :controller

  require Logger

  alias Blastek.Storage
  alias Blastek.Storage.Local

  # Slightly above the 10 MB image cap so an oversize upload is rejected by the
  # validator with a clear message rather than by a truncated read.
  @max_body 12 * 1024 * 1024

  def create(conn, params) do
    with {:ok, token} <- fetch_token(params),
         {:ok, %{key: key, content_type: content_type}} <- Local.verify_upload_token(token),
         :ok <- check_content_type(conn, content_type),
         {:ok, body, conn} <- read_all(conn),
         :ok <- Storage.put(key, body, content_type) do
      json(conn, %{ok: true, key: key})
    else
      {:error, :too_large, conn} ->
        fail(conn, 413, "That file is too large.")

      {:error, reason} ->
        fail(conn, 400, message_for(reason))

      {:error, reason, conn} ->
        fail(conn, 400, message_for(reason))
    end
  end

  defp fetch_token(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp fetch_token(_), do: {:error, :missing_token}

  # The signature covers the content type, so a mismatch means the client is not
  # uploading what it asked permission to upload.
  defp check_content_type(conn, expected) do
    case get_req_header(conn, "content-type") do
      [actual | _] ->
        if String.starts_with?(actual, expected), do: :ok, else: {:error, :content_type}

      [] ->
        {:error, :content_type}
    end
  end

  defp read_all(conn, acc \\ []) do
    case read_body(conn, length: @max_body, read_length: 1_000_000) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary([acc, chunk]), conn}

      {:more, chunk, conn} ->
        total = IO.iodata_length([acc, chunk])
        if total > @max_body, do: {:error, :too_large, conn}, else: read_all(conn, [acc, chunk])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fail(conn, status, message) do
    conn |> put_status(status) |> json(%{ok: false, error: message})
  end

  defp message_for(:missing_token), do: "Missing upload token."
  defp message_for(:invalid), do: "That upload link has expired."
  defp message_for(:content_type), do: "Upload content type does not match the signed type."

  defp message_for(reason) do
    Logger.error("upload failed: #{inspect(reason)}")
    "Upload failed."
  end
end
