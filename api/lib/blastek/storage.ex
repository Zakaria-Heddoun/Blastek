defmodule Blastek.Storage do
  @moduledoc """
  Object storage for uploaded media (E8-T1 / F0.6).

  Two adapters implement the same contract:

    * `Blastek.Storage.Local` — files under `priv/uploads`, served by the
      endpoint. The default, and what the test suite runs against so the upload
      path is covered without an object store in CI.
    * `Blastek.Storage.S3` — MinIO in dev (see `docker-compose.yml`), any
      S3-compatible bucket in production.

  Uploads are **presigned**: the browser PUTs bytes straight at storage and then
  tells the API to finalize. The app server never proxies image bodies, which is
  the whole point — a 8 MB photo would otherwise occupy a request process for
  the length of a mobile upload.

  The tradeoff is that a presigned PUT accepts whatever the client sends, so
  nothing may trust the upload until `Blastek.Media.finalize_upload/2` has
  fetched it back and made libvips decode it. See `Blastek.Media`.
  """

  @typedoc "Storage key: the object's path within the bucket, no leading slash."
  @type key :: String.t()

  @doc "Stores `body` under `key`."
  @callback put(key, body :: binary, content_type :: String.t()) :: :ok | {:error, term}

  @doc "Reads the object back — used by the variant worker."
  @callback get(key) :: {:ok, binary} | {:error, term}

  @doc "Removes the object. Succeeds if it was already gone."
  @callback delete(key) :: :ok | {:error, term}

  @doc "A URL a browser can GET the object from."
  @callback public_url(key) :: String.t()

  @doc """
  A short-lived URL the browser may PUT `content_type` bytes to.

  Returns the URL plus the headers the client must replay, because a signature
  that covers a header is only valid if the client sends it back verbatim.
  """
  @callback presign_put(key, content_type :: String.t(), expires_in :: pos_integer) ::
              {:ok, %{url: String.t(), headers: %{String.t() => String.t()}}} | {:error, term}

  def adapter, do: Application.get_env(:blastek, :storage_adapter, Blastek.Storage.Local)

  def put(key, body, content_type), do: adapter().put(key, body, content_type)
  def get(key), do: adapter().get(key)
  def delete(key), do: adapter().delete(key)
  def public_url(key), do: adapter().public_url(key)

  def presign_put(key, content_type, expires_in \\ 900),
    do: adapter().presign_put(key, content_type, expires_in)

  @doc """
  Builds a collision-proof storage key.

  The random component matters for more than uniqueness: keys are effectively
  public (they appear in image URLs), so they must not be guessable from the
  venue id and a filename, or one venue could enumerate another's unpublished
  photos.
  """
  def build_key(venue_id, kind, extension) do
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    "venues/#{venue_id}/#{kind}/#{random}#{extension}"
  end

  @doc "Builds an unguessable key for media owned by one user."
  def build_user_key(user_id, kind, extension) do
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    "users/#{user_id}/#{kind}/#{random}#{extension}"
  end

  @doc "Derives the variant's key from the original's, keeping them adjacent."
  def variant_key(key, variant) do
    extension = Path.extname(key)
    base = String.replace_suffix(key, extension, "")
    "#{base}_#{variant}.jpg"
  end
end
