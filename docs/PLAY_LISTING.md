# Play Store listing — copy from here

Draft text for Play Console → *Store presence → Main store listing*. Character
limits are Play's. Everything below describes what the app actually does today;
if a feature is removed, remove its line.

The one sentence that must survive any edit: **this app needs your own
FocusFlow server.** Reviewers read the listing before they open the app, and a
listing that reads like a hosted service sets up the "I can't sign in"
rejection.

## App name (30)

```
FocusFlow
```

## Short description (80)

```
Tasks, habits, goals and focus timer — synced to your own self-hosted server.
```

## Full description (4000)

```
FocusFlow is a productivity app for people who run their own server. It is the Android client for the open-source FocusFlow web app: point it at your instance, sign in, and everything you do on your phone is on your desktop a moment later — and nowhere else.

TASKS
• Lists and an Inbox for everything that has no list yet
• Subtasks with a progress badge, tags, priorities, start and due dates
• Repeating tasks — daily, weekly, monthly, yearly — that roll forward when you complete them
• Reminders delivered as system notifications
• Views: Board, List, Calendar, and an Eisenhower Matrix of urgent × important
• Smart lists for Today, Overdue, Next 7 Days and more, plus your own saved views

HABITS
• Every day, specific weekdays, or a number of times per week
• Simple check-off or a daily amount (8 glasses of water)
• Streaks, best streak, and your completion rate for the month

GOALS
• Manual progress, a numeric target, or progress computed from linked tasks

FOCUS
• A Pomodoro timer you can tie to a task, with a 7-day summary of your focus time

WORKS OFFLINE
Everything you write with no signal — a task, a check-in, a finished pomodoro — is saved on the phone and sent the moment you are back online. Nothing is ever silently dropped: anything the server refuses stays in "Unsent changes" for you to decide about.

YOUR DATA, YOUR SERVER
FocusFlow Mobile has no accounts of its own, no analytics, no ads and no tracking. It talks only to the server address you type into Settings. If you want an AI assistant, connect a provider key on your server and the app's chat uses it.

REQUIRES A FOCUSFLOW SERVER
This app is a client. You need a running FocusFlow web instance (self-hosted; setup instructions on GitHub) and an account on it. Use https — the app will tell you if the connection is not encrypted.

Open source: github.com/senafathoni2998/Focus-Flow-Mobile
```

## What Play asks for alongside the text — your assets

| Asset | Size | Notes |
|---|---|---|
| App icon | 512 × 512 PNG, no alpha | The launcher icon in `res/mipmap-*` is the in-app one; the listing wants a separate hi-res file |
| Feature graphic | 1024 × 500 PNG/JPG | Shown at the top of the listing; app name + one line is plenty |
| Phone screenshots | at least 2, 16:9 or 9:16, ≥ 320 px | Tasks board, Habits, Focus timer, Goals — real data, not lorem ipsum |

## Categorisation

- App category: **Productivity**
- Tags: to-do list, habit tracker, pomodoro
- Contact email: the one on your developer account
- Privacy policy: `https://github.com/senafathoni2998/Focus-Flow-Mobile/blob/main/docs/PRIVACY.md`
