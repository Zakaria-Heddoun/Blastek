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

**Post-implementation principal review (2026-07-30)** — full suite still green
(278 tests, up from 261) after the following. Two were security bugs shipped in
the first pass:

| Finding | Severity | Fix |
|---|---|---|
| **Refresh reuse detection did not exist.** Rotation overwrites `refresh_hash`, so a token captured before a rotation matched *no row* and returned `:invalid` — indistinguishable from a random string. The module documented a theft defence it did not have; rotation alone only meant a thief had to be quick | **High** | Sessions keep `previous_refresh_hash` for exactly one generation (new migration). Replaying it now proves two parties hold one session and ends it for both. Verified live: the second use of a rotated token returns `session_reused` |
| **Password reset links were replayable for their full hour.** `Phoenix.Token` is stateless and nothing marked one spent, so anyone who intercepted the email could reuse it *after* the owner had already reset | **High** | The token now carries a fingerprint of the password hash it was issued against. Using it changes that hash, so the link dies the moment it works — and an older link dies when a newer one is used |
| Request and verify shared one rate-limit bucket. A sign-in costs one request plus up to three attempts, so **two honest sign-ins inside the window locked the user out** | Medium | Separate budgets per action (`RateLimitOtp, :request` / `:verify`), with limits that match what each one actually costs |
| `Sessions.verify/1` wrote `last_used_at` on **every authenticated request** — a row lock and a WAL record behind every GraphQL call, for a value read as "3 hours ago" | Medium | Written only once the value is more than 5 minutes stale, as a single `update_all` with the staleness test in the WHERE clause |
| An expired code was reported as "not valid", sending users hunting for a typo that was not there. `Otp.message(:expired)` was unreachable | Low | Expiry is judged after the lookup rather than filtered inside it, so `:expired` is distinguishable. It leaks nothing — only someone who received a code can see it |
| `request_phone_verification/3` took a `%User{}` and ignored it, so a number already verified elsewhere was only refused *after* a stranger had been texted a code | Low | The conflict is checked before sending. `confirm_phone/3` still re-checks, since the number can be claimed in between — and there is now a test for exactly that race |
| `otp_request.phone` returned a masked string from a field named like a real one, inviting a client to store or resend it | Low | Renamed to `maskedPhone` |
| A rejected session cleared only the access token in the browser, stranding the refresh token in `localStorage` where nothing would reach it | Low | Both cleared together |
| Dead code: `Notifications.masked/1` (no callers), `Otp.pending?/2` (documented as used by the reset flow; it was not) | — | Removed |

**Test gap closed:** the `AuthContext` plug had no HTTP-level test at all —
every other auth test hands Absinthe a context map it built itself, so none of
them exercised the plug that *produces* it. `auth_context_test.exs` now drives
real requests: a live token authenticates, a revoked one stops working on the
very next request, an expired one is refused, a refresh token is not accepted
as a bearer token, a forged `x-venue-slug` cannot reach another venue, and
`last_used_at` is not rewritten per request.

### E4 · Team & permissions — F0.3

**Status: ✅ COMPLETE and verified** (345 tests). E1 had already built the
membership model, roles and last-owner protection, so the new work was
invitations, the audit trail, staff scoping and the permission matrix.

| ID | Task | Est | Labels | Status |
|---|---|---|---|---|
| E4-T1 | Migration + context: `venue_invitations`; invite/accept/remove/change-role | M | api | ✅ |
| E4-T2 | `RequireMember` per-field minimum roles across schema; role integration-test matrix | M | api,test | ✅ |
| E4-T3 | `staff` role scoping: own-calendar-only queries | S | api | ✅ |
| E4-T4 | Web: Team page members tab (invite modal, roles); role-aware nav in AdminLayout | M | web | ✅ |
| E4-T5 | Invitation accept flow (deep link → OTP → membership) | S | web | ✅ |
| E4-T6 | Last-owner protection + audit of membership changes | XS | api | ✅ |

**Acceptance criteria** (F0.3), all met: invite by phone or email creates a
pending invitation, and accepting links or creates the account through the OTP
flow · role changes take effect on the session's next request, because
`AuthContext` resolves memberships per request rather than caching them ·
`staff` see only their own calendar column, and the API refuses a colleague's
client with the same "Not found." a missing id gets · removing a member revokes
access and preserves the `staff` row and its history · **every dashboard
GraphQL op is integration-tested against all four roles**.

**Verification performed**

```
docker compose exec api sh -c "MIX_ENV=test mix test"   # 345 tests, 0 failures
docker compose exec api mix compile --warnings-as-errors && mix format --check-formatted
docker compose exec api sh -c "MIX_ENV=test mix ecto.rollback --all && mix ecto.migrate"
cd web && npx tsc --noEmit && npm run build              # + prerender, + money guard
```

Driven in a real browser: an owner opens Team → Access, sees the sole owner's
controls disabled, invites a receptionist by phone, gets a shareable link, and
watches the pending row appear. A clean browser session opens that link, is
shown the venue and role *before* being asked to sign in, signs in by code,
is asked its name, joins, and lands in the dashboard — where the nav offers
Calendar and Clients and no revenue.

**Notes from implementation**

* **Roster and Access are separate tabs, deliberately.** A `staff` row is a
  calendar column that takes appointments; a membership is a login. Most people
  are both, some are only one — a silent partner who reads the books, a junior
  who is booked but has no account — and merging them is what makes "remove
  their access" delete a year of history.
* An invitation is a bearer credential and follows the session rules: 32 random
  bytes, only the SHA-256 stored, 7-day expiry, single use. The **token grants,
  not the contact** — invitees routinely sign up with a different number than
  the owner had for them, and an invitation the holder of the link cannot
  redeem is just a support ticket.
* The invite modal shows the link as well as sending it. It is unrecoverable
  afterwards, and an owner standing next to the new hire should not have to wait
  for an SMS.
* Accepting **upgrades an existing membership but never downgrades one**. An
  invitation is an offer; taking one up should not cost someone access they
  already had.
* `audit_log` is the general shape with a deliberately narrow set of writers —
  the same seam-now, machinery-later approach as E3's `Notifications`. E11 adds
  actions and the admin UI rather than migrating a `membership_events` table.
  Recording never fails the operation being recorded: losing an audit row is
  bad, failing a member removal because the log was unavailable is worse.
* Staff get F0.3's "limited CRM": the client list narrowed to people they have
  actually served, via `EXISTS` rather than a join so a client with twenty
  appointments is still one row. A staff membership with **no** calendar column
  is scoped to `staff_id: 0` rather than `nil` — the latter would read as "no
  restriction" and hand the whole client list to the least privileged role.

**Defects found during verification** (each would have shipped):

| Defect | Fix |
|---|---|
| **The permission matrix was passing vacuously.** Absinthe hides field middleware behind a lazy shim, so reading `field.middleware` found nothing, `gated` was empty, and the completeness check asserted precisely zero. It was caught only because the check asserts a *lower bound* on what introspection finds | Expand and `unshim` the middleware. With it working, the check immediately found **28 gated fields with no matrix row** — including every photo and venue mutation E8 added, which had never been role-reviewed. All 37 are now covered |
| A malformed row in the matrix never reached the middleware, so it read as "allowed" for every role — a typo would have silently asserted nothing | GraphQL *validation* errors now fail the test loudly, separately from argument errors |
| `createService` with a non-existent `categoryId` raised `Ecto.ConstraintError` out of the resolver — an HTTP 500 for an ordinary bad argument. The same class of defect the E1 review fixed for cross-tenant reads, in the opposite direction | `foreign_key_constraint(:category_id)` on the changeset |
| **The invitee was never asked their name.** `JoinVenue` switched on `user`, so the instant `verifyOtp` set one it unmounted the phone flow mid-sequence — before the name step could render. New team members joined as a bare phone number | Gate on `profileComplete`, and let an already-signed-in-but-unnamed invitee start at the name step |

**Deferred, unchanged:** `phoenix` 1.7.23 (HIGH) and `react-router` 6.x
(2 × MODERATE) still need framework major bumps under CH-1.

**Post-implementation principal review (2026-07-30)** — full suite still green
(349 tests, up from 345). Two were real bugs in the shipped epic:

| Finding | Severity | Fix |
|---|---|---|
| **One invitation link could produce two memberships.** `accept/2` read the invitation, created the membership, then consumed the link — and discarded the `update_all` row count. Two people clicking at once both passed the read, and both were let in. The module documented single use, which was true only in sequence | **High** | Claim the invitation *first*, with a conditional `UPDATE … WHERE accepted_at IS NULL`, and roll back when it matches no rows. The UPDATE's row lock is what serializes the two callers |
| **`staffId` was taken from the client unchecked**, so an owner could attach a membership in their venue to a `staff` row in someone else's — a cross-tenant foreign key, against the discipline the whole tenancy model rests on | **Medium** | Validated in `Venues.add_member/4` (the funnel, so every caller is covered) and rejected early in `invite/3` with a message |
| `auditLog` resolved `actor` per row — a fifty-entry log was fifty user lookups of the same handful of people | Low | Batched through `Accounts.get_users/1` |
| The client scope used `staff_id: 0` as "matches nothing" — a magic id in the one place where getting it wrong hands the venue's whole client list to its least privileged role | Low | An explicit `:none`, handled by its own `served_by/2` clause |
| The accept URL was built in two places, so the link returned by the API and the link in the message could drift apart | Low | One `Invitations.accept_url/1` |
| A failed SMS still reported "Invitation sent", leaving an owner waiting for a message that was never going out | Low | `delivered` is returned and the UI says "share this link instead" when it is false |
| Dead code: `attrs_to_opts/1` (an option no caller passes), an unreachable `false -> :ok` clause | — | Removed |

**Two tests in this epic were passing vacuously**, both caught by asserting
something about the test itself rather than only about the code:

* The **permission matrix completeness check** found zero gated fields, because
  Absinthe hides field middleware behind a lazy shim. A lower-bound assertion on
  what introspection returns exposed it; with `expand` + `unshim` it immediately
  found 28 unreviewed fields (see the defect table above).
* The **first concurrency test** shared the sandbox connection, so its two tasks
  serialized and it passed against the buggy code. It now lives in
  `invitation_race_test.exs`, runs unboxed on real connections, and was verified
  by reintroducing the bug — against which it reports "expected exactly one
  winner, got 2". That test commits rows, so it sweeps its own prefix on the way
  **in** as well as out; an interrupted run would otherwise leave a stray venue
  in everyone else's search results.

### E5 · Venue settings & onboarding — F0.4, F0.5

**Status: ✅ DONE — 417 tests green, reviewed and browser-verified end to end.**

| ID | Task | Est | Labels | Status |
|---|---|---|---|---|
| E5-T1 | `updateVenue` + typed settings JSONB validation | S | api | ✅ |
| E5-T2 | Closures: table, CRUD, availability subtraction, past-midnight ranges | M | api | ✅ |
| E5-T3 | Hour templates (default/ramadan) + switch + staff-hours variants | M | api | ✅ |
| E5-T4 | Conflict detection: closures/template changes vs existing bookings | S | api | ✅ |
| E5-T7 | Onboarding: `service_templates` seed catalogs (5 categories, i18n names) | S | api | ✅ |
| E5-T8 | Onboarding wizard API (step state, submit, approve/reject) | M | api | ✅ |
| E5-T10 | Duplicate-venue detection heuristic for admin queue | XS | api | ✅ |
| — | GraphQL surface for all of the above | — | api | ✅ |
| E5-T5 | Web: SettingsPage (identity, hours grid, closures, templates) | L | web | ✅ |
| E5-T6 | Calendar: closure/holiday shading | S | web | ✅ |
| E5-T9 | Web: OnboardVenue wizard `/for-business` (mobile-first, resumable) | L | web | ✅ |

**Notes from the domain layer**

* **Two different kinds of "closed."** A *template* is the weekly grid a venue
  keeps and switches between, because Ramadan moves the working day rather than
  cancelling it. A *closure* is an exception to whatever the grid says. Both are
  subtracted by the slot engine; one query per date serves every candidate.
* **Template resolution order is the whole feature.** Staff rows for the active
  template win; rows with no template count only under the *default* template;
  otherwise the venue grid applies. An earlier draft let the default staff row
  win under any template — which made a one-tap seasonal switch silently do
  nothing, since the venue's winter slots kept being offered.
* Minutes may exceed 1440 (00:30 is 1470), so a Ramadan evening shift is just
  arithmetic. A whole-day closure covers the past-midnight tail too, or a
  21:00–00:30 template would leak slots on a day the venue is shut.
* `venues.settings` stays schemaless but its **writes are typed** through
  `Venues.Settings`: unknown keys are dropped rather than stored, and each known
  key is coerced and range-checked. Unknown keys are dropped rather than
  rejected so an older client cannot fail a whole save.
* Service templates are seeded **by migration**, not `seeds.exs`: an owner
  onboarding in production needs the same catalog a developer sees, and
  `seeds.exs` only builds demo venues. Names are FR/AR/EN from the start, since
  the wizard's premise is a salon owner listing their menu in Arabic on a phone.
* Duplicate detection flags rather than blocks — two salons in one city really
  can share a name, and a franchise really does reuse a phone number.

**Schema conflict found while building**: `staff_hours` carried
`unique (staff_id, weekday)` from E1, which made per-template variants
impossible — the second row for a weekday was rejected outright. Replaced by a
pair of partial indexes ("one row per weekday *per template*"), since Postgres
treats NULLs as distinct and a single index cannot express both halves.

**Notes from the API and web layers**

* **`venueWeek` exists because a venue can have no template at all.** Every
  venue from E1 keeps hours as `staff_hours` rows with no `template_id`. The
  dashboard has to be able to show those hours — a panel headed "Opening
  hours" that renders nothing reads as *your hours are not set*. The same
  query backs the marketplace, so both surfaces answer the question the same
  way. Opening the editor pre-fills from it rather than from a blank
  09:00–18:00 week, so setting up a template cannot silently overwrite hours
  the owner was never shown.
* **The conflict pre-check is a separate button, not a save-time warning.**
  `closureConflicts` runs against a *proposed* closure and returns the
  appointments with client names and phone numbers; creating the closure is a
  second, deliberate click. F0.4 requires the owner be shown who to telephone,
  and a dialog that appears only after the destructive action has begun is the
  wrong shape for that.
* **The wizard's terminal state is derived, not navigational.** `submitted` is
  read back from the venue's onboarding blob, so returning to `/for-business`
  a week later still shows "Sent for review" instead of inviting a second
  submission.

**Defects found while verifying**

| Where | Defect | Found by |
|---|---|---|
| `Salon.venue_view/1` | The public venue page aggregated `staff_hours` with **no `template_id` filter**, so it ignored the active template *and* min/max-ed Ramadan and default rows together. Switching to Ramadan hours left the marketplace advertising the winter times — customers would arrive at a locked door. | Reading the code while fixing the blank dashboard panel; now covered by a test that fails against the old aggregation |
| `ScheduleSettings` | "Opening hours" was empty for any venue predating templates, and the editor opened on a blank 09:00–18:00 week. | Browser drive |
| `OnboardVenue` | "Submit for review" and "Not yet" both navigated to `/dashboard/calendar`, so submitting produced no acknowledgement of any kind and the two buttons were indistinguishable in outcome. | Browser drive |
| `auth.css` | The wizard inherited the login screen's vertical centring, pushing the first input 296px down a 930px phone viewport — on a flow whose premise is "ten minutes, from your phone". Now 88px. | Browser drive |
| `admin.css` | `.tpl-badge` and E8's `.photo-badge` hardcoded `color: #14110f` against `var(--accent)`. That pairing is from the marketplace theme, where the accent is gold; the dashboard's accent is ink, so both badges rendered near-black on near-black. Now `var(--accent-ink)`. | Screenshot |

The `venue_view` bug is the one worth remembering: the E5 domain work added a
`template_id` dimension to `staff_hours`, and every *read* had to learn about
it. The booking engine did. The page that tells customers when to turn up did
not, and no domain test noticed because both layers were asked separately.

**Principal-engineer review before E6**

The review found one defect that outweighed everything else, plus a cluster of
smaller ones. All are fixed.

*Five settings were write-only.* `slot_step_min`, `booking_lead_min`,
`booking_horizon_days`, `cancellation_window_hours` and `instant_confirmation`
were validated, stored, exposed through GraphQL and rendered in the dashboard —
and **read by nothing**. The slot engine used a hardcoded `@slot_step 15`. Only
`women_only`, `amenities` and `locale` were ever consumed. This is worse than
not shipping the panel: the owner sets a two-hour notice period, sees it save,
and takes bookings for twenty minutes' time. Every one is now enforced, and
`test/blastek/booking_settings_test.exs` asserts each *changes booking
behaviour* rather than that it round-trips — verified by reverting all five
mechanisms and watching exactly those tests fail. `Booking rules` is now its own
settings section, since which grid customers see is a different decision from
fixing a typo in the tagline.

| Where | Defect |
|---|---|
| `Onboarding.possible_duplicates/1` | Folded the venue being checked **in Elixir** and the rows it was compared against **in SQL**. `String.downcase("Café Beauté")` never equals `unaccent`ed "cafe beaute", so every accented name — half of them, in Morocco — escaped detection, and phone matching only worked when the stored number happened to be E.164 already. The existing test passed because it picked that direction. Both sides now fold through the same Postgres expression, and phones match on the trailing nine digits. |
| `Onboarding.reject/3` | Left `submitted_at` in place, and the queue is "pending **and** submitted" — so a rejected venue went straight back to the top of the admin's list, and the owner's wizard went on saying "sent for review" instead of showing them what to fix. The ball was in both courts at once. Rejection now clears the marker and the owner meets the wizard again with the reason. |
| `venue_summary` | `rejectedReason`, `onboarding` and `settingsJson` were ungated on a type that marketplace search hands to anybody. Nothing leaked, because nothing returns a pending venue to a stranger — a property of today's queries, not of the type. Now gated on membership or admin. |
| `Salon.availability/4` | Re-queried the active template, its hour rows and the day's closures **once per candidate staff member** — a salon with five stylists ran twenty queries to answer one request, on the marketplace's hottest path. The comment claimed closures were fetched once per date; they were not. Hoisted into one per-request context. |
| `ScheduleSettings` | A **failed** conflict pre-check rendered as "nothing is booked in that period" — the one outcome the feature exists to prevent. It also left a stale answer on screen while the owner edited the dates underneath it. Both now clear, and a failure says so. |
| `Schedule.upsert_template/3` | Accepted a day whose end preceded its start, which `Closure` rejects outright; the slot engine then offered nothing with no explanation. Stored as closed. |
| `Schedule.activate_template/2` | Two concurrent switches both cleared the active flag and both set it; the partial unique index rejected the loser as a 500. Now a rollback with a message. |
| `Schedule.create_closure/2` | Reached for `String.to_existing_atom`, turning an unrecognised key from any future caller into a raise rather than the "ignored" `cast/3` already gives. |
| `Venues.Settings` | `amenities` was an unbounded list of unbounded strings written into a schemaless JSONB column. Capped at 40 × 60 characters. |
| `admin.css` | A checkbox inside `.identity-form` inherited the 40px bordered box meant for text inputs, rendering as a large blue square above its own label. |
| `CalendarPage` | A closure lying entirely outside the visible hours produced a band with a negative height — invalid CSS that happens to look like nothing. Clipped in the helper. |

Two things were noted and deliberately **not** changed. `possible_duplicates/1`
scans the venues table without a functional index; the admin queue is low-volume
and a migration is not worth it yet. `Onboarding.abandoned/1` has no caller —
it is a seam for a future archiving job, not dead code left behind.

<!-- Original task table retained for reference:
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
-->

### E6 · Notifications & WhatsApp — F0.10

**Status: ✅ DONE — 473 tests green, browser-verified end to end.**

| ID | Task | Est | Labels | Status |
|---|---|---|---|---|
| E6-T1 | Add Oban; queues, telemetry, dashboard config | S | api,infra | ✅ |
| E6-T2 | `Notifications` context: templates, locale rendering, send log table, prefs | M | api | ✅ |
| E6-T3 | Provider behaviour + `DevLogger`; config-driven selection | S | api | ✅ |
| E6-T4 | WhatsApp Cloud API provider: send, template mgmt, webhook (delivery + inbound STOP) | L | api,infra | ✅ |
| E6-T5 | SMS provider + WhatsApp→SMS fallback chain | M | api | ✅ |
| E6-T6 | Booking/cancel/reschedule hooks → confirmation jobs (customer + salon) | S | api | ✅ |
| E6-T7 | Reminder scheduling (T-24h/T-3h), cancellation-aware, venue-configurable offsets | M | api | ✅ |
| E6-T8 | Signed one-tap action links (confirm/cancel) HTTP endpoints | S | api | ✅ |
| E6-T9 | Meta template approval pack (FR/AR copy for all v1 templates) | S | design | ✅ |
| E6-T10 | Web: notification prefs UI; dashboard live toast on online booking (uses E2-T4) | S | web | ✅ |

**Notes**

* **The chain is a list, not a strategy object.** `config :blastek,
  :notifications_provider` holds providers tried in order until one succeeds.
  A Moroccan number with no WhatsApp account is the ordinary case rather than
  an exception, so "WhatsApp, then SMS" is the mechanism itself instead of a
  branch at every call site. A provider that *raises* falls through too — an
  SMS that still arrives is worth more than a clean stack trace about Meta.
* **The log row is written before the provider is called.** A message that
  vanished because the node died mid-send is exactly the one worth being able
  to see, and a row created only on success cannot record a failure to create
  it.
* **Cancellation is enforced at firing time, not by deleting jobs.** Cancelling
  an appointment does delete its pending reminders, but that is an
  optimisation: a job already fetched by a worker cannot be deleted. The
  guarantee is `Reminders.still_due/2`, which re-reads the appointment as the
  job fires. Trusting the delete is how somebody gets reminded about an
  appointment they cancelled yesterday.
* **Only reminders can be switched off.** F0.10 is explicit that transactional
  messages always send, and the reason is worth restating: somebody who turned
  off "your booking is confirmed" is left with no record of their own booking.
  An **opt-out** is different and outranks even that — it is keyed by address
  rather than by account, so replying STOP survives signing up again.
* **One-tap links are signed, not stored.** `Phoenix.Token` carries the
  appointment and the action; there is no table to leak and nothing to clean
  up, and rotating the endpoint secret invalidates every outstanding link at
  once. The trade is that individual links cannot be revoked, which is
  acceptable because the actions are idempotent and move no money.
* **The webhook needs the unparsed body.** Meta signs the exact bytes, and
  decoding JSON then re-encoding it does not reproduce them, so
  `BlastekWeb.RawBodyReader` stashes the raw body for that one path.
* **Arabic interpolation is direction-isolated.** Every value dropped into an
  RTL template is wrapped in `U+2066…U+2069`; without it "Le Salon Anfa"
  renders with its words reordered and `14:30` can come out as `30:14`.

**Defects found while verifying**

| Where | Defect | Found by |
|---|---|---|
| `Reminders.still_due/2` | Gated **every** appointment message on the appointment still being live, not just reminders — so the `cancelled_by_customer` and `cancelled_by_salon` notices were skipped precisely because the appointment had been cancelled. The Oban job completed successfully having sent nothing. The one message the other party has no other way of learning. | Browser drive: the job was `completed` but the send log had no row |
| `Provider.declared_channel/1` | Used bare `function_exported?/3`, which answers false for a module that has not been loaded yet — so the first message after a boot saw no declared channel on any provider and would have offered an email address to the SMS gateway. Disappears the moment you look for it, since inspecting the module loads it. | A `handles?` unit test |
| `Blastek.Accounts.User` | The migration added `notification_prefs` but the schema never declared the field, so every preference read raised. | Preference tests |
| `otp_test.exs`, `invitations_test.exs` | Both swapped the provider through **`Application.put_env`** — global — while `async: true`. Any concurrent test sending a notification got the failing provider, which surfaced as "an unrelated OTP test intermittently delivers no code". The override is now per-process, like the geocoder stub and the collector. | Chasing a flake that predated E6 but only bit once E6 made the suite busier |
| `role_matrix_test.exs` | Covered `RequireMember` fields but not `RequireAdmin` ones — the *more* dangerous of the two to add unnoticed, since they cross venues. Extended with a declared inventory, so adding a cross-venue field without gating it now fails. | Adding `notificationLog` and noticing nothing complained |

**Not done, deliberately**: no template is submitted to Meta yet, so every
WhatsApp send is attempted as free-form text, fails outside a session window
and falls through to SMS. `docs/whatsapp-templates.md` is the pack to submit;
until then this is the intended interim behaviour, not an outage.

#### Epic 6 review — principal-engineer pass

Everything below was found reading E6 as a pull request, then proved against
the running stack before and after the fix. 492 tests green.

| Where | Defect | Why it mattered |
|---|---|---|
| `Notifications` (whole module) | **No canonical form for an address.** `opted_out?/1` matched the `to` column exactly, so `+212612345678`, `212612345678` and `06 12 34 56 78` were three different people. Meta reports an inbound STOP in the second spelling, an account holds the first, a receptionist types the third — the webhook was papering over it by inserting two rows and still missed the third. | A withdrawal of consent that does not withdraw consent. Everything now goes through `Notifications.canonical/1`, and `opted_out?` matched all four spellings in the live system afterwards. |
| `notifications.body` / `payload` | **One-time codes and reset links were persisted in plaintext** and exposed over the admin-only `notificationLog` query. Verified: the row for a login read `Votre code Blastek : 482913`, and `payload` held `%{"code" => "482913"}`. | For a phone-first account the code *is* the credential. Anyone who could read the table — a platform admin, a backup, a read replica — could sign in as any user. Credential-bearing templates now log a marker; the provider still gets the real text. |
| `Blastek.Clock` (new) | **Every wall-clock comparison used the server's clock**, which is UTC in a container, against appointment times that are Casablanca local. Measured: a 60-minute skew. | Silent in all three directions it leaked into — a T-3h reminder scheduled for a moment already past, a two-hour cancellation window that let a customer cancel with one hour's notice, and a booking horizon counted from the wrong day for the hour after local midnight. None of them raise; all of them read as "the software is a bit off". |
| `Salon.Client` | Client phones were **stored exactly as typed**. A receptionist entering `06 12 34 56 78` produced `0612345678` for WhatsApp (no country code, rejected) and `+0612345678` for SMS (not E.164, rejected). | Silently undeliverable messages to every walk-in added through the dashboard. Canonicalized in the changeset now, so the number a STOP is keyed against is the number stored. |
| `Worker.perform/1` | A `rescue ArgumentError` wrapped the **whole** function body while only one expression could raise it. | Anything the rendering or the send raised would be discarded as `{:cancel, "unknown template"}` — a message that deserved a retry, thrown away with a false reason in the job for whoever came looking. Scoped to the one expression. |
| `Bookings.booked/2` | **20 queries inside `Salon.book/2`'s transaction**, which holds a `pg_advisory_xact_lock` on the staff member's day. `Reminders.assigns/2` was built twice and `get_venue` refetched six times. | The lock exists to serialize slot contention, not notification bookkeeping. Now 13 queries; the salon's copy is derived from the customer's rather than rebuilt. |
| `RawBodyReader.stash/2` | Kept only the **last** chunk of a chunked body instead of appending. | A webhook larger than the read length would fail signature verification — i.e. exactly the batched delivery receipts a busy deployment gets most of. |
| `runtime.exs` | `Enum.filter(&is_atom/1)` on the provider chain — `nil` and `false` are both atoms, so the filter kept everything and only the following `reject(&is_nil/1)` did any work. | Harmless today (`System.get_env` never returns `false`) but it reads as a guard and is not one. |
| `notifications.attempts` | Always `1`. Each retry writes its own row, and each row counted from zero. | The column promised a retry count and never delivered one; it now carries Oban's own attempt number, so three rows read as one message that took three goes. |
| `Reminders.customer_locale/1` | Comment claimed "the customer's own locale if their account states one"; the body only ever returned the venue's. | Dead function whose docstring described a feature that does not exist. Removed. |
| `router.ex` | Pipeline named `:upload` also served the one-tap action links. | Renamed `:signed_token` — both users authenticate with a signed token instead of a session, which is the actual shared property. |
| `Bookings` moduledoc | Claimed absolutely that nothing here can fail a booking, while running inside the booking's own transaction. | A rescue cannot un-abort a transaction Postgres has already marked failed. The claim is now stated with its caveat rather than overstated. |

Also simplified: `list_log`/`count_log` shared their filter chain (a filter added
to one and forgotten in the other would page through a total the rows do not add
up to); `sync/4` called `suppression/3` twice; `Venues.owner_contact/1` and
`owner_user_id/1` became one query; `Provider.deliver/1`'s docstring named the
wrong arity of return tuple; a no-op `Map.drop(args, [:__struct__])` in the
preferences resolver.

**Deployment note**: `Notifications.canonical/1` runs on the way in *and* on the
way out, so rows written before this change are matched correctly at send time
and no backfill is needed for delivery or suppression to be right. If the
`notification_optouts` table ever holds rows written by the old code in a real
deployment, normalizing that column is worth doing for tidiness — there are none
outside development today.

### E7 · i18n — F0.11

**Status: ✅ COMPLETE and verified** (514 API tests; the interface driven in all
three languages, RTL included).

| ID | Task | Est | Labels | Status |
|---|---|---|---|---|
| E7-T1 | i18next setup (fr/ar/en), language switcher, persistence, locale plug API-side | S | web,api | ✅ |
| E7-T2 | String extraction: market pages (Home, Venue, Flow, Auth, Account) | M | web | ✅ |
| E7-T3 | String extraction: admin pages (all 7) + platform | M | web | ✅ |
| E7-T4 | RTL audit + fixes for both CSS systems (logical properties pass) | L | web,design | ✅ |
| E7-T5 | FR + AR translation files (professional review, Darija tone for consumer) | M | design | ✅ |
| E7-T6 | DB content translations JSONB (services/categories/venues) + locale-resolving fields | M | api | ✅ |
| E7-T7 | Catalog editor per-locale inputs (FR/AR tabs) | S | web | ✅ |
| E7-T8 | Hardcoded-string CI lint gate | XS | infra | ✅ |

**Notes**

* **French is both the default and the fallback.** A key missing from `ar`
  renders the French string, never English and never the raw key. The market is
  Morocco; English exists for tourists and for us, and is a leaf that falls back
  through French rather than the other way round.
* **`dir="rtl"` goes on `<html>`, once.** That is what makes the browser's own
  bidi algorithm, form controls, scrollbars and `text-align: start` all agree.
  Every attempt to do direction per-component ends with a dropdown opening off
  the left edge of the screen.
* **The CSS is logical, not mirrored.** `inset-inline-start`, `border-inline-end`
  and `text-align: start` replaced every single-sided offset in both design
  systems, so there is one stylesheet rather than an LTR one and an RTL one to
  keep in step. What logical properties cannot express — chevrons pointing along
  the reading direction, Latin brand words needing bidi isolation, the calendar
  grid staying LTR because it is a time axis rather than prose — is a short,
  commented block at the end of `styles.css`.
* **Western digits, deliberately.** `Intl` renders Arabic locales with
  Arabic-Indic numerals by default and Morocco does not use them; the
  `-u-nu-latn` extension keeps Arabic words with Western numbers. Weekday and
  month names come from `Intl` rather than from the bundles — twelve hand-typed
  Arabic month names is twelve chances to be wrong.
* **Owner-written content falls back per field, never to nothing.** A salon with
  a French menu and no Arabic one is fully bookable in Arabic: `ar → fr → base
  column`, and the base column is always the last link. The failure mode of
  getting this wrong is not a missing translation but a blank service name — a
  booking flow with an unlabelled button.
* **French lives in the base columns, not in the JSONB.** The catalog editor
  shows one tab per language and does not know that one of them is stored
  differently; `I18n.expose/2` and `I18n.split/2` are the two halves of keeping
  that an implementation detail. Storing French in both places is how the two
  get to disagree.
* **A user's saved locale beats `Accept-Language`.** Choosing Arabic in the
  switcher is a more deliberate statement than a browser default, and phones
  sold in Morocco very often ship set to French or English whatever their owner
  reads. It is saved on the account, not only in the browser, so a phone and a
  laptop agree — and so E6's WhatsApp reminders arrive in the chosen language.

**Defects found while verifying**

| Where | Defect | Found by |
|---|---|---|
| `I18n.sanitize/2` | `normalize/1` is total and answers `"fr"` for anything unrecognised, so the "is this a real locale?" guard passed for every string — a translations map with a `de` key was stored **as French**, silently overwriting the owner's French text. Split into `parse/1` (honest, returns `:error`) and `normalize/1` (total, for rendering). | The first unit test written for it |
| `check-i18n.mjs` | The gate scanned **line by line**, so it could not see JSX text that Prettier had wrapped onto its own line — which is most of it. It reported success over 74 untranslated strings. Now scans whole files. | Reading the Arabic homepage and seeing English on it |
| `check-i18n.mjs` | Nothing checked that a key the source *asks for* exists. Deleting an unused key left all three bundles in perfect agreement while the page rendered the literal text `venues.useMyLocation` to a customer. | A screenshot |
| `check-i18n.mjs` | Copy in object literals (`{ value: 'rating', label: 'Top rated' }`) and inside JSX expressions (`{searched ? 'Search results' : 'Book an appointment'}`) was invisible to a JSX-text scan. Both are now covered. | The same screenshot |
| `role_matrix_test.exs` | The new `updateCategory` mutation had no row in the matrix — the E6 review's inventory check caught it on the first run. | The suite |

#### Epic 7 review — principal-engineer pass

526 tests green. Every finding was reproduced against the running stack before
being fixed, and every new assertion was mutation-tested.

| Where | Defect | Why it mattered |
|---|---|---|
| Five `aria-label={\`…\`}` sites | **Screen-reader labels still in English** — "opens", "closes", "Role for …", "out of 5", "Step n of m". The gate checks `attr="…"`, `attr='…'` and `attr={'…'}` but not the template-literal form, which is the one that reads as code. | The gate's own docstring says these are the strings that stay English for a year *because nobody sees them go wrong* — and it could not see them either. Now covered, with a lower bar for these attributes specifically: an `aria-label` is copy by construction, so any three letters count. |
| `check-i18n.mjs` | `lib/icons.tsx` was skipped **wholesale** to silence SVG path data, which also hid the one real `aria-label` in it. | A whole-file exemption is a permanent blind spot. Replaced with a rule that recognises path data by shape, so the file is scanned again. |
| `lib/fragments.ts` | `translations` was added to the **shared** service and category fragments, so every customer loading a venue page downloaded every other language's copy — for a page that renders `name` already resolved server-side. | Payload on the most-visited page, for data it never shows. The editor-only field is its own fragment now and only the dashboard asks for it. |
| `lib/format.ts` | `weekdaysShort()` built seven `Date`s and seven `Intl` formatters **on every call**, and it is called inside render loops — three times per row in the schedule editor, so ~147 formatter constructions per render. | `Intl.DateTimeFormat` construction is the classic JS performance footgun. Cached per locale and width; the call sites that loop now hoist it too. |
| `lib/locale.tsx` | Read `localStorage` with a hardcoded `'blastek-locale'` rather than the exported `STORAGE_KEY`. | Two copies of a key that must agree: change one and adopting the account's saved language silently stops working. |
| `I18n.sanitize/2` | No length bound. Base columns are `varchar` and Postgres refuses over-long values; JSONB accepts anything. | A manager could put a megabyte where a service name goes and every venue page would carry it. Bounded at 2 000 characters, truncated rather than rejected. |
| `Venues.Venue` | `translatable_fields/0` was never called — only `Category` and `Service` expose `translations`. | Dead public API that reads like a contract. Removed; the attribute it wrapped is still used by `cast_translations/2`. |
| Tests | The 21 i18n tests were **all pure unit tests** of `I18n`. Nothing covered the header → plug → context → resolver path, which is where it actually breaks: each link can be perfect on its own while the customer still reads French. | Added `localized_content_test.exs` — 12 tests over the wire, including a signed-in reader's saved locale outranking their browser, and French landing in the base column rather than the JSONB (which is what F0.6's search index is built from). |

**Not done, deliberately**: `venues.search_tsv` is still built from the base
columns only, so an Arabic-only service name is readable but not *searchable*.
Postgres has no Arabic stemmer configured here and `unaccent` does nothing for
it, which makes that a real piece of work rather than an oversight — F0.6's
search is unchanged and correct for the French and Latin text it already
indexes. The `bungee/` route is also left in English: it is a standalone
re-creation of somebody else's marketing template, not part of the product.

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

**Status: ✅ COMPLETE and verified** (557 tests; blocking, availability,
the time-off list and a customer reschedule all driven in the browser).

| ID | Task | Est | Labels | Status |
|---|---|---|---|---|
| E9-T1 | `staff_blocks` migration + CRUD + availability subtraction (incl. weekly repeats) | M | api | ✅ |
| E9-T2 | Calendar block rendering + create menu; Team time-off list | M | web | ✅ |
| E9-T3 | Block-vs-appointment conflict prompt flow | S | api,web | ✅ |
| E9-T4 | `rescheduleMyAppointment` (group move, window policy, race-safe, reminder resync) | M | api | ✅ |
| E9-T5 | Extract shared `SlotPicker`; Account reschedule UI; reminder deep-link landing | M | web | ✅ |

**Notes**

* **Three kinds of block, one table.** Availability asks all three the same
  question — "is this person free between these two minutes?" — and a table per
  kind would mean three queries and three chances to forget one. The shape
  differences are expressed by which columns are null, which is why none of
  `end_date`, `start_min`, `end_min` or `weekday` is required.
* **Weekly repeats are materialized on read.** A break every Friday is one row,
  not fifty-two. Storing the expansion would mean deciding how far into the
  future to write rows and then being wrong about it. The calendar expands the
  rule a second time on the client, because it draws days the availability
  engine was never asked about.
* **Blocks follow the clock, not the shift.** F0.7 is explicit that a
  12:00–14:00 break stays at 12:00–14:00 when a Ramadan template moves the
  working day. `outside_hours?/3` exists so the owner is *warned* the break now
  sits outside the working day rather than having it silently relocated.
* **A block over an appointment prompts, never acts.** `staffBlockConflicts`
  returns the list and the form shows it as the owner types. A stylist taking
  Thursday off still has to telephone the three people booked that afternoon,
  and the software's job is to say who.
* **Reschedule moves the booking, not the row**, under the same advisory lock
  as `book/2`, and asks availability to **exclude the rows being moved** —
  without that a booking cannot shift by less than its own length, because it
  collides with itself.
* **A holiday is not a closure.** One shuts a person, the other the salon.
  Subtracted at the same point in `availability/5` and deliberately kept apart:
  merging them would make one stylist's holiday read as the salon being shut,
  and cost every booking the rest of the team could have taken.

**Defects found while verifying**

| Where | Defect | Found by |
|---|---|---|
| `appointments_booking_ref_index` | **Multi-service bookings had never worked.** The index was created UNIQUE in E1, but a booking reference identifies a booking — one *or more* appointments — so the second insert of every multi-service booking violated it. Two things hid it: `insert_booking/3` mapped any `{:error, changeset}` to `Repo.rollback(slot_taken())`, so a schema violation surfaced as "That time was just taken — please pick another slot.", a plausible message that blames another customer for a constraint; and no test had ever booked more than one service. | Writing the first two-service booking, which F0.9's group move required |
| `Blocks.create/2` | Trusted `staff_id` against the foreign key alone, which proves a staff member exists but not that they work at this venue — a manager could write a row pointing across a tenant boundary. | Writing the test for it |
| `AdminLayout` | The E7 language switcher used the three-button strip in a 240px sidebar; the row overflowed and two of the three languages simply left the screen. Silent, because overflow is. | Looking at a calendar screenshot taken for something else |
| `DataCase.setup_sandbox/1` | The search performance gate died three times on the sandbox's own 120-second ownership timeout rather than on a slow query — the `@moduletag timeout:` raised in E8 governs ExUnit, not the sandbox. A loaded machine failed a performance assertion, which is exactly the confusion that gate's docstring says it exists to avoid. | The third flake |

**Not done, deliberately**: F0.7's drag-to-create on the calendar. The
click-to-create menu covers the same intent and drag needs pointer capture,
scroll-during-drag and a touch story of its own — a feature, not a detail of
this one.

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
