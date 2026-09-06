# Releasing to Google Play

Everything from an empty Play Console to `git tag` → phone, in the order it has to
happen. Steps 1–6 are done **once**. Step 7 is every release.

The one thing worth knowing before anything else: **Play's API cannot create the
first release of a brand-new app.** The first bundle is uploaded by hand in the
Console; every one after it comes from CI (`.github/workflows/android-release.yml`).

## 0. What you need

- A Google account, the one-time US$25 Play Developer registration, and identity
  verification (Google asks for an ID; it can take a day or two).
- A phone or emulator to take at least two screenshots.
- **A publicly reachable https FocusFlow server for Google's reviewers.** The app
  is login-only and points at a server the user configures, so App Review needs a
  URL plus a test account that works from outside your network. Without that the
  review is rejected on "App access" — see step 4.

## 1. Create the upload key — once, and keep it forever

```bash
keytool -genkeypair -v \
  -keystore ~/focusflow-upload.jks -alias upload \
  -keyalg RSA -keysize 2048 -validity 10000
```

Answer the prompts; the two passwords may be the same. Then **back the file up
somewhere that is not this laptop** (a password manager attachment is fine).

With Play App Signing (step 4) this is only the *upload* key — Google holds the
key that actually signs what users install — so losing it is recoverable through
a support request, but slow. Never commit it: `*.jks` and `key.properties` are
gitignored, and CI reconstructs both from secrets.

## 2. Point the build at it

Create `android/key.properties` (gitignored). A relative `storeFile` resolves
against `android/`, so the least surprising choice is an absolute path:

```properties
storeFile=/home/you/focusflow-upload.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

Absent this file a release build silently falls back to the **debug** key, which
Play refuses — so every bundle is checked after it is built, never trusted from
this file (step 3, and the CI guard).

## 3. Build and verify the first bundle locally

```bash
flutter build appbundle --release --build-name=1.0.0 --build-number=1
jarsigner -verify -verbose -certs build/app/outputs/bundle/release/app-release.aab | grep -m1 CN=
```

The second line must print your `CN=` from step 1 — **not** `CN=Android Debug`.
`--build-number=1` matters: CI's version codes start at 101 (see step 7), so the
hand upload must sit below them.

## 4. Play Console — create the app and upload by hand

1. [play.google.com/console](https://play.google.com/console) → **Create app**:
   name `FocusFlow`, default language, *App*, *Free*. Free is permanent.
2. **Set up your app** checklist, in the dashboard:
   - *Privacy policy* → the public URL of [`docs/PRIVACY.md`](PRIVACY.md) on
     GitHub (`https://github.com/senafathoni2998/Focus-Flow-Mobile/blob/main/docs/PRIVACY.md`).
     Read it first — it is written as a draft for **you** to stand behind.
   - *App access* → "All or some functionality is restricted" → add the reviewer
     server URL and a test account. This is the step self-hosted apps fail.
   - *Ads* → No. *Content rating* → fill the questionnaire (productivity, no
     user-generated public content). *Target audience* → 18+ (or 13+; either
     avoids the families programme). *News app* → No. *Data safety* → transcribe
     the section at the bottom of `PRIVACY.md`; the account-deletion URL it asks for is
     `https://github.com/senafathoni2998/Focus-Flow-Mobile/blob/main/docs/DELETE_ACCOUNT.md`. *Government / financial / health*
     → No.
3. **Store listing**: short + full description, a **512×512 icon**, a
   **1024×500 feature graphic**, and at least **two phone screenshots**. These
   are your assets; nothing in the repo produces them.
4. **Testing → Internal testing → Create new release**. Accept **Play App
   Signing** (Google-managed signing key). Upload the `.aab` from step 3. Release
   name `1.0.0 (1)`. Save → Review → **Start rollout to Internal testing**.
5. Under *Testers*, add your own email. Install from the opt-in link on your phone.
   This is a different app from any sideloaded build (new `applicationId`); sign
   in again.

## 5. Let CI talk to Play — a service account

1. [console.cloud.google.com](https://console.cloud.google.com) → any project →
   **IAM & Admin → Service accounts → Create**: name `play-publisher`. No roles.
2. Open it → **Keys → Add key → JSON**. Download. This file *is* the credential.
3. Play Console → **Users and permissions → Invite new users** → paste the
   service account's email (`play-publisher@….iam.gserviceaccount.com`).
   Under *App permissions* add **FocusFlow** with:
   *Release to testing tracks* and *Manage testing tracks and edit tester lists*.
   (Deliberately not production — promotion stays a human click, step 8.)
4. Send the invite. **Wait — the link can take up to 24 hours to take effect.**
   The symptom before then is `The caller does not have permission` from CI.

## 6. GitHub secrets (Settings → Secrets and variables → Actions)

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 ~/focusflow-upload.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password from step 1 |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | the key password from step 1 |
| `PLAY_SERVICE_ACCOUNT_JSON` | the whole JSON file from step 5, pasted verbatim |

A blank secret is not a missing one: CI writes `key.properties` from these, and
an unset secret expands to an empty line, which the Gradle helper rejects by name.

## 7. Every release: tag it

```bash
# keep pubspec.yaml's version in step with the tag, for humans
git tag v1.0.1 && git push origin v1.0.1
```

The workflow runs analyze and tests, builds, **refuses a debug-signed bundle**,
keeps the `.aab` as a run artifact, and uploads to the **internal** track.

- `versionName` = the tag without its `v`.
- `versionCode` = `100 + run number`, so it only ever goes up. Re-running a run
  that already uploaded is rejected by Play as a duplicate — a safe failure, not
  a double release. To ship again, tag again.
- *Actions → Android release → Run workflow* does the same from any branch and
  lets you pick `alpha`/`beta` instead.

## 8. Promote — by hand, on purpose

Play Console → Internal testing → the release → **Promote release → Production**.
Staged rollout is available there. A tag cannot reach every user's phone on its own.

## When it fails

| Message | Cause |
|---|---|
| `bundle is DEBUG-signed` | a keystore/password secret is missing or wrong |
| `android/key.properties has no usable 'X'` | that secret is blank |
| `Version code N has already been used` | re-run of a run that already uploaded; tag a new version |
| `The caller does not have permission` | service account not linked to the app yet, or the 24-hour wait |
| `APK signed in debug mode` (Console) | the hand upload in step 3 skipped `key.properties` |
| review rejected on *App access* | no working reviewer server + account (step 0) |
