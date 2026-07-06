# Full-screen behavior: popup IME + Settings/Welcome sliding

Notes on the two full-screen / activation-policy problems and how they're
solved. (Rewritten 2026-06-06; the old long investigation log was
superseded by the findings below.)

## TL;DR

- **Popups** (translate / polish / chat) must **float over** another
  app's full-screen Space and still receive the **IME candidate window**.
  Solved by running as an **agent app** (`LSUIElement = YES`) with a
  non-activating, key-able floating panel.
- **Settings / Welcome** must do the opposite — **slide the full-screen
  app away** and take their own Space + Dock icon (Raycast-Settings
  behavior). Solved by **relaunching into regular mode** so the process
  earns a home Space at launch.

These pull in opposite directions, which is the whole story below.

## 1. Popup IME over a full-screen app

**Problem:** a *regular* (Dock-icon) app showing an auxiliary panel over
another app's full-screen Space trips the macOS input-method server,
which **suppresses the candidate window** for that panel — so CJK input
shows no suggestions.

**Fix:** `INFOPLIST_KEY_LSUIElement = YES` (agent app — same trick
Raycast/Alfred use; agent panels bypass the suppression). The popup
(`PopupController.createPanel` / `PopupPanel`) is:
- `.nonactivatingPanel` (shows without stealing activation from the
  full-screen app),
- `override var canBecomeKey { true }` (so it can still hold keyboard
  focus — required or the IME server won't bind its candidate window),
- `.level = .floating`, `collectionBehavior = [.moveToActiveSpace,
  .fullScreenAuxiliary, .transient]` (rides over the foreign Space).

Supporting:
- **IME-safe ESC / Return** in `PopupPanel`: while marked text is
  composing, ESC defers to the IME (close candidates, not the popup) and
  Return commits the candidate instead of submitting.
- **IMK run-loop pump** in `AppActivation.register`: a ~250 ms pump binds
  Input Method Kit's mach port for SwiftUI `TextField`s after a policy
  flip (without it the first managed window drops keystrokes —
  `IMKCFRunLoopWakeUpReliable`).

**Still required on macOS 26:** popup IME over a full-screen app works
**only in agent mode**. (A mid-session "regular mode works too" claim was
WRONG — verified: with Settings open in regular mode, a popup over
full-screen gets no IME candidates.) So the agent app is load-bearing for
popup IME, and a popup must run in `.accessory` — see §2 for why that
makes popups and Settings mutually exclusive.

## 2. Settings / Welcome sliding a full-screen app away

**Want:** open Settings (or Welcome) while in a full-screen app → macOS
slides that app away and shows our window on its own Space with a Dock
icon; the full-screen app stays full-screen on its own Space (non-
destructive).

**Key facts (macOS 26, all verified by testing):**
1. That slide is free *system* behavior **only for an app that owns a
   managed "home" Space.**
2. A home Space is granted **only when `.regular` is set at LAUNCH**,
   before any window exists. A late runtime `setActivationPolicy(.regular)`
   (e.g. at window-open) gives the Dock-icon/menu-bar chrome but **no
   home Space** — the window is born on, and hovers over, the foreign
   full-screen Space. (Confirmed: `policy=.regular` yet
   `window.isOnActiveSpace == true` over full-screen.)
3. The home Space is **lost the instant you flip back to `.accessory`**.

So an `LSUIElement` agent process can never slide via a runtime flip.

**Solution — restart into regular mode:** opening Settings/Welcome from
agent mode sets a `launchRegularKey` flag and **relaunches**. The fresh
instance reads that flag **first in `applicationWillFinishLaunching`**
and flips `.regular` before any window → earns a home Space → the window
slides. On close it drops back to `.accessory` (Dock icon hidden, agent
idle) and clears the flag. The single-instance "new launch wins" gate
makes the restart **imperceptible**.

Only **Settings and Welcome** restart — they're the only windows opened
directly from agent mode. Mistake-type / Chat-history open *from inside*
Settings, so the process is already regular and they slide for free.

Because popup IME needs **agent** mode and Settings needs **regular**
mode, the two are **mutually exclusive** — one process, one activation
policy. So firing a popup first **closes any open Settings/Welcome and
drops the process back to `.accessory`** (`AppActivation.dismissAllRegistered()`
in `handleFire`). Skipping this leaves Settings open, the app regular,
and the popup's IME dead.

**Alternatives proven but not chosen:** a separate non-`LSUIElement`
helper app for Settings (branch `wip/two-process-settings`); "regular
always" (works but shows a Dock icon at idle). Private CGS/SkyLight
space-switch APIs also work but are App-Store-forbidden.

## Key files

- `Glotty/App/GlottyApp.swift` — early `.regular` flip via
  `launchRegularKey` in `applicationWillFinishLaunching`; reopens
  Settings/Welcome on the regular relaunch; permissions auto-open now
  waits for the (async) notifications status and is skipped on a
  restart-reopen launch.
- `Glotty/App/AppActivation.swift` — refcounted `.regular`/`.accessory`
  flip + the IMK pump.
- `Glotty/UI/SettingsWindow.swift` — `relaunchIntoRegularMode(reopenKey:)`;
  restart on show from agent mode.
- `Glotty/UI/WelcomeWindow.swift` — same restart; no `.moveToActiveSpace`.
- `Glotty/UI/PopupController.swift` — `PopupPanel` (non-activating,
  `canBecomeKey`, full-screen-auxiliary) + IME-safe ESC/Return.
