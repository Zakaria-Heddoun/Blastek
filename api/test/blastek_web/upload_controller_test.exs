defmodule BlastekWeb.UploadControllerTest do
  @moduledoc """
  The receiving end of a presigned PUT, for the local storage adapter.

  Worth testing over HTTP rather than through the context: the whole security
  property is that the signed token — not a session — decides which key a request
  may write, and that only shows up at the transport boundary.
  """
  use BlastekWeb.ConnCase, async: true

  import Blastek.Fixtures

  alias Blastek.Media
  alias Blastek.Storage
  alias Blastek.Storage.Local

  setup do
    %{venue: venue} = venue_fixture("Upload Salon")

    {:ok, ticket} =
      Media.request_upload(venue.id, %{content_type: "image/jpeg", byte_size: 2_000})

    %{venue: venue, ticket: ticket, token: token_from(ticket.url)}
  end

  defp token_from(url) do
    %URI{query: query} = URI.parse(url)
    URI.decode_query(query) |> Map.fetch!("token")
  end

  defp put_bytes(conn, token, body, content_type \\ "image/jpeg") do
    conn
    |> put_req_header("content-type", content_type)
    |> put("/api/uploads?token=#{token}", body)
  end

  defp jpeg do
    {:ok, image} = Image.new(80, 60, color: [10, 20, 30])
    {:ok, binary} = Image.write(image, :memory, suffix: ".jpg", quality: 70)
    binary
  end

  test "stores the bytes at the signed key", %{conn: conn, token: token, ticket: ticket} do
    body = jpeg()

    assert %{"ok" => true, "key" => key} =
             conn |> put_bytes(token, body) |> json_response(200)

    assert key == ticket.attachment.key
    assert {:ok, ^body} = Storage.get(key)
  end

  test "rejects a request with no token", %{conn: conn} do
    assert %{"error" => message} =
             conn
             |> put_req_header("content-type", "image/jpeg")
             |> put("/api/uploads", jpeg())
             |> json_response(400)

    assert message =~ "Missing upload token"
  end

  test "rejects a forged token", %{conn: conn} do
    assert %{"error" => message} =
             conn |> put_bytes("not-a-real-token", jpeg()) |> json_response(400)

    assert message =~ "expired"
  end

  test "rejects a token whose window has passed", %{ticket: ticket} do
    # Verified with a zero lifetime: the signature is intact, the clock is not.
    assert {:error, :invalid} = Local.verify_upload_token(token_from(ticket.url), -1)
  end

  test "rejects bytes whose type differs from the signed one", %{conn: conn, token: token} do
    assert %{"error" => message} =
             conn |> put_bytes(token, "GIF89a", "image/gif") |> json_response(400)

    assert message =~ "does not match the signed type"
  end

  test "a token cannot be redirected at another key", %{conn: conn, token: token, ticket: ticket} do
    # The key lives inside the signed payload, so the query string cannot move it.
    conn
    |> put_bytes(token <> "", jpeg())
    |> json_response(200)

    assert {:ok, _} = Storage.get(ticket.attachment.key)
    assert {:error, _} = Storage.get("venues/999999/gallery/forged.jpg")
  end

  test "the stored bytes then finalize into variants", %{
    conn: conn,
    token: token,
    venue: venue,
    ticket: ticket
  } do
    conn |> put_bytes(token, jpeg()) |> json_response(200)

    assert {:ok, photo} = Media.finalize_upload(venue.id, ticket.attachment.id)
    assert photo.status == "ready"
    assert Map.keys(photo.variants) |> Enum.sort() == ["card", "hero", "thumb"]
  end
end
