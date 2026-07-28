# Phase 3 — Differentiation & expansion

Goal: the features nobody else has — WhatsApp-native booking, Darija AI,
verticals (weddings, at-home, tourists), white-label. Specs are directional;
each requires a discovery spike before commitment (spikes are backlog tasks).

Implementation order: **F3.1a → F3.3 → F3.7 → F3.2 → F3.1b → F3.4 → F3.5 →
F3.6 → F3.9 → F3.8**.

---

## F3.1 WhatsApp-native booking bot

**Complexity: XL (split: F3.1a structured M→L, F3.1b AI XL) · Depends on: F0.10 infra, F1.2**

**Spec**: book entirely inside WhatsApp. **F3.1a (structured)**: interactive
message flows — service list messages → professional buttons → date/slot list
→ confirm; state machine per conversation; falls back to "open the site" link
anytime. **F3.1b (AI)**: free-text Darija/French understanding ("bghit
ndir salon had sebt m3a Sara" → slot proposal), LLM-driven with the
structured flow as guardrails (AI proposes, buttons confirm — never books from
free text without a tap).
**Stories**: *Customer*: I book without installing or opening anything —
just the salon's WhatsApp. *Owner*: my WhatsApp button on Instagram becomes a
booking machine. *Customer*: I write in Darija and it just understands.
**AC (a)**: full happy path ≤ 8 taps; state survives 24h gaps; reschedule/
cancel via the same chat; per-venue enable + number routing (platform number
with venue context vs. venue's own number via Cloud API — decision spike).
**AC (b)**: intent extraction (service, date, staff, party) evaluated on a
labeled Darija test set ≥ 90% top-intent accuracy; hallucination guard: only
real slots offered (AI output constrained to availability API results);
handoff to human (salon inbox) on 2 failed turns.
**Schema**: `wa_conversations` (phone, venue, state jsonb, expires),
`wa_messages` log.
**Backend**: `Blastek.WhatsApp.Bot` (state machine), `Blastek.AI` (LLM client
behind behaviour, provider-agnostic; availability-constrained tool calls).
**Frontend**: dashboard chat inbox (handoff view), bot settings page.
**Notifications**: n/a (it *is* the channel). **Edge cases**: shared family
phones (identify by conversation, confirm name each booking), message
ordering/duplication from Meta, 24h session window pricing (template re-entry),
Arabic/French/Darija code-switching mid-sentence (the test set must include
it).

---

## F3.3 AI no-show risk scoring

**Complexity: M · Depends on: F1.1, F0.10; 6+ months of data**

**Spec**: per-booking risk score (features: client history, lead time,
day/hour, deposit status, source, first-visit flag) → risk tiers driving
policy: high risk → suggest deposit requirement / extra confirmation
touchpoint; dashboard flag on risky bookings.
**AC**: start as transparent logistic model (interpretable, in-house, no PII
leaves platform) evaluated AUC ≥ 0.7 before surfacing; owner sees *reasons*
("2 previous no-shows, booked 9 days ahead"); measurable: no-show rate at
flagged-and-actioned vs. control.
**Schema**: `appointments.risk jsonb` (score, factors, model_version).
**Backend**: nightly scoring Oban job; `Blastek.AI.Risk` (pure Elixir —
Nx/Scholar or hand-rolled logistic; no external service needed).
**Frontend**: calendar badge + drawer explanation + one-tap "require deposit".
**Edge cases**: cold-start venues (global model prior), fairness (no
protected attributes as features; audit doc), score gaming.

---

## F3.7 Tourist mode

**Complexity: M · Depends on: F0.11, F0.6**

**Spec**: English locale completion + tourist-facing discovery for
Marrakech/Agadir/Casablanca (hammam & spa focus): currency *display* toggle
(EUR/USD estimates, MAD charged), international phone OTP, "tourist-friendly"
venue badge (English spoken, card accepted), curated city landing pages
(SEO: "best hammam in Marrakech").
**AC**: full EN flow; intl E.164 phones through OTP + WhatsApp; city landing
pages statically rendered; card-deposit path (F1.1) prioritized for tourist
segment — this segment *has* cards, monetize accordingly.
**Schema**: `venues.tourist_friendly bool`, curated `city_pages` content
table. **Frontend**: landing templates, currency estimate component
(daily ECB/BAM rate fetch). **Edge cases**: rate staleness disclaimer,
non-Moroccan numbers on SMS fallback costs (WhatsApp-only for intl).

---

## F3.2 Voice-note intake

**Complexity: L · Depends on: F3.1a; ASR provider spike**

**Spec**: customers send Darija/French voice notes to the venue's WhatsApp;
ASR → transcript shown in the salon inbox with extracted intent chips
("Saturday · balayage · afternoon?") → receptionist one-tap converts to a
booking proposal message; full auto-proposal once F3.1b is trusted.
**AC**: transcript ≤ 30 s after receipt; WER benchmark on Darija test set
documented (provider spike compares Whisper-large vs. hosted APIs on 100
real-style clips); privacy: audio retained 30 d max, opt-out honored;
receptionist correction UI feeds the eval set.
**Schema**: `wa_messages` gains media refs + transcript/intent.
**Backend**: ASR behind `Blastek.AI.Transcribe` behaviour (Oban job).
**Frontend**: inbox audio player + transcript + convert-to-booking action.
**Edge cases**: music/noise clips (confidence threshold → "couldn't
understand" reply), mixed audio languages, long rambles (chunk + summarize).

---

## F3.4 AI schedule optimization / gap filling

**Complexity: L · Depends on: F1.3, F3.3**

**Spec**: daily suggestions to reception: "moving Amal 15 min earlier closes a
45-min gap for a blow-dry — ask her?" One-tap sends a polite WhatsApp move
request (customer accepts/declines via buttons); waitlist offers target the
gaps that remain. Off-peak price suggestions (feed to F2.7) from utilization
patterns.
**AC**: suggestions only when net bookable time increases ≥ 30 min; customer
consent always required (never auto-move); acceptance rate + reclaimed hours
reported to the owner; suggestion engine is deterministic search first
(interval optimization), ML later.
**Backend**: `Blastek.AI.Optimizer` (daily + on-cancellation Oban).
**Frontend**: dashboard "Today's suggestions" panel. **Edge cases**: chain
bookings (move whole chains only), decline fatigue (max 1 ask/client/week).

---

## F3.5 Wedding / negafa vertical

**Complexity: XL · Depends on: F2.9 (groups/resources), F1.1 (installments)**

**Spec**: event-based bookings distinct from slot bookings: multi-day packages
(bride + party), quote workflow (request → salon quote → negotiation →
contract), installment deposit schedule (e.g. 30/40/30), event timeline
(trials, D-day schedule), party group management (N people × services matrix),
dedicated discovery vertical ("Mariage" category with portfolio galleries).
**Stories**: *Bride*: I request quotes from 3 negafas with my date and party
size, compare, and secure with a deposit plan. *Owner (negafa)*: contracts and
payments stop being notebook chaos.
**AC**: quote objects with line-item packages; accept → event with installment
schedule (F1.1 payment links per installment, WhatsApp dunning); event blocks
capacity/staff across days; cancellation ladder per contract terms;
portfolio galleries (attachments) on vertical pages.
**Schema**: `events`, `event_quotes`, `event_installments`, `event_party`
tables. **Backend**: `Blastek.Events` context (parallel to Salon appointments,
integrating with the same calendar). **Frontend**: quote request flow
(market), quote builder + event board (dashboard), vertical landing.
**Edge cases**: date changes (Moroccan wedding reality — reschedule whole
event with fee rules), multi-venue events (Phase 3+), seasonal surge pricing.

---

## F3.6 At-home professionals vertical

**Complexity: XL · Depends on: F0.6 geo, F1.1**

**Spec**: solo pros without a fixed venue ("coiffeuse à domicile"): profile =
service area (city zones), travel buffer auto-inserted between bookings from
zone-to-zone estimates, customer address capture (+ GPS pin), identity
verification tier (CIN check by admin, "Vérifié" badge), safety features
(share-my-appointment link, ratings both directions).
**AC**: availability accounts for travel time between consecutive addresses
(zone matrix, not live routing, v1); address privacy (pro sees exact address
T-24h, zone before); deposit mandatory (no-show cost is higher);
admin verification queue with document handling under CNDP rules (encrypted at
rest, 90-d retention post-decision).
**Schema**: `venues.kind = 'mobile'`, `service_zones`, `appointments.address
jsonb (encrypted)`, verification records.
**Backend**: travel-buffer availability wrapper; verification workflow.
**Frontend**: mobile-pro onboarding variant, address step in flow, zone
editor. **Edge cases**: address wrong on arrival (dispute flow), zone border
pricing, pro cancellation reliability scoring (stricter than venues).

---

## F3.9 Offline-tolerant POS

**Complexity: L · Depends on: F2.4**

**Spec**: dashboard POS keeps working through connectivity drops: local-first
queue (IndexedDB) for checkouts/queue-advances; sync with conflict rules
(server wins on availability, client wins on completed sales); explicit
offline banner + queued-actions drawer; invoice numbers allocated
server-side on sync (provisional receipt until then).
**AC**: airplane-mode demo: 5 checkouts offline → reconnect → all synced,
gapless invoice numbers, zero duplicates (idempotency keys per action);
conflicts surfaced, never silently dropped.
**Backend**: idempotent mutation envelope (`clientMutationId` dedupe table).
**Frontend**: service-worker + sync engine in `web/src/lib/offline.ts`
(scoped: POS + queue only, not the whole dashboard).
**Edge cases**: multi-device same venue offline simultaneously (dedupe by
appointment id), clock skew on provisional receipts.

---

## F3.8 White-label branded apps

**Complexity: XL · Depends on: F2.10 RN decision, F2.8 Business tier**

**Spec**: premium venues/chains get their own branded booking app (name,
icon, palette, their venues only) generated from a template RN shell +
config; Blastek runs backend + updates; store publishing managed service.
**AC**: config-driven theming (no per-client forks), single codebase with
per-tenant build pipeline; feature parity with marketplace booking; pricing in
Business tier + setup fee.
**Edge cases**: store rejections (review guidelines for template apps —
mitigation: sufficient customization + venue-owned developer accounts),
churned client's app sunset policy (contractual).

---

## Phase 3 exit criteria

1. WhatsApp bot handles ≥ 30% of bookings at enabled venues; CSAT ≥ 4.5.
2. Negafa vertical live with ≥ 10 verified providers before wedding season.
3. Tourist pages ranking page-1 for 3 target queries; card-deposit share of
   tourist bookings ≥ 60%.
4. At-home vertical launched in 1 city with 100% verified pros.
