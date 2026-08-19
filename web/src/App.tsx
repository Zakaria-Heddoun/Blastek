import { Component, lazy, Suspense } from 'react';
import type { ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { Link, Navigate, Route, Routes } from 'react-router-dom';
import { ToastProvider } from './components/ui';
import { AuthProvider } from './lib/auth';
import i18n from './lib/i18n';

// Route boundaries keep the public marketplace, business dashboard, and the
// media-heavy Bungee demo out of one another's initial download.
const AdminLayout = lazy(() => import('./admin/AdminLayout'));
const ProLogin = lazy(() => import('./admin/ProLogin'));
const CalendarPage = lazy(() => import('./admin/CalendarPage'));
const ClientsPage = lazy(() => import('./admin/ClientsPage'));
const CatalogPage = lazy(() => import('./admin/CatalogPage'));
const TeamPage = lazy(() => import('./admin/TeamPage'));
const SalesPage = lazy(() => import('./admin/SalesPage'));
const ReportsPage = lazy(() => import('./admin/ReportsPage'));
const SettingsPage = lazy(() => import('./admin/SettingsPage'));
const ReviewsPage = lazy(() => import('./admin/ReviewsPage'));
const MarketLayout = lazy(() => import('./market/MarketLayout'));
const Home = lazy(() => import('./market/Home'));
const VenueList = lazy(() => import('./market/VenueList'));
const VenuePage = lazy(() => import('./market/VenuePage'));
const BookingFlow = lazy(() => import('./market/BookingFlow'));
const AuthPage = lazy(() => import('./market/AuthPage'));
const CustomerOnboarding = lazy(() => import('./market/CustomerOnboarding'));
const ForgotPassword = lazy(() => import('./market/ForgotPassword'));
const JoinVenue = lazy(() => import('./market/JoinVenue'));
const OnboardVenue = lazy(() => import('./market/OnboardVenue'));
const AppointmentAction = lazy(() => import('./market/AppointmentAction'));
const ReviewPage = lazy(() => import('./market/ReviewPage'));
const Account = lazy(() => import('./market/Account'));
const BungeePage = lazy(() => import('./bungee/BungeePage'));

function RouteLoading() {
  const { t } = useTranslation();
  return <main className="app-state" role="status">{t('common.loading')}</main>;
}

function NotFound() {
  const { t } = useTranslation();
  return (
    <main className="app-state">
      <div className="app-state-code">404</div>
      <h1>{t('errors.notFoundTitle')}</h1>
      <p>{t('errors.notFoundBody')}</p>
      <Link className="btn" to="/">{t('errors.backHome')}</Link>
    </main>
  );
}

class AppErrorBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  render() {
    if (!this.state.failed) return this.props.children;

    return (
      <main className="app-state" role="alert">
        <h1>{i18n.t('errors.pageFailedTitle')}</h1>
        <p>{i18n.t('errors.pageFailedBody')}</p>
        <button className="btn" onClick={() => window.location.reload()}>
          {i18n.t('errors.reloadPage')}
        </button>
      </main>
    );
  }
}

// The marketplace is the root app (fresha.com) — the business dashboard lives
// under /dashboard (fresha.com's partners.fresha.com equivalent).
export default function App() {
  return (
    <AppErrorBoundary>
      <AuthProvider>
        <ToastProvider>
          <Suspense fallback={<RouteLoading />}>
            <Routes>
              {/* Standalone page — a React re-creation of the Bungee Framer
                  template. Unrelated to the salon app; no shared layout. */}
              <Route path="/bungee" element={<BungeePage />} />
              <Route path="/dashboard/login" element={<ProLogin />} />
              <Route path="/dashboard" element={<AdminLayout />}>
                <Route index element={<Navigate to="/dashboard/calendar" replace />} />
                <Route path="calendar" element={<CalendarPage />} />
                <Route path="clients" element={<ClientsPage />} />
                <Route path="catalog" element={<CatalogPage />} />
                <Route path="team" element={<TeamPage />} />
                <Route path="sales" element={<SalesPage />} />
                <Route path="reports" element={<ReportsPage />} />
                <Route path="reviews" element={<ReviewsPage />} />
                <Route path="settings" element={<SettingsPage />} />
              </Route>
              {/* Homepage — Blastek marketplace on the Bungee-style design.
                  Standalone (its own nav/footer); booking flow stays under
                  MarketLayout. Original landing archived in web/backups/. */}
              <Route path="/" element={<Home />} />
              {/* Auth — standalone full pages in the Blastek/Bungee design system */}
              <Route path="/login" element={<AuthPage mode="login" />} />
              <Route path="/signup" element={<AuthPage mode="signup" />} />
              <Route path="/welcome" element={<CustomerOnboarding />} />
              {/* One route for both halves of a reset: request a link, and consume
                  one arriving back as ?token=. */}
              <Route path="/forgot-password" element={<ForgotPassword />} />
              <Route path="/reset-password" element={<ForgotPassword />} />
              {/* Team invitation deep link (E4-T5). */}
              <Route path="/join" element={<JoinVenue />} />
              {/* The professional entry stays separate from setup: owners can
                  sign in here, and only the explicit create action opens the
                  onboarding wizard. */}
              <Route path="/for-business" element={<ProLogin />} />
              <Route path="/for-business/onboarding" element={<OnboardVenue />} />
              {/* One-tap confirm/cancel from a WhatsApp reminder (E6-T8). No login:
                  the signed token in the URL is the whole credential. */}
              <Route path="/a/:action/:token" element={<AppointmentAction />} />
              <Route path="/review/:token" element={<ReviewPage />} />
              {/* Marketplace: the directory, then one venue addressed by slug. */}
              <Route path="/venues" element={<VenueList />} />
              <Route path="/v/:slug" element={<MarketLayout />}>
                <Route index element={<VenuePage />} />
                <Route path="flow" element={<BookingFlow />} />
              </Route>
              {/* A customer's bookings span venues, so this sits outside the
                  venue layout. */}
              <Route path="/account" element={<Account />} />
              {/* Pre-multi-tenancy links pointed at a single hardcoded venue. */}
              <Route path="/venue" element={<Navigate to="/venues" replace />} />
              <Route path="/flow" element={<Navigate to="/venues" replace />} />
              <Route path="*" element={<NotFound />} />
            </Routes>
          </Suspense>
        </ToastProvider>
      </AuthProvider>
    </AppErrorBoundary>
  );
}
