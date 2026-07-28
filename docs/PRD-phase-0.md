# Phase 0 — Foundation (pre-launch)

Goal: turn the single-venue demo into a multi-venue, FR/AR, WhatsApp-connected
platform a real salon can join and a real customer can trust. Nothing in later
phases starts before F0.1–F0.2 land.

Implementation order: **F0.1 → F0.13 → F0.2 → F0.3 → F0.4 → F0.5 → F0.10 →
F0.11 → F0.6 → F0.7 → F0.9 → F0.8 → F0.12** (F0.11 i18n runs as a parallel
track from week 1; string extraction starts immediately).

Personas/permissions legend: see [PRD.md](PRD.md).

---

## F0.1 Multi-tenancy core

**Complexity: XL · Order: 1 · Depends on: — · Unblocks: everything**

### Functional spec
Introduce `venues` as the tenant root. Every salon-domain row belongs to one
venue. Dashboard users act *within* a venue via memberships; customers interact
with any venue. Public venue pages move to `/v/:slug`. The seed salon becomes
venue #1 with the demo professional as `owner`.

### User stories
- *Owner*: my data (calendar, clients, sales) is visible only to my team.
- *Customer*: I can view and book different salons; each keeps its own history of me.
- *Admin*: I can list every venue and see per-venue health (bookings, members).
- *Staff*: when I log in I land in my venue's dashboard without choosing anything.

### Acceptance criteria
- [ ] Two seeded venues; cross-venue reads/writes are impossible via any GraphQL operation (verified by integration tests attempting cross-tenant access).
- [ ] `venue(slug:)` query returns public venue data; `/venue` route replaced by `/v/:slug`.
- [ ] All dashboard operations resolve the venue from the caller's membership, never from client input.
- [ ] Booking race test: 20 concurrent `book` calls for one slot → exactly 1 success (B4).
- [ ] Clients page for a venue with 1,000 clients issues ≤ 3 SQL queries (B2).
- [ ] A customer with bookings at 2 venues sees both in My appointments, labeled by venue (B12).

### Schema changes
```sql
CREATE TABLE venues (
  id bigserial PRIMARY KEY,
  slug citext UNIQUE NOT NULL,
  name text NOT NULL, tagline text, address text, city text, phone text,
  status text NOT NULL DEFAULT 'pending', -- pending|active|suspended
  settings jsonb NOT NULL DEFAULT '{}',
  inserted_at, updated_at
);
CREATE TABLE venue_members (
  id bigserial PRIMARY KEY,
  venue_id bigint REFERENCES venues NOT NULL,
  user_id bigint REFERENCES users NOT NULL,
  role text NOT NULL,                      -- owner|manager|receptionist|staff
  staff_id bigint REFERENCES staff,        -- link login ↔ calendar column (F0.3)
  UNIQUE (venue_id, user_id)
);
-- venue_id NOT NULL + index on: service_categories, services, staff, clients,
-- appointments, sales, reviews. Composite hot-path indexes:
--   appointments (venue_id, date), appointments (venue_id, staff_id, date),
--   clients (venue_id, user_id) UNIQUE WHERE user_id IS NOT NULL,
--   sales (venue_id, inserted_at)
ALTER TABLE clients ADD COLUMN user_id bigint REFERENCES users; -- replaces users.client_id
-- users: DROP client_id (data-migrated into clients.user_id)
-- Double-booking invariant (B4):
ALTER TABLE appointments ADD CONSTRAINT no_overlap EXCLUDE USING gist
  (staff_id WITH =, date WITH =, int4range(start_min, end_min) WITH &&)
  WHERE (status NOT IN ('cancelled','no_show'));
-- settings key/value table: values migrate into venues columns, table dropped.
```

### GraphQL changes
- `venue(slug: String!)` replaces arg-less `venue`; adds `slug`, `city`, `status`.
- New: `myVenues: [VenueMembership]` (role + venue) for dashboard boot;
  context gains `current_venue` resolved from membership (header `X-Venue-Slug`
  when a user belongs to several — single-membership users need nothing).
- Every `RequireRole "professional"` middleware becomes `RequireMember role:`
  (per-capability minimum role; see matrix).
- `book` unchanged externally but takes venue from the queried slot's venue.

### Backend
- New context `Blastek.Venues` (CRUD, memberships, slug generation).
- `Blastek.Salon`: every public function gains `venue_id` as first argument;
  module-level `import Blastek.Scope` helper adds `where: x.venue_id == ^v` —
  a `scope(queryable, venue_id)` macro so scoping is uniform and greppable.
- `book/1`: wrap in `Ecto.Multi` + `SELECT pg_advisory_xact_lock(venue_id, staff_id⊕date)`;
  rescue exclusion-constraint violation into "slot just taken" error (B4).
- `booking_ref`: crypto-random base32 + unique index + single retry (B7).
- `client_stats` → `client_stats_for(venue_id, client_ids)` batch (B2) exposed
  through Absinthe Batch middleware.
- `Accounts.ensure_client(user, venue_id)` (B12); `link_client` removed.

### Frontend
- `MarketLayout`/`VenuePage`/`BookingFlow`: venue loaded by `:slug` route param
  (`/v/:slug`, `/v/:slug/flow`); `useVenue` context unchanged in shape.
- `AdminLayout`: boot via `myVenues` → store active venue; venue name in sidebar.
- `Account.tsx`: group appointments by venue.
- Home venue cards link to real venue slugs (interim until F0.6 search).

### Permissions
Membership roles enforced server-side per the matrix; `admin` bypasses with
audit log entry (F0.12).

### Notifications
None directly (foundation).

### Edge cases
- Deleting/suspending a venue: soft `status='suspended'` — public page 404s, dashboard read-only banner, existing future bookings remain visible to customers with "venue unavailable" messaging.
- A user who is both a customer and an owner: allowed; role derives from context (marketplace vs dashboard), not from `users.role`.
- Staff member employed at two venues: two memberships; venue switcher appears only then.
- Legacy data migration: single existing venue absorbs all rows; `users.role='professional'` → owner membership; migration is reversible.
- Slug collisions ("salon-anfa" ×2): suffix `-2`; slugs immutable after activation (SEO).

---

## F0.13 Platform hardening (paired with F0.1 while everything is open)

**Complexity: M · Order: 2 · Depends on: F0.1**

### Functional spec
Cross-cutting debt paydown: pagination, money as centimes, structured GraphQL
errors, missing indexes, subscriptions transport, request rate limiting.

### User stories
- *Owner*: the clients page opens fast even with years of history.
- *Admin*: platform stays responsive as venues multiply.

### Acceptance criteria
- [ ] `clients`, `sales`, `appointments` accept `limit/offset`, return `totalCount`; default 50, max 200; UI paginates Clients + Sales.
- [ ] All money read/written as integer centimes; MAD formatting util in `web/src/lib/format.ts`; no `:float` money field remains (B5).
- [ ] Mutations return structured errors `[{code, field, message}]`; auth forms show field-level errors (B14).
- [ ] Absinthe subscriptions socket connected end to end (`appointmentChanged(venueId)` demo) (B9).
- [ ] GraphQL endpoint rate-limited per IP+user (sane defaults; login/OTP stricter).

### Schema
`*_cents` integer columns migrated from floats (services.price, appointments.price, sales.subtotal/tip/total, sale_items.amount); drop float columns after backfill.

### GraphQL
Connection-style payloads `{ items, totalCount }` for list queries; `input`-level error type `MutationError`.

### Backend
`Absinthe.Phoenix` socket + PubSub topic per venue; `Hammer` (ETS) plug for rate limits; error formatter middleware replacing `format_errors/1`.

### Frontend
`gql.ts`: typed `MutationError[]` handling; `Clients`/`Sales` pagination controls; money formatter (`fmtMAD`).

### Edge cases
Backfill rounding (floats → centimes) uses `round(x*100)`; reconciliation script compares sums before dropping columns.

---

## F0.2 Auth hardening: phone-first accounts, OTP, reset, sessions

**Complexity: L · Order: 3 · Depends on: F0.13 (rate limits) · Unblocks: F0.3, F0.10**

### Functional spec
Phone number becomes a first-class, verified identifier. Signup/login via
phone + OTP (WhatsApp first, SMS fallback) **or** email+password (kept).
Server-side sessions with revocation; password reset by email or OTP.

### User stories
- *Customer*: I sign up with just my phone number and a code I get on WhatsApp.
- *Customer*: I forgot my password; I recover access via my phone.
- *Owner*: I can log out a device I lost.
- *Admin*: I can revoke all sessions for a compromised account.

### Acceptance criteria
- [ ] `requestOtp(phone)` → `verifyOtp(phone, code)` issues a session; new phone = account created (name asked post-verification).
- [ ] OTP: 6 digits, 5-min TTL, 3 attempts, resend cooldown 60s, delivery WhatsApp→SMS fallback.
- [ ] Sessions listed and revocable in account settings; access token TTL 24h, refresh 60d, refresh rotates.
- [ ] Password reset flow (email link or OTP) end to end.
- [ ] Login/OTP endpoints rate-limited (5/min/identity, 20/hr/IP); OTP hashes stored, never raw.
- [ ] Existing email/password users unaffected.

### Schema
```sql
CREATE TABLE sessions (id, user_id, token_hash UNIQUE, refresh_hash UNIQUE,
  device text, expires_at, revoked_at, inserted_at);
CREATE TABLE otp_codes (id, phone, code_hash, purpose, attempts int,
  expires_at, consumed_at);  -- purpose: login|verify|reset
ALTER TABLE users ADD phone_verified_at timestamp, ALTER phone UNIQUE where verified;
```

### GraphQL
Mutations: `requestOtp`, `verifyOtp`, `requestPasswordReset`, `resetPassword`,
`logout`, `revokeSession(id)`, `completeProfile(firstName…)`.
Query: `mySessions`.

### Backend
`Accounts` grows `Otp` + `Sessions` submodules; token verification switches
from `Phoenix.Token`-only to session lookup (keep Phoenix.Token as the bearer
format, hash stored in `sessions`). OTP delivery via `Notifications` (F0.10) —
dev mode logs the code.

### Frontend
`AuthShell` gains OTP mode (phone input → code input); account settings page
(sessions list, change password); ProLogin unchanged visually.

### Permissions
Public endpoints; heavily rate-limited.

### Notifications
OTP message template (FR/AR): "Votre code Blastek: {code}".

### Edge cases
Phone normalization to E.164 (+212…) with Moroccan local formats (06/07 prefixes); user with both email and phone identities; OTP requested for a phone mid-verification of another purpose; clock-skew on expiry; WhatsApp undeliverable → automatic SMS within 30s.

---

## F0.3 Staff accounts, roles & permissions

**Complexity: M · Order: 4 · Depends on: F0.1, F0.2**

### Functional spec
Owners invite team members by phone/email to a role; invitees become
`venue_members`, optionally linked to a `staff` calendar column. Staff get a
restricted dashboard (own calendar, limited CRM).

### User stories
- *Owner*: I invite my receptionist so she can manage the calendar but not see revenue.
- *Staff*: I see my own week and my clients' notes on my phone.
- *Manager*: I can fix the catalog without asking the owner.
- *Owner*: I remove a departing stylist's access in one tap without deleting their history.

### Acceptance criteria
- [ ] Invite by phone/email creates a pending invitation; accepting links/creates the user account (OTP flow) and membership.
- [ ] Role changes take effect immediately (session's next request).
- [ ] `staff`-role calendar shows only their own column; API refuses other staff's appointment details.
- [ ] Removing a member revokes access but preserves the `staff` row and history.
- [ ] Every dashboard GraphQL op integration-tested against all 4 roles.

### Schema
```sql
CREATE TABLE venue_invitations (id, venue_id, role, phone, email,
  token_hash UNIQUE, invited_by, expires_at, accepted_at);
```
(`venue_members.staff_id` from F0.1.)

### GraphQL
Mutations: `inviteMember`, `acceptInvitation(token)`, `updateMemberRole`,
`removeMember`. Query: `venueMembers`.

### Backend
`Venues.Memberships`; `RequireMember` middleware gains per-field minimum-role
option; appointment queries add `own_only` scoping for `staff` role.

### Frontend
Team page: members tab alongside staff profiles (invite modal, role select);
role-aware navigation in `AdminLayout` (hide Sales/Reports/Catalog per matrix).

### Notifications
Invitation via WhatsApp/SMS with deep link; "role changed" notice.

### Edge cases
Invite to a phone that's already a customer (allowed — adds membership);
last-owner protection (cannot demote/remove the only owner); invitation expiry
(7 d) and re-issue; member also bookable as staff at another venue.

---

## F0.4 Venue self-service settings, hours & closures

**Complexity: M · Order: 5 · Depends on: F0.1**

### Functional spec
Settings page for identity (name, tagline, address, city, phone, photos),
weekly opening hours, slot granularity, and **closures** (single days or
ranges; Eid/holiday presets; Ramadan hours template that shifts the week grid
seasonally).

### User stories
- *Owner*: I close for Eid in two taps and online booking respects it.
- *Owner*: during Ramadan we open 10:00–16:00 and 21:00–00:30; I switch to my saved Ramadan schedule once.
- *Customer*: I never see a bookable slot when the salon is closed.

### Acceptance criteria
- [ ] `updateVenue` persists identity + JSONB settings; public page reflects within one reload.
- [ ] Closures block availability (whole-day and time-range), shown as shaded on the dashboard calendar.
- [ ] Hour templates: `default` and `ramadan`, one-tap switch, auto-suggest banner near Ramadan dates.
- [ ] Existing appointments inside a new closure are flagged for action (list with reschedule shortcuts), never silently cancelled.
- [ ] Past-midnight ranges (21:00–00:30) work across the availability engine.

### Schema
```sql
CREATE TABLE venue_closures (id, venue_id, date, end_date, start_min, end_min,
  reason text, inserted_at);
CREATE TABLE venue_hour_templates (id, venue_id, name, hours jsonb, active bool);
-- staff_hours gains template_id nullable (staff variants per template)
```

### GraphQL
`updateVenue(input)`, `createClosure/deleteClosure`, `setHourTemplate(name)`;
`venue.closures`, `venue.hourTemplates`.

### Backend
`Venues.Settings`; `Salon.availability` subtracts closures; end-past-midnight
represented as `end_min > 1440` (engine already pure-minute math — extend range
checks).

### Frontend
New `admin/SettingsPage.tsx` (nav item, owner/manager only): identity form,
photo upload (F0.6 storage), hours grid, closures list, template switcher.

### Notifications
Optional broadcast to affected booked customers when a closure creates
conflicts ("we need to move your appointment").

### Edge cases
Closure overlapping existing bookings (see AC); template switch mid-week
(applies from selected date); staff hours exceeding venue hours (validation
warning, staff hours win for availability as today).

---

## F0.5 Venue onboarding

**Complexity: M · Order: 6 · Depends on: F0.1, F0.2, F0.4**

### Functional spec
Self-serve signup: business basics → category/city → first services (from
localized template catalogs: coiffure femme/homme, barbier, onglerie, hammam &
spa) → team size → hours → submitted for admin approval. Venue is usable in
"setup mode" (dashboard works, public page hidden) until approved.

### User stories
- *Owner*: I created my salon page from my phone in 10 minutes, in Arabic.
- *Owner*: template services meant I didn't type my whole menu.
- *Admin*: I review new venues (name, photos, phone verified) before they go live.

### Acceptance criteria
- [ ] Wizard completable on mobile in ≤ 10 min; progress saved per step (resume on return).
- [ ] Template catalogs per category seed real services (editable after).
- [ ] Status flow `pending → active` (admin approve) or `→ rejected` with reason; owner notified on decision.
- [ ] Setup-mode dashboard fully functional for internal use pre-approval.

### Schema
`venues.onboarding jsonb` (step state); `service_templates` seed table
(category, name_i18n, duration, price hint).

### GraphQL
`createVenue(input)`, `updateOnboarding(step, data)`, `submitVenue`; admin:
`approveVenue`, `rejectVenue(reason)`.

### Backend
`Venues.Onboarding`; template seeding.

### Frontend
`market/OnboardVenue.tsx` wizard at `/for-business` (linked from "For
professionals"); replaces direct pro-signup as the venue-creation path
(ProLogin remains the login gate).

### Notifications
Approval/rejection via WhatsApp; admin queue notification on submission.

### Edge cases
Abandoned onboarding (resume ≤ 30 d, then archived); duplicate venue detection
(same phone/name+city → admin warning); owner invites team before approval
(allowed).

---

## F0.10 Notifications core + WhatsApp/SMS confirmations & reminders

**Complexity: L · Order: 7 · Depends on: F0.1; Oban (B8) · Unblocks: F0.2 OTP, F0.8, F1.x automations**

### Functional spec
A `Notifications` context: templated, localized, multi-channel messages with
per-user channel preference and full send log. Launch flows: booking
confirmation (customer + salon), reminder 24h and 3h before, cancellation
notices both directions, reschedule notice. Channels: WhatsApp Cloud API
(primary), SMS gateway (fallback), dev logger. All sends async via Oban;
reminders via Oban scheduled jobs created at booking time and cancelled on
appointment cancellation.

### User stories
- *Customer*: I get a WhatsApp confirmation instantly, and a reminder the evening before.
- *Owner*: I'm pinged on WhatsApp when an online booking or cancellation lands.
- *Customer*: reminder includes one-tap links: confirm / reschedule / cancel.
- *Admin*: I can see delivery status and failure reasons per message.

### Acceptance criteria
- [ ] Booking → customer confirmation ≤ 30 s; salon notified simultaneously.
- [ ] Reminders at T-24h and T-3h (venue-configurable offsets); cancelled appointments never remind.
- [ ] WhatsApp failure → SMS fallback automatically; both fail → send log `failed` visible to admin.
- [ ] Templates localized FR + AR; customer's locale respected.
- [ ] Reminder links (signed tokens) confirm/cancel without login; reschedule deep-links to the flow.
- [ ] Provider is a behaviour: `WhatsAppCloud`, `SmsProvider`, `DevLogger` — swap by config.

### Schema
```sql
CREATE TABLE notifications (id, user_id, venue_id, appointment_id,
  template text, channel text, locale text, payload jsonb,
  status text, -- queued|sent|delivered|failed
  provider_id text, error text, sent_at, inserted_at);
ALTER TABLE users ADD notification_prefs jsonb DEFAULT '{}';
```
Oban tables (`oban_jobs`) via its migration.

### GraphQL
`updateNotificationPrefs`; admin `notificationLog(filters)`; public
`actOnAppointment(token, action)` for signed one-tap links (HTTP GET endpoint,
not GraphQL, for WhatsApp tap-through).

### Backend
New deps: `oban`, HTTP client (`req`). `Blastek.Notifications` (templates in
code with locale files), `Blastek.Notifications.Providers.*` behaviour impls;
hooks in `Salon.book/1`, `update_appointment` (status transitions) enqueue
jobs; WhatsApp webhook controller for delivery receipts.

### Frontend
Account settings: channel prefs. Dashboard: small toast/badge on new online
booking (uses B9 subscription). Admin log view (F0.12).

### Permissions
Prefs self-service; log admin-only.

### Notifications
This *is* the notification feature; template inventory v1: `otp`,
`booking_confirmed_customer`, `booking_confirmed_salon`, `reminder_24h`,
`reminder_3h`, `cancelled_by_customer`, `cancelled_by_salon`, `rescheduled`,
`venue_approved`, `invitation`.

### Edge cases
Phone unverified → skip WhatsApp, show in-app only; template pending Meta
approval → SMS text version; reminder time already past at booking (same-day
booking → only T-3h if ≥ 3h away, else skip); venue timezone fixed
Africa/Casablanca (store on venue anyway); user opts out of reminders but not
transactional confirms (prefs granularity: transactional always on).

---

## F0.11 Internationalization — FR/AR (+RTL), EN retained

**Complexity: L · Order: parallel track from week 1 · Depends on: — (frontend); F0.1 for DB content**

### Functional spec
Full UI localization: French (default), Moroccan Arabic (RTL), English kept
for tourists/dev. User-generated content (service/category names,
descriptions, venue tagline) gets optional per-locale values with fallback.

### User stories
- *Customer*: the whole booking flow reads naturally in Arabic, laid out RTL.
- *Owner*: I enter my service names in French and Arabic; customers see their language.
- *Staff*: dashboard in French by default.

### Acceptance criteria
- [ ] i18next with `fr` (default), `ar`, `en`; language switcher in market nav + account; persisted per user.
- [ ] `dir="rtl"` applied for `ar`; both CSS systems (bungee/market + admin) audited for RTL (logical properties or per-dir overrides); no broken layouts on the 6 core pages.
- [ ] Zero hardcoded strings in `web/src` (lint rule/CI grep gate).
- [ ] DB content: `services.translations jsonb` (`{"fr": {name, description}, "ar": …}`) with base-column fallback; GraphQL resolves by `Accept-Language`/user pref.
- [ ] Dates/times/currency localized (Intl, MAD, Arabic-Indic digits *not* used — Western digits per Moroccan convention).
- [ ] Notification templates (F0.10) share the locale files.

### Schema
`translations jsonb` on services, service_categories, venues; `users.locale`.

### GraphQL
`localized` field resolution (name/description honor request locale); `updateService` accepts translations map.

### Backend
Locale plug (header/user), Gettext for API-side strings (errors).

### Frontend
`react-i18next` setup, extraction of every page; catalog editor gains per-locale
name inputs (tabbed FR/AR).

### Edge cases
Missing translation → fallback chain ar→fr→base; mixed-direction strings
(Arabic text with Latin brand names) — test bidi isolation; slug generation
from Arabic names (transliterate or require Latin slug).

---

## F0.6 Venue discovery: search, filters, photos, map

**Complexity: L · Order: 8 · Depends on: F0.1, F0.5, B11 storage**

### Functional spec
Marketplace home becomes a real directory: search by treatment/venue name,
filter by city + category (+ women-only flag, F3-lite: the flag ships now,
see edge cases), sort by rating/distance; venue cards with photo, rating,
price-from; map view (Leaflet + OSM tiles — no Google billing dependency);
venue detail page gains photo gallery and location map.

### User stories
- *Customer*: I search "hammam Marrakech" and compare options by rating and price.
- *Customer*: "near me" shows salons around my location.
- *Owner*: my photos and services make my page sell for me.
- *Customer (woman)*: I filter to women-only salons confidently.

### Acceptance criteria
- [ ] Search returns active venues matching name/service text (Postgres FTS w/ `unaccent`, French + simple configs) filtered by city/category; p95 < 300 ms with 1k venues.
- [ ] Photo upload (owner): ≤ 10 photos, presigned S3 PUT, server-side variant generation (thumb/card/hero) via Oban job.
- [ ] Geocoding on onboarding (address → lat/lng, Nominatim w/ manual pin fallback); distance sort when user grants location.
- [ ] `womenOnly` venue flag filters discovery and badges the venue page.
- [ ] SEO: venue pages server-render meta (title/desc/og:image) — Vite SSR for `/v/:slug` only, or prerender middleware; decision task in backlog.

### Schema
```sql
ALTER TABLE venues ADD lat float8, lng float8, category text,
  women_only bool DEFAULT false, search_tsv tsvector GENERATED;
CREATE TABLE attachments (id, venue_id, kind text, key text, variants jsonb,
  sort int, inserted_at);
CREATE INDEX venues_search ON venues USING gin(search_tsv);
```

### GraphQL
`searchVenues(q, city, category, womenOnly, nearLat, nearLng, sort, limit,
offset)`; `createUploadUrl(kind)`; `venue.photos`, `venue.priceFrom`.

### Backend
`Venues.Search` (FTS + earthdistance for radius), `Blastek.Storage`
(S3/MinIO presign, behaviour), image variant Oban worker (`image` lib or
`vix`); docker-compose gains `minio`.

### Frontend
Home: real search bar wired (hero), city/category chips, results grid, map
toggle; `VenuePage`: gallery, map, "from X MAD" per category; new
`market/SearchResults.tsx`.

### Notifications
None.

### Edge cases
Venues without photos (branded placeholder); no results (suggest nearby city);
location permission denied (city fallback); duplicate images; slow uploads on
mobile data (client-side compression before upload).

---

## F0.7 Time off & blocked time

**Complexity: M · Order: 9 · Depends on: F0.1**

### Functional spec
Per-staff time blocks: vacation (multi-day), breaks, "blocked" ad-hoc slots;
created from the dashboard calendar (drag or form) and honored by
availability.

### User stories
- *Staff*: I mark Friday 12:00–14:00 as a break every week (weekly repeat).
- *Owner*: Sara is on vacation next week; her column shows it and takes no bookings.
- *Customer*: I can't book slots the stylist isn't truly available.

### Acceptance criteria
- [ ] Block types: `time_off` (day/range), `break` (time range, optional weekly repeat), `blocked` (one-off).
- [ ] Availability excludes blocks; calendar renders them shaded with label.
- [ ] Creating a block over existing appointments prompts conflict list (reschedule shortcuts); never silent.
- [ ] Staff role can manage own blocks; receptionist+ can manage anyone's.

### Schema
```sql
CREATE TABLE staff_blocks (id, venue_id, staff_id, kind text, date, end_date,
  start_min, end_min, weekly bool DEFAULT false, weekday int, note text);
```

### GraphQL
`createStaffBlock`, `deleteStaffBlock`; `staff.blocks(from, to)`.

### Backend
`Salon.availability` subtracts blocks (materialize weekly repeats in the query
window); calendar query returns blocks alongside appointments.

### Frontend
CalendarPage: block rendering + create-from-empty-slot menu ("New appointment /
Block time"); Team page: time-off list per member.

### Edge cases
Block spanning midnight; weekly break during Ramadan template (blocks follow
clock time, warn if outside working hours); overlapping blocks (merge on
read).

---

## F0.9 Online reschedule

**Complexity: S · Order: 10 · Depends on: F0.1, F0.10**

### Functional spec
Customers move an upcoming booking to another available slot (same venue, same
services/staff choice preserved, staff re-pickable) within the venue's
cancellation window. Dashboard can always reschedule (exists via
`update_appointment`; this feature is the *customer-facing* flow).

### User stories
- *Customer*: I move Thursday's appointment to Saturday from my phone in 30 s.
- *Owner*: instead of a cancellation I keep the revenue.

### Acceptance criteria
- [ ] `rescheduleMyAppointment(bookingRef, date, startMin, staffId?)` validates ownership + window + availability atomically (same locking as `book`).
- [ ] Multi-service bookings move as a group (whole `booking_ref`).
- [ ] Venue policy knob `settings.cancellation_window_hours` (default 3) gates both cancel and reschedule; inside window → "call the salon" message with tap-to-call.
- [ ] Both sides notified (F0.10 `rescheduled`).
- [ ] Reminder jobs rescheduled.

### GraphQL
`rescheduleMyAppointment` mutation; `venue.settings.cancellationWindowHours`
public field.

### Frontend
Account page: "Reschedule" button → compact slot picker (reuses BookingFlow
step-3 components — extract `SlotPicker` shared component); reminder deep link
lands here.

### Edge cases
Slot taken during selection (standard race error + refresh); reschedule of a
group where original staff now lacks a service (re-run eligibility);
reschedule chain limit (≤ 3 per booking to prevent abuse).

---

## F0.8 Verified reviews & owner replies

**Complexity: M · Order: 11 · Depends on: F0.1, F0.10**

### Functional spec
Reviews only from customers with a `completed` appointment at the venue;
requested post-visit via WhatsApp; owner reply (one per review); admin
moderation (hide + reason). Seeded fake reviews deleted at venue activation.

### User stories
- *Customer*: after my visit I rate 1–5 and comment in one tap from WhatsApp.
- *Owner*: I reply publicly to reviews; I report abusive ones.
- *Customer*: ratings I read reflect real visits only.
- *Admin*: flagged reviews queue for moderation.

### Acceptance criteria
- [ ] Review invite T+2h after checkout completion (one per booking_ref; no repeat nags — max 1 reminder at T+24h).
- [ ] Create requires eligible completed appointment ≤ 14 days old; one review per booking.
- [ ] Venue rating = mean of visible reviews, denormalized on `venues.rating_avg/rating_count`, recomputed on write.
- [ ] Owner reply displays under review; edited within 48h only.
- [ ] Hidden reviews excluded everywhere; author notified with reason category.

### Schema
```sql
-- reviews rebuilt: ADD venue_id, client_id, appointment_booking_ref UNIQUE,
--   reply text, reply_at, status text DEFAULT 'visible', -- visible|flagged|hidden
--   locale; DROP client_name (resolve from client)
ALTER TABLE venues ADD rating_avg float8 DEFAULT 0, rating_count int DEFAULT 0;
```

### GraphQL
`createReview(bookingRef, rating, comment)`, `replyToReview`, `flagReview`;
admin `moderateReview`; `venue.reviews(limit, offset)`.

### Backend
`Salon.Reviews` (eligibility, denormalized rating maintenance); review-invite
Oban job hooked to checkout.

### Frontend
VenuePage: reviews section with replies; Account: "leave a review" on past
visits; signed-link review page (from WhatsApp, no login re-prompt); dashboard
Reviews tab (list + reply box); admin moderation queue (F0.12).

### Edge cases
Review after refund/dispute (allowed; owner reply covers it); rating-only (no
comment) allowed; comment language ≠ UI language (store locale, no
translation v1); venue suspended (reviews frozen).

---

## F0.12 Admin panel v0

**Complexity: L · Order: 12 · Depends on: F0.1, F0.2; consumes queues from F0.5, F0.8, F0.10**

### Functional spec
Internal `/admin` SPA area (same React app, new layout) for platform staff:
venue approval queue, venue & user directory with impersonation, review
moderation, notification delivery log, platform KPIs (venues, bookings/day,
GMV, active customers).

### User stories
- *Admin*: I approve today's venue submissions with photo/phone checks.
- *Admin*: I impersonate an owner to reproduce their bug (read-only by default).
- *Admin*: I watch WhatsApp delivery failure rates per template.

### Acceptance criteria
- [ ] `users.role='admin'` gates `/admin` server-side; every admin action writes `audit_log`.
- [ ] Approval queue with venue preview → approve/reject(+reason) → owner notified.
- [ ] Directory search (venues, users) paginated; venue health card (members, bookings 30d, rating).
- [ ] Impersonation: banner + audit; mutations blocked unless elevated ("support write mode" toggle, also audited).
- [ ] KPI dashboard: daily bookings, GMV (completed sales), new venues/customers, notification failure rate.

### Schema
```sql
CREATE TABLE audit_log (id, admin_id, action, target_type, target_id,
  meta jsonb, inserted_at);
```

### GraphQL
Namespaced admin fields (`admin { venues(...), users(...), kpis(range) }`),
mutations `adminApproveVenue`, `adminModerateReview`, `impersonate(userId)`
(issues scoped session).

### Backend
`Blastek.Admin` context; KPI queries (indexed aggregates, 60 s cache via ETS).

### Frontend
`web/src/platform/` — `AdminShell.tsx`, queue/directory/log/KPI pages;
deliberately utilitarian styling (reuse admin.css).

### Permissions
`admin` only; impersonation write-mode requires per-session elevation.

### Notifications
Internal: new venue submission → admin WhatsApp/queue badge.

### Edge cases
Admin is also an owner (roles independent); impersonating an admin (forbidden);
audit log retention (12 mo min, CNDP).

---

## F0.14 PWA & push (bundled hardening, shipped with F0.11 done)

**Complexity: S · Order: 13 · Depends on: F0.10**

Installable PWA (manifest, icons, offline shell for market pages), web push on
Android for booking updates as a complement to WhatsApp.
AC: Lighthouse PWA pass; push opt-in flow; notification prefs honor push
channel. Edge: iOS Safari push limitations (WhatsApp remains primary there).

---

## Phase 0 exit criteria (launch gate)

1. 2+ real venues onboarded end-to-end by non-developers, in Arabic and French.
2. A real customer books, reschedules, gets WhatsApp confirmations/reminders, and leaves a verified review — no developer involvement.
3. Cross-tenant isolation test suite green; booking race test green.
4. Admin can approve venues and see delivery logs.
5. p95 GraphQL < 300 ms on seeded 1k-venue / 100k-appointment dataset.
