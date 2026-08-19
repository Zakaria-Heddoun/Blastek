defmodule Blastek.Media do
  @moduledoc """
  Venue photos: the presigned-upload handshake and the gallery read paths
  (E8-T1, E8-T2 / F0.6).

  Uploading is three steps, because the bytes never pass through the API:

      request_upload/2   → a pending row + a presigned PUT URL
      (browser PUTs the file straight at storage)
      finalize_upload/2  → fetch it back, validate it, derive variants

  Splitting it that way is what keeps an 8 MB photo off the app server, and the
  cost is that a `pending` row may never be finalized. That is not an error
  state — `sweep_abandoned/1` reclaims them.

  Nothing trusts the upload until `finalize_upload/2` has made libvips decode
  it; see `Blastek.Media.VariantWorker`.
  """
  import Ecto.Query
  import Blastek.Scope

  alias Blastek.Media.Attachment
  alias Blastek.Media.VariantWorker
  alias Blastek.Repo
  alias Blastek.Storage

  # Enough for a gallery, few enough that one venue cannot fill the bucket.
  @max_photos 24

  @extensions %{"image/jpeg" => ".jpg", "image/png" => ".png", "image/webp" => ".webp"}

  ## ---------- reads ----------

  @doc "A venue's finished photos, cover first, then display order."
  def list_photos(venue_id) do
    Repo.all(
      from a in scope(Attachment, venue_id),
        where: a.status == "ready",
        order_by: [
          asc: fragment("case when ? = 'cover' then 0 else 1 end", a.kind),
          asc: a.sort,
          asc: a.id
        ]
    )
  end

  @doc """
  Every photo of a venue, whatever its status.

  The dashboard read path: a `failed` upload has to stay visible or the owner
  cannot tell a rejected file from one that silently disappeared.
  """
  def list_all_photos(venue_id) do
    Repo.all(
      from a in scope(Attachment, venue_id),
        order_by: [
          asc: fragment("case when ? = 'cover' then 0 else 1 end", a.kind),
          asc: a.sort,
          asc: a.id
        ]
    )
  end

  @doc """
  Photos for many venues at once, as `%{venue_id => [photo]}`.

  A search results page renders a card per venue; resolved per card this would
  be one query per result.
  """
  def photos_for(venue_ids) do
    Repo.all(
      from a in Attachment,
        where: a.venue_id in ^venue_ids and a.status == "ready",
        order_by: [
          asc: fragment("case when ? = 'cover' then 0 else 1 end", a.kind),
          asc: a.sort,
          asc: a.id
        ]
    )
    |> Enum.group_by(& &1.venue_id)
  end

  @doc """
  The URLs a client needs for one photo: every variant plus the original.

  Keys are turned into URLs here rather than stored as URLs, so moving buckets
  or putting a CDN in front does not require rewriting rows.
  """
  def urls(%Attachment{} = photo) do
    variants =
      Map.new(photo.variants, fn {name, key} ->
        {String.to_atom(name), Storage.public_url(key)}
      end)

    Map.merge(%{original: Storage.public_url(photo.key)}, variants)
  end

  @doc "The card-sized URL of a venue's cover photo, or nil when it has none."
  def cover_url(photos) do
    case photos do
      [photo | _] -> urls(photo)[:card] || urls(photo)[:original]
      [] -> nil
    end
  end

  @doc "The small avatar URL for a user, or nil when they have not uploaded one."
  def avatar_url(user_id) do
    case current_avatar(user_id) do
      nil -> nil
      avatar -> urls(avatar)[:thumb] || urls(avatar)[:original]
    end
  end

  ## ---------- upload handshake ----------

  @doc """
  Reserves a key and returns a presigned PUT for the browser.

  Validation happens *before* a URL is issued: handing out upload capability for
  a content type we cannot process just moves the failure later.
  """
  def request_upload(venue_id, attrs) do
    content_type = attrs[:content_type] || attrs["content_type"] || ""
    kind = attrs[:kind] || attrs["kind"] || "gallery"
    byte_size = attrs[:byte_size] || attrs["byte_size"]

    with :ok <- check_type(content_type),
         :ok <- check_declared_size(byte_size),
         :ok <- check_quota(venue_id),
         {:ok, attachment} <- insert_pending(venue_id, kind, content_type),
         {:ok, presigned} <- Storage.presign_put(attachment.key, content_type) do
      {:ok, %{attachment: attachment, url: presigned.url, headers: presigned.headers}}
    end
  end

  @doc """
  Completes an upload: validates the stored bytes and derives the variants.

  Idempotent for already-finished photos so a double-tapped "done" cannot
  regenerate variants or double-count anything.
  """
  def finalize_upload(venue_id, id) do
    case get_scoped(Repo, Attachment, id, venue_id) do
      nil -> {:error, "Unknown photo."}
      %Attachment{status: "ready"} = ready -> {:ok, ready}
      attachment -> VariantWorker.run(attachment)
    end
  end

  @doc "Reserves a user-scoped avatar key and returns its presigned PUT."
  def request_avatar_upload(user_id, attrs) do
    content_type = attrs[:content_type] || attrs["content_type"] || ""
    byte_size = attrs[:byte_size] || attrs["byte_size"]

    with :ok <- check_type(content_type),
         :ok <- check_declared_size(byte_size) do
      discard_avatar_uploads(user_id, ["pending", "failed"])

      with {:ok, attachment} <- insert_pending_avatar(user_id, content_type),
           {:ok, presigned} <- Storage.presign_put(attachment.key, content_type) do
        {:ok, %{attachment: attachment, url: presigned.url, headers: presigned.headers}}
      end
    end
  end

  @doc "Validates an avatar and replaces the previous ready avatar atomically for readers."
  def finalize_avatar_upload(user_id, id) do
    case get_avatar(user_id, id) do
      nil ->
        {:error, "Unknown avatar."}

      %Attachment{status: "ready"} = ready ->
        {:ok, ready}

      attachment ->
        case VariantWorker.run(attachment) do
          {:ok, ready} ->
            discard_other_avatars(user_id, ready.id)
            {:ok, ready}

          other ->
            other
        end
    end
  end

  ## ---------- writes ----------

  @doc "Deletes a photo and every object derived from it."
  def delete_photo(venue_id, id) do
    case get_scoped(Repo, Attachment, id, venue_id) do
      nil ->
        {:error, "Unknown photo."}

      attachment ->
        # Row first: an orphaned object costs storage, whereas a row pointing at
        # a deleted object renders as a broken image.
        {:ok, deleted} = Repo.delete(attachment)
        purge_objects(attachment)
        {:ok, deleted}
    end
  end

  @doc "Deletes a user's avatar and every generated variant."
  def delete_avatar(user_id) do
    avatars = Repo.all(from(a in avatar_scope(user_id)))
    Repo.delete_all(from(a in avatar_scope(user_id)))
    Enum.each(avatars, &purge_objects/1)
    {:ok, avatars != []}
  end

  @doc """
  Makes one photo the venue's cover, demoting whichever held it.

  Exactly one cover per venue is enforced here rather than by a partial unique
  index, because the swap has to be atomic in the other direction too.
  """
  def set_cover(venue_id, id) do
    case get_scoped(Repo, Attachment, id, venue_id) do
      nil ->
        {:error, "Unknown photo."}

      attachment ->
        Repo.transaction(fn ->
          Repo.update_all(
            from(a in scope(Attachment, venue_id), where: a.kind == "cover"),
            set: [kind: "gallery"]
          )

          {:ok, updated} = attachment |> Attachment.changeset(%{kind: "cover"}) |> Repo.update()
          updated
        end)
    end
  end

  @doc "Applies a display order. Ids from another venue are ignored, not an error."
  def reorder_photos(venue_id, ids) do
    Repo.transaction(fn ->
      ids
      |> Enum.with_index()
      |> Enum.each(fn {id, index} ->
        Repo.update_all(
          from(a in scope(Attachment, venue_id), where: a.id == ^id),
          set: [sort: index]
        )
      end)

      list_photos(venue_id)
    end)
  end

  @doc """
  Removes uploads that were reserved but never completed.

  Called by operations rather than on a timer for now; it becomes a scheduled
  job when E6 adds the queue.
  """
  def sweep_abandoned(older_than_minutes \\ 120) do
    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-older_than_minutes * 60, :second)
      |> NaiveDateTime.truncate(:second)

    stale =
      Repo.all(
        from a in Attachment,
          where: a.status in ["pending", "failed"] and a.inserted_at < ^cutoff
      )

    Enum.each(stale, fn attachment ->
      Repo.delete(attachment)
      purge_objects(attachment)
    end)

    length(stale)
  end

  ## ---------- internals ----------

  defp insert_pending(venue_id, kind, content_type) do
    key = Storage.build_key(venue_id, kind, Map.fetch!(@extensions, content_type))

    %Attachment{}
    |> Attachment.changeset(%{
      venue_id: venue_id,
      # A new upload is never the cover; `set_cover/2` is an explicit choice.
      kind: if(kind == "cover", do: "cover", else: "gallery"),
      key: key,
      content_type: content_type,
      status: "pending",
      sort: next_sort(venue_id)
    })
    |> Repo.insert()
  end

  defp insert_pending_avatar(user_id, content_type) do
    key = Storage.build_user_key(user_id, "avatar", Map.fetch!(@extensions, content_type))

    %Attachment{}
    |> Attachment.changeset(%{
      user_id: user_id,
      kind: "avatar",
      key: key,
      content_type: content_type,
      status: "pending"
    })
    |> Repo.insert()
  end

  defp current_avatar(user_id) do
    Repo.one(
      from a in avatar_scope(user_id),
        where: a.status == "ready",
        order_by: [desc: a.id],
        limit: 1
    )
  end

  defp get_avatar(user_id, id) do
    Repo.one(from a in avatar_scope(user_id), where: a.id == ^id)
  end

  defp avatar_scope(user_id) do
    from a in Attachment, where: a.user_id == ^user_id and a.kind == "avatar"
  end

  defp discard_avatar_uploads(user_id, statuses) do
    avatars = Repo.all(from a in avatar_scope(user_id), where: a.status in ^statuses)
    Repo.delete_all(from a in avatar_scope(user_id), where: a.status in ^statuses)
    Enum.each(avatars, &purge_objects/1)
  end

  defp discard_other_avatars(user_id, keep_id) do
    avatars = Repo.all(from a in avatar_scope(user_id), where: a.id != ^keep_id)
    Repo.delete_all(from a in avatar_scope(user_id), where: a.id != ^keep_id)
    Enum.each(avatars, &purge_objects/1)
  end

  defp next_sort(venue_id) do
    Repo.one(from a in scope(Attachment, venue_id), select: coalesce(max(a.sort), -1)) + 1
  end

  defp purge_objects(%Attachment{} = attachment) do
    [attachment.key | Map.values(attachment.variants)]
    |> Enum.each(&Storage.delete/1)
  end

  defp check_type(type) do
    if type in VariantWorker.allowed_types(),
      do: :ok,
      else: {:error, "Photos must be JPEG, PNG or WebP."}
  end

  defp check_declared_size(nil), do: :ok

  defp check_declared_size(bytes) when is_integer(bytes) do
    # An advisory check on the browser's number: the authoritative one runs in
    # the worker, on bytes that actually landed.
    if bytes > VariantWorker.max_bytes(),
      do: {:error, "Images must be smaller than 10 MB."},
      else: :ok
  end

  defp check_declared_size(_), do: :ok

  defp check_quota(venue_id) do
    count = Repo.aggregate(scope(Attachment, venue_id), :count)

    if count >= @max_photos,
      do: {:error, "A venue can keep up to #{@max_photos} photos."},
      else: :ok
  end
end
