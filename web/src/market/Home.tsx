// Blastek marketplace homepage — reuses the Bungee design language
// (see ../bungee/bungee.css) with Blastek's own content: a beauty &
// wellness booking marketplace for Morocco. Standalone full page.
import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { gql } from '../lib/gql';
import type { VenueSummary } from '../lib/types';
import { IMG } from './assets';
import SearchBar from './SearchBar';
import '../bungee/bungee.css';
import './home.css';
import './market.css';

const BG = '/bungee'; // reuse the pixel-mosaic category icons from the Bungee assets

const NAV = [
  ['Home', '_01', '#top'],
  ['Book', '_02', '/venues'],
  ['For pros', '_03', '/dashboard'],
  ['Log in', '_04', '/login'],
  ['Contact', '_05', '#contact'],
] as const;

const CAROUSEL = [
  IMG.hair1, IMG.salon1, IMG.barber1, IMG.nails1, IMG.spa1, IMG.hair2,
  IMG.barber2, IMG.nails2, IMG.spa3, IMG.hair3, IMG.spa2, IMG.barber3,
];

const CATEGORIES = ['Hair', 'Barbering', 'Nails', 'Spa'];
// one half of the seamless marquee loop (rendered twice, scrolled -50%)
const LOGO_SET = [...CATEGORIES, ...CATEGORIES, ...CATEGORIES];

// Stand-in cover imagery until venues upload their own photos (F0.6).
const COVERS = [IMG.salon1, IMG.hair1, IMG.barber1, IMG.nails1, IMG.spa1, IMG.hair2];

const FEATURED = `{
  venues { id slug name city address rating reviewCount priceFromCents }
}`;

const SERVICES = [
  {
    num: '01',
    title: 'Hair',
    desc: 'Cuts, colour, balayage and treatments from expert stylists.',
    icon: 'BZpmeobL3RknjynlTBvNC6SHNF0.svg',
    bg: 'linear-gradient(150deg, #ede4fb 0%, #ddccf6 100%)',
  },
  {
    num: '02',
    title: 'Barbering',
    desc: 'Fades, beard trims and hot-towel shaves, booked in seconds.',
    icon: 'R83AHWxl1VSJAqb7qOjxFirVwRc.svg',
    bg: 'linear-gradient(150deg, #d9f4d0 0%, #c3edb6 100%)',
  },
  {
    num: '03',
    title: 'Nails',
    desc: 'Manicures, gel and nail art at studios near you.',
    icon: 'HfhC85ieUBMrAbi9v8f3VKOlQ.svg',
    bg: 'linear-gradient(150deg, #fbd9d9 0%, #f6c2c2 100%)',
  },
  {
    num: '04',
    title: 'Massage & Spa',
    desc: 'Facials, massage and wellness rituals to help you unwind.',
    icon: 'WS8HWySlI6hVuzWoL4783IH5IOA.svg',
    bg: 'linear-gradient(150deg, #fce9bc 0%, #f8d99b 100%)',
  },
] as const;

const METRICS = [
  { to: 12, suffix: 'k+', label: 'Appointments booked on Blastek.' },
  { to: 40, suffix: '+', label: 'Salons, barbershops and spas.' },
  { to: 60, suffix: '+', label: 'Treatments you can book online.' },
  { to: 98, suffix: '%', label: 'Clients who would book again.' },
];

const FAQ = [
  [
    'How do I book on Blastek?',
    'Pick a treatment, choose a venue and a time from live availability, and confirm. You get instant confirmation — no phone calls, no waiting.',
  ],
  [
    'Do I need an account to book?',
    'Yes — a quick sign-up lets you manage, reschedule and cancel your appointments from your account page.',
  ],
  [
    'Can I cancel or reschedule?',
    'Absolutely. Head to “My appointments” to cancel or move any upcoming booking, right up to the venue’s cancellation window.',
  ],
  [
    'How much does Blastek cost me?',
    'Booking on Blastek is free for clients. You pay the salon for your treatment as usual — in person, at the venue.',
  ],
  [
    'How do I find salons near me?',
    'Search by treatment and city, or browse featured venues. Every listing shows real ratings, services, prices and availability.',
  ],
  [
    'I run a salon — how do I join?',
    'Blastek is also a full business dashboard: calendar, clients, checkout and reports. Open the dashboard to see how it works.',
  ],
] as const;

const POSTS = [
  { title: 'How to prep for your first balayage appointment', img: IMG.hair2 },
  { title: 'Barbershop etiquette: getting the cut you actually want', img: IMG.barber1 },
  { title: 'Building a skincare routine that actually sticks', img: IMG.spa3 },
];

/* -------------------- building blocks -------------------- */

function Clock() {
  const [time, setTime] = useState('00:00:00');
  useEffect(() => {
    const tick = () =>
      setTime(
        new Intl.DateTimeFormat('en-US', {
          hour: '2-digit',
          minute: '2-digit',
          second: '2-digit',
          hour12: false,
          timeZone: 'Africa/Casablanca',
        }).format(new Date()),
      );
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, []);
  return <span className="mono clock">({time} CASA)</span>;
}

function CountUp({ to, suffix = '' }: { to: number; suffix?: string }) {
  const [n, setN] = useState(0);
  const ref = useRef<HTMLSpanElement>(null);
  const done = useRef(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let frame = 0;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries[0].isIntersecting && !done.current) {
          done.current = true;
          const dur = 1400;
          const start = performance.now();
          const step = (t: number) => {
            const p = Math.min(1, (t - start) / dur);
            setN(Math.round(to * (1 - Math.pow(1 - p, 3))));
            if (p < 1) frame = requestAnimationFrame(step);
          };
          frame = requestAnimationFrame(step);
        }
      },
      { threshold: 0.4 },
    );
    io.observe(el);
    return () => {
      io.disconnect();
      cancelAnimationFrame(frame);
    };
  }, [to]);
  return (
    <span ref={ref} className="val">
      {n}
      {suffix}
    </span>
  );
}

const reveal = {
  initial: { opacity: 0, y: 26 },
  whileInView: { opacity: 1, y: 0 },
  viewport: { once: true, margin: '-70px' },
  transition: { duration: 0.6, ease: [0.2, 0.8, 0.2, 1] as const },
};

/* -------------------- sections -------------------- */

function Nav() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <nav className="nav">
        <a href="#top" className="brand-mark" aria-label="Blastek home">
          <span className="brand-word">blastek</span>
        </a>
        <button
          className={`menu-btn${open ? ' open' : ''}`}
          onClick={() => setOpen((o) => !o)}
          aria-label={open ? 'Close menu' : 'Open menu'}
        >
          <span className="plus" />
        </button>
      </nav>
      <div className={`menu-overlay${open ? ' show' : ''}`}>
        <div className="menu-links">
          {NAV.map(([label, num, href]) =>
            href.startsWith('#') ? (
              <a key={label} href={href} onClick={() => setOpen(false)}>
                <sup>{num}</sup>
                {label}
              </a>
            ) : (
              <Link key={label} to={href} onClick={() => setOpen(false)}>
                <sup>{num}</sup>
                {label}
              </Link>
            ),
          )}
          <Link to="/venues" className="menu-mail" onClick={() => setOpen(false)}>
            Book an appointment ↗
          </Link>
        </div>
      </div>
    </>
  );
}

function Hero() {
  return (
    <header className="hero" id="top">
      <div className="hero-clock">
        <Clock />
      </div>
      <div className="hero-region">
        <span className="hot">CASA</span> / RBT / RAK
      </div>

      <div className="hero-center">
        <motion.h1
          className="wordmark-text"
          initial={{ opacity: 0, y: -150 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ type: 'spring', stiffness: 62, damping: 12, mass: 1.15, delay: 0.15 }}
        >
          Blastek<span className="reg">®</span>
        </motion.h1>
        <motion.p
          className="hero-sub"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ duration: 1.1, ease: 'easeOut', delay: 0.9 }}
        >
          Beauty &amp; wellness booking — Casablanca.
        </motion.p>

        <motion.div
          className="hero-search"
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, ease: 'easeOut', delay: 1.05 }}
        >
          <SearchBar />
        </motion.div>
      </div>

      <motion.div
        className="hero-carousel"
        aria-hidden="true"
        initial={{ opacity: 0, y: 180 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ type: 'spring', stiffness: 55, damping: 13, mass: 1.15, delay: 0.4 }}
      >
        <div className="carousel-track">
          {[...CAROUSEL, ...CAROUSEL].map((img, i) => (
            <div className="arch" key={i}>
              <img src={img} alt="" loading={i < 6 ? 'eager' : 'lazy'} />
            </div>
          ))}
        </div>
      </motion.div>
    </header>
  );
}

function Intro() {
  return (
    <section className="intro">
      <motion.p className="intro-line" {...reveal}>
        Blastek — book top salons, barbershops and spas near you. Real availability, instant
        confirmation, no phone calls.
      </motion.p>
      <div className="logos-marquee">
        <div className="logos-marquee-track">
          {[...LOGO_SET, ...LOGO_SET].map((name, i) => (
            <span className="logo" key={i}>
              <span className="logo-ic">✳</span>
              {name}
            </span>
          ))}
        </div>
      </div>
    </section>
  );
}

function Venues() {
  const [venues, setVenues] = useState<VenueSummary[] | null>(null);

  useEffect(() => {
    gql<{ venues: VenueSummary[] }>(FEATURED)
      .then((d) => setVenues(d.venues))
      // The homepage still reads fine without this section; no error UI.
      .catch(() => setVenues([]));
  }, []);

  if (venues !== null && venues.length === 0) return null;

  return (
    <section className="wrap pad-y" id="venues">
      <div className="sec-head">
        <div>
          <span className="mono">( Featured venues )</span>
          <h2 className="sec-title">Top-rated near you.</h2>
        </div>
        <Link to="/venues" className="pill">
          See all
        </Link>
      </div>

      <div className="works-grid">
        {(venues ?? []).slice(0, 6).map((v, i) => (
          <motion.div
            key={v.id}
            {...reveal}
            transition={{ ...reveal.transition, delay: (i % 2) * 0.08 }}
          >
            <Link className="work" to={`/v/${v.slug}`}>
              <div className="work-thumb">
                <img src={COVERS[i % COVERS.length]} alt={v.name} loading="lazy" />
              </div>
              <div className="work-meta">
                <h3>
                  {v.name}
                  {(v.address || v.city) && <span className="tag">— {v.address || v.city}</span>}
                </h3>
                <span className="work-date">
                  {(v.reviewCount ?? 0) > 0 ? `★ ${v.rating?.toFixed(1)}` : 'New'}
                </span>
              </div>
            </Link>
          </motion.div>
        ))}
      </div>
    </section>
  );
}

function Services() {
  const track = useRef<HTMLDivElement>(null);
  const [atStart, setAtStart] = useState(true);
  const [atEnd, setAtEnd] = useState(false);

  const update = () => {
    const el = track.current;
    if (!el) return;
    setAtStart(el.scrollLeft <= 2);
    setAtEnd(el.scrollLeft + el.clientWidth >= el.scrollWidth - 2);
  };
  useEffect(() => {
    update();
    const el = track.current;
    el?.addEventListener('scroll', update, { passive: true });
    window.addEventListener('resize', update);
    return () => {
      el?.removeEventListener('scroll', update);
      window.removeEventListener('resize', update);
    };
  }, []);

  const scroll = (dir: 1 | -1) => {
    const el = track.current;
    if (!el) return;
    const card = el.querySelector<HTMLElement>('.svc-card');
    const step = card ? card.offsetWidth + 20 : 420;
    el.scrollBy({ left: dir * step, behavior: 'smooth' });
  };

  return (
    <section className="wrap pad-b" id="categories">
      <div className="sec-head services-head">
        <h2 className="sec-title">Categories.</h2>
        <Link to="/venues" className="get-in-touch">
          Book now <span>+</span>
        </Link>
      </div>

      <div className="svc-carousel">
        <button
          className={`svc-arrow prev${atStart ? ' hidden' : ''}`}
          onClick={() => scroll(-1)}
          aria-label="Previous"
        >
          ‹
        </button>
        <div className="svc-track" ref={track}>
          {SERVICES.map((s) => (
            <div className="svc-card" key={s.num} style={{ background: s.bg }}>
              <span className="svc-num">( {s.num} )</span>
              <div className="svc-ic">
                <img src={`${BG}/${s.icon}`} alt="" />
              </div>
              <div className="svc-foot">
                <h3>{s.title}</h3>
                <p>{s.desc}</p>
              </div>
            </div>
          ))}
        </div>
        <button
          className={`svc-arrow next${atEnd ? ' hidden' : ''}`}
          onClick={() => scroll(1)}
          aria-label="Next"
        >
          ›
        </button>
      </div>
    </section>
  );
}

function Metrics() {
  return (
    <section className="wrap pad-b">
      <motion.h2 className="metrics-intro" {...reveal}>
        Blastek helps clients book and salons run — beautifully.
      </motion.h2>

      <motion.div className="metrics-video" {...reveal}>
        <img src={IMG.salon1} alt="Le Salon Anfa interior" loading="lazy" />
      </motion.div>

      <div className="metrics-grid">
        {METRICS.map((m) => (
          <div className="metric" key={m.label}>
            <CountUp to={m.to} suffix={m.suffix} />
            <p>{m.label}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function Faq() {
  const [open, setOpen] = useState<number | null>(0);
  return (
    <section className="wrap pad-y">
      <div className="faq-grid">
        <div>
          <span className="mono">( FAQ )</span>
          <h2 className="sec-title">FAQ.</h2>
        </div>
        <div className="faq-list">
          {FAQ.map(([q, a], i) => {
            const isOpen = open === i;
            return (
              <div className={`faq-item${isOpen ? ' open' : ''}`} key={q}>
                <button className="faq-q" onClick={() => setOpen(isOpen ? null : i)}>
                  {q}
                  <span className="pm" />
                </button>
                <div
                  className="faq-a"
                  ref={(el) => {
                    if (el) el.style.height = isOpen ? `${el.scrollHeight}px` : '0px';
                  }}
                >
                  <div className="faq-a-inner">{a}</div>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}

function Journal() {
  return (
    <section className="wrap pad-y" id="blog">
      <div className="sec-head">
        <div>
          <span className="mono">( The Blastek edit )</span>
          <h2 className="sec-title">From the journal.</h2>
        </div>
        <a href="#blog" className="pill">
          Read more
        </a>
      </div>
      <div className="journal-grid">
        {POSTS.map((p) => (
          <motion.a className="post" href="#blog" key={p.title} {...reveal}>
            <div className="post-thumb">
              <img src={p.img} alt="" loading="lazy" />
            </div>
            <div className="date">Beauty &amp; grooming</div>
            <h3>{p.title}</h3>
          </motion.a>
        ))}
      </div>
    </section>
  );
}

function Newsletter() {
  const [sent, setSent] = useState(false);
  return (
    <div className="newsletter">
      <h4>Join the list</h4>
      <p>Beauty tips and new venues, straight to your inbox.</p>
      {sent ? (
        <p className="mono">( Thanks — you’re on the list. )</p>
      ) : (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            setSent(true);
          }}
        >
          <input type="email" required placeholder="Your email" aria-label="Your email" />
          <button type="submit">Send</button>
        </form>
      )}
    </div>
  );
}

function Footer() {
  return (
    <footer className="footer" id="contact">
      <div className="wrap footer-inner">
        <div className="hero-bar footer-bar">
          <div className="region region-dark">
            <span>CASA</span>
            <span>RBT</span>
            <span>RAK</span>
          </div>
          <Clock />
        </div>

        <h2 className="cta-h">Ready to book? Your next appointment is a few taps away.</h2>
        <Link to="/venues" className="cta-mail">
          Book an appointment ↗
        </Link>

        <div className="foot-cols">
          <Newsletter />
          <div className="foot-nav">
            <ul>
              <li><Link to="/venues">Book now</Link></li>
              <li><Link to="/for-business">For professionals</Link></li>
              <li><Link to="/login">Log in</Link></li>
              <li><a href="#top">Back to top</a></li>
            </ul>
          </div>
        </div>

        <div className="foot-big">blastek</div>

        <div className="foot-bottom">
          <span className="mono">( © 2026 Blastek )</span>
          <span className="mono">Book beauty &amp; wellness in Morocco</span>
        </div>
      </div>
    </footer>
  );
}

export default function Home() {
  useEffect(() => {
    document.title = 'Blastek — Book beauty & wellness';
    window.scrollTo(0, 0);
  }, []);
  return (
    <div className="bungee blastek-home">
      <Nav />
      <Hero />
      <Intro />
      <Venues />
      <Services />
      <Metrics />
      <Faq />
      <Journal />
      <Footer />
      <div className="bottom-blur" aria-hidden="true" />
    </div>
  );
}

