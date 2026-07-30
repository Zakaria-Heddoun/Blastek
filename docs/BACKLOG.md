# Blastek — Engineering Backlog

Structure: **Epic → Feature → Task**. Task IDs are stable (`E<epic>-T<n>`).
Estimates use the PRD scale (XS ≤½d · S 1–2d · M 3–5d · L 1–2wk · XL >2wk).
Labels: `phase:0..3`, `area:api|web|infra|design|spike`, `type:feat|chore|test|spike`.

**Importing**: GitHub — create milestones `Phase 0..3`, labels above, then one
issue per Task (epics as GitHub *milestone-pinned tracking issues* with task
lists). Scriptable via `gh issue create` loop over this file's tables. Jira —
epics as Epics, tasks as Stories/Tasks with `Epic Link`; the tables below
paste into CSV import (columns: Summary, Description=PRD ref, Epic, Labels,
Estimate).

Dependency rule: within an epic, tasks are ordered; across epics, follow the
per-phase implementation order in the PRDs.

---

## Phase 0

### E1 · Multi-tenancy core — F0.1 · [PRD-phase-0.md](PRD-phase-0.md)

**Status: ✅ COMPLETE and verified.** Migration applied (forward and rollback),
two-venue seed running, **48 tests passing**, both apps verified end-to-end in
the browser against the live API.

| ID | Task | Est | Labels | Status |
|---|---|---|---|---|
| E1-T1 | Migration: `venues`, `venue_members`; `venue_id` on all salon tables; composite indexes | M | api | ✅ written |
| E1-T2 | Data migration: absorb existing rows into venue #1; `professional` → owner membership; reversible | S | api | ✅ written |
| E1-T3 | Migration: `clients.user_id` (+unique per venue), drop `users.client_id`, backfill | S | api | ✅ written |
| E1-T4 | `Blastek.Venues` context: CRUD, slug generation, memberships | M | api | ✅ |
| E1-T5 | `Blastek.Scope` helper + thread `venue_id` through every `Salon` function | L | api | ✅ |
| E1-T6 | Absinthe context: resolve `current_venue` from membership (+`X-Venue-Slug` for multi) | S | api | ✅ |
| E1-T7 | Replace `RequireRole "professional"` with `RequireMember` middleware (per-capability min role) | M | api | ✅ |
| E1-T8 | `venue(slug:)` + `myVenues` queries; public venue fields | S | api | ✅ |
| E1-T9 | Booking race fix: advisory lock + exclusion constraint; concurrency test (20× same slot) | M | api,test | ✅ verified |
| E1-T10 | `booking_ref` → crypto-random base32 + unique index | XS | api | ✅ |
| E1-T11 | Batch `client_stats` resolver (grouped aggregate, Absinthe Batch) | S | api,test | ✅ |
| E1-T12 | `Accounts.ensure_client(user, venue_id)`; remove `link_client` | S | api | ✅ |
| E1-T13 | Web: `/v/:slug` routes; MarketLayout/VenuePage/BookingFlow venue-by-slug | M | web | ✅ verified |
| E1-T14 | Web: AdminLayout venue switcher + role-aware nav; Account groups by venue | S | web | ✅ verified |
| E1-T15 | Cross-tenant isolation test suite (48 tests) | M | test | ✅ passing |
| E1-T16 | Seed: second demo venue (barbershop) with distinct catalog | S | api | ✅ verified |

**Verification performed**

```
docker compose run --rm api mix ecto.reset        # migration + two-venue seed
docker compose run --rm api sh -c "MIX_ENV=test mix test"   # 48 tests, 0 failures
docker compose run --rm api mix ecto.rollback && mix ecto.migrate   # reversible
```

Manual pass against the live API confirmed: two owners see disjoint
staff/clients/revenue; a forged `X-Venue-Slug` is rejected; a foreign record id
returns "Not found." rather than a 500; one customer books at both venues and
sees both in "My appointments".

**Post-verification principal review (2026-07-29)** — full-suite still green
(53 tests) after fixing: reactivating a cancelled appointment skipped the
clash check (500/ugly constraint error instead of "overlaps"); checkout of an
already-completed appointment recorded a second sale (revenue inflation on
double-click); `cancelMyAppointment` scanned a 100-row list instead of
querying by id (appointments beyond 100 uncancellable); `find_or_create_client`
race lost to the unique index instead of recovering the winner's row;
membership management was venue-scoped only in the resolver, now in the
`Venues` context like every other domain; advisory-lock key switched from
`phash2` (collision → false serialization) to collision-free (staff_id,
day-number); migration rollback now restores the settings table's identity
from venue #1; ProLogin refuses an empty salon name client-side (previously
burned the email on a customer account that could never reach the dashboard).
Added tests: staff own-column calendar scoping, adminVenues gate, cross-venue
membership management, reactivation clash, double checkout.

**Defects found and fixed during verification** (worth remembering — each would
have shipped):

| Defect | Fix |
|---|---|
| On a **fresh** DB the adoption `INSERT ... SELECT FROM settings` still produced an all-NULL aggregate row, creating a phantom "My salon" venue that made the seed skip | `HAVING COUNT(*) > 0 OR EXISTS(...)` so adoption only runs when there is data to adopt |
| Cross-tenant reads raised `Ecto.NoResultsError` out of Absinthe → HTTP 500 instead of a GraphQL error | `found/1` wrapper in the schema turns it into `"Not found."`, identical to a genuinely missing id so it cannot be used to probe ids |
| `config/test.exs` hardcoded `hostname: "localhost"` — tests could not run in Docker | mirrors dev's `DB_HOST`/`DB_PORT` env handling |
| `seeds.exs` passed a multi-generator `for` directly as a call argument (syntax error) | bound to a variable first |

### E2 · Platform hardening — F0.13, F0.14

**Status: 8 of 9 complete and verified** (73 tests). E2-T8 deferred — see below.

| ID | Task | Est | Labels | Status |
|---|---|---|---|---|
| E2-T1 | Pagination (`limit/offset/totalCount`) on clients + sales; date-range cap on appointments | M | api,web | ✅ |
| E2-T2 | Money → integer centimes: migration with reconciliation, `fmtMAD`/`madToCents` | M | api,web | ✅ |
| E2-T3 | Structured errors `{code, field, message}`; `GqlError` + form field-error display | S | api,web | ✅ |
| E2-T4 | Absinthe subscriptions: socket, PubSub, `appointmentChanged` per venue | M | api,web | ✅ api |
| E2-T5 | Rate limiting (ETS): per-IP plug + per-identity/per-IP auth buckets | S | api | ✅ |
| E2-T6 | Index audit with `EXPLAIN` at 100k rows; added + dropped redundant | S | api,infra | ✅ |
| E2-T7 | PWA: manifest, generated icons, offline app shell | S | web | ✅ |
| E2-T8 | Web push (Android): opt-in flow, subscription storage, send worker | S | api,web | ⏸ deferred |
| E2-T9 | CI pipeline: compile/format/migration-reversibility/test + web build + money guard | M | infra | ✅ |

**E2-T8 deferred to E6 (Notifications).** Push needs a template/locale/preference
model and a delivery worker — exactly the `Notifications` context F0.10 builds.
Shipping a second, push-only sender now means writing that machinery twice and
throwing one away. The PRD already records this dependency (F0.14 → F0.10).

**Notes from implementation**

* Money field names carry their unit (`priceCents`, not `price`) — a silent
  change of scale under an unchanged name is how a 100× pricing bug ships. CI
  greps for the old float accessors to keep them from coming back.
* The migration verifies every row round-trips within half a centime and
  aborts otherwise; on the seeded database 142,466.00 MAD converted exactly and
  came back exactly on rollback.
* Rate limiting is **per node** by design (ETS). A multi-node deployment needs
  a shared store; the buckets move unchanged.
* Auth limits are counted *before* the password check, so a wrong guess costs
  the same as a right one — otherwise the limiter is trivially evaded, and the
  error text tells an attacker when they hit the right password.
* Subscriptions authorize in `config/2`, not middleware: the topic *is* the
  authorization decision. Middleware on a subscription field also breaks
  Absinthe's telemetry path.
* `EXPLAIN` at 100k sale lines: the reports join ran **0.80 ms with the new
  `sale_items.sale_id` index vs 11.90 ms without**, and the gap grows with total
  history rather than the reporting window.
* Appointments are bounded by a 92-day range cap rather than offset paging — a
  calendar is naturally bounded by dates, and paging a week makes no sense.

### E3 · Auth & identity — F0.2

**Status: ✅ COMPLETE and verified** (261 tests).

| ID | Task | Est | Labels | Status |
|---|---|---|---|---|
| E3-T1 | Migrations: `sessions`, `otp_codes`, `users.phone_verified_at` + unique verified phone | S | api | ✅ |
| E3-T2 | Sessions module: issue/verify/refresh/revoke; token TTLs; swap auth_context | M | api | ✅ |
| E3-T3 | OTP module: generate/hash/verify, attempts, cooldown, purposes | S | api | ✅ |
| E3-T4 | Phone normalization (E.164, Moroccan formats) + property tests | S | api,test | ✅ |
| E3-T5 | GraphQL: requestOtp/verifyOtp/completeProfile/logout/revokeSession/mySessions | S | api | ✅ |
| E3-T6 | Password reset (email link + OTP variants) | S | api | ✅ |
| E3-T7 | Web: AuthShell OTP mode (phone → code screens); account settings sessions page | M | web | ✅ |
| E3-T8 | OTP delivery templates through Notifications (dev logger until E6 lands) | XS | api | ✅ |

**Acceptance criteria** (F0.2), all met: `requestOtp` → `verifyOtp` issues a
session and creates an account for an unseen number, with the name asked
afterwards · 6 digits, 5-minute TTL, 3 attempts, 60-second resend cooldown ·
sessions listed and revocable in the account, access 24 h, refresh 60 d,
refresh rotates · password reset end to end by email link and by SMS code ·
OTP endpoints rate-limited per phone and per IP, hashes stored and never the
code · existing email/password accounts unaffected.

**Verification performed**

```
docker compose exec api sh -c "MIX_ENV=test mix test"   # 261 tests, 0 failures
docker compose exec api mix compile --warnings-as-errors && mix format --check-formatted
docker compose exec api sh -c "MIX_ENV=test mix ecto.rollback --all && mix ecto.migrate"
docker compose run --rm api mix ecto.reset               # migrations + seed + reindex
cd web && npx tsc --noEmit && npm run build              # + prerender, + money guard
```

Driven in a real browser against the running stack: phone is the default
sign-in method, a code arrives and the number is masked, a wrong code is
refused, the real one creates the account and asks for a name, the session
survives a reload and lists "Edge on Windows" as the current device, the
password panel omits "current password" for an account that has none, the
60-second cooldown genuinely blocks a second code, the reset page confirms
without disclosing whether the address exists, and logout sends `/account`
back to `/login` because the session is really gone server-side.

**Notes from implementation**

* **Sessions replace the stateless token, and that is the whole point.** Auth
  was a signed `Phoenix.Token` carrying a user id with nothing stored, which
  made "log out the phone I lost" and "revoke a compromised account"
  unimplementable — there was no record to revoke. ⚠️ **Everyone signs in once
  more when this deploys**: old tokens reference a scheme that no longer exists,
  and keeping a parallel unrevocable path would have defeated the epic.
* Tokens are 32 random bytes; only the SHA-256 is stored. SHA-256 rather than
  Pbkdf2 *here* because the input already has 256 bits of entropy — there is no
  search to slow down, and this runs on every authenticated request.
* OTP codes are the opposite case and get **Pbkdf2**: six digits is a
  million-entry space, so a leaked table of SHA-256 digests would be reversed
  faster than it could be downloaded.
* **Refresh rotates, and reuse is treated as theft.** Presenting a refresh token
  that was already rotated away means two parties hold it; the session is
  revoked rather than guessing which caller is legitimate. Without that,
  rotation only means the thief has to be quick.
* Every OTP failure reads the same to the caller. Distinguishing "no code for
  this number" from "wrong code" would turn `requestOtp` into a way to ask which
  Moroccan numbers have Blastek accounts; `requestPasswordReset` always reports
  success for the same reason.
* One code live per `(phone, purpose)`. Purposes are isolated so a login code
  cannot complete a password reset, and a resend supersedes rather than adds —
  otherwise attempts could be banked across a stack of live codes.
* `email` and `password_hash` became nullable, because a phone-first account has
  neither. Empty string would not do for email: the unique index is on
  `lower(email)`, so the second passwordless account would collide with the
  first. The rollback backfills a reserved `.invalid` address, so going back is
  lossless.
* Changing a password from inside the account signs out **other** devices but
  not the caller's; a reset signs out everything. The first is how someone
  responds to "I think somebody else is logged in as me", the second happens
  when they are already locked out.
* `Notifications` is a deliberate stub — a provider behaviour, a dev logger, and
  FR/AR/EN templates. E6 replaces it with the real context; this establishes
  only the seam and the locale shape, which are the parts that would hurt to
  retrofit.

**Defects and hazards found during verification**

| Finding | Fix |
|---|---|
| The whole suite slowed to 170 s and the search perf gate began failing at ExUnit's 60 s limit — Pbkdf2 now runs on nearly every fixture. A perf gate that fails because the *machine* is slow is the most misleading way it can fail | `config :pbkdf2_elixir, :rounds, 1` in test (170 s → 6 s), plus a generous `@moduletag timeout` and one fixture build instead of two on the perf test |
| Every new auth test failed together: `Blastek.RateLimit` is one ETS table shared by the whole run, so `async: true` tests reusing one phone and IP throttled each other into failures that looked like bugs | A distinct number and IP per test — which is also what real users are |
| `Sessions.describe/1` parses a raw User-Agent, but the test passed it a pre-formatted label and asserted the label came back | Test fixed to pass a real User-Agent string |

**Deferred, unchanged from E8:** `phoenix` 1.7.23 (HIGH) and `react-router` 6.x
(2 × MODERATE) still need framework major bumps and still belong in their own
CH-1 change rather than a feature commit.

### E4 · Team & permissions — F0.3
| ID | Task | Est | Labels |
|---|---|---|---|
| E4-T1 | Migration + context: `venue_invitations`; invite/accept/remove/change-role | M | api |
| E4-T2 | `RequireMember` per-field minimum roles across schema; role integration-test matrix | M | api,test |
| E4-T3 | `staff` role scoping: own-calendar-only queries | S | api |
| E4-T4 | Web: Team page members tab (invite modal, roles); role-aware nav in AdminLayout | M | web |
| E4-T5 | Invitation accept flow (deep link → OTP → membership) | S | web |
| E4-T6 | Last-owner protection + audit of membership changes | XS | api |

### E5 · Venue settings & onboarding — F0.4, F0.5
| ID | Task | Est | Labels |
|---|---|---|---|
| E5-T1 | `updateVenue` + typed settings JSONB validation | S | api |
| E5-T2 | Closures: table, CRUD, availability subtraction, past-midnight ranges | M | api |
| E5-T3 | Hour templates (default/ramadan) + switch + staff-hours variants | M | api |
| E5-T4 | Conflict detection: closures/template changes vs existing bookings → action list | S | api |
| E5-T5 | Web: SettingsPage (identity, hours grid, closures, templates) | L | web |
| E5-T6 | Calendar: closure/holiday shading | S | web |
| E5-T7 | Onboarding: `service_templates` seed catalogs (5 categories, i18n names) | S | api |
| E5-T8 | Onboarding wizard API (step state, submit, approve/reject) | M | api |
| E5-T9 | Web: OnboardVenue wizard `/for-business` (mobile-first, resumable) | L | web |
| E5-T10 | Duplicate-venue detection heuristic for admin queue | XS | api |

### E6 · Notifications & WhatsApp — F0.10
| ID | Task | Est | Labels |
|---|---|---|---|
| E6-T1 | Add Oban; queues, telemetry, dashboard config | S | api,infra |
| E6-T2 | `Notifications` context: templates, locale rendering, send log table, prefs | M | api |
| E6-T3 | Provider behaviour + `DevLogger`; config-driven selection | S | api |
| E6-T4 | WhatsApp Cloud API provider: send, template mgmt, webhook (delivery + inbound STOP) | L | api,infra |
| E6-T5 | SMS provider (chosen gateway) + WhatsApp→SMS fallback chain | M | api |
| E6-T6 | Booking/cancel/reschedule hooks → confirmation jobs (customer + salon) | S | api |
| E6-T7 | Reminder scheduling (T-24h/T-3h), cancellation-aware, venue-configurable offsets | M | api |
| E6-T8 | Signed one-tap action links (confirm/cancel) HTTP endpoints | S | api |
| E6-T9 | Meta template approval pack (FR/AR copy for all v1 templates) | S | design |
| E6-T10 | Web: notification prefs UI; dashboard live toast on online booking (uses E2-T4) | S | web |

### E7 · i18n — F0.11
| ID | Task | Est | Labels |
|---|---|---|---|
| E7-T1 | i18next setup (fr/ar/en), language switcher, persistence, locale plug API-side | S | web,api |
| E7-T2 | String extraction: market pages (Home, Venue, Flow, Auth, Account) | M | web |
| E7-T3 | String extraction: admin pages (all 7) + platform | M | web |
| E7-T4 | RTL audit + fixes for both CSS systems (logical properties pass) | L | web,design |
| E7-T5 | FR + AR translation files (professional review, Darija tone for consumer) | M | design |
| E7-T6 | DB content translations JSONB (services/categories/venues) + locale-resolving fields | M | api |
| E7-T7 | Catalog editor per-locale inputs (FR/AR tabs) | S | web |
| E7-T8 | Hardcoded-string CI lint gate | XS | infra |

### E8 · Discovery — F0.6

**Status: ✅ COMPLETE and verified** (162 tests). Built out of phase order,
before E3–E7, at the product owner's direction.

| ID | Task | Est | Labels | Status |
|---|---|---|---|---|
| E8-T1 | Storage: MinIO in compose, `Blastek.Storage` behaviour, presigned uploads, `attachments` | M | api,infra | ✅ |
| E8-T2 | Image variant worker (thumb/card/hero) | S | api | ✅ |
| E8-T3 | Search: tsvector + FTS query, city/category/women-only filters, pagination | M | api | ✅ |
| E8-T4 | Geo: lat/lng, onboarding geocode (Nominatim + manual pin), distance sort | M | api | ✅ |
| E8-T5 | `searchVenues` GraphQL + `priceFrom` per venue | S | api | ✅ |
| E8-T6 | Web: Home search + results grid + filters + map toggle (Leaflet) | L | web | ✅ |
| E8-T7 | Web: VenuePage gallery + map + photo upload in Settings | M | web | ✅ |
| E8-T8 | SEO spike: SSR vs prerender for `/v/:slug`; implement chosen approach | M | spike,web | ✅ [ADR](adr/0001-venue-page-seo.md) |
| E8-T9 | Search perf test @1k venues (p95 < 300ms) | S | test | ✅ 23 ms |

**Verification performed**

```
docker compose exec api sh -c "MIX_ENV=test mix test"   # 162 tests, 0 failures
docker compose exec api mix compile --warnings-as-errors && mix format --check-formatted
docker compose exec api sh -c "MIX_ENV=test mix ecto.rollback --all && mix ecto.migrate"
docker compose run --rm api mix ecto.reset               # migrations + seed + reindex
cd web && npx tsc --noEmit && npm run build              # + prerender, + money guard
```

Driven in a real browser (Playwright over system Edge) against the running
stack: search filters narrow and survive a reload, the map toggle loads its
chunk and pins both venues, the venue page renders a street-level map, and a
photo uploaded through the dashboard reaches object storage and appears as the
cover on the public search card.

**Notes from implementation**

* **Search is a denormalized document per venue**, not a per-table match. A
  shopper types "fade rabat" in one box and expects the Rabat barber who does
  fades — no single row holds both facts, so each venue gets one `tsvector`
  combining its identity with its treatments. `ts_rank` weights name (A) above
  treatments (B) above city/address (C), or a venue that merely *mentions* a
  treatment outranks the salon named after it.
* Config is `simple` + `unaccent`, not `french`. The catalog mixes French,
  Arabic and English ("balayage", "hammam", "fade") and a French stemmer mangles
  two of the three. Unaccenting is what actually matters here — "Éclat" has to be
  findable by typing "eclat".
* The document can go stale, so every write funnels through
  `Discovery.reindex_venue/1` and `reindex_all/0` exists as the repair. The seed
  needs it: the catalog is bulk-inserted for speed, which bypasses the hook.
* **Presigned uploads mean nothing may be trusted until it is fetched back.** A
  presigned PUT accepts whatever the client sends, so `finalize_upload/2` makes
  libvips decode the bytes — a PDF renamed `.jpg` is caught there, not by its
  content-type header.
* Variants never upscale (a 320 px upload stays 320 px) and re-encoding strips
  EXIF — phone photos carry GPS, and these URLs are public, so a home-based
  salon would otherwise publish its owner's coordinates.
* **Two adapters, both real.** CI has no object store, so the filesystem adapter
  is what keeps the upload path under test; MinIO is what dev and production
  run. Verified both: the S3 path was round-tripped against live MinIO.
* Geocoding is advisory and **never overwrites a hand-placed pin**. Replacing an
  owner's marker with a street-centroid guess is a regression they cannot see
  until a customer arrives at the wrong door.
* Haversine in SQL, no PostGIS. The `asin` form is used over the textbook `acos`
  one because `acos` loses precision at short distances — the only range that
  matters when sorting salons within one city.
* Leaflet is **lazy-loaded**: ~150 kB that most visits never need (the results
  page defaults to list, an unpinned venue shows an address card). Main bundle
  567 kB → 412 kB.
* SEO is prerendered, not SSR — see the ADR. The deciding argument was that
  SSR's cost is structural and permanent (a second runtime beside Elixir,
  dual-environment components) while prerendering's cost is a staleness window
  we control. In Morocco a venue link is shared on WhatsApp far more than it is
  found on Google, and unfurlers read `<head>` and stop.

**Defects found and fixed during verification** (each would have shipped):

| Defect | Fix |
|---|---|
| `requestPhotoUpload` returned the context's `attachment` key while the schema declared a non-null `photo` → every upload failed at serialization, leaving an orphaned `pending` row. **Context-level tests all passed**; the browser was the first thing to notice | Map the key in the resolver, and add `photo_api_test.exs` covering the mutations *through GraphQL* so schema/resolver drift is caught |
| Presigned URLs were signed for `minio:9000`, the in-cluster address — a browser cannot resolve it, and SigV4 signs the `Host` header so re-pointing the URL would break the signature | Sign browser-facing URLs against the public base URL; server-side operations keep the internal one |
| `Venues.list_venues/1` was rewired through `Discovery.search/1`, which hardcodes `status: "active"` — this silently broke the platform admin queue, whose whole job is to show pending and suspended venues | Keep `list_venues/1` as the administrative listing; marketplace reads go through `Discovery` |
| `reindex_all/0` ran under Ecto's 15 s default timeout — a full rebuild over a large directory is an operator action, and it began timing out on a loaded machine | Long explicit timeout for the full rebuild; `reindex_venue/1` keeps the default because it *is* on a request path |
| The Settings page showed "No pin yet" while the venue was still loading, telling an owner with a pin that they had none | Distinguish loading from genuinely unpinned |
| Prerendered pages emitted `<title>`/`<meta description>` twice (shell + injected); which one wins is undefined and some unfurlers take the first | Strip the shell's generic tags before injecting |

**Dependency advisories** (surfaced by `mix deps.get` / `npm audit`, tracked as CH-1):

* Fixed in passing: **bandit** 1.12.0 → 1.12.4 (HIGH — quadratic CPU blow-up on
  fragmented WebSocket messages, which E2's subscriptions had just made
  reachable) and **postgrex** 0.22.2 → 0.22.3 (LOW). **hackney** was dropped
  entirely rather than patched — ExAws needs it only for transport, and
  presigning is pure computation, so `Blastek.HTTP` over OTP's `:httpc` carries
  the few requests instead.
* **Still open, deliberately not bundled into this epic:** `phoenix` 1.7.23
  (HIGH, EEF-CVE-2026-56811) needs a 1.7 → 1.8 major bump, and
  `react-router` 6.x (2 × MODERATE) needs 7.x. Both are framework majors whose
  blast radius is the whole app; they deserve their own change with their own
  verification, not a line in a feature commit.

### E9 · Scheduling depth — F0.7 blocks, F0.9 reschedule
| ID | Task | Est | Labels |
|---|---|---|---|
| E9-T1 | `staff_blocks` migration + CRUD + availability subtraction (incl. weekly repeats) | M | api |
| E9-T2 | Calendar block rendering + create menu; Team time-off list | M | web |
| E9-T3 | Block-vs-appointment conflict prompt flow | S | api,web |
| E9-T4 | `rescheduleMyAppointment` (group move, window policy, race-safe, reminder resync) | M | api |
| E9-T5 | Extract shared `SlotPicker`; Account reschedule UI; reminder deep-link landing | M | web |

### E10 · Reviews — F0.8
| ID | Task | Est | Labels |
|---|---|---|---|
| E10-T1 | Reviews rebuild migration (venue/client/booking link, status, reply) + rating denorm | S | api |
| E10-T2 | Eligibility + create/reply/flag/moderate mutations | M | api |
| E10-T3 | Review-invite job post-checkout (T+2h, one reminder) + signed review page | S | api,web |
| E10-T4 | Web: venue reviews section w/ replies; Account review prompts; dashboard Reviews tab | M | web |
| E10-T5 | Purge seeded fake reviews at venue activation | XS | api |

### E11 · Admin panel — F0.12
| ID | Task | Est | Labels |
|---|---|---|---|
| E11-T1 | `admin` role + audit_log + admin GraphQL namespace | S | api |
| E11-T2 | Approval queue API + venue preview | S | api |
| E11-T3 | Directory (venues/users) search + health cards | M | api |
| E11-T4 | Impersonation (read-only default, elevated write mode, audited) | M | api |
| E11-T5 | KPI queries + cache | S | api |
| E11-T6 | Web: `web/src/platform/` shell + queue/directory/log/KPI pages | L | web |
| E11-T7 | Review moderation + notification log views | S | web |

---

## Phase 1

### E12 · Booking depth — F1.2 chains, F1.4 catalog, F1.5 recurring
| ID | Task | Est | Labels |
|---|---|---|---|
| E12-T1 | Chain availability solver (multi-staff legs) + property tests | L | api,test |
| E12-T2 | Multi-staff atomic booking (sorted advisory locks) | S | api |
| E12-T3 | Web: per-service professional picker; BookingState legs migration | M | web |
| E12-T4 | Catalog schema: work/processing/finish, variants, staff overrides, add-ons | M | api |
| E12-T5 | Split-duration availability (processing-gap sub-bookings) | L | api |
| E12-T6 | `Salon.price_for` resolution + all read paths | S | api |
| E12-T7 | Web: service drawer (variants/buffers/overrides), flow variant+add-on UI | L | web |
| E12-T8 | Recurring series: schema, materializer, edit scopes | M | api |
| E12-T9 | Web: series creation in drawer + Account series display | S | web |

### E13 · Waitlist — F1.3
| ID | Task | Est | Labels |
|---|---|---|---|
| E13-T1 | Schema + join/leave/expiry + venue day view | S | api |
| E13-T2 | Matching + offer chain (15-min hold, serialized offers) on cancellation hook | M | api |
| E13-T3 | Offer notification + signed accept → race-safe book | S | api |
| E13-T4 | Web: flow empty-state join, Account management, calendar badge | M | web |

### E14 · Payments — F1.1
| ID | Task | Est | Labels |
|---|---|---|---|
| E14-T1 | Spike: CMI vs YouCan Pay (contract, fees, API, 3-DS, payout reconciliation) → decision doc | M | spike |
| E14-T2 | `Blastek.Payments` context: ledger (`payments`, `payment_events`), provider behaviour, `DevProvider` | L | api |
| E14-T3 | Card provider integration (hosted page, webhooks, idempotency, refunds) | L | api,infra |
| E14-T4 | Voucher rail: reference lifecycle, hold/expiry jobs, receptionist confirm, (webhook if partner API) | L | api |
| E14-T5 | Deposit policy config + booking-flow gating (tentative + hold) | M | api |
| E14-T6 | POS deposit credit line + refund/waive flows | M | api,web |
| E14-T7 | Web: payment step in BookingFlow (methods, voucher instructions), policy settings | L | web |
| E14-T8 | Daily reconciliation job + admin payments view | M | api,web |
| E14-T9 | Payment notification set (received, hold expiring, forfeited) FR/AR | S | api |

### E15 · Invoicing — F1.6
| ID | Task | Est | Labels |
|---|---|---|---|
| E15-T1 | Fiscal profiles (venue/client) + format validation | S | api |
| E15-T2 | Invoice engine: gapless per-venue-year numbering (locked), snapshot, credit notes | M | api |
| E15-T3 | PDF generation (engine decision task) + storage + WhatsApp/print delivery | M | api |
| E15-T4 | Web: fiscal settings, sales invoice actions, checkout receipt toggle | M | web |
| E15-T5 | TVA summary report | S | api |

### E16 · Marketing & channels — F1.7, F1.10
| ID | Task | Est | Labels |
|---|---|---|---|
| E16-T1 | Consent model (client flags, STOP webhook, audit) | S | api |
| E16-T2 | Automation recipes engine (config, daily sweep, guards) — win-back, birthday, thank-you | M | api |
| E16-T3 | Review routing (threshold split, private feedback inbox) | M | api,web |
| E16-T4 | Broadcasts (segments, quota, schedule, stats) | M | api |
| E16-T5 | Web: Marketing page (recipes, broadcast composer, feedback inbox) | L | web |
| E16-T6 | Channel links + QR + poster PDF; source attribution capture + report hookup | S | web |

### E17 · Reports v2 — F1.8
| ID | Task | Est | Labels |
|---|---|---|---|
| E17-T1 | Range-based report queries + comparisons; utilization/retention/sources/no-show | M | api |
| E17-T2 | XLSX + PDF export jobs + signed downloads | M | api |
| E17-T3 | Web: range picker, new charts, export menu | M | web |
| E17-T4 | Monthly digest job | S | api |

### E18 · Walk-in queue — F1.9
| ID | Task | Est | Labels |
|---|---|---|---|
| E18-T1 | Queue schema + state machine + advisory-lock positioning | M | api |
| E18-T2 | Wait estimator + appointment-aware interleaving | M | api |
| E18-T3 | Subscription topic + join/advance API + OTP-lite join | S | api |
| E18-T4 | Web: venue queue widget + `/v/:slug/queue` TV layout | M | web |
| E18-T5 | Web: dashboard QueuePage console | M | web |
| E18-T6 | Queue→appointment record creation + CRM/report integration | S | api |

---

## Phase 2

### E19 · Pricing & loyalty — F2.7, F2.1
| ID | Task | Est | Labels |
|---|---|---|---|
| E19-T1 | `Salon.Pricing` central resolution (migrate F1.4 logic) + promo/off-peak rules | M | api |
| E19-T2 | Promo codes CRUD + atomic validation + invoice/report itemization | M | api |
| E19-T3 | Web: Offers settings, flow promo input, struck-through pricing | M | web |
| E19-T4 | Loyalty ledger + accrual/redemption/expiry + settings | M | api |
| E19-T5 | Referral codes + attribution + fraud guards | M | api |
| E19-T6 | Web: Account loyalty/referral, POS redeem, share sheet | M | web |

### E20 · Resources & groups — F2.9
| ID | Task | Est | Labels |
|---|---|---|---|
| E20-T1 | Resources schema + capacity availability engine (`Salon.Capacity`) + race safety | L | api |
| E20-T2 | Party-size booking + pricing multiplication | M | api |
| E20-T3 | Generalize blocks to resources | S | api |
| E20-T4 | Web: calendar resource lanes, party-size step, resource editor | L | web |

### E21 · Prepaid — F2.2 gift/packages, F2.3 memberships
| ID | Task | Est | Labels |
|---|---|---|---|
| E21-T1 | Gift cards: schema, ledger, purchase (online/POS), redeem, liability report | M | api |
| E21-T2 | Packages: definitions, purchases, use-decrement at checkout | M | api |
| E21-T3 | Web: gift tab, POS redeem, Account wallet, settings CRUD | L | web |
| E21-T4 | Membership plans + benefit application + dunning ladder | L | api |
| E21-T5 | Web: plans tab, POS badge/renewal, membership settings + MRR report | M | web |

### E22 · Compensation — F2.5
| ID | Task | Est | Labels |
|---|---|---|---|
| E22-T1 | Plans schema + commission computation + exports | M | api |
| E22-T2 | Chair-rent schedules/payments + nudges | M | api |
| E22-T3 | Renter data partition in permission layer + test matrix | M | api,test |
| E22-T4 | Web: compensation tab, staff Earnings view, rent ledger | M | web |

### E23 · Inventory — F2.4
| ID | Task | Est | Labels |
|---|---|---|---|
| E23-T1 | Products + movements schema + context | M | api |
| E23-T2 | POS retail lines (+ TVA per line) + returns | M | api |
| E23-T3 | Barcode entry (scanner + mobile camera) | M | web |
| E23-T4 | Web: Inventory page, count mode, POS panel | L | web |
| E23-T5 | Low-stock digest + margin reporting | S | api |

### E24 · Multi-location — F2.6
| ID | Task | Est | Labels |
|---|---|---|---|
| E24-T1 | Orgs + org memberships + resolution order | M | api |
| E24-T2 | Consolidated reports + location filters | M | api |
| E24-T3 | Catalog copy/push with diff preview | M | api,web |
| E24-T4 | Web: org switcher, brand page `/b/:brand` | M | web |

### E25 · Monetization — F2.8, F2.10
| ID | Task | Est | Labels |
|---|---|---|---|
| E25-T1 | Plans/entitlements (`RequirePlan`) + usage metering | L | api |
| E25-T2 | Venue billing (card + transfer w/ admin confirm) + dunning/feature-freeze | M | api |
| E25-T3 | Featured placement (campaigns, capped injection, badging) | M | api,web |
| E25-T4 | Web: Plan & billing settings, soft paywalls, admin billing console | L | web |
| E25-T5 | PWA metrics instrumentation + RN go/no-go review doc | S | spike |

---

## Phase 3

### E26 · AI & WhatsApp bot — F3.1, F3.2, F3.3, F3.4
| ID | Task | Est | Labels |
|---|---|---|---|
| E26-T1 | Spike: bot number routing (platform vs venue Cloud API numbers) | S | spike |
| E26-T2 | Conversation state machine + interactive flows (F3.1a) | L | api |
| E26-T3 | Dashboard chat inbox + human handoff | M | web |
| E26-T4 | Darija/French labeled test set (intents + transcripts) — build & maintain | M | spike |
| E26-T5 | `Blastek.AI` LLM client + availability-constrained intent → proposal (F3.1b) | XL | api |
| E26-T6 | ASR spike (Whisper vs hosted, Darija WER) → voice-note pipeline (F3.2) | L | spike,api |
| E26-T7 | No-show risk model + nightly scoring + calendar surfacing (F3.3) | M | api,web |
| E26-T8 | Gap-fill optimizer + move-request consent flow (F3.4) | L | api,web |

### E27 · Verticals — F3.5, F3.6, F3.7
| ID | Task | Est | Labels |
|---|---|---|---|
| E27-T1 | Tourist mode: EN completion, currency display, intl OTP, city landing pages | M | web,api |
| E27-T2 | Events context: quotes, contracts, installments, party matrix (F3.5) | XL | api |
| E27-T3 | Web: quote request flow + quote builder + event board | XL | web |
| E27-T4 | Mobile-pro venue kind: zones, travel buffers, address privacy (F3.6) | L | api |
| E27-T5 | Verification workflow (CIN docs, encrypted, retention policy) + admin queue | M | api |
| E27-T6 | Web: mobile-pro onboarding + address step + zone editor | L | web |

### E28 · Resilience & white-label — F3.9, F3.8
| ID | Task | Est | Labels |
|---|---|---|---|
| E28-T1 | Idempotent mutation envelope + dedupe store | M | api |
| E28-T2 | Offline sync engine (IndexedDB queue, POS+queue scope) + conflict UI | L | web |
| E28-T3 | Provisional receipts → server numbering on sync | S | api |
| E28-T4 | White-label RN template + per-tenant build pipeline (post RN decision) | XL | infra,web |

---

## Standing chores (every phase)
| ID | Task | Cadence |
|---|---|---|
| CH-1 | Dependency & security update pass | monthly |
| CH-2 | DB backup/restore drill + migration dry-run on prod copy | per release |
| CH-3 | CNDP register update when new PII fields land | per feature |
| CH-4 | Load test (k6) against seeded large dataset | per phase |
| CH-5 | FR/AR translation review of new strings | per release |
