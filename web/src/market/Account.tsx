// Customer account: upcoming and past appointments, with online cancellation.
// One account books at many venues, so every row names the venue it belongs to.
import { useCallback, useEffect, useState } from 'react';
import { Link, Navigate, useSearchParams } from 'react-router-dom';
import { Trans, useTranslation } from 'react-i18next';
import { gql } from '../lib/gql';
import type { Appointment } from '../lib/types';
import { useAuth } from '../lib/auth';
import { Icon } from '../lib/icons';
import { StatusBadge, useToast } from '../components/ui';
import MarketTopbar from './MarketTopbar';
import AccountSecurity from './AccountSecurity';
import AccountNotifications from './AccountNotifications';
import AccountProfile from './AccountProfile';
import RescheduleModal from './RescheduleModal';
import ReviewPrompts from './ReviewPrompts';
import { useAccountLocale } from '../lib/locale';
import { fmtDateLong, fmtMAD, fmtTime, todayStr } from '../lib/format';
import './market.css';

const MY = `{ myAppointments {
  id date startMin endMin status priceCents bookingRef
  service { id name } staff { name }
  venue { id slug name city }
} }`;

type AccountTab = 'profile' | 'appointments' | 'notifications' | 'security';
const TABS: { id: AccountTab; icon: string }[] = [
  { id: 'profile', icon: 'user' },
  { id: 'appointments', icon: 'calendar' },
  { id: 'notifications', icon: 'bell' },
  { id: 'security', icon: 'shield' },
];

export default function Account() {
  const { t } = useTranslation();
  const { user, loading, logout } = useAuth();
  const toast = useToast();
  const [searchParams, setSearchParams] = useSearchParams();
  const requestedTab = searchParams.get('tab');
  const tab: AccountTab = TABS.some(({ id }) => id === requestedTab)
    ? requestedTab as AccountTab
    : 'profile';

  // Adopt the language saved on the account, if this browser has no choice yet.
  useAccountLocale();
  const [appts, setAppts] = useState<Appointment[] | null>(null);
  const [loadError, setLoadError] = useState('');
  const [moving, setMoving] = useState<Appointment | null>(null);

  const load = useCallback(async () => {
    setLoadError('');
    try {
      const d = await gql<{ myAppointments: Appointment[] }>(MY);
      setAppts(d.myAppointments);
    } catch (error) {
      setLoadError((error as Error).message);
    }
  }, []);

  useEffect(() => {
    document.title = `Blastek — ${t(`account.tabs.${tab}`)}`;
    if (user && tab === 'appointments' && appts === null) load();
  }, [user, load, t, tab, appts]);

  if (loading) return <div className="empty">{t(`common.loading`)}</div>;
  if (!user) return <Navigate to="/login?next=/account" replace />;

  const today = todayStr();
  const upcoming = (appts ?? []).filter((a) =>
    a.date >= today && !['cancelled', 'no_show', 'completed'].includes(a.status));
  const past = (appts ?? []).filter((a) => !upcoming.includes(a));

  const cancel = async (id: string) => {
    try {
      await gql(`mutation($id: ID!) { cancelMyAppointment(id: $id) { id status } }`, { id });
      toast(t('account.cancelled'));
      load();
    } catch (e) { toast((e as Error).message, true); }
  };

  const row = (a: Appointment, cancellable: boolean) => (
    <div key={a.id} className="card pad account-appt-row">
      <div className="grow account-appt-detail">
        <b>{a.service.name}</b>
        {a.venue && (
          <div className="mutetext" style={{ fontSize: 13 }}>
            <Link to={`/v/${a.venue.slug}`}>{a.venue.name}</Link> · {a.venue.city}
          </div>
        )}
        <div className="fainttext">
          {fmtDateLong(a.date)} · {fmtTime(a.startMin, true)} ·{' '}
          {t('account.with', { name: a.staff.name })}
          {a.bookingRef ? ` · ${a.bookingRef}` : ''}
        </div>
      </div>
      <div className="account-appt-meta">
        <StatusBadge status={a.status} />
        <span className="price">{fmtMAD(a.priceCents)}</span>
      </div>
      {cancellable && (
        <div className="account-appt-actions">
          <button className="btn btn-sm" onClick={() => setMoving(a)}>
            {t(`account.reschedule`)}
          </button>
          <button className="btn btn-sm" onClick={() => cancel(a.id)}>
            {t(`account.cancelAppointment`)}
          </button>
        </div>
      )}
    </div>
  );

  return (
    <div className="mkt">
      <MarketTopbar />
      <div className="account-shell">
        <aside className="account-sidebar">
          <Link className="account-back" to="/"><Icon name="left" size={16} /> {t('nav.home')}</Link>

          <div className="account-identity">
            <div className="account-avatar">
              {user.avatarUrl
                ? <img src={user.avatarUrl} alt="" />
                : <span>{initials(user)}</span>}
            </div>
            <div>
              <strong>{displayName(user, t('account.you'))}</strong>
              <span>{user.email || user.phone}</span>
            </div>
          </div>

          <nav className="account-nav" aria-label={t('account.accountNavigation')}>
            {TABS.map(({ id, icon }) => (
              <button
                key={id}
                type="button"
                className={tab === id ? 'active' : ''}
                aria-current={tab === id ? 'page' : undefined}
                onClick={() => setSearchParams(id === 'profile' ? {} : { tab: id })}
              >
                <Icon name={icon} size={18} />
                <span>{t(`account.tabs.${id}`)}</span>
              </button>
            ))}
          </nav>

          <div className="account-sidebar-actions">
            <button className="btn btn-sm" onClick={logout}>{t('nav.logout')}</button>
          </div>
        </aside>

        <main className="account-main">
          <header className="account-head">
            <h1>{t(`account.tabs.${tab}`)}</h1>
            <p>{t(`account.tabLead.${tab}`)}</p>
          </header>

          {tab === 'profile' && <AccountProfile />}

          {tab === 'appointments' && (
            <>
              <ReviewPrompts />

              <h2 className="section-title">{t('account.upcoming')}</h2>
              {loadError ? (
                <div className="empty">
                  <p>{loadError}</p>
                  <button className="btn btn-sm" onClick={load}>{t('common.retry')}</button>
                </div>
              ) : appts === null ? <div className="empty">{t('common.loading')}</div>
                : upcoming.length === 0
                  ? (
                    <div className="empty">
                      <Trans
                        i18nKey="account.noUpcomingWithLink"
                        components={{ 1: <Link to="/venues" /> }}
                      />
                    </div>
                  )
                  : upcoming.map((a) => row(a, true))}

              <h2 className="section-title">{t('account.past')}</h2>
              {!loadError && appts !== null && (past.length === 0
                ? <div className="empty">{t('account.nothingYet')}</div>
                : past.slice(0, 15).map((a) => row(a, false)))}
            </>
          )}

          {tab === 'notifications' && <AccountNotifications />}
          {tab === 'security' && <AccountSecurity />}
        </main>
      </div>

      {moving && (
        <RescheduleModal
          appointment={moving}
          group={groupOf(appts ?? [], moving)}
          onClose={() => setMoving(null)}
          onDone={() => { setMoving(null); load(); }}
        />
      )}
    </div>
  );
}

function displayName(user: { firstName: string; lastName: string }, fallback: string) {
  return [user.firstName, user.lastName].filter(Boolean).join(' ') || fallback;
}

function initials(user: { firstName: string; lastName: string; email: string | null }) {
  return `${user.firstName?.[0] ?? ''}${user.lastName?.[0] ?? ''}`.toUpperCase()
    || user.email?.[0]?.toUpperCase()
    || '?';
}

/**
 * Every appointment under one booking reference.
 *
 * A cut-and-colour is two rows and one arrival, and F0.9 moves the booking
 * rather than the row. An appointment with no reference — a walk-in the salon
 * typed in — is its own group.
 */
function groupOf(all: Appointment[], one: Appointment) {
  if (!one.bookingRef) return [one];
  return all.filter((a) => a.bookingRef === one.bookingRef);
}
