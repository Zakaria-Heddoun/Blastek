// Marketplace landing. Hero and testimonials patterns adapted from 21st.dev
// ("Hero Section" by ravikatiyar, "Testimonials with Marquee" by serafim),
// restyled to the Blastek design system.
import { useEffect, useState } from 'react';
import type { CSSProperties, ReactNode } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { motion, type Variants } from 'framer-motion';
import { useVenue } from './MarketLayout';
import { categoryImg, CITIES, IMG } from './assets';
import { Icon, Sparkle, StarRow } from '../lib/icons';
import { Marquee } from '../components/Marquee';
import { initials, todayStr } from '../lib/format';

const container: Variants = {
  hidden: { opacity: 0 },
  visible: { opacity: 1, transition: { staggerChildren: 0.12 } },
};
const item: Variants = {
  hidden: { opacity: 0, y: 14 },
  visible: { opacity: 1, y: 0, transition: { duration: 0.4, ease: 'easeOut' } },
};

// `?static` skips entrance animation — used by headless screenshot verification,
// where the rAF clock freezes and captures would show the mid-animation state.
const noMotion = new URLSearchParams(window.location.search).has('static');
function Floating({ children, delay = 0, className, style }: {
  children?: ReactNode; delay?: number; className?: string; style?: CSSProperties;
}) {
  // entrance (opacity/scale) and the infinite float (y) run on separate channels
  return (
    <motion.div className={className} style={style}
      initial={noMotion ? false : { opacity: 0, scale: 0.88 }}
      animate={{ opacity: 1, scale: 1, y: [0, -8, 0] }}
      transition={{
        opacity: { duration: 0.45, ease: 'easeOut', delay: delay * 0.4 },
        scale: { duration: 0.45, ease: 'easeOut', delay: delay * 0.4 },
        y: { duration: 4, repeat: Infinity, ease: 'easeInOut', delay },
      }}>
      {children}
    </motion.div>
  );
}

export default function Landing() {
  const { venue: v, booking } = useVenue();
  const navigate = useNavigate();
  const [svcId, setSvcId] = useState('');
  const [date, setDate] = useState(todayStr());

  useEffect(() => {
    document.title = 'Blastek — Book beauty & wellness';
    window.scrollTo(0, 0);
  }, []);

  const search = () => {
    booking.setDate(date);
    navigate(svcId ? `/venue?svc=${svcId}` : '/venue');
  };

  const heroStats = [
    { icon: 'calendar', value: `${v.stats.bookings.toLocaleString('en-US')}+`, label: 'appointments booked' },
    { icon: 'users', value: String(v.stats.professionals), label: 'professionals' },
    { icon: 'star', value: String(v.rating), label: 'average rating' },
  ];

  return (
    <>
      <section className="mk-hero sparkle-field">
        <div className="bk-shell hero-grid">
          <motion.div variants={container} initial={noMotion ? false : 'hidden'} animate="visible">
            <motion.div className="eyebrow" variants={item}>Booking platform · Morocco</motion.div>
            <motion.h1 variants={item}>Book beauty and wellness<br />services near you</motion.h1>
            <motion.p className="mutetext hero-sub" variants={item}>
              Discover top salons and barbershops, compare treatments, and book in
              seconds — with instant confirmation.
            </motion.p>
            <motion.div className="search-card" role="search" variants={item}>
              <div className="sfield">
                <label>Treatment</label>
                <select value={svcId} onChange={(e) => setSvcId(e.target.value)}>
                  <option value="">All treatments</option>
                  {v.categories.map((c) => (
                    <optgroup key={c.id} label={c.name}>
                      {v.services.filter((s) => s.categoryId === c.id).map((s) => (
                        <option key={s.id} value={s.id}>{s.name}</option>
                      ))}
                    </optgroup>
                  ))}
                </select>
              </div>
              <div className="sfield">
                <label>Location</label>
                <select defaultValue="Casablanca">
                  {CITIES.map((c) => <option key={c}>{c}</option>)}
                </select>
              </div>
              <div className="sfield">
                <label>Date</label>
                <input type="date" value={date} min={todayStr()} onChange={(e) => setDate(e.target.value)} />
              </div>
              <button className="btn btn-accent search-btn" onClick={search}>Search</button>
            </motion.div>
            <motion.div className="hero-stats" variants={item}>
              {heroStats.map((s) => (
                <div key={s.label} className="hero-stat">
                  <div className="bubble"><Icon name={s.icon} size={18} /></div>
                  <div>
                    <div className="v">{s.value}</div>
                    <div className="l">{s.label}</div>
                  </div>
                </div>
              ))}
            </motion.div>
          </motion.div>

          <motion.div className="hero-collage">
            <Floating className="float-shape" delay={0.4}
              style={{ left: '2%', top: '10%', width: 46, height: 46, background: 'rgba(216,184,138,.18)' }} />
            <Floating className="float-shape" delay={1.2}
              style={{ right: '6%', top: '4%', width: 30, height: 30, background: 'rgba(214,193,173,.14)' }} />
            <Floating className="float-shape" delay={0.8}
              style={{ right: '30%', bottom: '2%', width: 38, height: 38, background: 'rgba(101,26,42,.5)' }} />
            <Floating className="cimg cimg-a" delay={0}>
              <img src={IMG.barber1} alt="Barbershop interior" />
            </Floating>
            <Floating className="cimg cimg-b" delay={0.6}>
              <img src={IMG.nails1} alt="Manicure" />
            </Floating>
            <Floating className="cimg cimg-c" delay={1.1}>
              <img src={IMG.hair1} alt="Salon interior" />
            </Floating>
          </motion.div>
        </div>
      </section>

      <section className="bk-shell mk-section">
        <h2 className="section-title">Browse by category</h2>
        <div className="tile-grid">
          {v.categories.map((c) => (
            <Link key={c.id} className="tile" to={`/venue?cat=${c.id}`}>
              <img src={categoryImg(c.name)} alt={c.name} />
              <span>{c.name}</span>
            </Link>
          ))}
        </div>
      </section>

      <section className="bk-shell mk-section">
        <h2 className="section-title">Recommended near you</h2>
        <div className="venue-rail">
          <Link className="venue-card card" to="/venue">
            <img src={IMG.salon1} alt={v.settings.businessName} />
            <div className="vc-body">
              <b>{v.settings.businessName}</b>
              <div className="fainttext">
                <span className="stars"><Icon name="star" size={12} /></span>{' '}
                {v.rating} ({v.reviews.length}) · Gauthier, Casablanca
              </div>
              <div className="chip-row" style={{ marginTop: 8 }}>
                {v.categories.slice(0, 3).map((c) => <span key={c.id} className="badge online">{c.name}</span>)}
              </div>
            </div>
          </Link>
          {([['Riad Coiffure', 'Maârif, Casablanca', IMG.hair1], ['Barber Corner', 'Agdal, Rabat', IMG.barber2],
            ['Nova Nails', 'Guéliz, Marrakech', IMG.nails2]] as const).map(([name, area, img]) => (
            <div key={name} className="venue-card card is-soon">
              <img src={img} alt="" />
              <div className="vc-body">
                <b>{name}</b>
                <div className="fainttext">{area}</div>
                <div className="fainttext" style={{ marginTop: 8 }}>Coming soon to Blastek</div>
              </div>
            </div>
          ))}
        </div>
      </section>

      <section className="stats-band">
        <div className="bk-shell">
          <h2>The destination for beauty and wellness in Morocco</h2>
          <div className="stats-grid">
            <div><div className="sv">{v.stats.bookings.toLocaleString('en-US')}+</div><div className="sl">appointments booked</div></div>
            <div><div className="sv">{v.stats.professionals}</div><div className="sl">professionals</div></div>
            <div><div className="sv">{v.stats.services}</div><div className="sl">treatments to book</div></div>
            <div><div className="sv">{v.rating}</div><div className="sl">average rating</div></div>
          </div>
        </div>
      </section>

      <section className="mk-section" style={{ overflow: 'hidden' }}>
        <div className="bk-shell">
          <h2 className="section-title">Loved by clients across the city</h2>
        </div>
        <Marquee duration={45}>
          {v.reviews.map((r) => (
            <div key={r.id} className="card review-card">
              <div className="review-who">
                <div className="avatar">{initials(r.clientName)}</div>
                <div>
                  <b>{r.clientName}</b>
                  <div><StarRow rating={r.rating} size={11} /></div>
                </div>
              </div>
              <div className="mutetext">{r.comment}</div>
            </div>
          ))}
        </Marquee>
      </section>

      <section className="bk-shell mk-section">
        <div className="pro-band card">
          <div>
            <div className="eyebrow" style={{ marginBottom: 8 }}>Blastek for professionals</div>
            <h2 style={{ fontSize: 22 }}>The booking platform for salons and barbershops</h2>
            <p className="mutetext" style={{ maxWidth: 520 }}>
              Calendar, clients, payments and reporting in one place. Your clients book online,
              you run the day from one screen.
            </p>
          </div>
          <a className="btn btn-accent" style={{ borderRadius: 999, padding: '11px 22px' }}
            href="/dashboard" target="_blank" rel="noreferrer">Open the dashboard</a>
        </div>
      </section>

      <footer className="mk-footer">
        <div className="bk-shell">
          <div className="eyebrow" style={{ marginBottom: 10 }}>Browse by city</div>
          <div className="city-row">
            {CITIES.map((c) => <Link key={c} to="/venue">{c}</Link>)}
          </div>
          <div className="foot-base">
            <span className="logo" style={{ padding: 0, fontSize: 15 }}>
              <span className="spark"><Sparkle size={14} /></span> blastek
            </span>
            <span className="fainttext">© 2026 Blastek — demo, runs locally</span>
          </div>
        </div>
      </footer>
    </>
  );
}
