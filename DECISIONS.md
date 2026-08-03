# Decisions & Open Questions

This build ran autonomously. Wherever a choice came up, I executed my own
recommendation so the work could finish. This document lists those calls so you can
review them. Each has: **what I chose**, **why**, the **alternative**, and whether it
**needs your decision**.

Legend: ✅ = decided & implemented (change only if you disagree) · ⚠️ = worth a look ·
❓ = genuinely your call before going further.

---

## Architecture

**A1. Reuse the existing backend, don't rebuild it.** ✅
Added a bearer-token REST API (`/api/v1/*`) to the existing Next.js app instead of a
separate backend. One database, one source of truth, web + mobile share it.
*Alternative:* a standalone backend (Dart/Node/Go) — rejected: duplicates the tested
recurrence/stats logic and doubles maintenance.

**A2. New mobile API as a parallel "service layer"; web Server Actions untouched.** ✅
`src/lib/services/*` mirror each action's logic but take an explicit `userId` and throw
`ApiError`. The 1450+ existing web tests keep passing with **zero risk** because I
didn't edit the actions.
*Trade-off:* the CRUD wrapper logic is duplicated between actions and services (the hard
domain logic in `recurrence.ts`/`habitStats.ts`/`goalStats.ts` is **not** duplicated —
both call it). See ⚠️ O1.

**A3. Backend changes live in the existing repo on branch `feat/mobile-api`.** ✅
Not committed (your convention: commit only when you ask). The Flutter app is a **new
sibling repo** `Focus_Flow_Mobile`, matching your `*_Backend`/`*_Mobile` layout.

---

## Backend / API

**B1. Auth = JWT access + refresh tokens (HS256 via `jose`, signed with `NEXTAUTH_SECRET`).** ✅
Access token TTL **30 days**, refresh **90 days**. Independent of the NextAuth cookie
session (the two coexist). Verified end-to-end against live Postgres.
*Why long TTLs:* personal single-user app; avoids frequent re-login. *Alternative:* short
access (15 min) — unnecessary friction here. **Change the TTLs in `src/lib/apiAuth.ts`
if you prefer.**

**B2. Date handling matches the web app exactly.** ✅
All-day due/start dates are sent as bare `yyyy-MM-dd` and stored at the **server's local
midnight** (same as the web Server Actions already do). Reminders are absolute instants
sent as **UTC ISO-8601**. Habit check-ins/goal deadlines use UTC-midnight keying, as on
the web.

**B3. Single-timezone assumption.** ⚠️
The app assumes the **server and the phone are in the same timezone** (the web app
already assumes one app-local TZ). If you'll use the phone in a different TZ than the
server, all-day dates could shift by a day. *Recommendation:* keep single-TZ for now;
revisit only if you travel across zones with the app. **❓ Your call if that matters.**

**B4. `jose` is mocked in the Jest tests.** ✅
`jose` ships an ESM-only build Jest can't parse. Tests mock it with an
issuer/audience-enforcing stub (so token-scope logic is still tested); **real HS256
crypto was verified by a live smoke test** (register → task → recurrence → habits →
goals → refresh, all green) and by `next build`.

**B5. No auth rate-limiting / lockout.** ⚠️
Login/register have no brute-force protection. Fine on a LAN / behind a VPN. **❓ If you
expose the backend to the public internet, add rate-limiting** (e.g. a middleware or a
reverse-proxy rule).

**B6. Stats computed server-side.** ✅
`GET /habits` returns each habit with a `stats` block; `GET /goals` returns `progress`.
The app renders these directly instead of re-implementing streak/percent math — keeps
one source of truth.

---

## Flutter app

**F1. State management: Riverpod (`flutter_riverpod`), no codegen.** ✅
`StateNotifier` + `Provider`/`StateProvider`/`FutureProvider`, hand-written `fromJson`.
*Why:* stable, no `build_runner` step, and (since Flutter wasn't installable in the
build environment) maximally compile-safe. *Alternatives:* Bloc, or Riverpod with
codegen — both add moving parts without benefit here.

**F2. No `go_router` — a simple `AuthGate` + `Navigator`.** ✅
The root swaps Login ↔ app shell on auth state; sub-screens use `Navigator.push`.
*Why:* `go_router`'s API shifts across versions; Navigator 1.0 is rock-stable and I
couldn't compile-check here. *Alternative:* `go_router` (nicer deep links) — add later
if you want deep links / widget shortcuts.

**F3. `DropdownButtonFormField` uses `value:` (not `initialValue:`).** ✅
`value:` compiles on essentially every Flutter version; `initialValue:` only exists on
very recent SDKs. A deprecation warning at worst.

**F4. Offline-capable, at the HTTP boundary — no local database.** ✅
Superseded the original "online-first" position in two steps: successful GETs are cached
to disk and replayed when the network fails, and the four task WRITES are queued
durably and replayed with idempotency keys. Neither step added SQLite. The app holds
everything in memory and filters in Dart, so a local database would have bought a query
capability nothing uses, in exchange for a schema, on-device migrations and (for Drift)
the codegen F1 rules out. Caching one layer lower covers every endpoint at once; queueing
one layer lower covers every write the same way. See F7 for exactly what is queued.

**F5. Cross-entity freshness is refresh-based, not reactive.** ✅
Completing a task doesn't instantly re-derive a linked goal's percent in the UI; data
refreshes on **tab switch** and **pull-to-refresh**. *Why:* avoids tight cross-provider
coupling. *Alternative:* invalidate goals/dashboard on every task mutation — snappier but
more coupling/flicker. Easy to add if you want it.

**F6. App identity:** package `com.focusflow`, name "FocusFlow Mobile", version `1.0.0+1`. ⚠️
Fine for sideloading. **❓ Change the package id before any Play Store upload.**

---

**F7. The offline write queue covers FOUR task operations, and nothing else — on purpose.** ✅
Create, edit, complete and delete a task are queued; every other write stays online-only.
This list is a set of decisions, not a to-do list. Read the reason before "finishing" it:

| Operation | Verdict | Why |
|---|---|---|
| `POST /tasks` | **queued** | The only write carrying content the user cannot reconstruct. Idempotency-wrapped, and the key is mandatory: creating a row is the one inherently non-idempotent act. |
| `PATCH /tasks/:id` | **queued** | No idempotency support and none needed. Every field is an absolute assignment, tags and reminders are full replacements, and `completedAt` is `existing ?? now` — replaying the same body converges. |
| `POST /tasks/:id/complete` | **queued** | Key MANDATORY. For a recurring task the server rolls the row forward and increments `completedCount`, so a bare retry skips an occurrence the user never did. |
| `DELETE /tasks/:id` | **queued** | No key needed: the queue treats 404 as success. Ids are server cuids and never reused, so a 404 can only mean "already deleted". |
| `POST /tasks/reorder` | online-only | `newOrder` is an absolute position computed against a list the queue is about to change (`createTask` assigns `max(order)+10` server-side, invisible offline). It also has no caller anywhere in `lib/`, so refusing costs zero UX. |
| `POST /habits/:id/checkin`, `POST /goals/:id/progress` | online-only | The WIRE is safe — both are key-wrapped. The **UI** is not: neither has a local projection, so offline the tile does not move, the user taps again, and that is two ops with two DIFFERENT keys. An idempotency key defends against retry duplication, never against duplicate intent our own UI manufactured. Queue these only once habits and goals render a pending delta. |
| Create/edit/delete list, goal, habit, tag, saved filter | online-only (phase 2) | A blast-radius objection, not a contract one. Each opens a second local-id namespace with cross-entity references (`task.listId` pointing at a local list id). Additive later: add the key to `kIdBearingBodyKeys` and give the entity an overlay. |
| `POST /sessions` and friends | online-only, **blocked on the server** | `startSchema` has no `startTime` and `startSession` stamps `new Date()`. A flight's pomodoros would all land at the instant the wifi connected, putting hours of focus time on the wrong day in every analytics chart. Unblocking is a one-line server change (accept an optional client `startTime`, clamped to `<= now`). |
| `POST /chat` | online-only | The response IS the request's purpose. |
| `POST /reminders/dispatch` | online-only | A server-side "I showed this" marker whose read half needs the network anyway. |
| Anything under `/auth` | **never** | Hard rule: nothing carrying credentials is written to the queue file, which is plaintext in the documents directory. |

Supporting rules, each preventing something specific:

- **A persisted op body is never rewritten.** Local ids are substituted at dispatch into a
  throwaway request. The server 422s a key reused with a different body hash, and throws it
  *before* the handler runs so the key is never released — a wedged write with no recovery.
  Never mutating what we stored makes that unreachable rather than unlikely.
- **Transport failures consume no retry budget**, only a widening delay. A fortnight at sea
  must not dead-letter a valid task. 5xx and 409 have separate bounded budgets; 409's exists
  because `idempotency.ts` has no TTL and never releases a key stranded in `pending`.
- **A fresh idempotency key is minted on 422 only.** For 400/403/404 the server already
  released the key, so reuse is legal and keeps the lost-response protection.
- **Nothing is ever auto-discarded.** Failures land in Settings → Unsent changes with the
  server's own message and a "Copy text" action, so a typed task is never silently lost.
- **Signing out RETAINS the queue** unless the user explicitly chooses to discard it. It is
  their own unsent work, not the server's cached data, and the two must not share a policy.
  The file stays scoped, and the flusher re-checks the signed-in user before every request.

## Not in this version (scoped out; all are additive later)

- **R1. Reminder delivery / local notifications.** ⚠️ The API (`/reminders/due`,
  `/reminders/dispatch`) and the Dart repository exist, but the app doesn't yet poll and
  raise device notifications. *Recommendation (next):* add `flutter_local_notifications`
  + a foreground poller (mirrors the web's in-app dispatcher). Background delivery would
  need Web Push/FCM.
- **R2. Focus / Pomodoro timer UI.** Endpoints (`/sessions*`) exist; no timer screen yet.
- **R3. Calendar & Matrix task views.** Mobile ships the **list** view + smart-list
  horizons; the web's calendar/Eisenhower-matrix views aren't ported yet.
- **R4. Saved filters, AI assistant/chat, multi-provider AI settings.** Web-only for now.
- **R5. Home-screen widgets / deep links / share-to-app.** Future.

---

## Open items that are genuinely your call

- **O1 (⚠️):** Consolidate the action/service duplication (A2) by refactoring the web
  Server Actions to call the new services. *Recommendation:* **later, low priority** — it
  touches 1450 tests for a code-tidiness win; the domain logic is already shared.
- **O2 (❓):** Offline-first (F4) — want it?
- **O3 (❓):** Public-internet exposure → add auth rate-limiting (B5) and consider HTTPS
  termination + shorter access-token TTL.
- **O4 (❓):** Reminder notifications (R1) — worth doing next? (My recommendation: yes.)

If you don't respond to the ❓ items, the ✅ defaults above stand and the app is fully
usable as built.

---

## Post-build adversarial review (applied)

Because Flutter couldn't be compiled in the build environment, a 6-lens review
(compile-correctness, contract match, backend security, backend fidelity, Dart logic —
each finding independently verified) ran over both codebases. **8 findings confirmed;
6 fixed, 2 kept as decisions:**

**Fixed:**
- ✅ Task editor crashed if a task's list **or** goal id wasn't in the loaded dropdown
  items (deleted list / archived goal / list still loading) — Flutter asserts the
  dropdown value matches exactly one item. Now guarded (falls back to Inbox / None).
- ✅ All-day dates could shift by a day on a phone in a different timezone than the
  server. Task due/start dates are now emitted by the API as bare `yyyy-MM-dd`
  (calendar day), and goal deadlines are keyed by UTC day on the client — both are now
  timezone-independent. (This resolves most of ⚠️ B3.)
- ✅ Cold-starting the app while offline / server-down wiped the session and forced
  re-login. Now only a real `401` signs you out; transient errors keep the session.
- ✅ The 401-refresh interceptor no longer signs you out on a network blip during
  refresh (only on an actual auth failure), and avoids a refresh "stampede" when many
  requests 401 at once.
- ✅ Login now spends the same bcrypt cost even when the email is unknown, closing a
  timing side-channel that could reveal whether an account exists.

**Kept as decisions (see items above):**
- Registration still returns a distinct "already exists" (409) for good UX — accepted
  for a personal app (⚠️ B5 covers the enumeration angle if you go public).
- Access/refresh token TTLs (30d/90d) and no server-side revocation stand (B1/O3) —
  fine for LAN/self-host; revisit for public exposure.

Backend re-verified after the fixes: `tsc` clean, **1650 Jest tests pass**, `next build`
compiles.
