// Venue shell (dark theme): topbar + venue data context + booking state.
// The venue is addressed by slug in the URL (`/v/:slug`), so the marketplace
// serves every tenant from the same routes.
import { createContext, useContext, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
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
    lat
    lng
    amenities
    womenOnly
    ${F.photos}
    ${F.settings}
    ${F.categories}
    ${F.services}
    ${F.staff}
    reviews { id clientName rating comment createdAt }
    rating
    hours { weekday open close }
    stats { bookings professionals services }
  }
}`;

// Keys rather than labels: the step names are rendered through `t()` at the
// point of display, so switching language re-labels the strip without the
// component that owns the flow having to re-run.
export const STEP_KEYS = ['services', 'professional', 'time', 'confirm'] as const;

export default function MarketLayout() {
  const { slug = '' } = useParams();
  const [venue, setVenue] = useState<Venue | null>(null);
  const [error, setError] = useState('');
  const [services, setServices] = useState<string[]>([]);
  const [staffId, setStaffId] = useState('any');
  const [date, setDate] = useState('');
  const { t } = useTranslation();
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
  if (!venue) return <div className="empty">{t(`common.loading`)}</div>;

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
