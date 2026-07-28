// Admin shell: sidebar navigation + bootstrap data context shared by all pages.
//
// Access comes from venue memberships, not a global role: the sidebar shows the
// active venue, lets multi-venue users switch, and hides sections the member's
// role cannot use. The server enforces the same rules — this is only the UI.
import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { Navigate, NavLink, Outlet } from 'react-router-dom';
import { useToast } from '../components/ui';
import { gql } from '../lib/gql';
import { F } from '../lib/fragments';
import type { Category, Service, Settings, Staff } from '../lib/types';
import { useAuth } from '../lib/auth';
import './admin.css';

export interface AppData {
  settings: Settings;
  staff: Staff[];
  categories: Category[];
  services: Service[];
  refresh: () => Promise<void>;
}

type Bootstrap = Omit<AppData, 'refresh'>;

const AppCtx = createContext<AppData | null>(null);
export const useAppData = () => useContext(AppCtx)!;

const BOOTSTRAP = `{ ${F.settings} ${F.staff} ${F.categories} ${F.services} }`;

// Minimum role each section requires, mirroring the server's middleware.
const NAV = [
  { to: '/dashboard/calendar', label: 'Calendar', min: 'staff' },
  { to: '/dashboard/clients', label: 'Clients', min: 'receptionist' },
  { to: '/dashboard/catalog', label: 'Catalog', min: 'manager' },
  { to: '/dashboard/team', label: 'Team', min: 'manager' },
  { to: '/dashboard/sales', label: 'Sales', min: 'manager' },
  { to: '/dashboard/reports', label: 'Reports', min: 'manager' },
] as const;

const RANK = { staff: 0, receptionist: 1, manager: 2, owner: 3 } as const;

export default function AdminLayout() {
  const [data, setData] = useState<Bootstrap | null>(null);
  const [error, setError] = useState('');
  const { user, loading, logout, memberships, activeVenue, selectVenue } = useAuth();

  const membership = memberships.find((m) => m.venue.slug === activeVenue) ?? memberships[0];
  const authorized = !loading && !!user && !!membership;

  const toast = useToast();
  const loaded = useRef(false);

  // Pages call refresh() fire-and-forget, so failures are reported here rather
  // than left as a rejected promise nobody is listening to. Only the first load
  // takes over the screen — later failures keep the dashboard up.
  const refresh = useCallback(async () => {
    try {
      const d = await gql<Bootstrap>(BOOTSTRAP);
      loaded.current = true;
      setData(d);
      setError('');
    } catch (e) {
      const msg = (e as Error).message;
      if (loaded.current) toast(`Could not refresh: ${msg}`, true);
      else setError(msg);
    }
  }, [toast]);

  // Reload whenever the active venue changes — the data is venue-scoped.
  useEffect(() => {
    if (!authorized) return;
    loaded.current = false;
    setData(null);
    setError('');
    refresh();
  }, [refresh, authorized, activeVenue]);

  if (loading) return <div className="empty">Loading…</div>;
  if (!user) return <Navigate to="/dashboard/login" replace />;

  if (!membership) {
    return (
      <div className="empty">
        This account does not manage a venue yet.
        <br />
        <a href="/">Back to Blastek</a>
      </div>
    );
  }

  if (error) return <div className="empty">Could not reach the API: {error}</div>;
  if (!data) return <div className="empty">Loading…</div>;

  const rank = RANK[membership.role];
  const nav = NAV.filter((n) => rank >= RANK[n.min]);

  return (
    <AppCtx.Provider value={{ ...data, refresh }}>
      <div className="adm app">
        <aside className="adm-side">
          <div className="adm-brand">blastek</div>

          <div className="adm-venue">
            {memberships.length > 1 ? (
              <select
                aria-label="Active venue"
                value={membership.venue.slug}
                onChange={(e) => selectVenue(e.target.value)}
              >
                {memberships.map((m) => (
                  <option key={m.venue.id} value={m.venue.slug}>{m.venue.name}</option>
                ))}
              </select>
            ) : (
              <div className="adm-venue-name">{membership.venue.name}</div>
            )}
            <div className="adm-venue-role">{membership.role}</div>
          </div>

          <nav className="adm-nav">
            {nav.map((n, i) => (
              <NavLink key={n.to} to={n.to} className={({ isActive }) => (isActive ? 'active' : '')}>
                <span className="n">0{i + 1}</span>
                {n.label}
              </NavLink>
            ))}
          </nav>
          <div className="spacer" />
          <div className="adm-user">
            {user.firstName} {user.lastName}
            <br />
            {user.email}
          </div>
          <button className="adm-foot-btn" onClick={logout}>
            Log out
          </button>
          <a className="adm-foot-btn" href={`/v/${membership.venue.slug}`} target="_blank"
            rel="noreferrer">
            Open booking page ↗
          </a>
        </aside>
        <main className="adm-main">
          <Outlet />
        </main>
      </div>
    </AppCtx.Provider>
  );
}
