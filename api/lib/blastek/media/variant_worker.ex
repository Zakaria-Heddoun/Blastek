defmodule Blastek.Media.VariantWorker do
  @moduledoc """
  Derives the display variants of an uploaded image (E8-T2 / F0.6).

  Three widths, each with a job to do:

    * `thumb` (240) — search-result cards, many per screen
    * `card`  (640) — venue page gallery tiles
    * `hero`  (1600) — the lightbox / full-width header

  Serving the original instead is how a listing page ends up shipping 40 MB of
  phone photos over a Moroccan 4G connection.

  Two deliberate properties:

    * **Never upscales.** The target width is `min(original, spec)`, so a small
      upload yields three small files rather than three blurry big ones.
    * **Strips metadata.** Phone photos carry EXIF GPS. Re-encoding through
      libvips drops it, which matters because these URLs are public — a home-
      based salon would otherwise publish its owner's coordinates.

  Runs synchronously inside `Blastek.Media.finalize_upload/2`: libvips takes
  tens of milliseconds and the person who just picked a photo is waiting to see
  it. The module is kept separate and side-effect-free at the boundary so it
  becomes an Oban job unchanged when E6 adds the queue.
  """

  require Logger

  alias Blastek.Media.Attachment
  alias Blastek.Repo
  alias Blastek.Storage

  @variants [thumb: 240, card: 640, hero: 1600]

  # libvips decodes these; anything else is rejected before a key is issued.
  @allowed_types ~w(image/jpeg image/png image/webp)

  @max_bytes 10 * 1024 * 1024
  # A 20k-pixel-wide "image" is a decompression bomb, not a salon photo.
  @max_dimension 12_000

  def variants, do: @variants
  def allowed_types, do: @allowed_types
  def max_bytes, do: @max_bytes

  @doc """
  Validates the uploaded original and writes its variants.

  Returns the updated attachment, or marks it `failed` and returns an error. A
  failure is expected traffic, not an exception: a presigned PUT lets the client
  upload a PDF renamed to `.jpg`, and this is where that is caught.
  """
  def run(%Attachment{} = attachment) do
    with {:ok, body} <- fetch(attachment),
         :ok <- check_size(body),
         {:ok, image} <- decode(body),
         :ok <- check_dimensions(image),
         {:ok, variant_keys} <- write_variants(attachment, image) do
      attachment
      |> Attachment.changeset(%{
        status: "ready",
        byte_size: byte_size(body),
        width: Image.width(image),
        height: Image.height(image),
        variants: variant_keys
      })
      |> Repo.update()
    else
      {:error, reason} ->
        Logger.warning("variant generation failed for #{attachment.key}: #{inspect(reason)}")
        mark_failed(attachment)
        {:error, message_for(reason)}
    end
  end

  defp fetch(attachment) do
    case Storage.get(attachment.key) do
      {:ok, body} -> {:ok, body}
      # Almost always the client never completed its PUT.
      {:error, _} -> {:error, :not_uploaded}
    end
  end

  defp check_size(body) when byte_size(body) == 0, do: {:error, :empty}
  defp check_size(body) when byte_size(body) > @max_bytes, do: {:error, :too_large}
  defp check_size(_body), do: :ok

  # The real content check: the bytes are an image only if libvips can open
  # them, regardless of what the upload claimed.
  defp decode(body) do
    case Image.open(body) do
      {:ok, image} -> {:ok, image}
      {:error, _} -> {:error, :not_an_image}
    end
  end

  defp check_dimensions(image) do
    if Image.width(image) > @max_dimension or Image.height(image) > @max_dimension,
      do: {:error, :dimensions},
      else: :ok
  end

  defp write_variants(attachment, image) do
    Enum.reduce_while(@variants, {:ok, %{}}, fn {name, width}, {:ok, acc} ->
      case write_variant(attachment, image, name, width) do
        {:ok, key} -> {:cont, {:ok, Map.put(acc, to_string(name), key)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_variant(attachment, image, name, width) do
    key = Storage.variant_key(attachment.key, name)
    target = min(width, Image.width(image))

    with {:ok, resized} <- Image.thumbnail(image, target),
         {:ok, body} <- Image.write(resized, :memory, suffix: ".jpg", quality: 82),
         :ok <- Storage.put(key, body, "image/jpeg") do
      {:ok, key}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_failed(attachment) do
    attachment |> Attachment.changeset(%{status: "failed"}) |> Repo.update()
  end

  defp message_for(:not_uploaded), do: "The upload did not complete. Please try again."
  defp message_for(:empty), do: "That file is empty."
  defp message_for(:too_large), do: "Images must be smaller than 10 MB."
  defp message_for(:not_an_image), do: "That file is not a JPEG, PNG or WebP image."
  defp message_for(:dimensions), do: "That image is too large to process."
  defp message_for(_), do: "We could not process that image."
end
