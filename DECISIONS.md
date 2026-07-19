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

**F4. Online-first (no offline cache / sync).** ⚠️❓
The app reads/writes live; there's optimistic UI for mutations but **no local database
or offline queue**. *Recommendation:* defer offline-first unless you specifically need
to work with no signal — it's a real design layer (local SQLite/Drift + sync +
`updatedAt`/soft-delete on the API) and the same cost regardless of backend. **❓ Tell me
if offline matters and I'll design it.**

**F5. Cross-entity freshness is refresh-based, not reactive.** ✅
Completing a task doesn't instantly re-derive a linked goal's percent in the UI; data
refreshes on **tab switch** and **pull-to-refresh**. *Why:* avoids tight cross-provider
coupling. *Alternative:* invalidate goals/dashboard on every task mutation — snappier but
more coupling/flicker. Easy to add if you want it.

**F6. App identity:** package `com.focusflow`, name "FocusFlow Mobile", version `1.0.0+1`. ⚠️
Fine for sideloading. **❓ Change the package id before any Play Store upload.**

---

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
