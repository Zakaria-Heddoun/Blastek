# Phase 1 — Launch → month 6 (retention & trust)

Goal: keep the salons that joined (fewer no-shows, fuller calendars, cleaner
books) and deepen customer trust. Assumes all of Phase 0.

Implementation order: **F1.2 → F1.4 → F1.3 → F1.10 → F1.8 → F1.1 → F1.6 →
F1.7 → F1.9 → F1.5** (F1.1 payments starts early as a background integration
track; it has external dependencies — gateway contracts, Meta template
approvals).

---

## F1.2 Per-service staff selection in one booking

**Complexity: M · Order: 1 · Depends on: F0.1**

### Functional spec
A multi-service booking can assign a different professional per service
(colorist for balayage, then manicurist), scheduled back-to-back. "Any
professional" remains per service. The engine finds start times where the
*chain* of (service, staff) legs fits consecutively.

### User stories
- *Customer*: I book balayage with Sara then a manicure with Nadia in one confirmation.
- *Owner*: multi-treatment visits stop defaulting to whoever does everything.

### Acceptance criteria
- [ ] Step 2 of BookingFlow allows per-service professional choice (default "any"); summary shows each leg.
- [ ] Availability computes chained legs (leg N start = leg N-1 end), honoring each staff's hours/blocks/conflicts.
- [ ] Booking creates one appointment per leg, same `booking_ref`, possibly different `staff_id`s, atomically (all-or-nothing, race-safe per staff).
- [ ] Reschedule (F0.9) moves the whole chain.

### Schema
None (model already supports per-appointment staff).

### GraphQL
`availability` accepts `legs: [{serviceId, staffId}]` (back-compat: old args
map to uniform legs); `book` mirrors it.

### Backend
`Salon.availability` chain solver: for each candidate start, walk legs across
staff calendars; complexity bounded (≤ 5 legs × slots/day). Lock all involved
staff in `book` (sorted advisory locks to avoid deadlock).

### Frontend
BookingFlow step 2 becomes per-service selectors; `MarketLayout` booking state
`services: [{id, staffId}]` (migrate `BookingState`).

### Notifications
Confirmation lists each leg with its professional.

### Edge cases
No common chain window exists though each leg has slots (communicate "not
available together — book separately?"); same staff for consecutive legs
(collapse into contiguous block — no gap); a leg's staff removed between
availability and book (standard race error).

---

## F1.4 Catalog depth: buffers, variants, per-staff pricing, add-ons

**Complexity: L · Order: 2 · Depends on: F0.1 · Unblocks: realistic availability for F1.x**

### Functional spec
Services gain: **processing/buffer time** (occupied vs. finishing gap, e.g.
color 30 min work + 30 min processing during which staff is free), **variants**
(length/level: "Coupe — cheveux longs"), **per-staff price/duration
overrides** (senior stylist premium), and **add-ons** (attachable
mini-services, e.g. gommage on hammam).

### User stories
- *Owner*: my color service frees Sara during processing so she takes a blow-dry in between.
- *Owner*: senior stylists charge more for the same cut without duplicate services.
- *Customer*: I pick "long hair" and see the right price before booking.
- *Customer*: I add a beard trim to my haircut in one tap.

### Acceptance criteria
- [ ] Duration model per service: `work_min` + `processing_min` (staff free during processing) + `finish_min`; availability books staff time only for work+finish, room for the whole span.
- [ ] Variants: a service has 0..n variants (name_i18n, duration deltas, price); flow shows variant picker; appointments store `variant_id`.
- [ ] Per-staff overrides `(service_id, staff_id) → {price_cents, duration_min}` applied in menu ("from X MAD"), availability, and booking price.
- [ ] Add-ons: services flagged `addon` attach to a parent selection; extend duration/price of the same leg.
- [ ] Catalog editor covers all of the above without leaving the service drawer.

### Schema
```sql
ALTER TABLE services ADD work_min int, processing_min int DEFAULT 0,
  finish_min int DEFAULT 0, addon bool DEFAULT false; -- duration_min kept = total
CREATE TABLE service_variants (id, venue_id, service_id, name, translations jsonb,
  duration_min, price_cents, sort);
CREATE TABLE staff_service_overrides (id, venue_id, staff_id, service_id,
  price_cents, duration_min, UNIQUE(staff_id, service_id));
ALTER TABLE appointments ADD variant_id bigint, addon_of bigint;
```

### GraphQL
Service object gains `variants`, `addons`, `staffOverrides`; booking legs
accept `variantId`, `addonIds`.

### Backend
Availability split-duration support (the 15-min walker books discontinuous
staff segments for processing gaps — the significant piece of this feature);
price resolution helper `Salon.price_for(service, variant, staff)` used by
menu, booking, checkout.

### Frontend
CatalogPage service drawer: variants table, buffer fields, per-staff override
grid; BookingFlow: variant picker + add-on chips; price displays switch to
resolved prices.

### Edge cases
Overrides on a variant (resolve staff override → variant → base); processing
gap where "free" staff then runs over (gap bookings limited to ≤ processing
length); legacy services (work_min defaults to duration_min).

---

## F1.3 Waitlist

**Complexity: M · Order: 3 · Depends on: F0.10, F1.2**

### Functional spec
When a desired day has no slots, customers join a waitlist (services, staff
pref, date, time window). Cancellations/reschedules that open matching space
trigger offers via WhatsApp — first-come (single offer at a time with 15-min
hold) — to the queue in join order.

### User stories
- *Customer*: Saturday is full; I join the waitlist and get a WhatsApp offer when a slot opens.
- *Owner*: cancellations refill themselves.

### Acceptance criteria
- [ ] Join from empty-slots state in BookingFlow; manage (view/leave) in Account.
- [ ] On any appointment cancellation/move, matching engine finds fitting waitlist entries (services fit the freed window ± staff pref) and offers to the first.
- [ ] Offer: WhatsApp with signed accept link; 15-min exclusive hold; expiry auto-offers next in line.
- [ ] Accept books atomically through the normal race-safe path.
- [ ] Entries expire end-of-requested-day; venue sees its waitlist count per day on the calendar.

### Schema
```sql
CREATE TABLE waitlist_entries (id, venue_id, client_id, legs jsonb, date,
  window_start_min, window_end_min, status text, -- open|offered|booked|expired|left
  offer_expires_at, inserted_at);
```

### GraphQL
`joinWaitlist`, `leaveWaitlist`; `myWaitlist`; venue `waitlist(date)`.

### Backend
`Salon.Waitlist` + Oban: offer job on cancellation hook, expiry sweeps.
Matching = availability check constrained to the freed window.

### Frontend
BookingFlow empty-state CTA; Account waitlist section; calendar day header
badge ("3 waiting").

### Notifications
`waitlist_offer` (with countdown), `waitlist_expired_next` internal chain.

### Edge cases
Multiple simultaneous cancellations (offers serialize per entry — an entry
holds max one offer); customer books normally while waitlisted (auto-leave);
offer accepted after someone walked in (race error → apologize + auto-return
to head of queue).

---

## F1.10 Google & Instagram link-outs

**Complexity: S · Order: 4 · Depends on: F0.6**

### Functional spec
Make Blastek the booking backend for where discovery already happens: a
canonical short booking URL per venue (`blastek.ma/v/slug`) with UTM-tagged
variants for Instagram bio / WhatsApp status / Google Business Profile
("Appointment" link), a link-in-bio mini page, and per-source booking
attribution in reports. (Full "Reserve with Google" API integration is
deferred to Phase 2 — partner program dependency.)

### Acceptance criteria
- [ ] Owner settings expose copy-paste links per channel with QR codes (printable A5 "Réservez en ligne" poster PDF).
- [ ] `appointments.source` records channel from UTM (`online_instagram`, `online_google`, …); Reports v2 breaks down bookings by source.
- [ ] Link-in-bio page: logo, rating, top services, big Book button (mobile-perfect).

### Schema/GraphQL/Backend/Frontend
`appointments.source` values extended; landing variant of VenuePage; QR/PDF
generation (client-side); settings panel section. — Small, contained.

### Edge cases
UTM stripped by apps (fallback `?s=` short param); poster in FR/AR.

---

## F1.8 Reports v2 + export

**Complexity: M · Order: 5 · Depends on: F0.13 (centimes), F0.3 (roles)**

### Functional spec
Date-range picker (replaces fixed windows), new reports: staff utilization
(booked hours / working hours), retention (returning-client rate, cohort by
first-visit month), booking sources, no-show rate trend; Excel (xlsx) and PDF
export in French formatting; monthly auto-email/WhatsApp summary to owner.

### User stories
- *Owner*: I export last month for my accountant in one click.
- *Manager*: I see Sara is 85% utilized but Nadia 40% — I adjust hours.
- *Owner*: the 1st of each month I get my summary on WhatsApp.

### Acceptance criteria
- [ ] Arbitrary from/to (≤ 366 d) on all report queries; comparisons vs previous period.
- [ ] Utilization, retention cohort, source breakdown, no-show trend charts.
- [ ] XLSX export (sales journal, appointments log) generated async (Oban) → download link notification; PDF summary.
- [ ] Monthly digest job per venue (opt-out).
- [ ] Owner/manager only.

### GraphQL
`reportSummary(from, to)` replaces `days`; `reportExport(kind, from, to)` →
job id; `exportStatus(id)` → url.

### Backend
Aggregate queries with `(venue_id, date)` indexes; `elixlsx` for XLSX;
`ChromicPDF` or client-side print CSS for PDF (decide in task); exports
stored via Storage with signed URLs (24h).

### Frontend
ReportsPage: range picker, new chart components, export menu.

### Edge cases
Timezone day boundaries (Casablanca); huge exports (chunked queries); revenue
restated after refunds (F1.1 links).

---

## F1.1 Deposits & no-show protection (Moroccan rails)

**Complexity: XL · Order: 6 (track starts week 1) · Depends on: F0.13 (centimes), F0.10; external: gateway contract**

### Functional spec
Optional per-venue deposit policy: for selected services (or ticket ≥
threshold), booking requires a deposit — via **card (CMI gateway or YouCan
Pay)** or **cash-voucher rail** (customer gets a reference to pay at
CashPlus/Barid partner; booking auto-confirms on webhook/manual code entry;
slot held 4h pending payment). Deposit applies to the bill at checkout;
no-show forfeits per policy; cancellation within window refunds (card) or
credits a wallet balance (voucher).

### User stories
- *Owner*: negafa bookings require 200 MAD deposit — my no-shows collapse.
- *Customer (no card)*: I pay the deposit in cash at the CashPlus around the corner and my slot is secured.
- *Customer*: my deposit shows as already-paid at the salon.
- *Admin*: I see payment volumes, failures, and reconcile gateway payouts.

### Acceptance criteria
- [ ] Policy config: per-service toggle or amount threshold; deposit fixed amount or % (min 20 MAD).
- [ ] Card flow: gateway-hosted payment page (PCI SAQ-A), webhook-confirmed, idempotent; 3-DS supported.
- [ ] Voucher flow: reference generated, hold expires in 4h (configurable) releasing the slot; confirmation on webhook or receptionist code entry.
- [ ] Checkout (POS) shows deposit as credit line; sale totals reconcile to centime.
- [ ] Refund rules by cancellation window; no-show marks deposit forfeited (owner can waive).
- [ ] Ledger: every payment event (auth, capture, refund, forfeit, payout) is an immutable `payment_events` row; daily reconciliation report vs gateway.
- [ ] Provider behind a behaviour (`PaymentProvider`): `CmiProvider`, `YouCanProvider`, `VoucherProvider`, `DevProvider`.

### Schema
```sql
CREATE TABLE payments (id, venue_id, client_id, booking_ref, kind, -- deposit|balance
  method, -- card|voucher|wallet
  amount_cents, status, -- pending|authorized|paid|refunded|forfeited|expired
  provider, provider_ref, expires_at, inserted_at, updated_at);
CREATE TABLE payment_events (id, payment_id, event, payload jsonb, inserted_at);
ALTER TABLE sales ADD deposit_payment_id bigint;
ALTER TABLE appointments ADD hold_expires_at timestamp; -- pending-deposit holds
```

### GraphQL
`book` returns `paymentRequired {amountCents, methods}` when policy applies;
`initiateDeposit(bookingRef, method)` → redirect URL / voucher ref;
`confirmVoucher(code)` (receptionist); venue `paymentPolicy` CRUD; webhooks are
HTTP controllers, not GraphQL.

### Backend
New context `Blastek.Payments` (provider behaviour, ledger, reconciliation
Oban job); booking flow: policy check → tentative appointment with hold →
confirm on payment event → release job on expiry. Notifications: payment
received, hold expiring (T-1h), deposit forfeited.

### Frontend
BookingFlow step 4.5 payment screen (method choice, voucher instructions with
map link); dashboard settings → Payments policy; POS deposit line; admin
payments view.

### Permissions
Policy: owner. Voucher confirm: receptionist+. Refund/waive: manager+.

### Edge cases
Webhook before redirect-return (idempotent upsert); double webhook; partial
gateway outage (queue + retry with backoff, never block cash bookings);
deposit > final bill (change given / wallet credit); expired hold but customer
paid at agency late (auto-rebook if slot free else credit + apology flow);
gateway settlement currency MAD only.

---

## F1.6 Moroccan invoicing & fiscal receipts

**Complexity: L · Order: 7 · Depends on: F0.13, F1.8; pairs with F1.1**

### Functional spec
Legal-grade documents: venue fiscal profile (ICE, IF, RC, patente, TVA
regime: assujetti 20% / auto-entrepreneur exempt), numbered sequential
invoices per venue-year (`2027-000123`), TVA lines when applicable, PDF in
French (Arabic header optional), client fiscal details for B2B receipts;
sales journal export aligned (F1.8). DGI e-invoicing flagged as a tracked
compliance item (spec when published).

### User stories
- *Owner*: every checkout can print/WhatsApp a conforming receipt.
- *Owner (auto-entrepreneur)*: my receipts show the right regime, no TVA.
- *Customer (B2B, hotels/production)*: I get a proper facture with my ICE.

### Acceptance criteria
- [ ] Fiscal profile in settings; validation of ICE (15 digits)/IF formats.
- [ ] Checkout generates invoice row atomically with sale; numbering gapless per venue-year (Postgres sequence per venue, locked).
- [ ] PDF: header (venue fiscal ids), lines, TVA breakdown, totals in MAD, "Arrêté la présente facture à …" wording; WhatsApp/print/download.
- [ ] Credit notes on refunds referencing original number.
- [ ] TVA summary report by period (F1.8 addition).

### Schema
```sql
CREATE TABLE invoices (id, venue_id, sale_id UNIQUE, number, year,
  fiscal jsonb, -- frozen venue+client fiscal snapshot
  totals jsonb, pdf_key, kind, -- invoice|credit_note
  ref_invoice_id, inserted_at, UNIQUE(venue_id, year, number));
ALTER TABLE venues ADD fiscal jsonb; -- ICE, IF, RC, regime…
ALTER TABLE clients ADD fiscal jsonb;
```

### GraphQL/Backend/Frontend
`invoice(saleId)`, `venue.fiscal` CRUD; `Blastek.Invoicing` (numbering,
snapshot, PDF via same engine as F1.8); SalesPage invoice actions; checkout
modal "send receipt via WhatsApp" toggle (default on).

### Edge cases
Regime change mid-year (numbering continues, TVA per-invoice snapshot); voided
sale before send (credit note, never delete); receipt for cash sale without
client record (walk-in "Client de passage").

---

## F1.7 Marketing automations & reputation routing

**Complexity: L · Order: 8 · Depends on: F0.10, F0.8**

### Functional spec
Automation recipes (toggle + light config, not a campaign builder): win-back
(no visit in N weeks → offer message), birthday greeting (+optional promo),
post-visit thank-you, **review routing** (post-visit "how was it?" — 4–5★ →
Google Maps review link + Blastek review, ≤ 3★ → private feedback form to
owner first). Plus one-off broadcast to consenting clients (segment: all /
lapsed / top spenders) with monthly quota by plan. Consent ledger
(opt-in/opt-out per venue, STOP keyword honored).

### User stories
- *Owner*: lapsed clients get a gentle Darija come-back message automatically.
- *Owner*: happy clients get nudged to Google Maps; unhappy ones reach me privately first.
- *Customer*: one tap unsubscribes me from a salon's marketing (transactional unaffected).

### Acceptance criteria
- [ ] Recipes configurable per venue (thresholds, templates with variables, FR/AR), preview before enable.
- [ ] Marketing sends only to `marketing_consent=true` clients; STOP/"إيقاف" reply sets opt-out via webhook; consent changes audited.
- [ ] Win-back: max 1 per client per 90 d; birthday needs stored birthdate (new client field + booking-flow optional ask).
- [ ] Review routing thresholds; private feedback lands in dashboard inbox with reply-via-WhatsApp.
- [ ] Broadcast: segment estimate shown, quota enforced, scheduled send, per-message delivery stats.

### Schema
```sql
ALTER TABLE clients ADD birthdate date, marketing_consent bool DEFAULT false,
  consent_updated_at timestamp;
CREATE TABLE automation_settings (venue_id, recipe, enabled, config jsonb);
CREATE TABLE feedback (id, venue_id, client_id, booking_ref, rating, comment,
  status, inserted_at); -- private (≤3★) channel
CREATE TABLE broadcasts (id, venue_id, segment jsonb, template, status,
  scheduled_at, stats jsonb);
```

### GraphQL/Backend/Frontend
`updateAutomation`, `createBroadcast`, `feedbackInbox`; `Blastek.Marketing`
context + Oban cron (daily recipe sweep); dashboard Marketing page (new nav
item, manager+); consent toggle surfaced in client profile + booking flow.

### Edge cases
Client of many venues opts out per venue; quota race on scheduled broadcasts;
message variables with missing data (skip gracefully); Ramadan/Eid quiet hours
(no marketing sends 03:00–10:00; configurable).

---

## F1.9 Walk-in virtual queue

**Complexity: L · Order: 9 · Depends on: F0.1, F0.10, B9 subscriptions**

### Functional spec
A venue mode (can coexist with appointments): customers take a ticket from
the venue page/QR at the door; queue shows live position + estimated wait
(rolling avg service time per staff); staff advance the queue from a
dashboard "Queue" screen (also usable as door tablet); no-show after 2 calls →
dropped. Bridges appointment-less barbershops onto the platform.

### User stories
- *Customer*: I take a ticket from the QR at the door and get a WhatsApp ping when I'm 2nd.
- *Barber*: I tap "Next" between cuts; the shop TV/tablet shows who's up.
- *Owner*: queue clients become CRM clients I can market to later.

### Acceptance criteria
- [ ] Join via venue page (button when open + queue mode on) or QR deep link; phone required (OTP-lite: WhatsApp code only if not logged in).
- [ ] Live position via GraphQL subscription; estimated wait from trailing 10 services per active staff.
- [ ] Staff console: list, "call next", "start", "done", "no-show"; called → WhatsApp "you're up"; 2nd call + 5 min → dropped.
- [ ] Ticket optionally targets a specific barber (their own line) or first-free.
- [ ] Completed queue services create appointment rows (`source='walkin_queue'`) so CRM/reports/reviews work unchanged.

### Schema
```sql
CREATE TABLE queue_tickets (id, venue_id, client_id, staff_id nullable,
  service_id nullable, position, status, -- waiting|called|serving|done|dropped
  called_at, started_at, inserted_at);
ALTER TABLE venues ADD queue_mode bool DEFAULT false;
```

### GraphQL
`joinQueue`, `leaveQueue`, `advanceQueue(action, ticketId)`;
`queue(venueSlug)` query + `queueChanged(venueId)` subscription.

### Backend
`Salon.Queue` (position management single-writer per venue via advisory lock);
wait estimator; notification hooks.

### Frontend
Market: queue widget on VenuePage + standalone `/v/:slug/queue` (big-type
tablet/TV layout); dashboard QueuePage (staff+).

### Edge cases
Queue + appointments same staff (appointments win; queue estimator accounts
for upcoming appointments); venue closes with people waiting (bulk notify +
apologize); duplicate join (one live ticket per phone per venue); offline
tablet (subscription reconnect + state refetch).

---

## F1.5 Recurring appointments

**Complexity: M · Order: 10 · Depends on: F0.9, F0.10**

### Functional spec
Dashboard-created repeat bookings (weekly/biweekly/every-4-weeks, N
occurrences or until date) materialized as real appointments up front;
conflicts at creation listed for per-occurrence adjustment. Customers see the
series in Account; cancel one vs. rest. (Customer-initiated recurring is
Phase 2 polish.)

### Acceptance criteria
- [ ] Series create from appointment drawer; conflicting occurrences resolved interactively (skip/shift suggestions).
- [ ] Series id links occurrences; edit scope prompt (this one / this and following).
- [ ] Reminders per occurrence as normal; cancellation of the series notifies once.
- [ ] Series respects blocks/closures existing at creation; later closures flag conflicts (F0.4 mechanism).

### Schema
`appointments.series_id uuid`, `series` table (rule jsonb, created_by).

### GraphQL
`createAppointmentSeries`, `updateSeries(scope)`, `cancelSeries(scope)`.

### Backend/Frontend
Materializer in `Salon` (max horizon 6 mo); drawer UI + Account series badge.

### Edge cases
Staff leaves mid-series (bulk reassign helper); price changes mid-series
(occurrences keep booked price); DST-free (minute math, no tz shifts).

---

## Phase 1 exit criteria

1. ≥ 30% of bookings carry a deposit at venues with policy on; measured no-show drop published to owners.
2. Waitlist fills ≥ 20% of cancellations at active venues.
3. First 10 walk-in-only barbershops live on queue mode.
4. Every active venue issued ≥ 1 conforming invoice; TVA report reconciles.
5. Marketing consent ledger audited; zero spam complaints escalated.
