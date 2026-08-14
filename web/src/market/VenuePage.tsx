// Venue page — the marketplace's shop window and the entry point to booking.
// Order follows what a shopper decides in: is this the right place (header,
// photos), what can I get (treatments), who from (team), can I trust it
// (reviews), and can I actually get there (about, map, hours).
import { useEffect, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import { useVenue } from './MarketLayout';
import { IMG } from './assets';
import { Icon, StarRow } from '../lib/icons';
import { useToast } from '../components/ui';
import VenueMap from '../components/VenueMap';
import type { Photo } from '../lib/types';
import {
  dirOf, fmtDateShort, fmtDur, fmtMAD, fmtTime, initials, weekdaysFull,
} from '../lib/format';

// Shown only until a venue uploads its own photos. Deliberately generic stock:
// a placeholder that looks like a specific salon would misrepresent this one.
const PLACEHOLDER_GALLERY = [
  { src: IMG.salon1, alt: '' },
  { src: IMG.hair3, alt: '' },
  { src: IMG.barber3, alt: '' },
  { src: IMG.spa2, alt: '' },
  { src: IMG.spa3, alt: '' },
];

/**
 * Picks the right rendered size for each gallery slot.
 *
 * The first tile is displayed large, so it gets `hero`; the rest are thumbnails
 * and get `card`. Serving `hero` to all five is how a venue page ends up costing
 * several megabytes on a phone.
 */
function galleryTiles(photos: Photo[] | undefined, venueName: string, t: TFunction) {
  if (!photos || photos.length === 0) return PLACEHOLDER_GALLERY;

  return photos.slice(0, 5).map((photo, index) => ({
    src:
      (index === 0 ? photo.urls?.hero : photo.urls?.card) ||
      photo.urls?.card ||
      photo.urls?.original ||
      '',
    alt: photo.alt || t('venue.photoAlt', { name: venueName, index: index + 1 }),
  }));
}

/** Minutes-from-midnight comparison against the wall clock. */
function openState(
  hours: { open: number | null; close: number | null }[],
  now: Date,
  t: TFunction,
) {
  const today = hours[now.getDay()];
  const nowMin = now.getHours() * 60 + now.getMinutes();

  if (today?.open == null || today.close == null) {
    return { open: false, label: t('venue.closedToday') };
  }

  if (nowMin < today.open) {
    return { open: false, label: t('venue.opensAt', { time: fmtTime(today.open, true) }) };
  }
  if (nowMin >= today.close) {
    return { open: false, label: t('venue.closedOpensTomorrow') };
  }
  return { open: true, label: t('venue.openUntil', { time: fmtTime(today.close, true) }) };
}

export default function VenuePage() {
  const { venue: v, slug, booking } = useVenue();
  const { t } = useTranslation();
  const navigate = useNavigate();
  const toast = useToast();
  const [params] = useSearchParams();
  const focusCat = params.get('cat');
  const focusSvc = params.get('svc');
  const [showAllReviews, setShowAllReviews] = useState(false);

  const name = v.settings.businessName;
  const address = v.settings.businessAddress;

  useEffect(() => {
    document.title = `${name} — Blastek`;
    const el = focusSvc && document.getElementById(`svc-${focusSvc}`);
    if (el) el.scrollIntoView({ block: 'center' });
    else window.scrollTo(0, 0);
  }, [name, focusSvc]);

  const now = new Date();
  const status = openState(v.hours, now, t);
  const weekdayNames = weekdaysFull();
  const cats = focusCat ? v.categories.filter((c) => c.id === focusCat) : v.categories;

  const startFlow = (serviceId: string | null) => {
    booking.setServices(serviceId ? [serviceId] : []);
    booking.setStaffId('any');
    navigate(`/v/${slug}/flow`);
  };

  // Venues type their city into the address as often as not, so only append it
  // when it isn't already there.
  const fullAddress = [address, v.city]
    .filter(Boolean)
    .filter((part, i, all) => i === 0 || !all[0].toLowerCase().includes(part.toLowerCase()))
    .join(', ');

  // Google Maps accepts a plain address, so directions work without geocoding.
  const directionsUrl =
    `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(
      [name, fullAddress].filter(Boolean).join(', '),
    )}`;

  const pinned = v.lat != null && v.lng != null;
  const tiles = galleryTiles(v.photos, name, t);

  const share = async () => {
    const url = window.location.href;
    try {
      // The native sheet on mobile; clipboard everywhere else.
      if (navigator.share) await navigator.share({ title: name, url });
      else {
        await navigator.clipboard.writeText(url);
        toast(t('venue.linkCopied'));
      }
    } catch {
      // A cancelled share sheet is not an error worth reporting.
    }
  };

  const reviews = showAllReviews ? v.reviews : v.reviews.slice(0, 6);

  return (
    <>
      <div className="bk-shell venue-top">
        <nav className="crumbs" aria-label={t('venue.breadcrumb')}>
          <Link to="/">{t('nav.home')}</Link>
          <span aria-hidden="true">›</span>
          <Link to="/venues">{t('nav.venues')}</Link>
          {v.city && (
            <>
              <span aria-hidden="true">›</span>
              <Link to={`/venues?where=${encodeURIComponent(v.city)}`}>{v.city}</Link>
            </>
          )}
          <span aria-hidden="true">›</span>
          <span aria-current="page">{name}</span>
        </nav>

        <div className="venue-head">
          <div>
            <h1>{name}</h1>
            <div className="venue-sub">
              {v.reviewCount > 0 && (
                <>
                  <b>{v.rating.toFixed(1)}</b>
                  <StarRow rating={v.rating} size={13} />
                  <span className="fainttext">({v.reviewCount})</span>
                  <span className="dot-sep" aria-hidden="true">·</span>
                </>
              )}
              <span className={status.open ? 'open-now' : 'closed-now'}>{status.label}</span>
              {address && (
                <>
                  <span className="dot-sep" aria-hidden="true">·</span>
                  <span>{address}</span>
                  <a className="linky" href={directionsUrl} target="_blank" rel="noreferrer">
                    {t('venue.getDirections')}
                  </a>
                </>
              )}
            </div>
          </div>

          <div className="venue-actions">
            <button
              className="icon-btn"
              onClick={share}
              aria-label={t('venue.shareLabel')}
              title={t('venue.share')}
            >
              <Icon name="external" size={17} />
            </button>
          </div>
        </div>

        <div className="gallery">
          {tiles.map((tile, i) => (
            <img
              key={`${tile.src}-${i}`}
              className={i === 0 ? 'g-main' : ''}
              src={tile.src}
              alt={tile.alt}
              // The first tile is the page's largest image and its LCP; the rest
              // are below the fold.
              loading={i === 0 ? 'eager' : 'lazy'}
            />
          ))}
        </div>
      </div>

      <div className="bk-body" style={{ paddingTop: 8 }}>
        <div>
          <h2 className="section-title">{t('venue.treatments')}</h2>
          <div className="chip-row" style={{ marginBottom: 14 }}>
            <Link className={`chip ${!focusCat ? 'active' : ''}`} to={`/v/${slug}`}>
              {t('common.all')}
            </Link>
            {v.categories.map((c) => (
              <Link key={c.id} className={`chip ${focusCat === c.id ? 'active' : ''}`}
                to={`/v/${slug}?cat=${c.id}`}>{c.name}</Link>
            ))}
          </div>
          {cats.map((c) => {
            const svcs = v.services.filter((s) => s.categoryId === c.id);
            if (!svcs.length) return null;
            return (
              <div key={c.id}>
                <h3 style={{ margin: '18px 0 10px', fontSize: 15 }}>{c.name}</h3>
                {svcs.map((s) => (
                  <div key={s.id} id={`svc-${s.id}`}
                    className={`svc-row ${focusSvc === s.id ? 'sel' : ''}`} style={{ cursor: 'default' }}>
                    <div className="grow">
                      <b>{s.name}</b>
                      <div className="fainttext">{fmtDur(s.durationMin)}</div>
                      {s.description &&
                        <div className="mutetext" style={{ marginTop: 4, fontSize: 13 }}>{s.description}</div>}
                    </div>
                    <span className="price">{fmtMAD(s.priceCents)}</span>
                    <button className="btn svc-book" onClick={() => startFlow(s.id)}>
                      {t('venue.book')}
                    </button>
                  </div>
                ))}
              </div>
            );
          })}

          <h2 className="section-title">{t('venue.team')}</h2>
          <div className="pro-grid">
            {v.staff.map((st) => (
              <div key={st.id} className="pro-card" style={{ cursor: 'default' }}>
                <div className="avatar" style={{ background: st.color }}>{initials(st.name)}</div>
                <b>{st.name}</b>
                <div className="fainttext">{st.role}</div>
              </div>
            ))}
          </div>

          <h2 className="section-title">{t('venue.reviews')}</h2>
          {v.reviewCount === 0 ? (
            <div className="empty">{t('venue.noReviews')}</div>
          ) : (
            <>
              <div className="reviews-summary">
                <div className="reviews-score">{v.rating.toFixed(1)}</div>
                <div>
                  <StarRow rating={v.rating} size={16} />
                  <div className="fainttext">
                    {t('venue.basedOn', { count: v.reviewCount })}
                  </div>
                </div>
              </div>

              <div className="reviews-grid">
                {reviews.map((r) => (
                  <div key={r.id} className="review-card card">
                    <div className="who">
                      <span className="avatar sm">{initials(r.clientName)}</span>
                      <div className="grow">
                        <b>{r.clientName}</b>
                        {r.createdAt && (
                          <div className="fainttext">{fmtDateShort(r.createdAt)}</div>
                        )}
                      </div>
                      <StarRow rating={r.rating} size={12} />
                    </div>

                    {/* `dir` per comment, not per page: the review carries the
                        language it was written in, and an Arabic comment in a
                        French list still reads right-to-left. */}
                    {r.comment && (
                      <div className="mutetext" dir={dirOf(r.locale)}>{r.comment}</div>
                    )}

                    {r.reply && (
                      <div className="review-reply" dir={dirOf(r.locale)}>
                        <div className="review-reply-head">
                          <Icon name="reply" size={13} />
                          <b>{t('venue.ownerReply', { venue: v.settings.businessName })}</b>
                        </div>
                        <div className="mutetext">{r.reply}</div>
                      </div>
                    )}
                  </div>
                ))}
              </div>

              {v.reviewCount > 6 && !showAllReviews && (
                <button className="btn" style={{ marginTop: 14 }}
                  onClick={() => setShowAllReviews(true)}>
                  {t('venue.seeAllReviews', { count: v.reviewCount })}
                </button>
              )}
            </>
          )}

          <h2 className="section-title">{t('venue.about')}</h2>
          <p className="mutetext" style={{ marginTop: 0 }}>
            {t('venue.aboutFallback', { tagline: v.settings.businessTagline })}
          </p>

          {pinned ? (
            <VenueMap
              markers={[
                { id: v.id, lat: v.lat as number, lng: v.lng as number, label: name },
              ]}
              zoom={16}
              height={300}
              ariaLabel={t('venue.mapLabel', { name })}
            />
          ) : (
            // A venue is listable before anyone has geocoded it, so the address
            // card is a real state rather than an error.
            <div className="card pad venue-map-fallback">
              <Icon name="pin" size={18} />
              <div className="grow">{fullAddress || t('venue.locationOnRequest')}</div>
            </div>
          )}

          <div className="venue-loc">
            {/* Seeded addresses often already end in the city; don't repeat it. */}
            <div className="fainttext">{fullAddress}</div>
            <a className="linky" href={directionsUrl} target="_blank" rel="noreferrer">
              {t('venue.getDirections')}
            </a>
          </div>

          <div className="info-grid">
            <div>
              <h3 className="section-title">{t('venue.openingTimes')}</h3>
              <table className="hours-table">
                <tbody>
                  {v.hours.map((h) => (
                    <tr key={h.weekday} className={h.weekday === now.getDay() ? 'today' : ''}>
                      <td>
                        <span className={`hour-dot ${h.open != null ? 'on' : ''}`} aria-hidden="true" />
                        {weekdayNames[h.weekday]}
                      </td>
                      <td className="num">
                        {h.open != null
                          ? `${fmtTime(h.open, true)} – ${fmtTime(h.close!, true)}`
                          : t('common.closed')}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <div>
              <h3 className="section-title">{t('venue.additionalInfo')}</h3>
              <ul className="amenities">
                {(v.amenities ?? []).map((a) => (
                  <li key={a}><Icon name="check" size={15} /> {a}</li>
                ))}
                {v.settings.businessPhone && (
                  <li>
                    <Icon name="user" size={15} />
                    <a className="linky" href={`tel:${v.settings.businessPhone.replace(/\s/g, '')}`}>
                      {v.settings.businessPhone}
                    </a>
                  </li>
                )}
              </ul>
            </div>
          </div>
        </div>

        <div>
          <div className="card summary-card">
            <b style={{ fontSize: 16 }}>{name}</b>
            {v.reviewCount > 0 && (
              <div className="fainttext" style={{ marginBottom: 4 }}>
                <span className="stars"><Icon name="star" size={12} /></span> {v.rating.toFixed(1)}{' '}
                ({v.reviewCount})
              </div>
            )}
            <div className={`fainttext ${status.open ? 'open-now' : 'closed-now'}`}>{status.label}</div>
            <button className="btn btn-accent cta" onClick={() => startFlow(null)}>
              {t('venue.bookNow')}
            </button>
            <a className="linky block" href={directionsUrl} target="_blank" rel="noreferrer">
              <Icon name="pin" size={14} /> {t('venue.getDirections')}
            </a>
          </div>
        </div>
      </div>
    </>
  );
}
