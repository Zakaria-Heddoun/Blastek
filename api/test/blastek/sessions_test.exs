defmodule Blastek.SessionsTest do
  @moduledoc """
  Server-side sessions (E3-T2 / F0.2).

  The point of this module is that a session can be *taken away*, so most of
  these tests are about a token that used to work and now must not.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Accounts
  alias Blastek.Accounts.Session
  alias Blastek.Accounts.Sessions

  setup do
    %{user: user_fixture("sessions@example.com")}
  end

  describe "issue/2" do
    test "returns a usable pair and stores neither", %{user: user} do
      assert {:ok, tokens} = Sessions.issue(user, device: "Chrome on Android", ip: "10.0.0.1")

      assert is_binary(tokens.token)
      assert is_binary(tokens.refresh_token)
      assert tokens.token != tokens.refresh_token

      # The raw tokens must not be recoverable from the database — that is the
      # property that makes a leaked dump useless.
      stored = Repo.get!(Session, tokens.session.id)
      refute stored.token_hash == tokens.token
      refute to_string(stored.token_hash) =~ tokens.token
      assert stored.token_hash == :crypto.hash(:sha256, tokens.token)
    end

    test "tokens are unique across sessions", %{user: user} do
      tokens = for _ <- 1..10, do: elem(Sessions.issue(user), 1).token
      assert length(Enum.uniq(tokens)) == 10
    end

    test "records the device and expiry windows", %{user: user} do
      {:ok, tokens} = Sessions.issue(user, device: "Safari on iOS")

      assert tokens.session.device == "Safari on iOS"
      # 24h access, 60d refresh.
      assert_in_delta NaiveDateTime.diff(tokens.session.expires_at, NaiveDateTime.utc_now()),
                      Sessions.access_ttl_seconds(),
                      5

      assert_in_delta NaiveDateTime.diff(
                        tokens.session.refresh_expires_at,
                        NaiveDateTime.utc_now()
                      ),
                      Sessions.refresh_ttl_seconds(),
                      5
    end

    test "an absurd user agent cannot overflow the column", %{user: user} do
      {:ok, tokens} = Sessions.issue(user, device: String.duplicate("x", 5_000))
      assert String.length(tokens.session.device) <= 180
    end
  end

  describe "verify/1" do
    test "resolves a token to its user", %{user: user} do
      {:ok, tokens} = Sessions.issue(user)

      assert {:ok, found, session} = Sessions.verify(tokens.token)
      assert found.id == user.id
      assert session.id == tokens.session.id
    end

    test "refuses nonsense", %{user: user} do
      {:ok, tokens} = Sessions.issue(user)

      assert {:error, :invalid} = Sessions.verify("not-a-token")
      assert {:error, :invalid} = Sessions.verify("")
      assert {:error, :invalid} = Sessions.verify(nil)
      # A near-miss must not pass either.
      assert {:error, :invalid} = Sessions.verify(tokens.token <> "x")
    end

    test "refuses a revoked session — the whole reason this table exists", %{user: user} do
      {:ok, tokens} = Sessions.issue(user)
      assert {:ok, _, _} = Sessions.verify(tokens.token)

      Sessions.revoke_token(tokens.token)

      assert {:error, :invalid} = Sessions.verify(tokens.token)
    end

    test "refuses an expired session", %{user: user} do
      {:ok, tokens} = Sessions.issue(user)
      expire(tokens.session, :expires_at, -60)

      assert {:error, :invalid} = Sessions.verify(tokens.token)
    end

    test "a refresh token is not an access token", %{user: user} do
      {:ok, tokens} = Sessions.issue(user)
      assert {:error, :invalid} = Sessions.verify(tokens.refresh_token)
    end

    test "records that the session was used", %{user: user} do
      {:ok, tokens} = Sessions.issue(user)

      Repo.update_all(from(s in Session, where: s.id == ^tokens.session.id),
        set: [last_used_at: ~N[2020-01-01 00:00:00]]
      )

      {:ok, _, _} = Sessions.verify(tokens.token)

      touched = Repo.get!(Session, tokens.session.id).last_used_at
      assert NaiveDateTime.compare(touched, ~N[2020-01-02 00:00:00]) == :gt
    end
  end

  describe "refresh/2" do
    test "issues a new pair and retires the old one", %{user: user} do
      {:ok, first} = Sessions.issue(user)
      assert {:ok, second} = Sessions.refresh(first.refresh_token)

      assert second.token != first.token
      assert second.refresh_token != first.refresh_token
      # Same session, rotated — not a new device.
      assert second.session.id == first.session.id

      assert {:ok, _, _} = Sessions.verify(second.token)
      assert {:error, :invalid} = Sessions.verify(first.token)
    end

    test "reusing a rotated refresh token kills the session", %{user: user} do
      {:ok, first} = Sessions.issue(user)
      {:ok, second} = Sessions.refresh(first.refresh_token)

      # The old refresh token no longer matches any row, so it is simply invalid.
      assert {:error, :invalid} = Sessions.refresh(first.refresh_token)

      # And the live one still works, because nothing suspicious has happened.
      assert {:ok, _, _} = Sessions.verify(second.token)
    end

    test "a refresh token captured from a revoked session is treated as theft", %{user: user} do
      {:ok, tokens} = Sessions.issue(user)
      Sessions.revoke_token(tokens.token)

      assert {:error, :reused} = Sessions.refresh(tokens.refresh_token)
      assert {:error, :invalid} = Sessions.verify(tokens.token)
    end

    test "refuses an expired refresh token", %{user: user} do
      {:ok, tokens} = Sessions.issue(user)
      expire(tokens.session, :refresh_expires_at, -60)

      assert {:error, :invalid} = Sessions.refresh(tokens.refresh_token)
    end

    test "rolls the refresh window forward so an active device is not logged out", %{user: user} do
      {:ok, first} = Sessions.issue(user)

      Repo.update_all(from(s in Session, where: s.id == ^first.session.id),
        set: [refresh_expires_at: NaiveDateTime.add(NaiveDateTime.utc_now(), 60, :second)]
      )

      {:ok, second} = Sessions.refresh(first.refresh_token)

      assert NaiveDateTime.diff(second.session.refresh_expires_at, NaiveDateTime.utc_now()) >
               Sessions.refresh_ttl_seconds() - 60
    end
  end

  describe "listing and revoking" do
    test "lists live sessions only", %{user: user} do
      {:ok, live} = Sessions.issue(user, device: "Chrome on Windows")
      {:ok, revoked} = Sessions.issue(user, device: "Firefox on Linux")
      Sessions.revoke_token(revoked.token)

      ids = Sessions.list_for_user(user.id) |> Enum.map(& &1.id)
      assert ids == [live.session.id]
    end

    test "one user cannot revoke another's session", %{user: user} do
      stranger = user_fixture("stranger@example.com")
      {:ok, theirs} = Sessions.issue(stranger)

      assert {:error, "Unknown session."} = Sessions.revoke(user.id, theirs.session.id)
      # Still working, because that attempt did nothing.
      assert {:ok, _, _} = Sessions.verify(theirs.token)
    end

    test "revoke_all clears every session", %{user: user} do
      tokens = for _ <- 1..3, do: elem(Sessions.issue(user), 1)

      assert Sessions.revoke_all(user.id) == 3
      for t <- tokens, do: assert({:error, :invalid} = Sessions.verify(t.token))
    end

    test "revoke_all can spare the current session — \"log out my other devices\"", %{user: user} do
      {:ok, keep} = Sessions.issue(user)
      {:ok, drop} = Sessions.issue(user)

      assert Sessions.revoke_all(user.id, except: keep.session.id) == 1

      assert {:ok, _, _} = Sessions.verify(keep.token)
      assert {:error, :invalid} = Sessions.verify(drop.token)
    end

    test "revoking an already-revoked token is not an error", %{user: user} do
      {:ok, tokens} = Sessions.issue(user)
      assert Sessions.revoke_token(tokens.token) == :ok
      assert Sessions.revoke_token(tokens.token) == :ok
      assert Sessions.revoke_token("never-existed") == :ok
    end
  end

  describe "describe/1" do
    test "turns a user agent into something a human recognises" do
      android =
        "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) " <>
          "Chrome/120.0 Mobile Safari/537.36"

      assert Sessions.describe(android) == "Chrome on Android"

      iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Version/17.0 Safari/605.1"
      assert Sessions.describe(iphone) == "Safari on iOS"

      edge = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0 Safari/537.36 Edg/120.0"
      assert Sessions.describe(edge) == "Edge on Windows"
    end

    test "never fails on something it does not recognise" do
      assert Sessions.describe("") == "Unknown device"
      assert Sessions.describe(nil) == "Unknown device"
      assert is_binary(Sessions.describe("curl/8.4.0"))
    end
  end

  describe "integration with Accounts" do
    test "verify_token returns the user and session", %{user: user} do
      {:ok, tokens} = Accounts.start_session(user, device: "Chrome on Android")

      assert {:ok, found, session} = Accounts.verify_token(tokens.token)
      assert found.id == user.id
      assert session.device == "Chrome on Android"
    end

    test "purge_expired removes only long-dead sessions", %{user: user} do
      {:ok, live} = Sessions.issue(user)
      {:ok, ancient} = Sessions.issue(user)

      Repo.update_all(from(s in Session, where: s.id == ^ancient.session.id),
        set: [refresh_expires_at: ~N[2020-01-01 00:00:00]]
      )

      assert Sessions.purge_expired(90) == 1
      assert Repo.get(Session, live.session.id)
      refute Repo.get(Session, ancient.session.id)
    end
  end

  defp expire(session, field, seconds) do
    Repo.update_all(from(s in Session, where: s.id == ^session.id),
      set: [{field, NaiveDateTime.add(NaiveDateTime.utc_now(), seconds, :second)}]
    )
  end
end
