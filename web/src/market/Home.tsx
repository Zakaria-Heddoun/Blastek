// Blastek marketplace homepage — reuses the Bungee design language
// (see ../bungee/bungee.css) with Blastek's own content: a beauty &
// wellness booking marketplace for Morocco. Standalone full page.
import { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { gql } from '../lib/gql';
import type { VenueSummary } from '../lib/types';
import { IMG } from './assets';
import LanguageSwitcher from '../components/LanguageSwitcher';
import SearchBar from './SearchBar';
import '../bungee/bungee.css';
import './home.css';
import './market.css';

const BG = '/bungee'; // reuse the pixel-mosaic category icons from the Bungee assets

// Only the number and the destination are structural; the label is copy and
// comes from `home.nav` in the same order.
const NAV = [
  ['_01', '#top'],
  ['_02', '/venues'],
  ['_03', '/dashboard'],
  ['_04', '/login'],
  ['_05', '#contact'],
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

// Art direction only — the title and description live in the locale files and
// are matched to these by position.
const SERVICE_ART = [
  { num: '01', icon: 'BZpmeobL3RknjynlTBvNC6SHNF0.svg', bg: 'linear-gradient(150deg, #ede4fb 0%, #ddccf6 100%)' },
  { num: '02', icon: 'R83AHWxl1VSJAqb7qOjxFirVwRc.svg', bg: 'linear-gradient(150deg, #ffe9d6 0%, #ffd5b0 100%)' },
  { num: '03', icon: 'BZpmeobL3RknjynlTBvNC6SHNF0.svg', bg: 'linear-gradient(150deg, #ffe1ec 0%, #ffc6dc 100%)' },
  { num: '04', icon: 'R83AHWxl1VSJAqb7qOjxFirVwRc.svg', bg: 'linear-gradient(150deg, #d9f2ec 0%, #b8e6da 100%)' },
  { num: '05', icon: 'BZpmeobL3RknjynlTBvNC6SHNF0.svg', bg: 'linear-gradient(150deg, #e6efff 0%, #c9dcff 100%)' },
  { num: '06', icon: 'R83AHWxl1VSJAqb7qOjxFirVwRc.svg', bg: 'linear-gradient(150deg, #f6f0e2 0%, #eadfc4 100%)' },
];

// Counters only; the labels are copy, matched by position.
const METRIC_NUMBERS = [
  { to: 12, suffix: 'k+' },
  { to: 40, suffix: '+' },
  { to: 60, suffix: '+' },
  { to: 98, suffix: '%' },
];

// Images only; the titles are copy.
const POST_IMAGES = [IMG.hair2, IMG.barber1, IMG.spa3];

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
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const labels = t('home.nav', { returnObjects: true }) as string[];
  return (
    <>
      <nav className="nav">
        {/* i18n-exempt: the brand name is the same word in every language. */}
        <a href="#top" className="brand-mark" aria-label="Blastek">
          <span className="brand-word">blastek</span>
        </a>
        <button
          className={`menu-btn${open ? ' open' : ''}`}
          onClick={() => setOpen((o) => !o)}
          aria-label={open ? t('home.closeMenu') : t('home.openMenu')}
        >
          <span className="plus" />
        </button>
      </nav>
      <div className={`menu-overlay${open ? ' show' : ''}`}>
        <div className="menu-links">
          {NAV.map(([num, href], i) =>
            href.startsWith('#') ? (
              <a key={num} href={href} onClick={() => setOpen(false)}>
                <sup>{num}</sup>
                {labels[i]}
              </a>
            ) : (
              <Link key={num} to={href} onClick={() => setOpen(false)}>
                <sup>{num}</sup>
                {labels[i]}
              </Link>
            ),
          )}
          <Link to="/venues" className="menu-mail" onClick={() => setOpen(false)}>
            {t('home.ctaButton')}
          </Link>
          <div className="menu-lang"><LanguageSwitcher variant="inline" /></div>
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
        {/* i18n-exempt: city abbreviations, the same in every language. */}
        <span className="hot">CASA</span> / RBT / RAK
      </div>

      <div className="hero-center">
        <motion.h1
          className="wordmark-text"
          initial={{ opacity: 0, y: -150 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ type: 'spring', stiffness: 62, damping: 12, mass: 1.15, delay: 0.15 }}
        >
          {/* i18n-exempt: the wordmark. */}
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
  const { t } = useTranslation();

  return (
    <section className="intro">
      <motion.p className="intro-line" {...reveal}>
        {t(`home.intro`)}
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
  const { t } = useTranslation();
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
          <span className="mono">{t('home.featuredEyebrow')}</span>
          <h2 className="sec-title">{t('home.featuredHeading')}</h2>
        </div>
        <Link to="/venues" className="pill">
          {t('home.seeAll')}
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
  const { t } = useTranslation();
  const services = t('home.services', { returnObjects: true }) as { title: string; desc: string }[];
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
        <h2 className="sec-title">{t('home.categoriesHeading')}</h2>
        <Link to="/venues" className="get-in-touch">
          {t('nav.bookNow')} <span>+</span>
        </Link>
      </div>

      <div className="svc-carousel">
        <button
          className={`svc-arrow prev${atStart ? ' hidden' : ''}`}
          onClick={() => scroll(-1)}
          aria-label={t('home.previous')}
        >
          ‹
        </button>
        <div className="svc-track" ref={track}>
          {SERVICE_ART.map((art, i) => (
            <div className="svc-card" key={art.num} style={{ background: art.bg }}>
              <span className="svc-num">( {art.num} )</span>
              <div className="svc-ic">
                <img src={`${BG}/${art.icon}`} alt="" />
              </div>
              <div className="svc-foot">
                <h3>{services[i]?.title}</h3>
                <p>{services[i]?.desc}</p>
              </div>
            </div>
          ))}
        </div>
        <button
          className={`svc-arrow next${atEnd ? ' hidden' : ''}`}
          onClick={() => scroll(1)}
          aria-label={t('home.next')}
        >
          ›
        </button>
      </div>
    </section>
  );
}

function Metrics() {
  const { t } = useTranslation();
  const labels = t('home.metrics', { returnObjects: true }) as string[];

  return (
    <section className="wrap pad-b">
      <motion.h2 className="metrics-intro" {...reveal}>
        {t('home.metricsIntro')}
      </motion.h2>

      <motion.div className="metrics-video" {...reveal}>
        <img src={IMG.salon1} alt={t('home.interiorAlt')} loading="lazy" />
      </motion.div>

      <div className="metrics-grid">
        {METRIC_NUMBERS.map((m, i) => (
          <div className="metric" key={m.to}>
            <CountUp to={m.to} suffix={m.suffix} />
            <p>{labels[i]}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function Faq() {
  const { t } = useTranslation();
  const [open, setOpen] = useState<number | null>(0);
  const faq = t('home.faq', { returnObjects: true }) as { q: string; a: string }[];
  return (
    <section className="wrap pad-y">
      <div className="faq-grid">
        <div>
          <span className="mono">{t('home.faqEyebrow')}</span>
          <h2 className="sec-title">{t('home.faqHeading')}</h2>
        </div>
        <div className="faq-list">
          {faq.map(({ q, a }, i) => {
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
  const { t } = useTranslation();
  const posts = t('home.posts', { returnObjects: true }) as { title: string }[];

  return (
    <section className="wrap pad-y" id="blog">
      <div className="sec-head">
        <div>
          <span className="mono">{t('home.journalEyebrow')}</span>
          <h2 className="sec-title">{t('home.journalHeading')}</h2>
        </div>
        <a href="#blog" className="pill">
          {t('home.readMore')}
        </a>
      </div>
      <div className="journal-grid">
        {POST_IMAGES.map((img, i) => (
          <motion.a className="post" href="#blog" key={img} {...reveal}>
            <div className="post-thumb">
              <img src={img} alt="" loading="lazy" />
            </div>
            <div className="date">{t('home.postCategory')}</div>
            <h3>{posts[i]?.title}</h3>
          </motion.a>
        ))}
      </div>
    </section>
  );
}

function Newsletter() {
  const { t } = useTranslation();
  const [sent, setSent] = useState(false);
  return (
    <div className="newsletter">
      <h4>{t('home.newsletterTitle')}</h4>
      <p>{t('home.newsletterBody')}</p>
      {sent ? (
        <p className="mono">{t('home.newsletterThanks')}</p>
      ) : (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            setSent(true);
          }}
        >
          <input
            type="email"
            required
            placeholder={t('home.emailPlaceholder')}
            aria-label={t('home.emailPlaceholder')}
          />
          <button type="submit">{t('home.send')}</button>
        </form>
      )}
    </div>
  );
}

function Footer() {
  const { t } = useTranslation();

  return (
    <footer className="footer" id="contact">
      <div className="wrap footer-inner">
        <div className="hero-bar footer-bar">
          <div className="region region-dark">
            {/* i18n-exempt: city abbreviations. */}
            <span>CASA</span>
            {/* i18n-exempt: city abbreviations. */}
            {/* i18n-exempt: city abbreviations. */}
            <span>RBT</span>
            {/* i18n-exempt: city abbreviations. */}
            <span>RAK</span>
          </div>
          <Clock />
        </div>

        <h2 className="cta-h">{t('home.ctaHeading')}</h2>
        <Link to="/venues" className="cta-mail">
          {t('home.ctaButton')}
        </Link>

        <div className="foot-cols">
          <Newsletter />
          <div className="foot-nav">
            <ul>
              <li><Link to="/venues">{t('nav.bookNow')}</Link></li>
              <li><Link to="/for-business">{t('nav.forProfessionals')}</Link></li>
              <li><Link to="/login">{t('nav.login')}</Link></li>
              <li><a href="#top">{t('home.backToTop')}</a></li>
            </ul>
          </div>
        </div>

        <div className="foot-big">blastek</div>

        <div className="foot-bottom">
          <span className="mono">{t('home.copyright')}</span>
          <span className="mono">{t('home.footerLine')}</span>
        </div>
      </div>
    </footer>
  );
}

export default function Home() {
  const { t } = useTranslation();

  useEffect(() => {
    document.title = t('home.title');
    window.scrollTo(0, 0);
  }, [t]);
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

