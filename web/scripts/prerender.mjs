// Post-build prerender for venue pages (E8-T8). See docs/adr/0001-venue-page-seo.md
// for why this is prerendering rather than SSR.
//
// Takes the built SPA shell and writes one copy per active venue with a
// venue-specific <head> plus JSON-LD, then emits sitemap.xml and robots.txt.
// The SPA still boots and renders the page — only the metadata is baked in, so
// there is exactly one rendering path.
//
// Safe to run without an API: a build must never fail because the database was
// unreachable, so a failed fetch degrades to the generic shell and exits 0.
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DIST = join(HERE, '..', 'dist');

const SITE_URL = (process.env.SITE_URL ?? 'https://blastek.ma').replace(/\/$/, '');
const API_URL = process.env.API_URL ?? 'http://localhost:4000/api/graphql';
const TIMEOUT_MS = 10_000;

const QUERY = `{
  searchVenues(limit: 60) {
    items {
      slug name city address tagline phone
      lat lng rating reviewCount priceFromCents coverUrl
    }
  }
}`;

/** HTML-escapes text for element content and double-quoted attributes. */
function esc(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/**
 * Escapes a JSON-LD payload for embedding in a <script> block.
 *
 * `</script>` inside a JSON string would end the block early, which is both a
 * broken page and an injection vector — venue names are user-supplied.
 */
function jsonLd(data) {
  return JSON.stringify(data).replace(/</g, '\\u003c');
}

async function fetchVenues() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const response = await fetch(API_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: QUERY }),
      signal: controller.signal,
    });

    if (!response.ok) throw new Error(`API returned ${response.status}`);

    const body = await response.json();
    if (body.errors?.length) throw new Error(body.errors[0].message);

    return body.data?.searchVenues?.items ?? [];
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Venue location as one phrase.
 *
 * Venues type the city into the address as often as not, so appending it
 * unconditionally yields "…, Gauthier, Casablanca, Casablanca".
 */
function locationOf(venue) {
  const address = (venue.address ?? '').trim();
  const city = (venue.city ?? '').trim();

  if (!address) return city;
  if (city && address.toLowerCase().includes(city.toLowerCase())) return address;
  return [address, city].filter(Boolean).join(', ');
}

/** Taglines are written as fragments, so they need terminal punctuation. */
function sentence(text) {
  const trimmed = text.trim();
  return /[.!?]$/.test(trimmed) ? trimmed : `${trimmed}.`;
}

function description(venue) {
  const where = locationOf(venue);

  const text = [
    venue.tagline ? sentence(venue.tagline) : `Book an appointment at ${venue.name}.`,
    where ? `${where}.` : '',
    'Book online with live availability on Blastek.',
  ]
    .filter(Boolean)
    .join(' ');

  // Search engines truncate around 160 characters; cut on a word, not mid-word.
  if (text.length <= 160) return text;
  const clipped = text.slice(0, 157);
  return `${clipped.slice(0, clipped.lastIndexOf(' ')).trimEnd()}…`;
}

function structuredData(venue) {
  const data = {
    '@context': 'https://schema.org',
    '@type': 'HealthAndBeautyBusiness',
    name: venue.name,
    url: `${SITE_URL}/v/${venue.slug}`,
  };

  if (venue.tagline) data.description = venue.tagline;
  if (venue.coverUrl) data.image = venue.coverUrl;
  if (venue.phone) data.telephone = venue.phone;

  if (venue.address || venue.city) {
    data.address = {
      '@type': 'PostalAddress',
      streetAddress: venue.address || undefined,
      addressLocality: venue.city || undefined,
      addressCountry: 'MA',
    };
  }

  if (venue.lat != null && venue.lng != null) {
    data.geo = { '@type': 'GeoCoordinates', latitude: venue.lat, longitude: venue.lng };
  }

  if (venue.priceFromCents != null) {
    // A range, not a price: schema.org priceRange is a free-text hint.
    data.priceRange = `from ${Math.round(venue.priceFromCents / 100)} MAD`;
  }

  // Only with real reviews. Emitting a rating for an unreviewed venue is the
  // structured-data abuse that costs a whole domain its rich results.
  if (venue.reviewCount > 0 && venue.rating > 0) {
    data.aggregateRating = {
      '@type': 'AggregateRating',
      ratingValue: Number(venue.rating.toFixed(1)),
      reviewCount: venue.reviewCount,
      bestRating: 5,
      worstRating: 1,
    };
  }

  return data;
}

function headFor(venue) {
  const url = `${SITE_URL}/v/${venue.slug}`;
  const title = [venue.name, venue.city, 'Blastek'].filter(Boolean).join(' — ');
  const desc = description(venue);
  const image = venue.coverUrl ? `${venue.coverUrl}` : `${SITE_URL}/icons/icon-512.png`;

  return `
    <title>${esc(title)}</title>
    <meta name="description" content="${esc(desc)}" />
    <link rel="canonical" href="${esc(url)}" />
    <meta property="og:type" content="business.business" />
    <meta property="og:site_name" content="Blastek" />
    <meta property="og:title" content="${esc(title)}" />
    <meta property="og:description" content="${esc(desc)}" />
    <meta property="og:url" content="${esc(url)}" />
    <meta property="og:image" content="${esc(image)}" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="${esc(title)}" />
    <meta name="twitter:description" content="${esc(desc)}" />
    <meta name="twitter:image" content="${esc(image)}" />
    <script type="application/ld+json">${jsonLd(structuredData(venue))}</script>`;
}

/**
 * Injects venue metadata into the built shell.
 *
 * The shell's generic `<title>` and `<meta name="description">` are removed
 * first. Leaving them would emit each tag twice, and which one a consumer honours
 * is undefined — some unfurlers take the first, which is the generic one.
 */
function render(shell, venue) {
  return shell
    .replace(/<title>.*?<\/title>/is, '')
    .replace(/<meta\s+name=["']description["'][^>]*>/i, '')
    .replace(/<\/head>/i, `${headFor(venue)}\n  </head>`);
}

function sitemap(venues) {
  const urls = [
    { loc: `${SITE_URL}/`, priority: '1.0', changefreq: 'weekly' },
    { loc: `${SITE_URL}/venues`, priority: '0.9', changefreq: 'daily' },
    ...venues.map((v) => ({
      loc: `${SITE_URL}/v/${v.slug}`,
      priority: '0.8',
      changefreq: 'weekly',
    })),
  ];

  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls
  .map(
    (u) =>
      `  <url><loc>${esc(u.loc)}</loc><changefreq>${u.changefreq}</changefreq>` +
      `<priority>${u.priority}</priority></url>`,
  )
  .join('\n')}
</urlset>
`;
}

function robots() {
  return `User-agent: *
Allow: /

# The dashboard is behind auth and has nothing to index.
Disallow: /dashboard

Sitemap: ${SITE_URL}/sitemap.xml
`;
}

async function main() {
  const shell = await readFile(join(DIST, 'index.html'), 'utf8');

  let venues = [];
  try {
    venues = await fetchVenues();
  } catch (error) {
    // Deliberately not fatal: CI builds with no API running must still produce
    // a deployable bundle. The pages work, they just carry the generic <head>.
    console.warn(
      `prerender: skipping venue pages — could not reach ${API_URL} (${error.message})`,
    );
  }

  for (const venue of venues) {
    const dir = join(DIST, 'v', venue.slug);
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, 'index.html'), render(shell, venue), 'utf8');
  }

  await writeFile(join(DIST, 'sitemap.xml'), sitemap(venues), 'utf8');
  await writeFile(join(DIST, 'robots.txt'), robots(), 'utf8');

  console.log(
    `prerender: ${venues.length} venue page(s), sitemap with ${venues.length + 2} URL(s).`,
  );
}

main().catch((error) => {
  // A genuine bug here (a missing dist/, a broken template) should fail loudly —
  // only the network path above is tolerated.
  console.error(`prerender failed: ${error.message}`);
  process.exit(1);
});
