// Venue page: gallery, treatments with descriptions, team, about + hours, reviews.
import { useEffect } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useVenue } from './MarketLayout';
import { IMG } from './assets';
import { Icon, StarRow } from '../lib/icons';
import { fmtDur, fmtMoney, fmtTime, initials, WEEKDAYS_FULL } from '../lib/format';

export default function VenuePage() {
  const { venue: v, slug, booking } = useVenue();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const focusCat = params.get('cat');
  const focusSvc = params.get('svc');

  useEffect(() => {
    document.title = `${v.settings.businessName} — Blastek`;
    const el = focusSvc && document.getElementById(`svc-${focusSvc}`);
    if (el) el.scrollIntoView({ block: 'center' });
    else window.scrollTo(0, 0);
  }, [v, focusSvc]);

  const now = new Date();
  const todayHours = v.hours[now.getDay()];
  const openLabel = todayHours.open != null
    ? `Open today · ${fmtTime(todayHours.open, true)} – ${fmtTime(todayHours.close!, true)}`
    : 'Closed today';

  const cats = focusCat ? v.categories.filter((c) => c.id === focusCat) : v.categories;

  const startFlow = (serviceId: string | null) => {
    booking.setServices(serviceId ? [serviceId] : []);
    booking.setStaffId('any');
    navigate(`/v/${slug}/flow`);
  };

  return (
    <>
      <div className="bk-shell" style={{ paddingTop: 20 }}>
        <Link className="btn btn-ghost btn-sm" to="/"><Icon name="left" size={15} /> Home</Link>
        <div className="venue-head" style={{ marginTop: 12 }}>
          <h1>{v.settings.businessName}</h1>
          <div className="venue-sub">
            <span className="stars"><Icon name="star" size={14} /></span><b>{v.rating}</b>
            ({v.reviews.length} reviews) · {v.settings.businessAddress} · {openLabel}
          </div>
        </div>
        <div className="gallery">
          <img className="g-main" src={IMG.salon1} alt="Salon interior" />
          <img src={IMG.hair3} alt="Hair wash" /><img src={IMG.barber3} alt="Barber tools" />
          <img src={IMG.spa2} alt="Spa" /><img src={IMG.spa3} alt="Facial treatment" />
        </div>
      </div>

      <div className="bk-body" style={{ paddingTop: 8 }}>
        <div>
          <h2 className="section-title">Treatments</h2>
          <div className="chip-row" style={{ marginBottom: 14 }}>
            <Link className={`chip ${!focusCat ? 'active' : ''}`} to={`/v/${slug}`}>All</Link>
            {v.categories.map((c) => (
              <Link key={c.id} className={`chip ${focusCat === c.id ? 'active' : ''}`}
                to={`/v/${slug}?cat=${c.id}`}>{c.name}</Link>
            ))}
          </div>
          {cats.map((c) => (
            <div key={c.id}>
              <h3 style={{ margin: '18px 0 10px', fontSize: 15 }}>{c.name}</h3>
              {v.services.filter((s) => s.categoryId === c.id).map((s) => (
                <div key={s.id} id={`svc-${s.id}`}
                  className={`svc-row ${focusSvc === s.id ? 'sel' : ''}`} style={{ cursor: 'default' }}>
                  <div className="grow">
                    <b>{s.name}</b>
                    <div className="fainttext">{fmtDur(s.durationMin)}</div>
                    {s.description &&
                      <div className="mutetext" style={{ marginTop: 4, fontSize: 13 }}>{s.description}</div>}
                  </div>
                  <span className="price">{fmtMoney(s.price)}</span>
                  <button className="btn svc-book" onClick={() => startFlow(s.id)}>Book</button>
                </div>
              ))}
            </div>
          ))}

          <h2 className="section-title">Team</h2>
          <div className="pro-grid">
            {v.staff.map((st) => (
              <div key={st.id} className="pro-card" style={{ cursor: 'default' }}>
                <div className="avatar" style={{ background: st.color }}>{initials(st.name)}</div>
                <b>{st.name}</b>
                <div className="fainttext">{st.role}</div>
              </div>
            ))}
          </div>

          <h2 className="section-title">About</h2>
          <div className="card pad about-grid">
            <div>
              <p className="mutetext" style={{ marginTop: 0 }}>
                {v.settings.businessTagline}. Walk-ins welcome when the calendar allows — booking
                ahead guarantees your slot. Find us in the heart of Gauthier.
              </p>
              <div className="fainttext">{v.settings.businessAddress}<br />{v.settings.businessPhone}</div>
            </div>
            <table className="hours-table">
              <tbody>
                {v.hours.map((h) => (
                  <tr key={h.weekday} className={h.weekday === now.getDay() ? 'today' : ''}>
                    <td>{WEEKDAYS_FULL[h.weekday]}</td>
                    <td className="num">
                      {h.open != null ? `${fmtTime(h.open, true)} – ${fmtTime(h.close!, true)}` : 'Closed'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <h2 className="section-title">Reviews</h2>
          {v.reviews.map((r) => (
            <div key={r.id} className="card review-card">
              <div className="who"><span>{r.clientName}</span><StarRow rating={r.rating} size={12} /></div>
              <div className="mutetext">{r.comment}</div>
            </div>
          ))}
        </div>

        <div>
          <div className="card summary-card">
            <b style={{ fontSize: 16 }}>{v.settings.businessName}</b>
            <div className="fainttext" style={{ marginBottom: 4 }}>
              <span className="stars"><Icon name="star" size={12} /></span> {v.rating} ({v.reviews.length})
            </div>
            <div className="fainttext">{openLabel}</div>
            <button className="btn btn-accent cta" onClick={() => startFlow(null)}>Book now</button>
          </div>
        </div>
      </div>
    </>
  );
}
