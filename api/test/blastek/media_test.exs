defmodule Blastek.MediaTest do
  @moduledoc """
  Venue photos: the presigned-upload handshake, variant generation, and the
  validation that has to happen because a presigned PUT is unsupervised.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Media
  alias Blastek.Media.Attachment
  alias Blastek.Media.VariantWorker
  alias Blastek.Storage

  setup do
    %{venue: venue} = venue_fixture("Photo Salon")
    %{venue: venue}
  end

  # A real JPEG, not a fixture file: libvips is the validator, so the tests have
  # to hand it bytes it will genuinely accept.
  defp jpeg(width \\ 1200, height \\ 800) do
    {:ok, image} = Image.new(width, height, color: [90, 140, 200])
    {:ok, binary} = Image.write(image, :memory, suffix: ".jpg", quality: 80)
    binary
  end

  # Stands in for the browser's PUT to the presigned URL.
  defp client_uploads(key, body), do: :ok = Storage.put(key, body, "image/jpeg")

  defp upload!(venue, body \\ nil) do
    {:ok, ticket} =
      Media.request_upload(venue.id, %{content_type: "image/jpeg", byte_size: 5_000})

    client_uploads(ticket.attachment.key, body || jpeg())
    {:ok, photo} = Media.finalize_upload(venue.id, ticket.attachment.id)
    photo
  end

  describe "requesting an upload" do
    test "returns a presigned PUT and a pending row", %{venue: venue} do
      assert {:ok, ticket} =
               Media.request_upload(venue.id, %{content_type: "image/jpeg", byte_size: 4_000})

      assert ticket.attachment.status == "pending"
      assert ticket.attachment.venue_id == venue.id
      assert ticket.url =~ "/api/uploads"
      assert ticket.headers["content-type"] == "image/jpeg"
    end

    test "the key is unguessable, so one venue cannot enumerate another's", %{venue: venue} do
      keys =
        for _ <- 1..5 do
          {:ok, ticket} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})
          ticket.attachment.key
        end

      assert length(Enum.uniq(keys)) == 5
      # Scoped to the venue for tidiness, but the filename itself is random.
      assert Enum.all?(keys, &String.starts_with?(&1, "venues/#{venue.id}/"))
      refute Enum.any?(keys, &String.contains?(&1, "photo"))
    end

    test "refuses a type libvips cannot process, before issuing a URL", %{venue: venue} do
      assert {:error, message} =
               Media.request_upload(venue.id, %{content_type: "application/pdf"})

      assert message =~ "JPEG, PNG or WebP"
      # No key was reserved, so nothing to sweep up later.
      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "refuses an oversize file on the browser's own numbers", %{venue: venue} do
      assert {:error, message} =
               Media.request_upload(venue.id, %{
                 content_type: "image/jpeg",
                 byte_size: 40 * 1024 * 1024
               })

      assert message =~ "10 MB"
    end

    test "caps how many photos one venue can keep", %{venue: venue} do
      for _ <- 1..24 do
        {:ok, _} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})
      end

      assert {:error, message} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})
      assert message =~ "up to 24 photos"
    end
  end

  describe "finalizing an upload" do
    test "derives thumb, card and hero", %{venue: venue} do
      photo = upload!(venue)

      assert photo.status == "ready"
      assert photo.width == 1200
      assert photo.height == 800
      assert Map.keys(photo.variants) |> Enum.sort() == ["card", "hero", "thumb"]

      # Every variant is really in storage, and really smaller.
      for {name, key} <- photo.variants do
        assert {:ok, body} = Storage.get(key)
        {:ok, image} = Image.open(body)

        expected = Keyword.fetch!(VariantWorker.variants(), String.to_existing_atom(name))
        assert Image.width(image) == min(expected, 1200)
      end
    end

    test "never upscales a small original", %{venue: venue} do
      photo = upload!(venue, jpeg(320, 200))

      {:ok, hero} = Storage.get(photo.variants["hero"])
      {:ok, image} = Image.open(hero)

      # hero is nominally 1600 wide; a 320px upload must stay 320px.
      assert Image.width(image) == 320
    end

    test "rejects a file that is not an image whatever it claimed to be", %{venue: venue} do
      {:ok, ticket} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})
      # The presigned PUT accepts anything — this is the point of the check.
      Storage.put(ticket.attachment.key, "%PDF-1.7 not really a jpeg", "image/jpeg")

      assert {:error, message} = Media.finalize_upload(venue.id, ticket.attachment.id)
      assert message =~ "not a JPEG, PNG or WebP"

      # Kept as `failed` rather than deleted, so the owner sees what happened.
      assert Repo.get(Attachment, ticket.attachment.id).status == "failed"
    end

    test "reports an upload the browser never completed", %{venue: venue} do
      {:ok, ticket} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})

      assert {:error, message} = Media.finalize_upload(venue.id, ticket.attachment.id)
      assert message =~ "did not complete"
    end

    test "is idempotent, so a double-tapped Done cannot regenerate variants", %{venue: venue} do
      photo = upload!(venue)
      assert {:ok, again} = Media.finalize_upload(venue.id, photo.id)
      assert again.variants == photo.variants
      assert again.updated_at == photo.updated_at
    end

    test "another venue cannot finalize this venue's upload", %{venue: venue} do
      %{venue: other} = venue_fixture("Rival Salon")
      {:ok, ticket} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})

      assert {:error, "Unknown photo."} =
               Media.finalize_upload(other.id, ticket.attachment.id)
    end
  end

  describe "gallery management" do
    test "set_cover moves the cover, leaving exactly one", %{venue: venue} do
      first = upload!(venue)
      second = upload!(venue)

      {:ok, _} = Media.set_cover(venue.id, first.id)
      {:ok, _} = Media.set_cover(venue.id, second.id)

      photos = Media.list_photos(venue.id)
      assert Enum.count(photos, &(&1.kind == "cover")) == 1
      # The cover sorts first regardless of upload order.
      assert hd(photos).id == second.id
    end

    test "list_photos hides anything not ready", %{venue: venue} do
      ready = upload!(venue)
      {:ok, _pending} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})

      assert Enum.map(Media.list_photos(venue.id), & &1.id) == [ready.id]
      # The dashboard still sees both, or a failed upload would vanish.
      assert length(Media.list_all_photos(venue.id)) == 2
    end

    test "reorder_photos applies a display order", %{venue: venue} do
      a = upload!(venue)
      b = upload!(venue)
      c = upload!(venue)

      {:ok, _} = Media.reorder_photos(venue.id, [c.id, a.id, b.id])
      assert Enum.map(Media.list_photos(venue.id), & &1.id) == [c.id, a.id, b.id]
    end

    test "reorder ignores another venue's ids rather than moving them", %{venue: venue} do
      %{venue: other} = venue_fixture("Other Salon")
      mine = upload!(venue)
      theirs = upload!(other)

      {:ok, _} = Media.reorder_photos(venue.id, [theirs.id, mine.id])

      assert Repo.get(Attachment, theirs.id).sort == 0
    end

    test "deleting a photo removes every derived object too", %{venue: venue} do
      photo = upload!(venue)
      keys = [photo.key | Map.values(photo.variants)]

      assert {:ok, _} = Media.delete_photo(venue.id, photo.id)

      assert Repo.get(Attachment, photo.id) == nil
      for key <- keys, do: assert({:error, _} = Storage.get(key))
    end

    test "another venue cannot delete this venue's photo", %{venue: venue} do
      %{venue: other} = venue_fixture("Thief Salon")
      photo = upload!(venue)

      assert {:error, "Unknown photo."} = Media.delete_photo(other.id, photo.id)
      assert Repo.get(Attachment, photo.id)
    end
  end

  describe "abandoned uploads" do
    test "are swept once they are old enough, and finished ones are left alone", %{venue: venue} do
      keeper = upload!(venue)
      {:ok, ticket} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})

      # Nothing is stale yet.
      assert Media.sweep_abandoned(120) == 0

      Repo.update_all(
        from(a in Attachment, where: a.id == ^ticket.attachment.id),
        set: [inserted_at: ~N[2020-01-01 00:00:00]]
      )

      assert Media.sweep_abandoned(120) == 1
      assert Repo.get(Attachment, ticket.attachment.id) == nil
      assert Repo.get(Attachment, keeper.id)
    end
  end

  describe "urls" do
    test "expose every variant plus the original", %{venue: venue} do
      urls = venue |> upload!() |> Media.urls()

      assert urls.original =~ "/uploads/venues/#{venue.id}/"
      assert urls.thumb =~ "_thumb.jpg"
      assert urls.card =~ "_card.jpg"
      assert urls.hero =~ "_hero.jpg"
    end

    test "a pending photo has an original and nothing else", %{venue: venue} do
      {:ok, ticket} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})
      urls = Media.urls(ticket.attachment)

      assert urls.original
      refute Map.has_key?(urls, :card)
    end
  end
end
