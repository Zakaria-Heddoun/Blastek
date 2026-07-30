defmodule Blastek.Repo.Migrations.SessionRefreshHistory do
  @moduledoc """
  Remembers the refresh token a session just rotated away from, so that reusing
  it can actually be detected.

  ## The gap this closes

  `sessions.refresh_hash` is overwritten on every rotation. That means a refresh
  token captured before a rotation matches **no row at all** afterwards, and the
  server can only answer "invalid" — indistinguishable from a random string.
  Reuse detection was documented but not implemented: rotation alone just means
  a thief has to be quick.

  Keeping the immediately-previous hash turns that silence into a signal. A
  request presenting it proves two parties hold tokens from the same session —
  the real device and someone else — and since there is no way to tell which one
  is calling, the safe answer is to end the session and make both sign in again.
  Only the attacker will fail to.

  One generation is enough. A legitimate client never replays the previous token
  (it discards it on success), so a single slot separates "stale by one
  rotation", which is the theft signal, from "ancient", which is just noise.
  """
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :previous_refresh_hash, :binary
    end

    # Looked up on every refresh, in the same shape as `refresh_hash`. Not
    # unique: the value is transient and is cleared when the session ends.
    create index(:sessions, [:previous_refresh_hash])
  end
end
