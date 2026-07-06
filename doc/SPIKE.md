# Glotty — Spike v0 Plan

**Author:** Engineering
**Date:** 2026-05-08
**Status:** Plan
**Parent doc:** `TECH.md` (full architecture)

---

## 1. Goal

Build the **smallest end-to-end Glotty** that proves the macOS plumbing works, **before** committing to the full Rust + FFI + cloud-provider architecture in `TECH.md`. If the spike succeeds, the rest of the project is layering features on a foundation we know is solid. If any of the core macOS interactions fail, we'd rather find out now.

The spike is **throwaway-eligible**. We may keep individual files (e.g. the selection grabber probably survives), but we will not be precious about it.

---

## 2. Validation Questions

The spike succeeds if we can answer **yes** to all four:

1. **Selection grab** — does the app reliably read highlighted text from Chrome, Safari, Preview (PDF), Notes, VS Code, Slack, and Microsoft Word, **when triggered by the Fn wake-up key**? *(User-locked: trigger must be Fn, not a Carbon chord.)*
2. **Focus preservation** — does the popup appear without stealing focus or breaking the source app's selection state?
3. **Translation quality** — does Apple `Translation` produce usable output for the language pairs the user actually wants to use?
4. **Latency** — is the time from hotkey press to popup-with-translation under **300ms** on the M3 Pro for cached / on-device cases?
5. **Fn detection viability** *(added because trigger is now Fn-based)* — can we reliably detect `Fn → T` via `CGEventTap` without breaking macOS's native Fn behavior (emoji picker / dictation / Globe key actions)?

A "no" on any of these flips a corresponding decision in `TECH.md` (see §6 Decision Matrix below).

---

## 3. Scope

### 3.1 In scope

| Component             | Choice                                                      |
|-----------------------|-------------------------------------------------------------|
| Project               | Single Swift macOS app target, menu-bar-only (`LSUIElement = true`) |
| Hotkey                | **`CGEventTap` — minimal Fn leader.** Detect `Fn` press, then if `T` arrives within 600ms = translate. **No HUD, no other commands, no rebinding** — just `Fn → T`. Native Fn behavior (emoji / dictation) preserved when no command key follows within the window. |
| Permission (extra)    | **Input Monitoring** TCC permission required by `CGEventTap`. First-run alert covers it alongside Accessibility. |
| Selection grab        | Accessibility API (`AXUIElement`) primary, Cmd+C pasteboard fallback. |
| Translation           | Apple **`Translation`** framework (Swift, on-device). One backend, no abstraction. |
| Source language       | `NLLanguageRecognizer` on the grabbed text.                |
| Target language       | Hardcoded for now: pick the user's `NSLocale.current.language`. (Will be overridden in tests.) |
| Popup                 | `NSPanel` with `.nonactivatingPanel` style mask, SwiftUI content. |
| Permission flow       | One-shot alert on first launch directing user to System Settings → Privacy & Security → Accessibility. |
| Build                 | Xcode project, Apple Silicon only, debug builds. No notarization, no DMG. |

### 3.2 Out of scope (deferred to post-spike)

- Rust core, uniffi, FFI bridge — *all of `TECH.md` §5.0 deferred*
- Full leader-key model: HUD, command vocabulary (S/E/R/H/?), rebinding, conflict detection, "exclusive Fn" mode — *§5.1.2–5.1.5 deferred. Spike includes only the minimal `Fn → T` path.*
- SQLite history, FTS5, spaced repetition, review window — *§5.6, §6 deferred*
- Personality engine, `FoundationModels`, LLM providers, prompt overlay — *§5.5, §5.3.4 deferred*
- DeepL / Google / Claude / GPT cloud providers — *§5.3 deferred*
- `AVSpeechSynthesizer` / ElevenLabs / TTS — *§4 deferred*
- Settings UI, onboarding wizard, Languages pane, provider pickers — *§5.7, §5.8 deferred*
- Sparkle, notarization, code signing, distribution — *§4 deferred*

---

## 4. Build Plan

### 4.1 File layout (spike-only — final layout per `TECH.md` §13)

```
Glotty.xcodeproj
Glotty/
├── App/
│   └── GlottyApp.swift              # @main, NSApplicationDelegateAdaptor, menu bar status item
├── Hotkey/
│   └── FnLeaderHotkey.swift         # CGEventTap, minimal Fn → T detection, native-Fn passthrough
├── Selection/
│   └── SelectionGrabber.swift       # AX primary, Cmd+C fallback w/ pasteboard restore
├── Translation/
│   └── AppleTranslator.swift        # Translation framework wrapper
├── UI/
│   ├── PopupController.swift        # NSPanel lifecycle, positioning
│   └── PopupView.swift              # SwiftUI view (translation, source detection, dismiss)
├── Permissions/
│   └── PermissionCheck.swift        # AXIsProcessTrustedWithOptions + Input Monitoring check + first-run alert
└── Resources/
    ├── Info.plist                   # LSUIElement, NSAccessibilityUsageDescription
    └── Glotty.entitlements          # app sandbox OFF (Developer ID, not MAS)
```

Target ~400–600 LOC total.

### 4.2 Step order (build in this sequence — each step is independently testable)

1. **Empty menu bar app** — status item with one "Quit" entry. Validate `LSUIElement = true` hides Dock icon.
2. **Permission flow** — on first launch, check both Accessibility (`AXIsProcessTrustedWithOptions`) and Input Monitoring (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`). Show alert + deep links to both panes in System Settings → Privacy & Security if either is denied.
3. **`CGEventTap` Fn detection** — install a session-level event tap, log every `Fn`-down with timestamp. Validate it fires regardless of focused app.
4. **`Fn → T` minimal leader** — detect `T` pressed within 600ms after `Fn`-down. On match: consume the `T` event, fire a Swift callback. On timeout: pass `Fn` through so native macOS behavior (emoji picker / dictation) still works. Validate native Fn behavior is unaffected when no `T` follows.
5. **Selection grabber (AX primary)** — on the Fn → T callback, log the selected text from the focused app. Test in Safari, Notes, Chrome.
6. **Selection grabber (Cmd+C fallback)** — when AX returns nil, synthesize Cmd+C, read pasteboard, restore prior contents. Test in VS Code, Slack (Electron).
7. **NSPanel popup** — display the grabbed text. Validate focus stays in source app and selection isn't lost.
8. **Apple Translation integration** — call `TranslationSession` with grabbed text, render result in the popup. Validate ~10ms latency on cached pairs.
9. **First-run model download** — handle Apple's "language pair not yet downloaded" case: show a one-time progress UI and trigger the download via `LanguageAvailability.status`.
10. **Polish for testing** — keyboard shortcut to dismiss popup (`Esc`), click-outside dismiss, simple type styling.

---

## 5. Test Plan

### 5.1 App coverage matrix

For each app, perform: highlight a sentence → press `Fn` then `T` (within 600ms) → confirm popup appears with translation → confirm source app retains focus and selection.

**Fn-coexistence sub-test (run once globally, not per-app):** with no app focused on a text selection, press `Fn` alone (no follow-up). Confirm the macOS native Fn action still triggers (whatever the user has configured in System Settings → Keyboard → "Press 🌐 key to..." — emoji picker, dictation, language switch, or do-nothing). The spike must not break this.

| App                       | AX expected | Fallback path | Notes                                 |
|---------------------------|-------------|---------------|---------------------------------------|
| Safari                    | yes         | n/a           | Native WebKit.                        |
| Chrome                    | partial     | likely needed | Some content frames don't expose AX.  |
| Notes                     | yes         | n/a           | Apple-native, AX gold path.           |
| Preview (PDF)             | yes         | n/a           | Validate selection from PDF text.     |
| Microsoft Word            | partial     | likely needed | AppKit-bridged Office app.            |
| iA Writer / TextEdit      | yes         | n/a           |                                       |
| VS Code                   | no          | required      | Electron — proves Cmd+C fallback.     |
| Slack / Discord           | no          | required      | Electron.                             |
| Terminal / iTerm2         | varies      | likely needed | Different selection model.            |

Record results in a simple table during testing. Anything that fails both AX and Cmd+C is a known limitation — document, don't fix in spike.

### 5.2 Language-pair coverage

Test at least these pairs against Apple `Translation`:

- Whatever the user's `NSLocale` says ↔ English
- 中文 ↔ English (relevant per username inference; not load-bearing per `TECH.md` §12.1)
- Spanish, French, German ↔ English (sanity baseline)

For each: short word, sentence, paragraph. Note any pair Apple doesn't support — those become the cases where DeepL becomes load-bearing later.

### 5.3 Latency measurement

Add a debug overlay (toggleable) showing milliseconds for: hotkey-fired → selection-grabbed → translation-returned → popup-rendered. Run 10 trials per app; record median + p95. Target: median < 300ms for cached on-device pairs.

### 5.4 Regression checks (focus preservation)

After dismissing the popup:
- Source app still has selection highlighted
- Source app still has keyboard focus (typing immediately works)
- Cmd+Z in source app does not undo the spike's pasteboard manipulation (validates pasteboard restore in fallback path)

---

## 6. Decision Matrix

What each "no" in §2 means for the full architecture:

| Failure                                              | Implication for `TECH.md`                                                  |
|------------------------------------------------------|-----------------------------------------------------------------------------|
| AX selection grab fails widely                       | Cmd+C fallback becomes the *primary* path; design pasteboard restore carefully (e.g. multi-format preserve). |
| `NSPanel` steals focus                               | Investigate `NSWindow.Level.statusBar` + custom borderless window; rule out SwiftUI presentation modes.  |
| Apple Translation lacks user's language pair         | Move DeepL up the priority chain — ship a key or make API-key entry part of onboarding for affected users. |
| Latency > 300ms on cached path                       | Re-examine `TranslationSession` lifecycle (one-shot vs. retained); aggressive prewarming on app start.   |
| Cmd+C fallback breaks an app's undo stack            | Document the affected apps; add a "force AX-only" toggle for users who care about that.                  |
| `CGEventTap` can't reliably see `Fn`                  | Rethink trigger entirely — fall back to `⌃⌥T` chord for v1, document that Fn was investigated and rejected. |
| `Fn → T` consumption breaks native Fn behavior       | Tighten the consumption window; consider only consuming once a registered command key is detected; revisit the §5.1.3 strategy in `TECH.md`. |
| Input Monitoring permission is too off-putting in testing | Reconsider whether Fn is worth the permission cost vs. a no-permission Carbon chord; surface this trade-off in onboarding. |

---

## 7. Branch & Cleanup

- Spike lives on a `spike-v0` branch (or `main` if we agree this is the only thing in the repo). No PRs needed for personal validation.
- After validation, spike code is **rebased / re-extracted** into the layout from `TECH.md` §13 — files that survive cleanly (`SelectionGrabber`, `AppleTranslator` adapter, `PopupController` skeleton) get moved; the rest is rewritten against the Rust core.
- Spike-only files (`AccessibilityCheck` first-run alert, the debug latency overlay) are deleted.

---

## 8. Estimate

~1–2 focused days of work. Faster if Apple Translation "just works" on the user's pairs; slower if Electron apps require non-trivial pasteboard handling.

---

## 9. What This Spike Does NOT Promise

- It does not validate the **full leader-key model** (HUD, multi-command vocabulary like `Fn → S/E/R/H`, rebinding, conflict detection, "exclusive Fn" mode). Only the minimal `Fn → T` path is in scope. The full §5.1 model is a follow-up once basic Fn detection is proven.
- It does not validate the **Rust ↔ Swift FFI** — that's a separate spike (build a stub `Engine.translate` in Rust, call it from Swift via uniffi, ignore everything else).
- It does not validate **on-device LLM personality** (`FoundationModels`) — separate, optional spike.

If the user wants any of those validated alongside Spike v0, say so before we start.

---

*End of spike plan.*
