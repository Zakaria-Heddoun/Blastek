// Account security: the devices signed in, and the password (E3-T7 / F0.2).
//
// "Log out the device I lost" is the reason sessions became server-side rows at
// all, so this list is the visible half of that work.
import { useCallback, useEffect, useState } from 'react';
import { gql } from '../lib/gql';
import { useAuth } from '../lib/auth';
import { useToast } from '../components/ui';

interface Session {
  id: string;
  device: string;
  ip: string;
  lastUsedAt: string;
  current: boolean;
}

const SESSIONS = `{ mySessions { id device ip lastUsedAt current } }`;

export default function AccountSecurity() {
  const { user, refreshMe } = useAuth();
  const toast = useToast();

  const [sessions, setSessions] = useState<Session[] | null>(null);
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const d = await gql<{ mySessions: Session[] }>(SESSIONS);
      setSessions(d.mySessions);
    } catch {
      setSessions([]);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const act = async (work: () => Promise<void>, done: string) => {
    if (busy) return;
    setBusy(true);
    try {
      await work();
      toast(done);
      await load();
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  const revoke = (id: string) =>
    act(async () => {
      await gql(`mutation($id: ID!) { revokeSession(id: $id) }`, { id });
    }, 'Device signed out');

  const revokeOthers = () =>
    act(async () => {
      await gql(`mutation { revokeOtherSessions }`);
    }, 'Other devices signed out');

  const savePassword = () =>
    act(async () => {
      await gql(
        `mutation($currentPassword: String, $password: String!) {
          changePassword(currentPassword: $currentPassword, password: $password) }`,
        // A phone-first account has no current password to prove; the session
        // it is using is the proof.
        { currentPassword: user?.hasPassword ? current : null, password: next },
      );
      setCurrent('');
      setNext('');
      await refreshMe();
    }, 'Password updated');

  const others = (sessions ?? []).filter((s) => !s.current).length;

  return (
    <>
      <h2 className="section-title">Devices</h2>
      <p className="mutetext" style={{ marginTop: 0 }}>
        Signed in on {sessions?.length ?? 0} device{sessions?.length === 1 ? '' : 's'}. Do not
        recognise one? Sign it out — it stops working immediately.
      </p>

      {sessions === null && <div className="empty">Loading…</div>}

      {sessions?.map((session) => (
        <div key={session.id} className="card pad sess-row">
          <div className="grow">
            <b>{session.device}</b>
            {session.current && <span className="sess-current">This device</span>}
            <div className="fainttext">
              {session.ip || 'unknown address'} · last used {relative(session.lastUsedAt)}
            </div>
          </div>
          {!session.current && (
            <button className="btn btn-sm btn-danger" disabled={busy} onClick={() => revoke(session.id)}>
              Sign out
            </button>
          )}
        </div>
      ))}

      {others > 0 && (
        <button className="btn btn-sm" disabled={busy} onClick={revokeOthers}>
          Sign out all other devices
        </button>
      )}

      <h2 className="section-title">Password</h2>
      <p className="mutetext" style={{ marginTop: 0 }}>
        {user?.hasPassword
          ? 'Changing it signs you out of every other device.'
          : 'You sign in with a code. Setting a password is optional — you can keep using codes.'}
      </p>

      <div className="card pad sess-password">
        {user?.hasPassword && (
          <div className="auth-field">
            <label htmlFor="current-password">Current password</label>
            <input
              id="current-password"
              type="password"
              autoComplete="current-password"
              value={current}
              onChange={(e) => setCurrent(e.target.value)}
            />
          </div>
        )}

        <div className="auth-field">
          <label htmlFor="next-password">
            {user?.hasPassword ? 'New password' : 'Password'} — min 8 characters
          </label>
          <input
            id="next-password"
            type="password"
            autoComplete="new-password"
            value={next}
            onChange={(e) => setNext(e.target.value)}
          />
        </div>

        <button
          className="btn btn-primary btn-sm"
          disabled={busy || next.length < 8 || (Boolean(user?.hasPassword) && !current)}
          onClick={savePassword}
        >
          {user?.hasPassword ? 'Change password' : 'Set password'}
        </button>
      </div>
    </>
  );
}

// "3 hours ago" beats a timestamp for recognising your own session — the
// question being answered is "was that me, just now?".
function relative(iso: string) {
  if (!iso) return 'never';
  const seconds = Math.floor((Date.now() - new Date(`${iso}Z`).getTime()) / 1000);

  if (seconds < 90) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)} h ago`;
  return `${Math.floor(seconds / 86_400)} d ago`;
}
