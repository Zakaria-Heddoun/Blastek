// Search results / venue directory (E8-T6).
//
// Every input lives in the URL. That is what makes a result set linkable, the
// back button behave, and a reload land where the shopper was — and it means the
// component has no filter state of its own to fall out of sync.
import { useCallback, useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { gql } from '../lib/gql';
import type { CategoryFacet, CityFacet, VenuePage, VenueSummary } from '../lib/types';
import { fmtMAD } from '../lib/format';
import { Icon, StarRow } from '../lib/icons';
import VenueMap, { type MapMarker } from '../components/VenueMap';
import Pager from '../components/Pager';
import MarketTopbar from './MarketTopbar';
import SearchBar from './SearchBar';
import { IMG } from './assets';
import './market.css';

const PAGE_SIZE = 12;

const SEARCH = `query(
  $q: String, $city: String, $category: String, $womenOnly: Boolean,
  $near: GeoPoint, $sort: String, $limit: Int, $offset: Int
) {
  searchVenues(
    q: $q, city: $city, category: $category, womenOnly: $womenOnly,
    near: $near, sort: $sort, limit: $limit, offset: $offset
  ) {
    totalCount
    items {
      id slug name city tagline address
      rating reviewCount priceFromCents
      lat lng distanceKm coverUrl
    }
  }
}`;

const FACETS = `{
  venueCities { city venueCount }
  venueCategories { name serviceCount }
}`;

// Stand-in imagery for venues that have not uploaded photos yet. A real
// `coverUrl` always wins; this only keeps the grid from looking broken.
const COVERS = [IMG.salon1, IMG.hair1, IMG.barber1, IMG.nails1, IMG.spa1, IMG.hair2];

const SORTS = [
  { value: 'relevance', label: 'Most relevant' },
  { value: 'rating', label: 'Best rated' },
  { value: 'price', label: 'Lowest price' },
  { value: 'distance', label: 'Nearest' },
  { value: 'name', label: 'Name (A–Z)' },
];

export default function VenueList() {
  const [params, setParams] = useSearchParams();

  const q = params.get('q') ?? '';
  const where = params.get('where') ?? '';
  const city = params.get('city') ?? '';
  const category = params.get('category') ?? '';
  const womenOnly = params.get('women') === '1';
  const sort = params.get('sort') ?? 'relevance';
  const offset = Number(params.get('offset') ?? 0) || 0;
  const view = params.get('view') === 'map' ? 'map' : 'list';

  const [page, setPage] = useState<VenuePage | null>(null);
  const [error, setError] = useState('');
  const [cities, setCities] = useState<CityFacet[]>([]);
  const [categories, setCategories] = useState<CategoryFacet[]>([]);
  const [near, setNear] = useState<{ lat: number; lng: number } | null>(null);
  const [locating, setLocating] = useState(false);
  const [hovered, setHovered] = useState<string | null>(null);

  // Merges into the existing query string and resets paging, because any filter
  // change makes the current offset meaningless.
  const update = useCallback(
    (changes: Record<string, string | null>, keepOffset = false) => {
      const next = new URLSearchParams(params);
      for (const [key, value] of Object.entries(changes)) {
        if (value === null || value === '') next.delete(key);
        else next.set(key, value);
      }
      if (!keepOffset) next.delete('offset');
      setParams(next, { replace: true });
    },
    [params, setParams],
  );

  useEffect(() => {
    gql<{ venueCities: CityFacet[]; venueCategories: CategoryFacet[] }>(FACETS)
      .then((d) => {
        setCities(d.venueCities ?? []);
        setCategories(d.venueCategories ?? []);
      })
      // Filters are an enhancement; free-text search still works without them.
      .catch(() => undefined);
  }, []);

  const load = useCallback(async () => {
    setPage(null);
    setError('');

    // The two search boxes collapse into one term: the API matches name, city,
    // address and treatments together, so "barber rabat" needs no split.
    const term = [q, where].filter(Boolean).join(' ').trim();

    try {
      const data = await gql<{ searchVenues: VenuePage }>(SEARCH, {
        q: term || null,
        city: city || null,
        category: category || null,
        womenOnly: womenOnly || null,
        near,
        sort,
        limit: PAGE_SIZE,
        offset,
      });
      setPage(data.searchVenues);
    } catch (e) {
      setError((e as Error).message);
    }
  }, [q, where, city, category, womenOnly, sort, offset, near]);

  useEffect(() => {
    const parts = [q, where, city].filter(Boolean);
    document.title = parts.length
      ? `Blastek — ${parts.join(' · ')}`
      : 'Blastek — Book a salon, barbershop or spa';
    load();
  }, [load, q, where, city]);

  const locate = () => {
    if (!navigator.geolocation) {
      setError('This browser cannot share your location.');
      return;
    }
    setLocating(true);
    navigator.geolocation.getCurrentPosition(
      (position) => {
        setNear({ lat: position.coords.latitude, lng: position.coords.longitude });
        setLocating(false);
        update({ sort: 'distance' });
      },
      () => {
        setLocating(false);
        setError('We could not get your location. Try picking a city instead.');
      },
      { timeout: 8000 },
    );
  };

  const venues = page?.items ?? [];
  const searched = Boolean(q || where || city || category || womenOnly);
  const filtersOn = Boolean(city || category || womenOnly);

  const markers: MapMarker[] = venues
    .filter((v) => v.lat != null && v.lng != null)
    .map((v) => ({
      id: v.id,
      lat: v.lat as number,
      lng: v.lng as number,
      label: v.name,
      active: hovered === v.id,
    }));

  return (
    <div className="mkt">
      <MarketTopbar />
      <div className="bk-shell vlist-shell">
        <SearchBar initialQ={q} initialWhere={where} variant="inline" />

        <div className="vfilters" role="group" aria-label="Filter results">
          <select aria-label="City" value={city} onChange={(e) => update({ city: e.target.value })}>
            <option value="">All cities</option>
            {cities.map((c) => (
              <option key={c.city} value={c.city}>
                {c.city} ({c.venueCount})
              </option>
            ))}
          </select>

          <select
            aria-label="Treatment category"
            value={category}
            onChange={(e) => update({ category: e.target.value })}
          >
            <option value="">All treatments</option>
            {categories.map((c) => (
              <option key={c.name} value={c.name}>
                {c.name}
              </option>
            ))}
          </select>

          <select
            aria-label="Sort results"
            value={sort}
            onChange={(e) => update({ sort: e.target.value })}
          >
            {SORTS.map((s) => (
              <option key={s.value} value={s.value} disabled={s.value === 'distance' && !near}>
                {s.label}
                {s.value === 'distance' && !near ? ' — needs your location' : ''}
              </option>
            ))}
          </select>

          <label className="vfilter-check">
            <input
              type="checkbox"
              checked={womenOnly}
              onChange={(e) => update({ women: e.target.checked ? '1' : null })}
            />
            Women only
          </label>

          <button className="btn btn-sm" onClick={locate} disabled={locating}>
            <Icon name="pin" size={14} />{' '}
            {locating ? 'Locating…' : near ? 'Near you' : 'Use my location'}
          </button>

          {filtersOn && (
            <button
              className="btn btn-sm vfilter-clear"
              onClick={() => update({ city: null, category: null, women: null })}
            >
              Clear filters
            </button>
          )}

          <div className="grow" />

          <div className="vview" role="group" aria-label="Result view">
            <button
              className={view === 'list' ? 'active' : ''}
              onClick={() => update({ view: null }, true)}
              aria-pressed={view === 'list'}
            >
              List
            </button>
            <button
              className={view === 'map' ? 'active' : ''}
              onClick={() => update({ view: 'map' }, true)}
              aria-pressed={view === 'map'}
            >
              Map
            </button>
          </div>
        </div>

        <div className="vlist-head">
          <h1>
            {searched ? 'Search results' : 'Book an appointment'}
            {page && (
              <span className="vlist-count">
                {' '}
                · {page.totalCount} venue{page.totalCount === 1 ? '' : 's'}
              </span>
            )}
          </h1>
          <p className="mutetext">
            {searched
              ? 'Showing venues that match your search.'
              : 'Choose a salon, barbershop or spa to see live availability.'}
          </p>
        </div>

        {error && <div className="empty">{error}</div>}
        {!page && !error && <div className="empty">Searching…</div>}

        {page?.totalCount === 0 && (
          <div className="empty">
            No venues match that search. <Link to="/venues">Browse all venues</Link>
          </div>
        )}

        {view === 'map' && venues.length > 0 && (
          <>
            <VenueMap markers={markers} height={420} ariaLabel="Map of search results" />
            {markers.length < venues.length && (
              <p className="fainttext vmap-note">
                {venues.length - markers.length} of these venues have not placed a map pin yet, so
                they appear in the list only.
              </p>
            )}
          </>
        )}

        {(view === 'list' || venues.length === 0) && (
          <div className="vgrid">
            {venues.map((v, i) => (
              <VenueCard
                key={v.id}
                venue={v}
                fallbackCover={COVERS[i % COVERS.length]}
                onHover={setHovered}
              />
            ))}
          </div>
        )}

        {page && (
          <Pager
            offset={offset}
            limit={PAGE_SIZE}
            totalCount={page.totalCount}
            onChange={(next) => update({ offset: String(next) }, true)}
          />
        )}
      </div>
    </div>
  );
}

function VenueCard({
  venue,
  fallbackCover,
  onHover,
}: {
  venue: VenueSummary;
  fallbackCover: string;
  onHover: (id: string | null) => void;
}) {
  const reviewed = (venue.reviewCount ?? 0) > 0;

  return (
    <Link
      className="vcard"
      to={`/v/${venue.slug}`}
      onMouseEnter={() => onHover(venue.id)}
      onMouseLeave={() => onHover(null)}
    >
      <div className="vcard-thumb">
        <img src={venue.coverUrl || fallbackCover} alt="" loading="lazy" />
        {venue.distanceKm != null && (
          <span className="vcard-dist">{formatDistance(venue.distanceKm)}</span>
        )}
      </div>
      <div className="vcard-body">
        <h3>{venue.name}</h3>

        {reviewed ? (
          <div className="vcard-rating">
            <b>{venue.rating?.toFixed(1)}</b>
            <StarRow rating={venue.rating ?? 0} size={12} />
            <span className="fainttext">({venue.reviewCount})</span>
          </div>
        ) : (
          <div className="fainttext">New on Blastek</div>
        )}

        <div className="vcard-where">
          <Icon name="pin" size={13} /> {venue.address || venue.city || 'Morocco'}
        </div>

        {venue.priceFromCents != null && (
          <div className="vcard-price">from {fmtMAD(venue.priceFromCents)}</div>
        )}
      </div>
    </Link>
  );
}

// Below a kilometre "0.4 km" reads worse than "400 m", and rounding a 12 km
// drive to one decimal implies a precision the pin does not have.
function formatDistance(km: number) {
  if (km < 1) return `${Math.round(km * 1000)} m`;
  if (km < 10) return `${km.toFixed(1)} km`;
  return `${Math.round(km)} km`;
}
