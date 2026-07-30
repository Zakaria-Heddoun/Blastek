# Blastek — a Fresha clone on Fresha's real stack

A salon management platform + booking marketplace, built with the same core
technologies Fresha uses in production: **Elixir/Phoenix**, **PostgreSQL**,
**GraphQL (Absinthe)** and **React/TypeScript**, containerized with Docker.

## Architecture

```
┌────────────────┐   GraphQL    ┌─────────────────┐   Ecto    ┌────────────────┐
│ React + TS     │ ───────────► │ Phoenix/Elixir  │ ────────► │ PostgreSQL 16  │
│ Vite :5173     │  /api/graphql│ Absinthe :4000  │           │ Docker :5433   │
└────────────────┘              └─────────────────┘           └────────────────┘
     web/                            api/  (runs in Docker)        (Docker volume)
```

What real Fresha adds beyond this on their servers: Kafka event streaming, gRPC
microservices, GraphQL federation across services, and Kubernetes. Those only
make sense across a fleet of machines — this is the same stack scaled to one PC.

## Run it

Requires Docker Desktop and Node.js.

```
# 1. API + database + object storage (first boot compiles Elixir deps, ~2-3 min)
docker compose up -d

# 2. Frontend
cd web
npm install
npm run dev
```

Then open:

- **Marketplace** → http://localhost:5173/ — landing, search + venue directory
  (`/venues`), venue page (`/v/:slug`) and booking flow (this is the root app,
  same as fresha.com being the consumer-facing site)
- **Admin dashboard** → http://localhost:5173/dashboard — calendar, clients, catalog, team, sales, reports, settings
  (Fresha's equivalent of partners.fresha.com)
- **GraphQL playground** → http://localhost:4000/api/graphiql — explore the API directly
- **MinIO console** → http://localhost:9001 (`blastek` / `blastek-dev-secret`) — venue photos land in the `blastek-media` bucket

First boot seeds **two independent venues** so multi-tenancy is exercised from
the start:

| Venue | Slug | Contents |
|---|---|---|
| Le Salon Anfa (Casablanca) | `/v/le-salon-anfa` | 4 staff, 15 services, 18 clients, ~5 weeks of history |
| Barber Corner (Rabat) | `/v/barber-corner` | 2 barbers, 6 services, 8 clients, ~4 weeks of history |

Demo accounts (password `blastek123`):

| Account | Access |
|---|---|
| owner@salonanfa.ma | Owner of Le Salon Anfa |
| owner@barbercorner.ma | Owner of Barber Corner |
| leila.bennani@example.com | Customer — no dashboard access |

Signing in to either owner account shows only that venue's calendar, clients
and revenue. Customers sign in once and can book at any venue; "My
appointments" lists their bookings across all of them.

To reseed:

```
docker compose exec api mix ecto.reset
```

### Media storage

Venue photos go to **MinIO** in dev. The browser uploads straight to the bucket
through a presigned PUT — image bytes never pass through the API — and the
server then fetches the file back to validate it and derive the thumb/card/hero
variants. See [api/lib/blastek/media.ex](api/lib/blastek/media.ex).

The adapter is chosen at boot by the presence of `S3_BUCKET`
([api/config/runtime.exs](api/config/runtime.exs)):

| Variable | Dev value | Purpose |
|---|---|---|
| `S3_BUCKET` | `blastek-media` | Set → S3 adapter; unset → filesystem adapter |
| `S3_ENDPOINT_URL` | `http://minio:9000` | Where the **API** reaches storage |
| `S3_PUBLIC_BASE_URL` | `http://localhost:9000` | Where the **browser** reaches it |
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | `blastek` / `blastek-dev-secret` | Credentials |

### Message delivery

All unset in dev, which leaves `DevLogger` in force. Setting either pair
switches the real chain on; production refuses to boot with neither.

| Variable | Purpose |
|---|---|
| `WHATSAPP_TOKEN` / `WHATSAPP_PHONE_NUMBER_ID` | Cloud API credentials; both needed |
| `WHATSAPP_APP_SECRET` | Verifies the HMAC on delivery receipts. Without it the webhook rejects everything |
| `WHATSAPP_VERIFY_TOKEN` | Echoed back during Meta's subscription handshake |
| `SMS_GATEWAY_URL` / `SMS_GATEWAY_KEY` / `SMS_SENDER` | The fallback gateway |
| `PUBLIC_WEB_URL` | Where one-tap links point. The API and the browser reach different addresses |

The two URLs are genuinely different hosts, and both matter: SigV4 signs the
`Host` header, so a URL handed to a browser must be signed for the address the
browser will actually call.

Without `S3_BUCKET` the filesystem adapter writes to `api/priv/uploads` and
serves it at `/uploads`. That is what CI and the test suite use, so the upload
path stays covered with no object store running.

### Signing in

Two ways in. **Phone + one-time code** is the default: the number is the
identity, there is no password to invent, and the name is asked after the code
rather than before it. **Email + password** still works exactly as before.

In dev, nothing is actually texted — `Blastek.Notifications.DevLogger` prints
the message to the API log, so the code is read from there:

```
docker compose logs api --tail 20 | grep "code Blastek"
```

Sessions are server-side rows, which is what makes "log out the device I lost"
possible; they are listed and revocable under **My account**. An access token
lasts 24 h and a refresh token 60 d, and refreshing rotates both — presenting a
refresh token that has already been rotated away revokes the whole session,
since it means two parties are holding it.

> ⚠️ Upgrading past this point invalidates existing sign-ins. The old scheme was
> a self-contained signed token with no server record, so there is nothing to
> migrate — everyone signs in once more.

### Team & roles

A venue's **Roster** (who takes appointments) and its **Access** (who can sign
in) are separate lists on the Team page, because most people are both but some
are only one — and merging them makes "remove their access" delete a year of
history.

Four roles, strongest last: `staff` → `receptionist` → `manager` → `owner`.
Each dashboard field declares its own minimum, and
[role_matrix_test.exs](api/test/blastek_web/role_matrix_test.exs) asserts all of
them against all four roles — including a check that fails when a new gated
field is added without a row.

An owner invites by phone or email; the invitee gets a one-time link
(`/join?token=…`, 7-day expiry), signs in by code, and joins. Role changes and
removals take effect on the member's very next request, and are recorded in
`audit_log`.

### Opening hours, seasons and closures

A venue's week is a **schedule** it can keep more than one of and switch
between with one tap. Ramadan is the reason: it moves the working day rather
than cancelling it, so a salon that opens 21:00–00:30 for a month needs a
second grid, not thirty closures. Minutes past 1440 are just arithmetic —
00:30 is `1470` — and the slot engine, the calendar and the public page all
read the same one.

A **closure** is an exception to whatever the grid says: a day, a range of
days, or a window within a day. Before creating one, **Check bookings** lists
the appointments it would strand, with client names and phone numbers:

> **9 appointments would need moving.** Adding the closure does not cancel
> them — call these customers first.

Nothing is ever silently cancelled. A salon closing for a funeral still has to
telephone the four people booked that afternoon, and the software's job is to
tell it who they are.

Which schedule is active changes what the marketplace advertises, not only what
the booking engine offers — otherwise a venue on Ramadan hours would keep
showing its winter times to shoppers.

### Booking rules

Five settings under **Booking rules** decide what an online customer is offered
and what they can undo without telephoning:

| Setting | Effect |
|---|---|
| Booking slots every | Spacing of the offered grid — 5 to 60 minutes |
| Bookable up to | Beyond the horizon nothing is offered at all |
| Notice needed | Minimum lead time; reaches across midnight, so a 22:00 request cannot take tomorrow's 00:30 slot |
| Cancel online until | Inside the window cancelling becomes a phone call, since the salon has already turned other customers away |
| Confirm automatically | Off means online bookings arrive as `booked` for the salon to confirm, rather than `confirmed` |

They are stored in a schemaless JSONB column but **written through a typed
schema** (`Blastek.Venues.Settings`): unknown keys are dropped rather than
stored, each known key is coerced and range-checked, and reads fall back to a
default so a venue predating a setting behaves sensibly.

### Listing a salon

`/for-business` is a six-step wizard: identity, what you do, your menu, team
size, hours, review. It is **resumable** — the step and its answers live on the
venue, so closing the tab on a phone loses nothing — and the menu step is
seeded from starter catalogs (hair, barber, nails, skin, massage) with FR/AR/EN
names, so an owner picks treatments rather than typing them.

Submitting sends the venue to the admin review queue, which flags likely
duplicates (same name in the same city, or a shared phone number) without
blocking them: two salons in one city really can share a name. The dashboard
works immediately either way — only the public page waits for approval.

### Messages

Confirmations, reminders and cancellation notices go out over **WhatsApp with
SMS as a fallback** — in Morocco WhatsApp is how people are actually reached,
and a number with no WhatsApp account is the ordinary case rather than an
error. The chain is a list tried in order:

```elixir
config :blastek, :notifications_provider, [
  Blastek.Notifications.Providers.WhatsApp,
  Blastek.Notifications.Providers.Sms
]
```

With neither configured, `DevLogger` prints instead of sending — which is what
keeps a bare checkout and CI working. Production refuses to boot on it.

Everything is sent through **Oban**, so a provider outage costs a retry rather
than a lost confirmation, and every attempt is a row in `notifications` written
*before* the provider is called. `notificationLog` (admin-only) is how you find
out what happened to a message somebody says never arrived.

**Reminders** go at T-24h and T-3h, both venue-configurable, both scheduled at
booking time. Cancelling deletes the pending jobs — but the guarantee is that
each job re-reads the appointment as it fires and declines to send if it is no
longer on. Trusting the delete is how somebody gets reminded about an
appointment they cancelled yesterday.

A reminder carries a **one-tap cancel link**: a signed token, no login, opened
on a phone at a bus stop. Tapping it cancels, tells the salon, drops the
remaining reminders, and updates any dashboard that happens to be open.

Only reminders and offers can be switched off, under **My account → Messages**.
Confirmations and sign-in codes always send: somebody who turned off "your
booking is confirmed" would be left with no record of their own booking. An
opt-out — replying STOP on WhatsApp — is different and outranks everything,
and is keyed by number rather than by account so it survives signing up again.

```
docker compose logs api --tail 40 | grep -A 2 "SMS →"
```

WhatsApp template copy for Meta approval lives in
[docs/whatsapp-templates.md](docs/whatsapp-templates.md).

### Search

The venue directory is full-text searched over a per-venue `tsvector` that
combines the venue's identity with the treatments it offers — so "fade rabat"
finds the Rabat barber who does fades. Every write that changes either funnels
through `Blastek.Discovery.reindex_venue/1`; `reindex_all/0` is the repair.

```
docker compose exec api mix run -e "IO.puts(Blastek.Discovery.reindex_all())"
```

## Project layout

| Piece | Where |
|---|---|
| Phoenix API (Elixir) | [api/](api/) — schemas in [api/lib/blastek/salon/](api/lib/blastek/salon/), business logic in [api/lib/blastek/salon.ex](api/lib/blastek/salon.ex) |
| Tenancy | [api/lib/blastek/venues.ex](api/lib/blastek/venues.ex) (venues + memberships), [api/lib/blastek/scope.ex](api/lib/blastek/scope.ex) (query scoping) |
| Authorization | [api/lib/blastek_web/auth_context.ex](api/lib/blastek_web/auth_context.ex) — `RequireMember` / `RequireAdmin` middleware |
| GraphQL schema | [api/lib/blastek_web/schema.ex](api/lib/blastek_web/schema.ex) |
| Migrations + seeds | [api/priv/repo/](api/priv/repo/) |
| Auth & identity | [api/lib/blastek/accounts.ex](api/lib/blastek/accounts.ex) — sessions, OTP and phone normalization in [api/lib/blastek/accounts/](api/lib/blastek/accounts/) |
| Discovery (search + geo) | [api/lib/blastek/discovery.ex](api/lib/blastek/discovery.ex), [api/lib/blastek/geocode.ex](api/lib/blastek/geocode.ex) |
| Schedules, closures, settings | [api/lib/blastek/venues/schedule.ex](api/lib/blastek/venues/schedule.ex), [api/lib/blastek/venues/settings.ex](api/lib/blastek/venues/settings.ex) |
| Notifications | [api/lib/blastek/notifications.ex](api/lib/blastek/notifications.ex) — copy in [templates.ex](api/lib/blastek/notifications/templates.ex), providers in [providers/](api/lib/blastek/notifications/providers/), reminders in [reminders.ex](api/lib/blastek/notifications/reminders.ex) |
| Background jobs | Oban, on Postgres — queues configured in [api/config/config.exs](api/config/config.exs) |
| Venue onboarding | [api/lib/blastek/venues/onboarding.ex](api/lib/blastek/venues/onboarding.ex), [web/src/market/OnboardVenue.tsx](web/src/market/OnboardVenue.tsx) |
| Media (photos) | [api/lib/blastek/media.ex](api/lib/blastek/media.ex), [api/lib/blastek/storage.ex](api/lib/blastek/storage.ex) |
| React frontend | [web/src/](web/src/) — admin in [web/src/admin/](web/src/admin/), marketplace in [web/src/market/](web/src/market/) |
| Design system CSS | [web/src/styles.css](web/src/styles.css) (Blastek tokens: burgundy/ivory/gold, Sora/Inter/JetBrains Mono) |
| Containers | [docker-compose.yml](docker-compose.yml) |
| Research & plan | [PLAN.md](PLAN.md) |
| PRD & roadmap | [docs/PRD.md](docs/PRD.md) — phases 0–3, architecture bottlenecks, [backlog](docs/BACKLOG.md) |

## Multi-tenancy

Every salon-domain table carries `venue_id`, and every query filters on it
through [`Blastek.Scope`](api/lib/blastek/scope.ex) — a single, greppable call
site instead of a `where` clause copy-pasted into each query. Passing a `nil`
venue raises rather than returning every tenant's rows.

Dashboard access comes from **memberships**, not from a global user role. A
`venue_members` row links a user to a venue with one of four roles — `owner >
manager > receptionist > staff` — and each GraphQL field declares the minimum
role it needs (`middleware(RequireMember, "manager")`). The venue a request
acts on is resolved from the caller's own memberships (via the `X-Venue-Slug`
header when they belong to several), never from an argument, so a client
cannot reach a venue by passing its id.

Two invariants are enforced by the database rather than by application checks:

- **No double-booking.** `appointments` has an exclusion constraint over
  (staff, date, time range) for non-cancelled rows. The availability check
  alone is racy — between checking and inserting, another request can take the
  slot — so `Salon.book/2` also takes a per-(venue, staff, day) advisory lock
  and re-checks under it.
- **Unique booking references.** Refs are random and uniquely indexed; the
  previous timestamp-derived ones collided within a millisecond.

Customers have one account and a **separate client record per venue**, because
their notes, allergies and history belong to the salon they visit.

## Platform conventions

**Money is integer centimes, everywhere.** Fields carry their unit in the name
(`priceCents`, `totalCents`, `revenueCents`) and the API never sends a float —
0.10 has no exact float representation, so sums drift, which is tolerable on a
demo dashboard and illegal on an invoice. The UI converts at the edges only:
`fmtMAD(cents)` to display, `madToCents(mad)` to submit. CI fails the build if
the old float accessors reappear.

**Errors are structured.** Every GraphQL error carries a `code`
(`validation`, `not_found`, `forbidden`, `conflict`, `rate_limited`,
`unauthenticated`) and validation errors also carry the `field` they belong to,
so forms attach each message to the input that caused it instead of printing one
concatenated string.

**Lists are paginated.** `clients` and `sales` return `{ items, totalCount }`
with a server-clamped page size (50 default, 200 max). The calendar is bounded
by a 92-day range cap instead, since a date range is its natural limit.

**Requests are rate limited.** 300/minute per IP for the API as a whole, plus a
much stricter budget on credential checks (8 per identity per 15 min, 40 per IP
per hour) counted *before* the password is verified.

**Subscriptions** are available over `/socket` — `appointmentChanged` pushes a
venue's calendar changes to its own team, scoped by topic so no tenant can
listen to another.

## Try this flow

1. Open the marketplace (`/`) → **Book now** → the venue directory lists both venues.
2. Open **Le Salon Anfa**, pick **Balayage**, choose **Any professional** and a
   time from real availability, then sign in (or sign up) to confirm.
3. Sign into the dashboard (`/dashboard`) as `owner@salonanfa.ma` — the booking
   is there on the calendar (gold "online" tag).
4. Click it → **Check out** → add a tip → **Complete sale**.
5. Check **Sales** and **Reports** — the numbers update from live Postgres aggregations.
6. Now sign in as `owner@barbercorner.ma`: a different calendar, different
   clients, different revenue. Neither dashboard can see the other's data.
7. Back in the marketplace, open **My appointments** (the avatar in the topbar)
   to see bookings from every venue, each labelled with where it was made.
