defmodule BlastekWeb.PhotoApiTest do
  @moduledoc """
  Photo mutations through the GraphQL layer.

  `Blastek.MediaTest` covers the context directly, and that is exactly why this
  file exists: the context can be perfectly correct while the schema names a
  field the resolver never returns. The first version of `requestPhotoUpload`
  shipped with `attachment` where the schema declared a non-null `photo`, which
  every context-level test passed straight through — the browser was the first
  thing to notice.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Media
  alias Blastek.Storage
  alias BlastekWeb.Schema

  setup do
    %{venue: venue} = venue_fixture("Api Photo Salon")
    %{user: owner} = member_fixture(venue, "owner", "owner@apiphoto.ma")
    %{user: staffer} = member_fixture(venue, "staff", "staff@apiphoto.ma")

    context = fn user ->
      %{
        current_user: user,
        current_venue: venue,
        venue_id: venue.id,
        membership: Blastek.Venues.get_membership(user.id, venue.id),
        memberships: Blastek.Venues.list_memberships(user.id)
      }
    end

    %{venue: venue, owner: owner, staffer: staffer, context: context}
  end

  defp run(query, context), do: Absinthe.run(query, Schema, context: context)

  defp error_message({:ok, %{errors: [%{message: message} | _]}}), do: message

  defp jpeg do
    {:ok, image} = Image.new(600, 400, color: [30, 60, 90])
    {:ok, binary} = Image.write(image, :memory, suffix: ".jpg", quality: 80)
    binary
  end

  describe "requestPhotoUpload" do
    test "returns a ticket whose every declared field is populated", %{
      owner: owner,
      context: context
    } do
      assert {:ok, %{data: %{"requestPhotoUpload" => ticket}}} =
               run(
                 """
                 mutation {
                   requestPhotoUpload(contentType: "image/jpeg", byteSize: 4000) {
                     url
                     headers { name value }
                     photo { id status kind }
                   }
                 }
                 """,
                 context.(owner)
               )

      # The regression this file exists for: `photo` is non-null in the schema,
      # so a resolver returning the context's own key name fails here.
      assert %{"id" => id, "status" => "pending", "kind" => "gallery"} = ticket["photo"]
      assert is_binary(id)
      assert ticket["url"] =~ "/api/uploads"
      assert %{"name" => "content-type", "value" => "image/jpeg"} in ticket["headers"]
    end

    test "rejects a type we cannot process", %{owner: owner, context: context} do
      result =
        run(
          ~s|mutation { requestPhotoUpload(contentType: "application/pdf") { url } }|,
          context.(owner)
        )

      assert error_message(result) =~ "JPEG, PNG or WebP"
    end

    test "a staff member cannot upload photos", %{staffer: staffer, context: context} do
      result =
        run(
          ~s|mutation { requestPhotoUpload(contentType: "image/jpeg") { url } }|,
          context.(staffer)
        )

      assert error_message(result) =~ "Your role does not allow this action."
    end
  end

  describe "finalizePhotoUpload" do
    test "returns the photo with variant URLs a client can render", %{
      venue: venue,
      owner: owner,
      context: context
    } do
      {:ok, ticket} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})
      :ok = Storage.put(ticket.attachment.key, jpeg(), "image/jpeg")

      assert {:ok, %{data: %{"finalizePhotoUpload" => photo}}} =
               run(
                 """
                 mutation {
                   finalizePhotoUpload(id: "#{ticket.attachment.id}") {
                     status width height
                     urls { original thumb card hero }
                   }
                 }
                 """,
                 context.(owner)
               )

      assert photo["status"] == "ready"
      assert photo["width"] == 600
      assert photo["height"] == 400

      # Every size the gallery and the result cards ask for must be present, or
      # the UI renders a broken image.
      for size <- ~w(original thumb card hero) do
        assert is_binary(photo["urls"][size]), "missing #{size} URL"
      end
    end

    test "reports a file that is not an image", %{venue: venue, owner: owner, context: context} do
      {:ok, ticket} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})
      :ok = Storage.put(ticket.attachment.key, "definitely not a jpeg", "image/jpeg")

      result =
        run(
          ~s|mutation { finalizePhotoUpload(id: "#{ticket.attachment.id}") { status } }|,
          context.(owner)
        )

      assert error_message(result) =~ "not a JPEG, PNG or WebP"
    end
  end

  describe "gallery mutations" do
    setup %{venue: venue} do
      photos =
        for _ <- 1..2 do
          {:ok, ticket} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})
          :ok = Storage.put(ticket.attachment.key, jpeg(), "image/jpeg")
          {:ok, photo} = Media.finalize_upload(venue.id, ticket.attachment.id)
          photo
        end

      %{photos: photos}
    end

    test "setCoverPhoto promotes one photo", %{
      owner: owner,
      context: context,
      photos: [_, second]
    } do
      assert {:ok, %{data: %{"setCoverPhoto" => %{"kind" => "cover"}}}} =
               run(
                 ~s|mutation { setCoverPhoto(id: "#{second.id}") { kind } }|,
                 context.(owner)
               )
    end

    test "reorderPhotos returns the new order", %{
      owner: owner,
      context: context,
      photos: [first, second]
    } do
      assert {:ok, %{data: %{"reorderPhotos" => ordered}}} =
               run(
                 ~s|mutation { reorderPhotos(ids: ["#{second.id}", "#{first.id}"]) { id } }|,
                 context.(owner)
               )

      assert Enum.map(ordered, & &1["id"]) == [to_string(second.id), to_string(first.id)]
    end

    test "deletePhoto removes it from the public gallery", %{
      venue: venue,
      owner: owner,
      context: context,
      photos: [first | _]
    } do
      assert {:ok, %{data: %{"deletePhoto" => _}}} =
               run(~s|mutation { deletePhoto(id: "#{first.id}") { id } }|, context.(owner))

      refute first.id in Enum.map(Media.list_photos(venue.id), & &1.id)
    end
  end

  describe "venue location" do
    test "setVenueLocation places the pin", %{owner: owner, context: context} do
      assert {:ok, %{data: %{"setVenueLocation" => venue}}} =
               run(
                 ~s|mutation { setVenueLocation(lat: 33.5883, lng: -7.6329) { lat lng } }|,
                 context.(owner)
               )

      assert venue["lat"] == 33.5883
      assert venue["lng"] == -7.6329
    end

    test "setVenueWomenOnly flips the search filter flag", %{owner: owner, context: context} do
      assert {:ok, %{data: %{"setVenueWomenOnly" => %{"womenOnly" => true}}}} =
               run(
                 ~s|mutation { setVenueWomenOnly(value: true) { womenOnly } }|,
                 context.(owner)
               )
    end

    test "a staff member cannot move the pin", %{staffer: staffer, context: context} do
      result =
        run(
          ~s|mutation { setVenueLocation(lat: 0.0, lng: 0.0) { lat } }|,
          context.(staffer)
        )

      assert error_message(result) =~ "Your role does not allow this action."
    end
  end

  describe "venuePhotos" do
    test "shows processing and rejected uploads the public gallery hides", %{
      venue: venue,
      owner: owner,
      context: context
    } do
      {:ok, _pending} = Media.request_upload(venue.id, %{content_type: "image/jpeg"})

      assert {:ok, %{data: %{"venuePhotos" => photos}}} =
               run("{ venuePhotos { id status } }", context.(owner))

      assert Enum.any?(photos, &(&1["status"] == "pending"))
    end
  end
end
