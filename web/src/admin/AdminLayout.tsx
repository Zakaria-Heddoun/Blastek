// Admin shell: sidebar navigation + bootstrap data context shared by all pages.
//
// Access comes from venue memberships, not a global role: the sidebar shows the
// active venue, lets multi-venue users switch, and hides sections the member's
// role cannot use. The server enforces the same rules — this is only the UI.
import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { Navigate, NavLink, Outlet } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useToast } from '../components/ui';
import LanguageSwitcher from '../components/LanguageSwitcher';
import { useAccountLocale } from '../lib/locale';
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

// The dashboard is the one caller that edits copy, so it is the one caller
// that asks for every locale.
const BOOTSTRAP = `{
  ${F.settings} ${F.staff}
  categories { id name ${F.translations} sort }
  services { id categoryId name description ${F.translations} durationMin priceCents active staffIds }
}`;

// Minimum role each section requires, mirroring the server's middleware.
const NAV = [
  { to: '/dashboard/calendar', key: 'calendar', min: 'staff' },
  { to: '/dashboard/clients', key: 'clients', min: 'receptionist' },
  { to: '/dashboard/catalog', key: 'catalog', min: 'manager' },
  { to: '/dashboard/team', key: 'team', min: 'manager' },
  { to: '/dashboard/sales', key: 'sales', min: 'manager' },
  { to: '/dashboard/reports', key: 'reports', min: 'manager' },
  { to: '/dashboard/reviews', key: 'reviews', min: 'staff' },
  { to: '/dashboard/settings', key: 'settings', min: 'manager' },
] as const;

const RANK = { staff: 0, receptionist: 1, manager: 2, owner: 3 } as const;

export default function AdminLayout() {
  const [data, setData] = useState<Bootstrap | null>(null);
  const [error, setError] = useState('');
  const { t } = useTranslation();
  const { user, loading, logout, memberships, activeVenue, selectVenue } = useAuth();

  // A member who chose Arabic on their phone gets Arabic here too.
  useAccountLocale();

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
      if (loaded.current) toast(msg, true);
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

  if (loading) return <div className="empty">{t('common.loading')}</div>;
  if (!user) return <Navigate to="/dashboard/login" replace />;

  if (!membership) {
    return (
      <div className="empty">
        {t('admin.noVenue')}
        <br />
        <a href="/">{t('admin.login.backToMarket')}</a>
      </div>
    );
  }

  if (error) return <div className="empty">{error}</div>;
  if (!data) return <div className="empty">{t('common.loading')}</div>;

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
                aria-label={t('admin.activeVenue')}
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
            <div className="adm-venue-role">{t(`admin.team.roles.${membership.role}`)}</div>
          </div>

          <nav className="adm-nav">
            {nav.map((n, i) => (
              <NavLink key={n.to} to={n.to} className={({ isActive }) => (isActive ? 'active' : '')}>
                <span className="n">0{i + 1}</span>
                {t(`admin.nav.${n.key}`)}
              </NavLink>
            ))}
          </nav>
          <div className="spacer" />
          {/* The dropdown, not the three-button strip: three language names
              side by side overflow a 240px sidebar, and the overflow is silent
              — two of the three simply leave the screen. */}
          <div className="adm-lang"><LanguageSwitcher /></div>
          <div className="adm-user">
            {user.firstName} {user.lastName}
            <br />
            {user.email}
          </div>
          <button className="adm-foot-btn" onClick={logout}>
            {t('admin.nav.signOut')}
          </button>
          <a className="adm-foot-btn" href={`/v/${membership.venue.slug}`} target="_blank"
            rel="noreferrer">
            {t('admin.nav.viewShop')} ↗
          </a>
        </aside>
        <main className="adm-main">
          <Outlet />
        </main>
      </div>
    </AppCtx.Provider>
  );
}
