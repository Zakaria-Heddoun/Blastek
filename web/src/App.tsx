import { Navigate, Route, Routes } from 'react-router-dom';
import { ToastProvider } from './components/ui';
import { AuthProvider } from './lib/auth';
import AdminLayout from './admin/AdminLayout';
import ProLogin from './admin/ProLogin';
import CalendarPage from './admin/CalendarPage';
import ClientsPage from './admin/ClientsPage';
import CatalogPage from './admin/CatalogPage';
import TeamPage from './admin/TeamPage';
import SalesPage from './admin/SalesPage';
import ReportsPage from './admin/ReportsPage';
import MarketLayout from './market/MarketLayout';
import Home from './market/Home';
import VenueList from './market/VenueList';
import VenuePage from './market/VenuePage';
import BookingFlow from './market/BookingFlow';
import AuthPage from './market/AuthPage';
import Account from './market/Account';
import BungeePage from './bungee/BungeePage';

// The marketplace is the root app (fresha.com) — the business dashboard lives
// under /dashboard (fresha.com's partners.fresha.com equivalent).
export default function App() {
  return (
    <AuthProvider>
      <ToastProvider>
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
          </Route>
          {/* Homepage — Blastek marketplace on the Bungee-style design.
              Standalone (its own nav/footer); booking flow stays under
              MarketLayout. Original landing archived in web/backups/. */}
          <Route path="/" element={<Home />} />
          {/* Auth — standalone full pages in the Blastek/Bungee design system */}
          <Route path="/login" element={<AuthPage mode="login" />} />
          <Route path="/signup" element={<AuthPage mode="signup" />} />
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
        </Routes>
      </ToastProvider>
    </AuthProvider>
  );
}
