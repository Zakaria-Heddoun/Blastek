# Blastek — a local Fresha clone

Plan and research notes for recreating Fresha's base functionality as an app that runs
entirely on this computer.

---

## 1. What Fresha actually is (research summary)

Fresha is the largest beauty & wellness booking platform (~130k businesses, 120+
countries). It is really **two products sharing one data model**:

1. **A business dashboard ("Fresha Partner")** — the salon's operating system:
   - **Calendar** — the heart of the product. Day view with one column per staff
     member, appointments as colored blocks, drag/click to create, statuses
     (booked → confirmed → started → completed / cancelled / no-show).
   - **Clients (CRM)** — profiles with contact info, notes, allergy alerts, and full
     appointment/purchase history.
   - **Services catalog** — categories → services, each with duration, price, and
     which staff can perform it (staff-specific pricing exists upstream).
   - **Team management** — staff members, per-weekday working hours, permissions,
     commissions (Team Pay payroll upstream).
   - **POS / checkout** — check out an appointment: line items, tip, payment method
     (card/cash), produces a sale record.
   - **Reports** — revenue over time, top services/staff, client stats.
   - Also upstream: inventory/retail, marketing campaigns (email/SMS), forms,
     waitlist, memberships, multi-location.

2. **A consumer marketplace (fresha.com)** — clients discover venues and book 24/7:
   - Venue page: name, rating/reviews, photos, service menu with prices/durations.
   - **Booking flow: pick service(s) → pick professional (or "any") → pick a time
     from computed availability → confirm.** Booking lands instantly in the
     business's calendar.
   - Business model: free SaaS; Fresha monetizes payments (~2.3% + 20¢ in person),
     a 20% new-client marketplace fee, and paid add-ons — not monthly fees.

Their real stack (for reference, not for copying): Ruby monolith migrated to
Elixir/Ruby/TypeScript microservices, GraphQL federation, Kafka, Kubernetes, React
frontends. Massive overkill for a local clone.

## 2. Scope for the local clone ("base functionality")

**In scope**

| Area | What we build |
|---|---|
| Calendar | Day view with staff columns + week view per staff, 15-min grid, click-to-book, appointment drawer |
| Appointments | Full lifecycle: booked / confirmed / started / completed / cancelled / no-show, reschedule |
| Online booking | Fresha-style public page: services → professional → time slots → client details → confirmation |
| Availability | Computed from staff working hours minus existing appointments, honoring service duration |
| Clients | Searchable directory, profile with notes + allergy alert + history, auto-created from online bookings |
| Services | Categories, duration, price, staff assignment, CRUD |
| Team | Staff CRUD, per-weekday working hours editor, calendar colors |
| Checkout / POS | Checkout an appointment with tip + payment method → sale record |
| Sales & Reports | Transaction list, revenue tiles, revenue-by-day chart, top services/staff |
| Marketplace feel | Venue page with seeded star ratings + reviews |

**Out of scope** (what real Fresha adds on top): real payment processing, SMS/email
sending, multi-location, inventory, marketing campaigns, waitlist, memberships,
payroll, user accounts/auth (single-tenant local app).

## 3. Architecture

Optimized for "runs on this computer with zero setup pain":

- **Runtime:** Node.js 24 (installed) — no other runtime needed.
- **Dependencies: none.** Built-in `node:http` for the server and built-in
  `node:sqlite` for storage. No `npm install`, no native builds, no node_modules
  syncing into OneDrive.
- **Backend:** small REST/JSON API (`server.js` + `src/`), SQLite file `data.db`
  created and seeded on first run.
- **Frontend:** two static vanilla-JS single-page apps served by the same server:
  - `/` — **admin dashboard** (calendar, clients, services, team, sales, reports)
  - `/book` — **client booking page** (the marketplace/venue experience)
- **Time model:** appointments stored as `date` (YYYY-MM-DD) + start/end minutes —
  keeps availability math trivial and timezone-proof for a local app.

```
Blastek/
├── PLAN.md
├── package.json          # scripts only, zero deps
├── server.js             # http server: static files + /api router
├── src/
│   ├── db.js             # schema, connection, first-run seed
│   ├── seed.js           # demo salon: staff, services, clients, history
│   ├── availability.js   # slot computation
│   └── api.js            # route handlers
└── public/
    ├── index.html        # admin app shell
    ├── book.html         # booking app shell
    ├── css/app.css
    └── js/  (admin.js, calendar.js, booking.js, shared.js)
```

## 4. Data model

```
settings          key, value                      (business name, hours, slot size)
service_categories id, name, sort
services          id, category_id, name, description, duration_min, price, active
staff             id, name, role, color, active
staff_services    staff_id, service_id            (who can perform what)
staff_hours       staff_id, weekday(0-6), start_min, end_min, working
clients           id, first_name, last_name, email, phone, allergies, notes, created_at
appointments      id, booking_ref, client_id, staff_id, service_id,
                  date, start_min, end_min, status, price, notes, source, created_at
sales             id, client_id, subtotal, tip, total, payment_method, created_at
sale_items        id, sale_id, appointment_id, description, amount
reviews           id, client_name, rating, comment, created_at
```

Multi-service online bookings create one appointment per service, back-to-back,
grouped by `booking_ref` — same as Fresha's behavior on the calendar.

**Availability algorithm** (the core of any booking product): for a date, staff
member, and total requested duration — take that weekday's working hours, walk it in
15-minute steps, keep each start time whose full duration fits inside working hours
and overlaps no non-cancelled appointment; drop past times for today. "Any
professional" = union across all staff qualified for every selected service.

## 5. Build phases

1. **Backend core** — server, schema, seed data (demo salon with 4 staff, ~14
   services, ~18 clients, 5 weeks of appointment + sales history, reviews).
2. **Admin dashboard** — calendar day/week views, appointment create/edit drawer,
   status flow, checkout modal; clients, services, team pages.
3. **Online booking** — venue page, 4-step flow, availability API, confirmation;
   bookings appear live in the admin calendar.
4. **Sales & reports** — transactions, revenue tiles, by-day chart, top lists.
5. **Verify** — exercise both apps end-to-end against the running server.

## 6. Later, if we want closer parity

Deposit/no-show protection (Stripe test mode), email reminders (local SMTP catcher),
waitlist, inventory & retail checkout, multi-location, real auth and roles, drag-drop
rescheduling, recurring appointments, marketing blasts, a React/Next.js rewrite if
the vanilla app hits its ceiling.
