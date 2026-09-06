# Deleting your FocusFlow account

You can delete your account yourself, from either app, in under a minute. It
removes the account and **everything in it** — tasks, lists, tags, habits and
their check-ins, goals, focus sessions, reminders, saved views and any
notification subscriptions — immediately and permanently. There is no recovery.
If you want a copy first, the web app's Settings page can export the whole
account as a single JSON file.

## In the Android app

1. Open **Settings** (the gear icon).
2. Scroll to the bottom and tap **Delete account**.
3. Read what will be removed, enter your password, and tap **Delete permanently**.

You are signed out as soon as the server confirms. Any changes made offline
that had not yet synced are discarded with the account; the dialog tells you
how many before you confirm.

## In the web app

**Settings → Delete account → Delete my account…** → enter your password →
**Delete my account permanently**.

## If you cannot sign in

The account lives on the FocusFlow server you connected the app to — this app
has no accounts of its own. Ask the administrator of that server to delete it;
they can do so directly in the database. For the instance operated by this
app's developer, open an issue at
https://github.com/senafathoni2998/Focus-Flow-Mobile/issues or email the
address on the Play Store listing.

## What is kept

Nothing that identifies you. The server keeps a short-lived, anonymous record
that certain item IDs were deleted (a "tombstone", used so other devices stop
showing them), which contains no content and no personal data.
