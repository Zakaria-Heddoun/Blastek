// Customer account: upcoming and past appointments, with online cancellation.
// One account books at many venues, so every row names the venue it belongs to.
import { useCallback, useEffect, useState } from 'react';
import { Link, Navigate } from 'react-router-dom';
import { gql } from '../lib/gql';
import type { Appointment } from '../lib/types';
import { useAuth } from '../lib/auth';
import { Icon } from '../lib/icons';
import { StatusBadge, useToast } from '../components/ui';
import MarketTopbar from './MarketTopbar';
import AccountSecurity from './AccountSecurity';
import AccountNotifications from './AccountNotifications';
import { fmtDateLong, fmtMAD, fmtTime, todayStr } from '../lib/format';
import './market.css';

const MY = `{ myAppointments {
  id date startMin endMin status priceCents bookingRef
  service { name } staff { name }
  venue { id slug name city }
} }`;

export default function Account() {
  const { user, loading, logout } = useAuth();
  const toast = useToast();
  const [appts, setAppts] = useState<Appointment[] | null>(null);

  const load = useCallback(async () => {
    const d = await gql<{ myAppointments: Appointment[] }>(MY);
    setAppts(d.myAppointments);
  }, []);

  useEffect(() => {
    document.title = 'Blastek — My appointments';
    if (user) load();
  }, [user, load]);

  if (loading) return <div className="empty">Loading…</div>;
  if (!user) return <Navigate to="/login?next=/account" replace />;

  const today = todayStr();
  const upcoming = (appts ?? []).filter((a) =>
    a.date >= today && !['cancelled', 'no_show', 'completed'].includes(a.status));
  const past = (appts ?? []).filter((a) => !upcoming.includes(a));

  const cancel = async (id: string) => {
    try {
      await gql(`mutation($id: ID!) { cancelMyAppointment(id: $id) { id status } }`, { id });
      toast('Appointment cancelled');
      load();
    } catch (e) { toast((e as Error).message, true); }
  };

  const row = (a: Appointment, cancellable: boolean) => (
    <div key={a.id} className="card pad" style={{ marginBottom: 10, display: 'flex', gap: 14, alignItems: 'center' }}>
      <div className="grow" style={{ flex: 1 }}>
        <b>{a.service.name}</b>
        {a.venue && (
          <div className="mutetext" style={{ fontSize: 13 }}>
            <Link to={`/v/${a.venue.slug}`}>{a.venue.name}</Link> · {a.venue.city}
          </div>
        )}
        <div className="fainttext">
          {fmtDateLong(a.date)} · {fmtTime(a.startMin, true)} · with {a.staff.name}
          {a.bookingRef ? ` · ${a.bookingRef}` : ''}
        </div>
      </div>
      <StatusBadge status={a.status} />
      <span className="price">{fmtMAD(a.priceCents)}</span>
      {cancellable && (
        <button className="btn btn-sm" onClick={() => cancel(a.id)}>Cancel</button>
      )}
    </div>
  );

  return (
    <div className="mkt">
      <MarketTopbar />
      <div className="bk-shell" style={{ paddingTop: 24, paddingBottom: 60, maxWidth: 760 }}>
        <Link className="btn btn-ghost btn-sm" to="/"><Icon name="left" size={15} /> Home</Link>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, margin: '14px 0 4px' }}>
          <h1 style={{ fontSize: 26 }}>My appointments</h1>
          <div className="grow" style={{ flex: 1 }} />
          <button className="btn btn-sm" onClick={logout}>Log out</button>
        </div>
        <div className="mutetext" style={{ marginBottom: 22 }}>
          {/* A phone-first account may have no email and no name yet, so the
              identity line falls back to whichever of them exists. */}
          Signed in as {[user.firstName, user.lastName].filter(Boolean).join(' ') || 'you'}
          {user.email ? ` · ${user.email}` : ''}
          {user.phone ? ` · ${user.phone}` : ''}
        </div>

        <h2 className="section-title">Upcoming</h2>
        {appts === null ? <div className="empty">Loading…</div>
          : upcoming.length === 0
            ? <div className="empty">No upcoming appointments — <Link to="/venues">book one</Link>.</div>
            : upcoming.map((a) => row(a, true))}

        <h2 className="section-title">Past</h2>
        {appts !== null && (past.length === 0
          ? <div className="empty">Nothing here yet.</div>
          : past.slice(0, 15).map((a) => row(a, false)))}

        <AccountNotifications />
        <AccountSecurity />
      </div>
    </div>
  );
}
