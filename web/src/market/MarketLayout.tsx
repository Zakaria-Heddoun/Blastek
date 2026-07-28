// Venue shell (dark theme): topbar + venue data context + booking state.
// The venue is addressed by slug in the URL (`/v/:slug`), so the marketplace
// serves every tenant from the same routes.
import { createContext, useContext, useEffect, useState } from 'react';
import { Outlet, useLocation, useParams } from 'react-router-dom';
import { gql } from '../lib/gql';
import { F } from '../lib/fragments';
import type { Venue } from '../lib/types';
import MarketTopbar from './MarketTopbar';
import './market.css';

export interface BookingState {
  services: string[];
  staffId: string;
  date: string;
  setServices: (ids: string[]) => void;
  setStaffId: (id: string) => void;
  setDate: (d: string) => void;
}

const VenueCtx = createContext<{ venue: Venue; slug: string; booking: BookingState } | null>(null);
export const useVenue = () => useContext(VenueCtx)!;

const VENUE = `query($slug: String!) {
  venue(slug: $slug) {
    id
    slug
    city
    status
    ${F.settings}
    ${F.categories}
    ${F.services}
    ${F.staff}
    reviews { id clientName rating comment }
    rating
    hours { weekday open close }
    stats { bookings professionals services }
  }
}`;

export const STEPS = ['Services', 'Professional', 'Time', 'Confirm'];

export default function MarketLayout() {
  const { slug = '' } = useParams();
  const [venue, setVenue] = useState<Venue | null>(null);
  const [error, setError] = useState('');
  const [services, setServices] = useState<string[]>([]);
  const [staffId, setStaffId] = useState('any');
  const [date, setDate] = useState('');
  const location = useLocation();
  const inFlow = location.pathname.endsWith('/flow');

  useEffect(() => {
    setVenue(null);
    setError('');
    // Switching venues invalidates any half-built booking.
    setServices([]);
    setStaffId('any');
    gql<{ venue: Venue }>(VENUE, { slug })
      .then((d) => setVenue(d.venue))
      .catch((e) => setError(e.message));
  }, [slug]);

  if (error) return <div className="empty">{error}</div>;
  if (!venue) return <div className="empty">Loading…</div>;

  return (
    <VenueCtx.Provider
      value={{ venue, slug, booking: { services, staffId, date, setServices, setStaffId, setDate } }}
    >
      <div className="mkt">
        <MarketTopbar inFlow={inFlow} />
        <Outlet />
      </div>
    </VenueCtx.Provider>
  );
}
