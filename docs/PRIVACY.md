# FocusFlow Mobile — Privacy Policy

*Draft, written from how the app is built. Read it, edit it, and only then point
Play Console at it: once published it is a statement made in your name.*

**Last updated: 2026-09-06**

FocusFlow Mobile is an Android client for a **self-hosted** FocusFlow server. The
developer of this app does not operate that server. You choose which server the
app talks to (Settings → Server URL), and everything the app stores or sends goes
to that server and nowhere else.

## What the app handles

- **Account:** the email address and password you sign in with. The password is
  sent to your server over the connection you configured and is not stored by the
  app; the app keeps sign-in tokens in Android's encrypted storage on the device.
- **Your content:** tasks, lists, tags, habits and check-ins, goals, focus
  sessions, reminders and saved views. Stored on your server; a copy is cached on
  the device so the app opens without a network, and edits made offline are kept
  on the device until they can be sent.
- **Notifications:** with your permission, the app shows reminders as system
  notifications. This is local to the device; no third-party push service is used.

## What the app does not do

- No analytics, no advertising, no crash reporting, no tracking SDKs.
- No data is sent to the developer or to any third party. The only network
  destination is the server URL you set.
- No access to contacts, location, camera, microphone, or files beyond text you
  choose to share into the app from another app.

## Encryption in transit

Data is protected in transit **only if your server uses https**. The app warns
on the Server URL row when the configured address is plain `http`, and release
builds refuse cleartext to any host other than a device-local address.

## Deleting your data

**Settings → Delete account**, in this app or in the web app, removes the
account and everything in it immediately and permanently — see
[DELETE_ACCOUNT.md](DELETE_ACCOUNT.md) for the exact steps and for what to do
if you can no longer sign in. The web app can export the whole account as JSON
first. Uninstalling the app alone removes only the device cache and stored
tokens.

## Contact

Open an issue at https://github.com/senafathoni2998/Focus-Flow-Mobile/issues.

---

## Appendix — answers for the Play Console *Data safety* form

These describe the app as built. Check each against the current code before
submitting; Play treats them as your declaration.

| Question | Answer | Why |
|---|---|---|
| Does your app collect or share any of the required user data types? | **Yes** — see below. (Data leaves the device to a server *the user chooses*.) | Play's definition of "collected" is "transmitted off the device"; it does not matter who runs the server. |
| Is all user data encrypted in transit? | **No** | Only when the user's server uses https. Answer honestly. |
| Do you provide a way for users to request data deletion? | **Yes** — in-app (Settings → Delete account) and via `https://github.com/senafathoni2998/Focus-Flow-Mobile/blob/main/docs/DELETE_ACCOUNT.md` | Play asks for the URL in the Data safety form. |
| Personal info → Email address | Collected, required, purpose: **Account management** | Sign-in. |
| App activity → Other user-generated content | Collected, required, purpose: **App functionality** | Tasks, habits, goals, notes. |
| App info and performance → Crash logs / Diagnostics | **Not collected** | No crash reporting SDK. |
| Device or other IDs | **Not collected** | — |
| Location, Contacts, Photos, Audio, Financial, Health | **Not collected** | Permissions are not requested. |
| Data shared with third parties | **None** | The only destination is the user-configured server. |
