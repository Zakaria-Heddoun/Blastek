# Phase 2 — Months 6–18 (monetization & depth)

Goal: revenue for Blastek (plans, placement, messaging) and depth for salons
(retail, loyalty, chains). Specs here are one notch lighter than Phase 0/1 —
each gets a full grooming pass before its sprint.

Implementation order: **F2.7 → F2.1 → F2.9 → F2.2 → F2.5 → F2.4 → F2.3 →
F2.6 → F2.8 → F2.10**.

---

## F2.7 Promo codes & off-peak pricing

**Complexity: M · Order: 1 · Depends on: F0.13, F1.4**

**Spec**: venue-defined promo codes (percent/fixed, service scope, validity,
usage caps, new-clients-only flag) entered in booking flow; off-peak automatic
discounts (weekday/time-window % off shown as struck-through prices).
**Stories**: *Owner*: Tuesdays 10–14h at −20% fill my dead hours. *Customer*:
the discount applies automatically, no code needed. *Receptionist*: codes also
work at POS.
**AC**: price resolution order base→staff-override→variant→off-peak→code,
never negative; code validation atomic with booking (usage cap race-safe);
discounts itemized on invoice (F1.6) and reports (net revenue).
**Schema**: `promo_codes` (venue_id, code, rules jsonb, uses, cap),
`price_rules` (venue_id, kind='offpeak', windows jsonb, pct),
`appointments.discount_cents + promo_code_id`.
**GraphQL**: `validatePromo(code, legs)`, venue CRUD; menu prices return
`{listCents, effectiveCents, rule}`.
**Backend**: `Salon.Pricing` module centralizing resolution (refactor F1.4's
`price_for` here). **Frontend**: settings → Offers page; flow promo input;
struck-through price components.
**Notifications**: none. **Edge cases**: code + off-peak stacking (config:
best-of, default), expired mid-checkout, code sharing beyond cap.

---

## F2.1 Loyalty & referrals

**Complexity: L · Order: 2 · Depends on: F0.10, F2.7**

**Spec**: per-venue points program (earn per dirham completed, redeem as
discount at threshold) and platform referral credits (both sides get venue
credit after referee's first completed visit).
**Stories**: *Customer*: my 10th blow-dry is basically free. *Owner*: points
config is 2 fields, not a rules engine. *Customer*: my referral link gives my
friend 20 MAD off and me the same.
**AC**: points accrue on checkout complete (not booking) and reverse on
refund; balance visible in Account + POS; redemption creates discount line;
referral attribution via link/code survives signup; fraud guards
(self-referral by phone/device, cap per referrer/month); expiry 12 mo with
T-30d nudge.
**Schema**: `loyalty_settings` (venue), `loyalty_ledger` (venue, client,
delta, reason, ref), `referrals` (code, referrer_user, referee_user, status,
credited_at).
**GraphQL**: `myLoyalty(venue)`, `redeemPoints`, `myReferralCode`,
`applyReferral(code)`.
**Backend**: `Blastek.Loyalty` ledger-first (balances are sums, never stored
mutable); checkout + refund hooks; Oban expiry sweeps.
**Frontend**: Account loyalty cards per venue; POS redeem control; settings
page; referral share sheet (WhatsApp-first).
**Notifications**: points earned (batched, max 1/day), reward unlocked,
referral credited, expiry warning.
**Edge cases**: redemption > bill (cap at bill), venue disables program with
balances outstanding (honor 90 d), merged client records.

---

## F2.9 Resource scheduling & group bookings (hammam-grade)

**Complexity: L · Order: 3 · Depends on: F1.4 · Unblocks: F3.5**

**Spec**: bookable **resources** (rooms, chairs, equipment) with capacity;
services declare resource requirements (e.g. hammam session: 1 slot of
steam-room capacity 8 + optional gommage staff); **group bookings**: one
booker reserves N spots (guest names optional), one payment/deposit, N
capacity units.
**Stories**: *Owner (hammam)*: my steam room takes 8 people; bookings stop at
8 regardless of staff. *Customer*: I book hammam for me and 3 friends in one
go. *Staff*: the calendar shows room occupancy, not fake staff columns.
**AC**: availability = staff (if required) ∩ resource capacity; calendar gains
resource lanes; group size selector (≤ capacity remainder) multiplies
price/deposit; check-in marks attendees; capacity race-safe (same exclusion
approach with capacity counting via constraint trigger).
**Schema**: `resources` (venue, name, capacity), `service_resources`
(service, resource, units), `appointment_resources` (appointment, resource,
units), `appointments.party_size int DEFAULT 1`.
**GraphQL**: availability/book accept `partySize`; venue resources CRUD;
calendar query returns resource occupancy.
**Backend**: availability engine third dimension (capacity counting per
15-min step — precompute occupancy vector per resource/day); this is the
hardest piece, isolate in `Salon.Capacity`.
**Frontend**: CalendarPage resource lanes toggle; flow party-size step for
capacity services; catalog resource editor.
**Notifications**: standard, party size mentioned. **Edge cases**: party
larger than remaining capacity (offer split times), resource maintenance
(blocks apply to resources too — reuse staff_blocks generalized to
`subject_type`), mixed staff+resource legs in chains (F1.2 solver extension).

---

## F2.2 Gift cards & packages

**Complexity: L · Order: 4 · Depends on: F1.1 (payment), F0.13**

**Spec**: digital gift cards (fixed amounts, personalized message, WhatsApp
delivery, redeem by code at POS/booking) and service packages (e.g. 10-entry
hammam pass, 5-session gommage cure) sold prepaid, tracked per-use.
**Stories**: *Customer*: Eid gift for my mother in 2 minutes. *Owner*:
packages get me cash up front and habitual clients. *Receptionist*: redeem =
type code / scan QR.
**AC**: card purchase online (F1.1 rails) or POS cash; balance ledger;
package uses decrement on checkout of matching service; expiry (12 mo min,
displayed); refunds only to unspent balance; liability report for the owner
(outstanding balances).
**Schema**: `gift_cards` (venue, code UNIQUE, initial/balance cents, buyer,
recipient, expires), `packages` (venue, name, service_id/variant scope, uses,
price), `package_purchases` (client, remaining, expires), ledgers for both.
**GraphQL**: purchase/redeem mutations, `myPackages`, POS lookup by code.
**Backend**: extend `Payments` + POS checkout paths; code generation (human
8-char). **Frontend**: venue page "Gift" tab, POS redeem, settings CRUD,
Account wallet section.
**Notifications**: delivery to recipient (scheduled for Eid morning if
chosen), balance reminders T-30d expiry.
**Edge cases**: partial redemptions across visits, venue suspension with
outstanding liabilities (platform policy: escrowed in Phase 2 payments
design), gifting to non-user phone (claims on signup).

---

## F2.5 Commissions & chair rent

**Complexity: L · Order: 5 · Depends on: F0.3, F1.8**

**Spec**: per-staff compensation models: commission % per service category
and/or retail %, fixed salary note (informational), or **chair rent** (renter
flag: fixed weekly/monthly rent tracked with payment log; renter's revenue
excluded from venue reports and visible in their own P&L view).
**Stories**: *Owner*: end of month, each stylist's commission sheet is ready.
*Renter barber*: I see my own numbers and my rent status; the shop doesn't see
my client list. *Owner*: rent due-dates stop living in my head.
**AC**: commission report per staff/period (services, retail when F2.4
lands); rent schedule with due/paid/late states + WhatsApp nudges; renter data
partition (their appointments/clients visible to them + owner-configurable);
export to XLSX.
**Schema**: `compensation_plans` (staff, kind, rules jsonb),
`rent_schedules`/`rent_payments`; `staff.renter bool`.
**GraphQL**: plans CRUD, `commissionReport(staffId, from, to)`,
`rentLedger`, staff self `myEarnings`.
**Backend**: `Blastek.Compensation` computing from sales/sale_items; renter
scoping added to `RequireMember` visibility rules (the sensitive piece —
test matrix).
**Frontend**: Team member drawer → Compensation tab; staff dashboard
"Earnings"; rent ledger page.
**Notifications**: rent due T-3d/T0/late, monthly commission summary.
**Edge cases**: plan changes mid-period (effective-dated rules), tips
(pass-through, excluded), mixed model staff (commission + rented chair —
supported), retro corrections via adjustment entries not edits.

---

## F2.4 Inventory & retail POS

**Complexity: XL · Order: 6 · Depends on: F0.13, F1.6**

**Spec**: product catalog (brands, purchase/retail price, barcode), stock
levels with movements (purchase, sale, adjustment, internal-use), low-stock
alerts, retail lines in POS checkout (standalone or attached to appointment
sale), basic supplier records; product sales in reports/commissions/invoices.
**Stories**: *Receptionist*: scan the shampoo, it lands on the same ticket.
*Owner*: I see margin per product and get pinged at 2 units left. *Staff*:
internal-use tracking stops the "where did the color stock go" mystery.
**AC**: stock never blocks a sale (allow negative with warning — salon reality),
movement ledger immutable, POS barcode entry (USB scanner = keyboard input +
camera scan on mobile), inventory count mode (guided recount → adjustments),
COGS margin in reports, invoice lines include products with TVA rate
(products 20% — separate from service rate config).
**Schema**: `products` (venue, brand, name, barcode, cost/retail cents,
stock_qty, min_qty, tva_rate), `stock_movements` (product, kind, qty, ref,
by), `sale_items.product_id nullable + qty`.
**GraphQL**: product CRUD, `recordStockMovement`, POS `checkout` accepts
`retailLines`, low-stock query.
**Backend**: `Blastek.Inventory`; checkout extension; alert Oban daily.
**Frontend**: new Inventory page (nav, manager+), POS retail search/scan
panel, count mode UI.
**Notifications**: low-stock digest (daily max 1). **Edge cases**: same
barcode two venues (venue-scoped), returns (negative sale line + movement),
unit vs. usage products (colors consumed per-service: track as internal-use,
not per-appointment recipe — recipes = Phase 3+).

---

## F2.3 Memberships & subscriptions

**Complexity: L · Order: 7 · Depends on: F2.2, F1.1**

**Spec**: recurring plans (e.g. "Coupe illimitée homme 199 MAD/mois",
"2 brushings/mois") with benefit rules (unlimited service X with fair-use
cap, or N credits/month, or % off everything); collection via card auto-charge
where possible, else in-salon renewal with WhatsApp dunning.
**AC**: benefit application automatic at booking/POS; pause/cancel rules
(owner-set commitment, min 1 mo); renewal states current/grace(7d)/lapsed
with notification ladder; fair-use cap (default 1/day) anti-abuse; MRR report.
**Schema**: `membership_plans` (venue, rules jsonb, price, period),
`memberships` (client, plan, status, renews_at), usage ledger.
**GraphQL**: plans CRUD, `subscribe`, `renewMembership(pos)`,
`membershipUsage`. **Backend**: `Blastek.Memberships` + dunning Oban; POS
integration. **Frontend**: venue page Plans tab, POS membership badge +
renewal, settings CRUD, Account membership card.
**Notifications**: renewal T-3d, receipt, grace, lapsed win-back.
**Edge cases**: card fails → grace + in-salon renewal path (cash reality),
plan price change (grandfather existing), benefit + promo stacking (benefit
wins, no stack).

---

## F2.6 Multi-location

**Complexity: L · Order: 8 · Depends on: F0.1 groundwork, F0.3, F1.8**

**Spec**: organizations grouping venues: shared owner/managers via org-level
memberships, cross-location dashboard (consolidated reports, per-location
compare), optional shared client base (client record per venue kept, org view
merges by user/phone), staff transferable, catalog copy tools ("push this
menu to Rabat branch").
**AC**: org roles overlay venue roles (org_owner ⊃ venue owner everywhere);
consolidated reports sum correctly (currency/centimes exact); catalog
push/copy is explicit action with diff preview, never sync-magic; customer
sees branches on one brand page (`/b/:brand` listing venues).
**Schema**: `orgs`, `org_members`, `venues.org_id`, `venues.brand_slug`.
**GraphQL**: org queries mirroring venue ones with `venueIds` filter; admin
org tooling. **Backend**: report aggregations accept venue sets; membership
resolution order org→venue. **Frontend**: venue switcher becomes org-aware;
Reports location filter; brand page.
**Edge cases**: franchisee independence (org sees aggregates, not client PII —
configurable), moving a venue between orgs (admin-only, audited).

---

## F2.8 Marketplace monetization: plans, featured placement, messaging credits

**Complexity: L · Order: 9 · Depends on: F0.12, F1.7; legal/pricing decisions**

**Spec**: platform revenue: **subscription tiers** (Free: core calendar/CRM +
capped WhatsApp msgs/mo; Pro: automations, marketing, reports v2, invoicing,
queue; Business: multi-location, API, white-label eligibility), **featured
placement** (paid ranking boost, clearly badged "Sponsorisé", capped per
city/category), **messaging credit packs** beyond quota. Billing itself uses
F1.1 rails (card) + bank transfer with manual admin confirmation (Moroccan
B2B reality); dunning → feature-freeze (never data hostage: export always
free).
**AC**: entitlement checks server-side per feature key; usage metering
(messages) accurate ±0; sponsored results ≤ 2 per results page, badged;
plan change prorates; admin billing console (invoices to venues via F1.6
engine — Blastek invoices itself the same way).
**Schema**: `plans`, `venue_subscriptions`, `usage_counters`,
`placement_campaigns` (city, category, budget, cpc-lite: flat weekly slots).
**GraphQL**: `venuePlan`, `upgradePlan`, admin billing ops; search injects
sponsored entries. **Backend**: `Blastek.Billing` + entitlement plug/middleware
(`RequirePlan feature:`); metering counters (Postgres, not Redis — volume
fine). **Frontend**: settings → Plan & billing; upgrade paywalls (soft,
FR/AR); admin billing console; search sponsored styling.
**Notifications**: quota 80%/100%, invoice due, dunning ladder.
**Edge cases**: downgrade with data above caps (read-only, never delete),
sponsor of suspended venue (auto-pause + credit), fairness audit log for
ranking (admin-visible).

---

## F2.10 Native apps evaluation & mobile deepening

**Complexity: M (evaluation + PWA push) · Order: 10 · Depends on: F0.14 metrics**

**Spec**: decision gate with data: if PWA install/notification metrics
underperform targets (install rate < 15% of repeat customers, push opt-in
< 40% Android), green-light React Native shell (Expo) reusing the GraphQL
API 1:1 — customer app first, staff calendar app second. Until then: PWA
polish (app shortcuts, share targets, offline booking view).
**AC**: metrics instrumented and reviewed; if RN approved → separate epic
kick-off with its own PRD; staff PWA "My day" standalone view ships
regardless (S).
**Edge cases**: iOS PWA limitations documented per feature (push, badging).

---

## Phase 2 exit criteria

1. ≥ 25% of active venues on a paid tier; churn < 3%/mo.
2. Featured placement live in ≥ 2 cities without ranking-trust complaints.
3. First hammam running capacity bookings; first chain on multi-location.
4. Retail attached to ≥ 15% of sales at venues using inventory.
