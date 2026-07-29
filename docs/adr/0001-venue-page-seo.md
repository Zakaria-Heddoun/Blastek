# ADR 0001 — SEO for `/v/:slug`: prerender, not SSR

**Status:** accepted · **Date:** 2026-07-29 · **Task:** E8-T8 (spike) · **PRD:** F0.6

## Context

Venue pages are the marketplace's organic acquisition surface. A shopper
searching "coiffeur Gauthier Casablanca" should find `blastek.ma/v/le-salon-anfa`,
and the result should carry the salon's name, city, rating and price range.

Today `web/` is a client-rendered SPA. `dist/index.html` is one shell whose
`<head>` is identical for every route; the venue's identity only exists after
React has run and a GraphQL round trip has resolved. That gives us:

- Every URL shares one `<title>` and no description — so a result, if it appears
  at all, is titled "Blastek".
- Nothing for the crawlers and unfurlers that do **not** execute JavaScript.
  Google does render JS, but WhatsApp, Facebook, LinkedIn, iMessage and Twitter
  read raw HTML only — and in Morocco a venue link is shared on WhatsApp far more
  often than it is found on Google. A link with no preview is the real loss here.
- No structured data, so no rating stars or price range in a rich result.

## Options considered

### A. Server-side rendering

Render React per request in Node, hydrate on the client.

- **For:** correct for every route; content is in the HTML for any consumer;
  no staleness.
- **Against:** introduces a Node server into a stack whose only backend is
  Elixir — a second runtime to deploy, monitor, patch and keep at version
  parity. Every component becomes dual-environment: `window`, `localStorage`
  (which `lib/gql.ts` reads for the auth token) and `navigator.geolocation` all
  have to be guarded, and the failure mode is a hydration mismatch that only
  shows up in production. It also puts the SPA's render on the critical path of
  a page a crawler hits, so a slow API becomes a slow crawl.

### B. Prerender venue pages at build time

After `vite build`, query the API for active venues and emit
`dist/v/<slug>/index.html` — the same SPA shell with a venue-specific `<head>`
and JSON-LD.

- **For:** no new runtime; the static host keeps serving static files. Crawlers
  and unfurlers get real metadata. The SPA boots exactly as before, so there is
  one rendering path, not two. Build stays offline-safe: if the API is
  unreachable the build still succeeds with the generic shell.
- **Against:** metadata is as old as the last deploy — a renamed venue keeps its
  old `<title>` until the next build. New venues have no prerendered page until
  then (they still work, just without metadata). Build time grows with the
  directory.

### C. Prerender on demand via a crawler-detecting proxy

Serve rendered HTML to bots, the SPA to humans.

- **Against:** requires a headless-Chrome service or a paid third party, and
  user-agent branching is fragile and looks like cloaking. Disproportionate at
  this size.

## Decision

**Option B.** Prerender `<head>` metadata and JSON-LD for every active venue at
build time.

The deciding argument is not the SEO ceiling — SSR's is higher — but that SSR's
cost is *structural* and permanent while prerendering's cost is a staleness
window we control. Adding a Node runtime to an Elixir stack is a decision that
becomes progressively harder to reverse, and dual-environment components are a
class of bug (hydration mismatch, `window` on the server) this codebase would
carry forever, in exchange for freshness on pages that change a few times a year.

Body content is deliberately **not** prerendered. Doing so would mean rendering
React to a string, which is most of SSR's complexity for a fraction of its
benefit: Google renders JS, and the non-JS consumers we actually care about
(WhatsApp and the other unfurlers) read `<head>` and stop.

## Consequences

- `web/scripts/prerender.mjs` runs as part of `npm run build`.
- Metadata is refreshed by deploying. When venue churn makes that too coarse,
  the same script can run on a schedule, or move behind the API — that is a
  change of trigger, not of design.
- Revisit if any of these become true:
  - venue detail needs to be indexed (reviews, service list) → reconsider SSR;
  - the directory grows past a few thousand venues, making build-time
    prerendering slow → generate on demand and cache;
  - we adopt a framework that makes SSR the default (E25-T5's React Native
    review may pull rendering strategy along with it).

## Also delivered

- `sitemap.xml` — home, `/venues`, and every active venue, so the directory is
  discoverable without relying on internal links being crawled.
- `robots.txt` pointing at the sitemap.
- JSON-LD `HealthAndBeautyBusiness` per venue: address, geo, price range and
  `aggregateRating` where reviews exist. Emitted **only** when there is a real
  rating — inventing `ratingValue` for an unreviewed venue is exactly the
  structured-data abuse that gets rich results revoked for the whole domain.
