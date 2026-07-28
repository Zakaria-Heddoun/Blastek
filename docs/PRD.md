# Blastek — Product Requirements & Technical Roadmap (Master)

Owner: Product/Engineering · Status: Draft v1 · Date: 2026-07-28

Blastek is a beauty & wellness booking marketplace + salon operating system for
Morocco (Fresha model, localized). This document set is the implementation
contract for taking the current single-venue demo to a launchable multi-venue
platform.

## Document map

| Doc | Contents |
|---|---|
| [PRD.md](PRD.md) (this file) | Personas, roles, conventions, architecture bottlenecks & remediations |
| [PRD-phase-0.md](PRD-phase-0.md) | Foundation — pre-launch must-haves (F0.x) |
| [PRD-phase-1.md](PRD-phase-1.md) | Launch → month 6 — retention & trust (F1.x) |
| [PRD-phase-2.md](PRD-phase-2.md) | Months 6–18 — monetization & depth (F2.x) |
| [PRD-phase-3.md](PRD-phase-3.md) | Differentiation & expansion (F3.x) |
| [BACKLOG.md](BACKLOG.md) | GitHub/Jira-ready backlog: Epics → Features → Tasks |

## Current architecture (what we reuse)

- **API**: Elixir/Phoenix + Absinthe GraphQL (`api/lib/blastek_web/schema.ex`),
  business logic in one context `Blastek.Salon` (`api/lib/blastek/salon.ex`),
  Ecto schemas in `api/lib/blastek/salon/schemas.ex`, accounts in
  `api/lib/blastek/accounts.ex`. PostgreSQL 16 in Docker.
- **Web**: React 18 + Vite + react-router 6. Marketplace in `web/src/market/`,
  dashboard in `web/src/admin/`, shared libs in `web/src/lib/` (`gql.ts` fetch
  client, `auth.tsx` context, `fragments.ts` shared selections).
- **Auth**: email/password (Pbkdf2), stateless `Phoenix.Token` (30-day max age),
  roles `customer | professional`, `RequireRole` Absinthe middleware.
- **Availability engine**: `Salon.availability/3` — staff-hours minus
  non-cancelled appointments walked in 15-min steps; multi-service bookings are
  back-to-back appointments grouped by `booking_ref`.

**Principle: extend, don't rewrite.** Every feature spec below names the
existing module/page it modifies. New domains get new Phoenix contexts
(`Venues`, `Notifications`, `Payments`, `Marketing`, …) alongside `Salon`, and
`Salon` itself gets split only when a file exceeds ~1,000 lines.

## Personas & roles

| Persona | Role value | Description |
|---|---|---|
| Customer | `customer` | Books, reschedules, reviews; has one user account, one client record **per venue** |
| Owner | `owner` (venue-scoped) | Full control of their venue(s), billing, team |
| Manager | `manager` (venue-scoped) | Everything except billing & venue deletion |
| Receptionist | `receptionist` (venue-scoped) | Calendar, clients, checkout; no reports/settings |
| Staff (stylist/barber) | `staff` (venue-scoped) | Own calendar, own clients' notes; read-only elsewhere |
| Platform admin | `admin` (global) | Venue approval, moderation, support, platform analytics |

Venue-scoped roles live in a `venue_members` join (user ↔ venue ↔ role); the
global `users.role` field keeps `customer | admin` and gains no venue
semantics. The legacy `professional` role migrates to an `owner` membership on
the seed venue (F0.1).

### Permission matrix (summary — details per feature)

| Capability | customer | staff | receptionist | manager | owner | admin |
|---|---|---|---|---|---|---|
| Book / cancel / reschedule own appts | ✅ | — | — | — | — | — |
| View venue calendar | — | own only | ✅ | ✅ | ✅ | ✅ |
| Create/edit appointments | — | own only | ✅ | ✅ | ✅ | ✅ |
| Checkout / POS | — | ❌ | ✅ | ✅ | ✅ | — |
| Clients CRM | — | limited | ✅ | ✅ | ✅ | — |
| Catalog / team / hours | — | ❌ | ❌ | ✅ | ✅ | — |
| Reports / sales | — | own stats | ❌ | ✅ | ✅ | aggregate |
| Venue settings / billing | — | ❌ | ❌ | ❌ | ✅ | ✅ |
| Approve venues / moderate reviews | — | — | — | — | — | ✅ |

## Architecture bottlenecks — fix BEFORE building on top

Ordered by how expensive they become if deferred. Each has a backlog task (see
BACKLOG.md, Epic E0).

| # | Bottleneck (verified in code) | Why it breaks at scale | Remediation |
|---|---|---|---|
| B1 | **Global single-tenant data model.** No `venues` table; every query in `Salon` is unscoped (`schema.ex` `venue` query takes no args). | Cannot onboard a second salon. Every feature built before this is rework. | F0.1: `venues` table + `venue_id` on all salon tables; **row-scoping, single schema** (not schema-per-tenant — Ecto prefixes complicate migrations/joins and Fresha-scale multitenancy is row-scoped). All `Salon` functions take a `venue_id` first arg; Absinthe context carries `current_venue`. Composite indexes `(venue_id, …)` on every hot path. |
| B2 | **N+1 client stats.** `client` GraphQL object resolves `appt_count`/`total_spent` via `Salon.client_stats/1` per row — 2 aggregate queries × N clients on the Clients page. | Clients page = 2N+1 queries; unusable at ~1k clients/venue. | Replace with one grouped aggregation (`GROUP BY client_id`) exposed as a batch resolver via `Absinthe.Middleware.Batch` (or dataloader). Do in F0.1 while touching every query. |
| B3 | **No pagination anywhere.** `clients`, `sales`, `services` return full tables. | Payload size + memory grows unbounded per venue and per platform admin views. | Cursor-less `limit/offset` + `total_count` connection pattern (simple, adequate); default `limit: 50`, max 200. F0.13. |
| B4 | **Booking race condition.** `Salon.book/1` checks `availability` then inserts — no lock/constraint between check and insert (`salon.ex:334`). Two clients can win the same slot. | Double-bookings appear exactly when marketing works (concurrent demand). | Wrap in `Ecto.Multi` + Postgres advisory lock on `(venue_id, staff_id, date)`; plus DB exclusion constraint (`EXCLUDE USING gist` on staff/date/int4range(start_min,end_min) where status not in cancelled) as a belt-and-braces invariant. F0.1. |
| B5 | **Money as `:float`.** `services.price`, `sales.*` are floats. | Rounding drift in invoices/TVA/commissions; illegal for fiscal documents. | Migrate to integer **centimes** (`price_cents :integer`), format in MAD client-side. Must land before invoicing (F1.6) and payments (F1.1). F0.13. |
| B6 | **Token auth is irrevocable.** `Phoenix.Token` 30-day, no server-side session, no refresh, no logout-everywhere, no password reset. | Compromised token = 30 days of access; blocker for real accounts + staff roles. | `sessions` table (token hash, user, device, expires/revoked) + short-lived access token; OTP + reset flows. F0.2. |
| B7 | **`booking_ref` from `System.os_time`** (`salon.ex:341`). | Collides under concurrency; refs are customer-facing. | `BK-` + 6-char base32 from `:crypto.strong_rand_bytes` with unique index + retry. F0.1. |
| B8 | **No background job system.** All work is request-time; nothing can send reminders, retries, digests. | Notifications, automations, exports, AI — all need async + scheduled execution. | Add **Oban** (Postgres-backed, the Elixir standard — no new infra). All sends/exports/webhooks become Oban jobs. F0.10 prerequisite. |
| B9 | **No GraphQL subscriptions transport.** Calendar/queue updates require refresh. | Walk-in queue (F1.9) and live calendar need push. | Enable Absinthe subscriptions over Phoenix PubSub + `Absinthe.Phoenix` socket. Land with F0.13; first consumer F1.9. |
| B10 | **Settings as untyped key/value strings**, read via `settings_map()`. | Per-venue config (policies, locales, deposit rules) doesn't fit `key,value` strings. | Typed `venues` columns for identity fields + `venues.settings :map` (JSONB) for policy knobs, validated by changeset. F0.1/F0.4. |
| B11 | **Uploads don't exist** (venue photos, staff portfolios, review photos). | Discovery (F0.6) needs images day one. | S3-compatible object storage (MinIO in dev docker-compose, any S3 in prod) with presigned upload URLs; `attachments` table. F0.6 prerequisite. |
| B12 | **Client identity is venue-siloed by design** (user.client_id is 1:1). | One customer at N venues needs N client records linked to one login. | Replace `users.client_id` with `clients.user_id` (nullable) + unique `(venue_id, user_id)`; `Accounts.ensure_client(user, venue_id)`. F0.1. |
| B13 | **English-only, LTR-only frontend**; strings inline in JSX. | FR/AR/RTL retrofit cost grows with every new page. | i18next + extraction now (F0.11); DB content via JSONB `translations`. |
| B14 | **Absinthe error surface is stringly-typed** (`format_errors/1` joins changeset errors). | Frontends can't map field errors to inputs; localization of errors impossible. | Structured errors `{code, field, message}` list; gql.ts surfaces per-field. F0.13. |

## Cross-cutting conventions

- **Complexity scale**: XS ≤ ½ day · S 1–2 d · M 3–5 d · L 1–2 wk · XL > 2 wk.
- **Every feature ships with**: Ecto migration (reversible), context functions +
  unit tests, GraphQL layer + integration test, frontend + i18n keys (FR/AR/EN),
  permission checks at the GraphQL layer (never UI-only), seed updates.
- **Notification flows** are declared per feature and implemented as Oban jobs
  through the `Notifications` context; channels: WhatsApp template → SMS
  fallback → (email last). All copy in FR + AR (Darija where appropriate).
- **Feature flags**: `venues.settings["flags"]` map; platform-level flags in
  `platform_settings`. Anything risky ships dark.
- **IDs in GraphQL** remain integer-backed `:id` (existing convention); slugs
  for public venue URLs.
