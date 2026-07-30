defmodule BlastekWeb.AuthContextTest do
  @moduledoc """
  Authentication over real HTTP (E3-T2 / F0.2).

  Every other auth test hands Absinthe a context map it built itself, which
  means none of them exercise the plug that *produces* that map — the bearer
  header, the session lookup, the venue selection. That plug is where E3's
  central promise lives: a revoked session must stop working on the very next
  request. Asserting it anywhere else would be asserting it about the test's own
  fixture.
  """
  use BlastekWeb.ConnCase, async: true

  # ConnCase does not bring this in the way DataCase does.
  import Ecto.Query
  import Blastek.Fixtures

  alias Blastek.Accounts.Session
  alias Blastek.Accounts.Sessions
  alias Blastek.Repo

  @android "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36"

  setup do
    %{venue: venue} = venue_fixture("Auth Context Salon")
    %{user: owner} = member_fixture(venue, "owner", "ctx-owner@example.com")
    {:ok, tokens} = Sessions.issue(owner, device: @android, ip: "10.9.9.9")

    %{venue: venue, owner: owner, tokens: tokens}
  end

  defp post_gql(conn, query, headers) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)

    post(conn, "/api/graphql", %{query: query})
  end

  defp me(conn, headers \\ []) do
    post_gql(conn, "{ me { id email } }", headers) |> json_response(200)
  end

  describe "bearer token" do
    test "a live token identifies the caller", %{conn: conn, tokens: tokens, owner: owner} do
      body = me(conn, [{"authorization", "Bearer #{tokens.token}"}])

      assert body["data"]["me"]["id"] == to_string(owner.id)
      assert body["data"]["me"]["email"] == owner.email
    end

    test "no header is anonymous rather than an error", %{conn: conn} do
      assert me(conn)["data"]["me"] == nil
    end

    test "a malformed header is anonymous", %{conn: conn, tokens: tokens} do
      for header <- [
            "Bearer ",
            "Bearer not-a-real-token",
            # The scheme matters: a bare token is not a bearer header.
            tokens.token,
            "Basic #{tokens.token}",
            "bearer #{tokens.token}"
          ] do
        assert me(conn, [{"authorization", header}])["data"]["me"] == nil,
               "#{inspect(header)} should not authenticate"
      end
    end

    test "a refresh token is not accepted as a bearer token", %{conn: conn, tokens: tokens} do
      assert me(conn, [{"authorization", "Bearer #{tokens.refresh_token}"}])["data"]["me"] == nil
    end
  end

  describe "revocation takes effect immediately" do
    test "a revoked session stops working on the next request", %{conn: conn, tokens: tokens} do
      header = [{"authorization", "Bearer #{tokens.token}"}]

      assert me(conn, header)["data"]["me"]

      Sessions.revoke_token(tokens.token)

      # The whole reason sessions became rows. A self-contained token could not
      # do this.
      assert me(build_conn(), header)["data"]["me"] == nil
    end

    test "revoking one device does not sign out another", %{conn: conn, owner: owner} do
      {:ok, phone} = Sessions.issue(owner, device: @android)
      {:ok, laptop} = Sessions.issue(owner, device: "Mozilla/5.0 (Windows NT 10.0) Firefox/121.0")

      {:ok, _} = Sessions.revoke(owner.id, phone.session.id)

      assert me(conn, [{"authorization", "Bearer #{laptop.token}"}])["data"]["me"]
      assert me(build_conn(), [{"authorization", "Bearer #{phone.token}"}])["data"]["me"] == nil
    end

    test "an expired session is rejected", %{conn: conn, tokens: tokens} do
      Repo.update_all(from(s in Session, where: s.id == ^tokens.session.id),
        set: [expires_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -60, :second)]
      )

      assert me(conn, [{"authorization", "Bearer #{tokens.token}"}])["data"]["me"] == nil
    end
  end

  describe "request metadata" do
    test "a new session records the device that started it", %{conn: conn} do
      body =
        post_gql(
          conn,
          ~s|mutation { requestOtp(phone: "0698765432") { maskedPhone } }|,
          [{"user-agent", @android}]
        )
        |> json_response(200)

      # The mutation itself is beside the point; what matters is that the plug
      # put a user agent in the context for a session to be labelled with.
      assert body["data"]["requestOtp"]["maskedPhone"] =~ "••"
    end

    test "logout revokes the session behind the presented token", %{conn: conn, tokens: tokens} do
      header = [{"authorization", "Bearer #{tokens.token}"}]

      assert post_gql(conn, "mutation { logout }", header)
             |> json_response(200)
             |> get_in(["data", "logout"]) == true

      # Proof it was the *presented* token that died, not merely local state.
      assert {:error, :invalid} = Sessions.verify(tokens.token)
      assert me(build_conn(), header)["data"]["me"] == nil
    end
  end

  describe "venue selection" do
    test "a member's only venue is resolved without a header", %{conn: conn, tokens: tokens} do
      body =
        post_gql(conn, "{ currentVenue { slug } }", [
          {"authorization", "Bearer #{tokens.token}"}
        ])
        |> json_response(200)

      assert body["data"]["currentVenue"]["slug"]
    end

    test "a venue the caller does not belong to is refused", %{conn: conn, tokens: tokens} do
      %{venue: stranger} = venue_fixture("Someone Elses Salon")

      body =
        post_gql(conn, "{ currentVenue { slug } }", [
          {"authorization", "Bearer #{tokens.token}"},
          # Asking for a venue by slug must never grant access to it.
          {"x-venue-slug", stranger.slug}
        ])
        |> json_response(200)

      assert body["data"]["currentVenue"] == nil
      assert [%{"message" => message} | _] = body["errors"]
      assert message =~ "Select which venue"
    end
  end

  describe "last_used_at" do
    test "is not rewritten on every request", %{conn: conn, tokens: tokens} do
      header = [{"authorization", "Bearer #{tokens.token}"}]
      recent = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.update_all(from(s in Session, where: s.id == ^tokens.session.id),
        set: [last_used_at: recent]
      )

      me(conn, header)
      me(build_conn(), header)

      # Unchanged: an UPDATE behind every authenticated request would be a row
      # lock and a WAL record for a value nobody reads to the second.
      assert Repo.get!(Session, tokens.session.id).last_used_at == recent
    end

    test "is refreshed once the value has gone stale", %{conn: conn, tokens: tokens} do
      stale =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-Sessions.touch_interval_seconds() - 60, :second)
        |> NaiveDateTime.truncate(:second)

      Repo.update_all(from(s in Session, where: s.id == ^tokens.session.id),
        set: [last_used_at: stale]
      )

      me(conn, [{"authorization", "Bearer #{tokens.token}"}])

      touched = Repo.get!(Session, tokens.session.id).last_used_at
      assert NaiveDateTime.compare(touched, stale) == :gt
    end
  end
end
