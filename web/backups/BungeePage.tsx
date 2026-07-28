import { useEffect, useRef, useState } from 'react';
import { motion } from 'framer-motion';
import './bungee.css';

/* ------------------------------------------------------------------ *
 * Bungee — a React re-creation of the "Bungee" Framer agency template
 * (bungee.framer.website). Standalone page, unrelated to the salon app.
 * Section order, copy and imagery mirror the published source. /bungee
 * ------------------------------------------------------------------ */

const A = '/bungee'; // asset base

const NAV = [
  ['Home', '_01'],
  ['Works', '_02'],
  ['About', '_03'],
  ['Blog', '_04'],
  ['Contact', '_05'],
] as const;

const WORKS = [
  { name: 'THINGS®', date: '_07.25', tag: 'Branding', img: `${A}/25vnq1mtLOQZtyHC2SFJ5oOwM.png` },
  { name: 'LUNAR+', date: '_10.25', tag: 'Art Direction', img: `${A}/Aj2HIaCgDaRIBU5CPOXDYG87Xkw.png` },
  { name: 'KROMA', date: '_11.25', tag: 'Editorial', img: `${A}/0CstQqBMXHRxgJJJijOvgtf27k.png` },
  { name: 'ASTERISK', date: '_09.25', tag: 'Product', img: `${A}/RBclzaKA5wZvHtqKqsDYbFU.png` },
  { name: 'ZYPHER®', date: '_02.25', tag: 'Identity', img: `${A}/mBH6kth6L7OWKHbrGNTsxRpqEg0.jpg` },
  { name: 'GROTESKS', date: '_08.25', tag: 'Fashion', img: `${A}/ShYZkTNcW7zmk0iqaTzhXsehgk.jpg` },
];

// Full-bleed hero carousel — the art/editorial image set, shown as
// tall arch-topped panels scrolling horizontally.
const CAROUSEL = [
  '5JZsiS77dldRFBDfx3Lfk3b87M.png',
  'GGQuG2gM9TePsmC84XEwEaDl3g.png',
  'LOSSn1XuJFxdkQeIdkzwe48fY.png',
  'RBclzaKA5wZvHtqKqsDYbFU.png',
  'ui0xiw6ho8t85E3453z1YpP1M.png',
  '0CstQqBMXHRxgJJJijOvgtf27k.png',
  'mGQ8JCIsW2AAEHxOugX4Lrge2s.png',
  'HfoXDGQsWsPpJU5TGy2N63TFYnc.png',
  'ShYZkTNcW7zmk0iqaTzhXsehgk.jpg',
  'Aj2HIaCgDaRIBU5CPOXDYG87Xkw.png',
  'mBH6kth6L7OWKHbrGNTsxRpqEg0.jpg',
  'IdUxpWYbkXu6ud9ebMdtIIizs.png',
];

// Client logos shown under the intro line.
const LOGOS = [
  ['◍', 'Yallo!'],
  ['❋', 'Bliss+'],
  ['◮', 'Flea'],
  ['✳', 'Polltree'],
] as const;

const SERVICES = [
  {
    num: '001',
    title: 'Branding',
    desc: 'We craft logos and brand systems that leave a lasting impression.',
    icon: 'BZpmeobL3RknjynlTBvNC6SHNF0.svg',
    bg: 'linear-gradient(150deg, #ede4fb 0%, #ddccf6 100%)',
  },
  {
    num: '002',
    title: 'Development',
    desc: 'Beautiful and functional websites built with purpose and precision.',
    icon: 'R83AHWxl1VSJAqb7qOjxFirVwRc.svg',
    bg: 'linear-gradient(150deg, #d9f4d0 0%, #c3edb6 100%)',
  },
  {
    num: '003',
    title: 'SEO Optimization',
    desc: 'Get found faster with tailored SEO strategies backed by real data.',
    icon: 'HfhC85ieUBMrAbi9v8f3VKOlQ.svg',
    bg: 'linear-gradient(150deg, #fbd9d9 0%, #f6c2c2 100%)',
  },
  {
    num: '004',
    title: 'Social Media',
    desc: 'We plan, post, and grow your brand across every platform with purpose.',
    icon: 'WS8HWySlI6hVuzWoL4783IH5IOA.svg',
    bg: 'linear-gradient(150deg, #fce9bc 0%, #f8d99b 100%)',
  },
] as const;

const METRICS = [
  { to: 3, prefix: '', suffix: 'm+', label: 'Capital raised by brands we helped out.' },
  { to: 289, prefix: '', suffix: '', label: 'Brands launched through our creative process.' },
  { to: 56, prefix: '', suffix: '', label: 'Awards recognizing our branding excellence.' },
  { to: 97, prefix: '', suffix: '%', label: 'Client satisfaction rate across all delivered work.' },
];

const FAQ = [
  [
    'What’s included in the monthly package?',
    'Each monthly package includes a set number of design or development hours, dedicated project management, weekly updates, and priority support. We tailor it to fit your needs — whether that’s ongoing branding, web updates, or new creative assets.',
  ],
  [
    'How long does a project usually take?',
    'Timelines depend on the scope, but most branding projects take 2–3 weeks, and full website builds range from 3–6 weeks. We’ll always give you a clear timeline upfront — and stick to it.',
  ],
  [
    'Do you offer ongoing support after launch?',
    'Absolutely. We offer ongoing maintenance, design tweaks, updates, and new feature support. Think of us as your creative partner, not just a one-time service.',
  ],
  [
    'Can I hire you for just a logo or one-off design?',
    'Yes — we take on one-off projects like logos, pitch decks, or landing pages. If it’s a good fit, we’re happy to jump in and help.',
  ],
  [
    'What platforms do you build websites on?',
    'We primarily work with Framer, Webflow, and Shopify — but we’re flexible depending on your project needs and tech stack.',
  ],
  [
    'How do payments work?',
    'For fixed-scope projects, we split payments into 50% upfront and 50% upon completion. For monthly retainers, payments are made at the start of each billing cycle. We accept most major payment methods.',
  ],
  [
    'What if I’m not happy with the first concept?',
    'No problem — that’s part of the process. We include multiple rounds of revisions to ensure you’re completely happy with the final result. Your feedback helps us shape it just right.',
  ],
  [
    'Do you work with clients from any country?',
    'Yes! We work with clients around the world — across time zones, industries, and cultures. Remote collaboration is our default, and we’ve got it down to a science.',
  ],
] as const;

const POSTS = [
  { title: 'Inside the Studio: Our Process for Crafting a Standout Identity', img: `${A}/LOSSn1XuJFxdkQeIdkzwe48fY.png` },
  { title: 'From Sketch to Screen: How Ideas Evolve Into Impactful Designs', img: `${A}/GGQuG2gM9TePsmC84XEwEaDl3g.png` },
  { title: 'Why Every Brand Needs a Signature Visual Language', img: `${A}/LWFDO42tuu3vRgllxVsPbZC5SMM.png` },
];

/* -------------------- building blocks -------------------- */

function Region({ dark = false }: { dark?: boolean }) {
  return (
    <div className={`region${dark ? ' region-dark' : ''}`}>
      {['BE', 'DR', 'X'].map((i) => (
        <span key={i}>{i}</span>
      ))}
    </div>
  );
}

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
          timeZone: 'America/New_York',
        }).format(new Date()),
      );
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, []);
  return <span className="mono clock">({time} NY)</span>;
}

function CountUp({ to, prefix = '', suffix = '' }: { to: number; prefix?: string; suffix?: string }) {
  const [n, setN] = useState(0);
  const ref = useRef<HTMLSpanElement>(null);
  const done = useRef(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries[0].isIntersecting && !done.current) {
          done.current = true;
          const dur = 1400;
          const start = performance.now();
          const step = (t: number) => {
            const p = Math.min(1, (t - start) / dur);
            setN(Math.round(to * (1 - Math.pow(1 - p, 3))));
            if (p < 1) requestAnimationFrame(step);
          };
          requestAnimationFrame(step);
        }
      },
      { threshold: 0.4 },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [to]);
  return (
    <span ref={ref} className="val">
      {prefix}
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
        <a href="#top" className="brand-mark" aria-label="Bungee home">
          <img src={`${A}/hcIRUi1qFh8aGDJENXamzOak3Z8.svg`} alt="Bungee" />
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
          {NAV.map(([label, num]) => (
            <a key={label} href={`#${label.toLowerCase()}`} onClick={() => setOpen(false)}>
              <sup>{num}</sup>
              {label}
            </a>
          ))}
          <a href="mailto:hi@bungee.io" className="menu-mail">
            hi@bungee.io
          </a>
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
        <span className="hot">BE</span> / DR / X
      </div>

      <div className="hero-center">
        <motion.img
          className="wordmark-img"
          src={`${A}/MYaL4AWEDy6afpn3WmSVtWlXFjM.svg`}
          alt="Bungee®"
          initial={{ opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, ease: [0.2, 0.8, 0.2, 1] }}
        />
        <p className="hero-sub">Creative studio based in Gotham.</p>
      </div>

      <div className="hero-carousel" aria-hidden="true">
        <div className="carousel-track">
          {[...CAROUSEL, ...CAROUSEL].map((img, i) => (
            <div className="arch" key={i}>
              <img src={`${A}/${img}`} alt="" loading={i < 6 ? 'eager' : 'lazy'} />
            </div>
          ))}
        </div>
      </div>
    </header>
  );
}

function Intro() {
  return (
    <section className="intro">
      <motion.p className="intro-line" {...reveal}>
        We’re Bungee<span className="reg">®</span> — a creative studio cultivating bold brands,
        beautiful websites, and ideas that refuse to be ordinary.
      </motion.p>
      <div className="logos">
        {LOGOS.map(([glyph, name]) => (
          <span className="logo" key={name}>
            <span className="logo-ic">{glyph}</span>
            {name}
          </span>
        ))}
      </div>
    </section>
  );
}

function Works() {
  return (
    <section className="wrap pad-y" id="works">
      <div className="sec-head">
        <div>
          <span className="mono">( Selected Works )</span>
          <h2 className="sec-title">Latest Projects.</h2>
        </div>
        <span className="mono">( _©25 )</span>
      </div>

      <div className="works-grid">
        {WORKS.map((w, i) => (
          <motion.a
            key={w.name}
            className="work"
            href="#works"
            {...reveal}
            transition={{ ...reveal.transition, delay: (i % 2) * 0.08 }}
          >
            <div className="work-thumb">
              <img src={w.img} alt={w.name} loading="lazy" />
            </div>
            <div className="work-meta">
              <h3>
                {w.name} <span className="tag">— {w.tag}</span>
              </h3>
              <span className="work-date">{w.date}</span>
            </div>
          </motion.a>
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
    <section className="wrap pad-b" id="services">
      <div className="sec-head services-head">
        <h2 className="sec-title">Services.</h2>
        <a href="mailto:hi@bungee.io" className="get-in-touch">
          Get in touch <span>+</span>
        </a>
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
                <img src={`${A}/${s.icon}`} alt="" />
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
  const vid = useRef<HTMLVideoElement>(null);
  const [playing, setPlaying] = useState(false);
  const play = () => {
    vid.current?.play();
    setPlaying(true);
  };
  return (
    <section className="wrap pad-b">
      <motion.h2 className="metrics-intro" {...reveal}>
        Bungee® is a creative studio shaping bold brands and daring ideas.
      </motion.h2>

      <motion.div className="metrics-video" {...reveal}>
        <video
          ref={vid}
          src={`${A}/hero2.mp4`}
          poster={`${A}/5JZsiS77dldRFBDfx3Lfk3b87M.png`}
          playsInline
          preload="none"
          controls={playing}
          onEnded={() => setPlaying(false)}
        />
        {!playing && (
          <button className="play-btn" onClick={play} aria-label="Play video">
            <span className="tri" />
          </button>
        )}
      </motion.div>

      <div className="metrics-grid">
        {METRICS.map((m) => (
          <div className="metric" key={m.label}>
            <CountUp to={m.to} prefix={m.prefix} suffix={m.suffix} />
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
          <span className="mono">( Creative dispatch )</span>
          <h2 className="sec-title">From the journal.</h2>
        </div>
        <a href="#blog" className="pill">
          Visit Blog
        </a>
      </div>
      <div className="journal-grid">
        {POSTS.map((p) => (
          <motion.a className="post" href="#blog" key={p.title} {...reveal}>
            <div className="post-thumb">
              <img src={p.img} alt="" loading="lazy" />
            </div>
            <div className="date">May 23, 2025</div>
            <h3>{p.title}</h3>
          </motion.a>
        ))}
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="footer" id="contact">
      <div className="wrap footer-inner">
        <div className="hero-bar footer-bar">
          <Region dark />
          <Clock />
        </div>

        <h2 className="cta-h">
          We’d love to hear from you — whether you have a project in mind, or just want to say hi.
        </h2>
        <a href="mailto:hi@bungee.io" className="cta-mail">
          hi@bungee.io ↗
        </a>

        <div className="foot-cols">
          <div className="newsletter">
            <h4>Join our newsletter</h4>
            <p>Daily dose of design trends by the team.</p>
            <form onSubmit={(e) => e.preventDefault()}>
              <input type="email" placeholder="Your email" aria-label="Your email" />
              <button type="submit">Send</button>
            </form>
          </div>
          <div className="foot-nav">
            <ul>
              <li><a href="#works">Projects</a></li>
              <li><a href="#about">About</a></li>
              <li><a href="#blog">Blog</a></li>
              <li><a href="#contact">Contact</a></li>
            </ul>
          </div>
        </div>

        <div className="foot-big">Bungee®</div>

        <div className="foot-bottom">
          <span className="mono">( ©25 Bungee® )</span>
          <span className="mono">React re-creation — after the Framer template</span>
        </div>
      </div>
    </footer>
  );
}

export default function BungeePage() {
  return (
    <div className="bungee">
      <Nav />
      <Hero />
      <Intro />
      <Works />
      <Services />
      <Metrics />
      <Faq />
      <Journal />
      <Footer />
      <div className="bottom-blur" aria-hidden="true" />
    </div>
  );
}
