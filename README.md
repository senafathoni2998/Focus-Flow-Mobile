# FocusFlow Mobile (Android · Flutter)

A native Android client for the self-hosted **FocusFlow** productivity app. It talks
to the existing Next.js backend over a bearer-token REST API (`/api/v1/*`) — the same
database and domain logic that powers the web app. Tasks (with smart-list date
horizons, subtasks, tags, reminders, recurrence), habits, goals, a dashboard, and
settings.

> The Android host project (`android/`) **is committed**, with the permissions and
> backup settings the app needs already applied. Do not regenerate it with
> `flutter create` unless you intend to redo those — see **Android host project**
> below for what was customised and why.

---

## Prerequisites

- **Flutter SDK** (stable, 3.24+ recommended) and the **Android SDK** (Android Studio
  or `sdkmanager`). Verify with `flutter doctor`.
- The **FocusFlow backend** running and reachable, on the `feat/mobile-api` branch
  (it adds the `/api/v1` mobile API). From the Next.js repo:
  ```bash
  git checkout feat/mobile-api
  npm install
  npm run dev          # serves http://localhost:3000
  ```

## Setup

The platform folders are committed, so there is nothing to generate:

```bash
cd Focus_Flow_Mobile
flutter pub get
flutter analyze     # expect only DropdownButtonFormField deprecation infos
flutter test
flutter run
```

## Android host project

`android/` is version-controlled rather than generated, because the app depends on
manifest changes that `flutter create` does not produce and would silently discard:

| Setting | Why |
| --- | --- |
| `INTERNET` | Every screen calls your backend. Without it the app builds and then fails every request with a connection error. |
| `POST_NOTIFICATIONS` | Android 13+ needs this declared before the runtime prompt can appear. Without it due reminders stay silent with no visible cause. |
| `usesCleartextTraffic="true"` | The dev backend is plain `http://` on a LAN address. **Remove it once you terminate TLS** — as written it permits cleartext to any host, so on a shared network bearer tokens travel in the clear. |
| `allowBackup="false"` | Tokens live in `flutter_secure_storage`, which is Keystore-backed and therefore device-bound. Android auto-backup would copy the encrypted blobs to a new device where the key does not exist, and that decryption failure is what used to pin the app on its splash screen forever. |

If you ever do re-run `flutter create .`, restore the tracked files afterwards with
`git checkout -- $(git diff --name-only)` and re-check the table above.

### Reminder notifications

The app raises a device notification when a task's reminder time arrives. The
permission is already declared (see the table above); Android asks for the grant
on first launch. Decline it and everything else keeps working — only reminders go
silent.

> **Foreground only.** Reminders fire while the app is running, mirroring the web
> app's in-app dispatcher. Waking a closed app needs a push transport (FCM) and a
> backend that can reach Google, which a self-hosted deployment may not want.

## Point the app at your backend

The API origin is configurable (no rebuild needed):

- **Android emulator** → the host machine's `localhost` is `10.0.2.2`, so the default
  `http://10.0.2.2:3000` works out of the box.
- **Physical device** → use your computer's LAN IP, e.g. `http://192.168.1.20:3000`
  (phone and computer on the same network; the Next.js dev server must be reachable).

Set it from the **login screen** (server icon, top-right) or **Settings → Server URL**.
You can also bake in a default at build time:

```bash
flutter run --dart-define=FOCUSFLOW_BASE_URL=http://192.168.1.20:3000
```

## Run

```bash
flutter run                      # on a connected device/emulator
# or build an installable APK:
flutter build apk --release
```

First launch: **Create an account** (or sign in with an existing FocusFlow account —
the mobile and web apps share the same user table).

---

## Architecture

```
lib/
  core/         config, Dio API client (bearer + 401-refresh), token storage,
                constants, theme, date/horizon helpers, JSON coercion
  models/       plain data classes with hand-written fromJson (no codegen)
  data/         repositories: one per resource, thin wrappers over the API client
  providers/    Riverpod: core wiring + StateNotifier controllers per resource
  features/     UI: auth, shell (bottom nav), tasks (+editor, drawer, card),
                habits (+editor), goals (+editor), dashboard, settings
  widgets/      shared UI (loading/error/empty, soft card, dialogs, server-url dialog)
```

- **State:** `flutter_riverpod` (StateNotifier + Provider/StateProvider/FutureProvider).
  No code generation — everything compiles as-is after `flutter pub get`.
- **Networking:** `dio` with an interceptor that attaches the access token and, on a
  `401`, transparently refreshes once (using the refresh token) and retries; if refresh
  fails it clears tokens and returns you to the login screen.
- **Auth:** email/password → a JWT **access + refresh** pair, stored in
  `flutter_secure_storage` (Android Keystore-backed).
- **Domain logic stays server-side:** habit streaks/rates and goal percentages are
  computed by the backend and returned as `stats` / `progress`, so the app never
  re-implements that (single source of truth).

## Feature coverage

- **Tasks:** smart-list date horizons (Today, Overdue, Next 7 Days, This/Next Month,
  This/Next Year, No Date, All) with live counts; lists (Inbox + custom) & tags in the
  drawer; create/edit with priority, due date, list, goal, tags, reminders, recurrence;
  subtask checklist; complete (recurring tasks roll forward); swipe-to-delete; search;
  sort; show/hide completed.
- **Habits:** daily / specific-days / N-times-per-week; "do it" or "amount" goals; one-tap
  check-in; streaks & this-month rate; archive/delete.
- **Goals:** manual / numeric / task-derived progress; ± adjust; achieve/reopen; deadline
  countdown; archive/delete.
- **Dashboard:** task counts, overdue/due-today, completions, focus minutes, active goals.
- **Settings:** account, server URL, sign out.

See [`DECISIONS.md`](DECISIONS.md) for the judgment calls made while building this and
which ones are worth your review.
