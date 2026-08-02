# FocusFlow Mobile (Android · Flutter)

A native Android client for the self-hosted **FocusFlow** productivity app. It talks
to the existing Next.js backend over a bearer-token REST API (`/api/v1/*`) — the same
database and domain logic that powers the web app. Tasks (with smart-list date
horizons, subtasks, tags, reminders, recurrence), habits, goals, a dashboard, and
settings.

> This repo contains **only the app source** (`lib/`, `pubspec.yaml`, …). The Android
> host project (`android/`) is generated on your machine with `flutter create` — see
> **Setup** below. Flutter was not installed in the environment that authored this, so
> run `flutter analyze` once after setup and fix any SDK-version nits it reports.

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

Because only the Dart source is committed, generate the platform folders first, then
restore this repo's source (which `flutter create` would otherwise overwrite):

```bash
cd Focus_Flow_Mobile

# 1) Generate android/ (and other platform scaffolding) IN PLACE.
#    This may overwrite pubspec.yaml / lib/main.dart with defaults — that's expected.
flutter create --org com.focusflow --project-name focusflow_mobile --platforms=android .

# 2) Restore this project's real source over the generated defaults.
#    (Safe: everything here is committed to git.)
git checkout -- pubspec.yaml lib/ analysis_options.yaml

# 3) Fetch packages and sanity-check.
flutter pub get
flutter analyze
```

### Enable network access — **REQUIRED**

The app makes HTTP calls to your backend, so after `flutter create` edit
`android/app/src/main/AndroidManifest.xml`:

1. Add the INTERNET permission just inside `<manifest …>` (above `<application>`):
   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   ```
2. Allow cleartext HTTP **for local dev** (the dev backend is `http://`, not `https://`) —
   add this attribute to the `<application …>` tag:
   ```xml
   android:usesCleartextTraffic="true"
   ```
   > Omit this if you serve the backend over HTTPS.

Without both, every request fails on a real build with a connection error.

### Enable reminder notifications — optional

The app raises a device notification when a task's reminder time arrives while
the app is open. Android 13 (API 33) and later also need the permission declared
alongside `INTERNET`:

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

The app requests the runtime grant on first launch. Without the declaration the
prompt never appears and reminders stay silent — everything else keeps working.

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
