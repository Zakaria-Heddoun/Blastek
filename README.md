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
# 1. API + database (first boot compiles Elixir deps, ~2-3 min)
docker compose up -d

# 2. Frontend
cd web
npm install
npm run dev
```

Then open:

- **Marketplace** → http://localhost:5173/ — landing, venue directory (`/venues`),
  venue page (`/v/:slug`) and booking flow (this is the root app, same as
  fresha.com being the consumer-facing site)
- **Admin dashboard** → http://localhost:5173/dashboard — calendar, clients, catalog, team, sales, reports
  (Fresha's equivalent of partners.fresha.com)
- **GraphQL playground** → http://localhost:4000/api/graphiql — explore the API directly

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

## Project layout

| Piece | Where |
|---|---|
| Phoenix API (Elixir) | [api/](api/) — schemas in [api/lib/blastek/salon/](api/lib/blastek/salon/), business logic in [api/lib/blastek/salon.ex](api/lib/blastek/salon.ex) |
| Tenancy | [api/lib/blastek/venues.ex](api/lib/blastek/venues.ex) (venues + memberships), [api/lib/blastek/scope.ex](api/lib/blastek/scope.ex) (query scoping) |
| Authorization | [api/lib/blastek_web/auth_context.ex](api/lib/blastek_web/auth_context.ex) — `RequireMember` / `RequireAdmin` middleware |
| GraphQL schema | [api/lib/blastek_web/schema.ex](api/lib/blastek_web/schema.ex) |
| Migrations + seeds | [api/priv/repo/](api/priv/repo/) |
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
