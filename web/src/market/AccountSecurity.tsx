// Account security: the devices signed in, and the password (E3-T7 / F0.2).
//
// "Log out the device I lost" is the reason sessions became server-side rows at
// all, so this list is the visible half of that work.
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
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
  const { t } = useTranslation();
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
    }, t('account.deviceSignedOut'));

  const revokeOthers = () =>
    act(async () => {
      await gql(`mutation { revokeOtherSessions }`);
    }, t('account.othersSignedOut'));

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
    }, t('account.passwordUpdated'));

  const others = (sessions ?? []).filter((s) => !s.current).length;

  return (
    <>
      <h2 className="section-title">{t(`account.devices`)}</h2>
      <p className="mutetext" style={{ marginTop: 0 }}>
        {t('account.devicesLead', { count: sessions?.length ?? 0 })}
      </p>

      {sessions === null && <div className="empty">{t(`common.loading`)}</div>}

      {sessions?.map((session) => (
        <div key={session.id} className="card pad sess-row">
          <div className="grow">
            <b>{session.device}</b>
            {session.current && <span className="sess-current">{t(`account.thisDevice`)}</span>}
            <div className="fainttext">
              {session.ip || t('account.unknownAddress')} ·{' '}
              {t('account.lastUsed', { when: relative(session.lastUsedAt, t) })}
            </div>
          </div>
          {!session.current && (
            <button className="btn btn-sm btn-danger" disabled={busy} onClick={() => revoke(session.id)}>
              {t(`common.signOut`)}
            </button>
          )}
        </div>
      ))}

      {others > 0 && (
        <button className="btn btn-sm" disabled={busy} onClick={revokeOthers}>
          {t(`account.signOutAll`)}
        </button>
      )}

      <h2 className="section-title">{t(`account.passwordSection`)}</h2>
      <p className="mutetext" style={{ marginTop: 0 }}>
        {user?.hasPassword
          ? t('account.changeSignsOut')
          : t('account.codeUserHint')}
      </p>

      <div className="card pad sess-password">
        {user?.hasPassword && (
          <div className="auth-field">
            <label htmlFor="current-password">{t(`account.currentPassword`)}</label>
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
            {user?.hasPassword ? t('auth.newPasswordLabel') : t('common.password')}
            {' · '}{t('account.passwordMinimum')}
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
          {user?.hasPassword ? t('account.changePassword') : t('account.setPassword')}
        </button>
      </div>
    </>
  );
}

// "3 hours ago" beats a timestamp for recognising your own session — the
// question being answered is "was that me, just now?".
function relative(iso: string, t: (key: string, options?: Record<string, unknown>) => string) {
  if (!iso) return t('account.never');
  const seconds = Math.floor((Date.now() - new Date(`${iso}Z`).getTime()) / 1000);

  if (seconds < 90) return t('account.justNow');
  if (seconds < 3600) return t('account.minutesAgo', { count: Math.floor(seconds / 60) });
  if (seconds < 86_400) return t('account.hoursAgo', { count: Math.floor(seconds / 3600) });
  return t('account.daysAgo', { count: Math.floor(seconds / 86_400) });
}
