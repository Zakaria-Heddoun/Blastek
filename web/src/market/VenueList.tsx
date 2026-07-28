// Every active venue on the marketplace. A plain directory for now — search,
// filters, photos and map arrive with discovery (F0.6).
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { gql } from '../lib/gql';
import type { VenueSummary } from '../lib/types';
import MarketTopbar from './MarketTopbar';
import './market.css';

const VENUES = `{ venues { id slug name city tagline address } }`;

export default function VenueList() {
  const [venues, setVenues] = useState<VenueSummary[] | null>(null);
  const [error, setError] = useState('');

  useEffect(() => {
    document.title = 'Blastek — Book a venue';
    gql<{ venues: VenueSummary[] }>(VENUES)
      .then((d) => setVenues(d.venues))
      .catch((e) => setError(e.message));
  }, []);

  return (
    <div className="mkt">
      <MarketTopbar />
      <div className="bk-shell" style={{ paddingTop: 28 }}>
        <h1 style={{ fontSize: 26, marginBottom: 6 }}>Book an appointment</h1>
        <p className="mutetext" style={{ marginTop: 0 }}>
          Choose a salon, barbershop or spa to see live availability.
        </p>

        {error && <div className="empty">{error}</div>}
        {!venues && !error && <div className="empty">Loading…</div>}
        {venues?.length === 0 && <div className="empty">No venues are open for booking yet.</div>}

        <div className="vlist">
          {venues?.map((v) => (
            <Link className="vlist-card" key={v.id} to={`/v/${v.slug}`}>
              <div>
                <h3>{v.name}</h3>
                <div className="mutetext">{v.tagline}</div>
                <div className="fainttext">{v.address || v.city}</div>
              </div>
              <span className="btn btn-accent btn-sm">Book</span>
            </Link>
          ))}
        </div>
      </div>
    </div>
  );
}
