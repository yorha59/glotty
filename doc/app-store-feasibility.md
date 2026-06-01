# Mac App Store feasibility

What it would take to ship Glotty through the Mac App Store, and an
honest read on whether it's a fit.

## Verdict

**Glotty as it stands is not a Mac App Store candidate.** Three of its
five user-visible features depend on APIs the App Store sandbox blocks
or App Review rejects:

| Feature | Mechanism | App Store status |
|---|---|---|
| Fn-leader hotkey (T/P/E/C) | `CGEventTap` system-wide (`Glotty/Hotkey/FnLeaderHotkey.swift`) | **Blocked.** Sandboxed apps cannot install event taps. No entitlement fixes this. |
| Selection grab from frontmost app | `AXUIElementCreateSystemWide` + `AXUIElementCopyAttributeValue(.focused)` + `AXSelectedText` (`Glotty/Selection/SelectionGrabber.swift`) | **Blocked.** Sandboxed apps cannot drive Accessibility on other processes. The "request Accessibility" flow in System Settings only works for non-sandboxed apps. |
| Translate (dictionary section) | Private CoreServices symbols `DCSGetActiveDictionaries` / `DCSCopyTextDefinition`, loaded via `dlsym` (`Glotty/Translation/DictionaryEntry.swift`) | **Rejected.** App Review forbids private API usage, especially symbols loaded via `dlsym` — it's grounds for automated rejection (Guideline 2.5.1). |
| Polish, Explain, Chat | OpenAI-compatible HTTP to user-configured providers | Survives with `com.apple.security.network.client` entitlement. |
| Settings, memory, usage stats | Local UserDefaults + container files | Survives. UserDefaults writes to global prefs (e.g. AppleLanguages) need to move to container-only. |

There's no path to ship the current binary on the App Store. The first
three rows are the core of "Glotty" — selecting text in another app
and translating it with one chord. That product can't exist on the App
Store; Raycast, Rectangle, Bartender, Hammerspoon, Alfred, and every
other tool of this shape ships outside the App Store for the same
reasons.

## What survives sandboxing

If a Mac App Store version is desired anyway, it would be a different
product — call it **Glotty Lite**. The shape:

- **Paste-driven, not selection-grab.** User pastes text (Cmd+V) into
  Glotty's window instead of selecting it in another app. No
  Accessibility, no global hotkey.
- **Translation via `Translation.framework`** (Apple's, public,
  sandbox-safe) instead of macOS dictionaries.
- **No dictionary section** in the popup. The "monolingual + bilingual
  dictionaries" panel disappears. LLM gloss + Apple Translation are
  the only outputs.
- **No global Fn chord.** Replace with: menu bar item click, or an
  in-window keyboard shortcut (`Cmd+T` / `Cmd+P` / `Cmd+E`) that only
  works when Glotty's window has focus.
- **All existing LLM-based flows survive:** chat, polish, explain,
  practice scheduler, learned-memory store, usage tracking.

## Required rework for Glotty Lite

In rough effort order — none of these are one-line changes:

1. **Drop CGEventTap.** Delete `FnLeaderHotkey.swift` entirely. Wire
   `AppDelegate.handleFire(mode:)` to in-window `KeyboardShortcut`s or
   to a `NSMenuItem` per mode in the status bar menu.
2. **Drop AX-driven SelectionGrabber.** The popup must open with the
   text already in `tutorInput` / `sourceText` — i.e. user pastes or
   types. The `grabber.grab()` call site in `handleFire` goes away.
3. **Replace Dictionary Services with Apple Translation.** The
   `Translation` framework (macOS 14.4+) exposes `TranslationSession`
   for sandboxed inline translation. The `DictionaryLookup`
   abstraction can stay but its implementation switches from
   `DCSCopyTextDefinition` to a stub returning empty results, and the
   popup's dictionary section is conditionally hidden when results
   are empty.
4. **Add the sandbox entitlement and required scopes:**
   ```
   com.apple.security.app-sandbox = true
   com.apple.security.network.client = true
   com.apple.security.files.user-selected.read-only = true  (for Backup → Import)
   ```
   Test the existing Backup/Import flows still work under sandbox
   (they probably do — NSOpenPanel inherits sandbox scope on
   user-selected files).
5. **Move global-pref writes into the container.** `SystemLanguage`
   currently writes `AppleLanguages` via `kCFPreferencesAnyApplication`
   to override Foundation's locale resolution. Under sandbox, that
   write either no-ops or writes to the container's own plist (which
   doesn't take effect). The UI-language switch needs a different
   mechanism — e.g. setting `Bundle.main.preferredLocalizations` at
   launch via `LSEnvironment` plist keys or via re-launch with
   `LANG=` env. Worth verifying behavior under sandbox before
   investing.
6. **Update marketing copy + Welcome flow** to reflect the
   paste-driven model. The current Welcome demos show "select text
   in any app and press Fn-T" — that's the wrong story for Lite.
7. **App Store Connect setup:** bundle ID (separate from
   `com.ruojunye.glotty` so the two SKUs can coexist), App Store
   Connect record, screenshots, description, age rating, privacy
   nutrition label (Glotty sends text to user-configured LLM
   providers — this needs disclosure), TestFlight build for review.

Rough estimate: a focused engineer needs 2–4 weeks to get Lite past
App Review, mostly fighting unobvious sandbox edge cases (relaunch
behavior, file-scope persistence, NSOpenPanel quirks).

## Distribution alternative — Developer ID + notarization

The realistic path for the full-feature Glotty is what every app of
this shape uses: **Developer ID Application certificate + Apple
notarization, distributed via your own download link.**

- Gatekeeper trusts the binary on any Mac with no scary warnings.
- All current features work — no sandbox, no AX restrictions, no
  private-API rejections.
- One-time setup of a `Developer ID Application` cert + an
  App-specific password (or App Store Connect API key) for
  `notarytool`.
- The existing CI pipeline (`.gitea/workflows/build.yml` →
  `scripts/make-dmg-nosign.sh`) is the right shape — adding signing
  + notarization is a focused change, not a rewrite.

This is the recommendation. The App Store path is documented here for
completeness; see Track 1 in the parent conversation for the
Developer ID work plan.

## Why not "just request entitlements"

The temporary-exception entitlements (`com.apple.security.temporary-
exception.*`) historically let some apps request waivers for sandbox
restrictions on a case-by-case basis. Three reasons that path doesn't
help here:

1. Apple has been progressively narrowing temporary exceptions; new
   approvals for "drive Accessibility on other processes" are
   essentially unheard of since ~2020.
2. Even if granted, `dlsym`-loaded private symbols are a separate
   rejection vector (Guideline 2.5.1) that no entitlement covers.
3. The Fn-leader chord is implemented as a `CGEventTap`; there's no
   entitlement that re-enables event taps for sandboxed processes.
   The only sanctioned global-shortcut path is `KeyboardShortcuts` /
   `NSEvent.addGlobalMonitorForEvents`, which doesn't support the
   Fn-leader chord (Fn key state isn't surfaced).

## If we ever do this

The right ordering would be:

1. **Establish the Developer ID build first** so the existing user
   base has a real distribution.
2. Maintain `main` as the full-feature build.
3. Add a `glotty-lite` Xcode target (or branch) that compiles the
   same source with `#if APPSTORE` flags around the
   sandbox-incompatible code paths. Each `#if APPSTORE` site becomes
   a documented seam.
4. Use a separate bundle ID + product page; explain on the website
   that Glotty Lite is the App Store variant with a feature subset.
5. Don't reverse-port Lite restrictions into the main build.

Until there's clear demand for an App Store presence, this whole
track stays in `pending`. The DMG distribution is sufficient for the
audience this app is built for.
