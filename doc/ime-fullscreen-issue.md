# IME candidates don't appear in Glotty's polish chat while overlaying a full-screen app

## Symptom

When a source app (e.g. Chrome, Safari) is in macOS full-screen mode and
the user triggers Glotty's polish popup via the Fn → P hotkey:

- The polish window correctly appears overlaid on the full-screen app's
  Mission Control space (because the panel uses
  `NSWindow.CollectionBehavior.fullScreenAuxiliary`).
- The user clicks "Discuss with Glotty" to expand the chat panel.
- The user clicks into the chat `TextField`. SwiftUI's `@FocusState`
  reports the field as focused.
- The user begins typing using a CJK IME (e.g. macOS built-in Pinyin).
- **The IME candidate window never appears**, so the user can't actually
  type Chinese into the chat field.

If the user then **swipes out** of the source app's full-screen space to
Glotty's regular desktop space (Ctrl + Up + click Glotty's space tile,
or Ctrl + ←/→), the polish window comes with them (because it has
`.moveToActiveSpace`), and the IME candidate window appears as expected
the next time they type.

So the IME works fine in every other context — the failure is specifically
when the polish window is overlaying *another app's full-screen space*.

## Window configuration

The polish panel is created with:

| Property              | Value                                                       |
| --------------------- | ----------------------------------------------------------- |
| Class                 | `NSPanel` subclass (`PopupPanel`)                           |
| Style mask            | `.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .resizable` |
| `isFloatingPanel`     | `true`                                                      |
| `level`               | `.floating`                                                 |
| `collectionBehavior`  | `[.moveToActiveSpace, .fullScreenAuxiliary, .transient]`    |
| `canBecomeKey`        | overridden to return `true`                                 |
| Show method           | `panel.orderFrontRegardless()`                              |

The translation mode (read-only overlay) uses the same configuration and
behaves identically with respect to space placement. Translation works
because it doesn't need text input.

## What I tried

| Attempt                                                          | Result                                                                                |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Override `canBecomeKey` on the `NSPanel`                         | Panel can take key status, but IME still doesn't bind on the full-screen space.       |
| Drop `.nonactivatingPanel` (make it an activating panel)         | The polish window now appears *behind* the source app — defeats the whole UX.         |
| Call `NSApp.activate(ignoringOtherApps: true)` on Fn → P show    | Forces our app forward but also drags any other open Glotty windows (e.g. Settings on another space) onto the user's current view. Disruptive. |
| Call `NSApp.activate()` (macOS 14+) instead                      | Too conservative — doesn't trigger a space switch out of the source app's full-screen space. |
| Bind `NSApp.activate(ignoringOtherApps: true)` to the chat field's `@FocusState` transition (only fire when user actually clicks into the field) | `NSApp.isActive` is logged as `true` both *before* and *after* the activate call. Our process is already the active app. **Activation isn't the problem.** |
| Re-assert `panel.level = .modalPanel` + `orderFrontRegardless()` after activation | No effect — the issue isn't window layering inside one space, it's IME ownership of the space itself. |

## Working hypothesis

macOS treats a full-screen app's Mission Control space as having an
**exclusive Text Input Source / Input Method Editor context owned by the
full-screen app**. Auxiliary windows that join the space via
`.fullScreenAuxiliary` can render their UI on the space and even take
keyboard focus at the AppKit / SwiftUI level, but the system input method
server (`com.apple.inputmethodkit.InputMethodServer` /
`com.apple.HIToolbox`) does not transfer the candidate window to them —
the IME stays bound to the full-screen-owning app.

In other words: full-screen mode is the macOS equivalent of "you get
exclusive IME ownership for the duration of your full-screen session",
and `.fullScreenAuxiliary` only grants visual auxiliary status, not input
auxiliary status.

The same `NSApp.isActive == true` value confirms that "activation" is a
process-level concept and is decoupled from per-space IME binding.

## Possible workarounds (none verified)

1. **Synthesize a Mission Control keyboard shortcut** (e.g. `Ctrl + ←/→`
   via `CGEvent.post`) when the chat field gains focus — programmatically
   swipes the user off the full-screen space. Fragile: depends on the
   user's `System Settings → Keyboard → Keyboard Shortcuts → Mission
   Control` configuration, and there's no reliable way to know which
   direction the target space lies.
2. **Private CGS / SkyLight APIs** (`CGSGetActiveSpace`,
   `CGSSetActiveSpace`, `CGSManagedDisplayGetCurrentSpace`) to switch
   spaces directly. Undocumented, may break with each macOS release, and
   App Store review would reject this.
3. **InputMethodKit explicit client registration** — use
   `TextInputSources` APIs to force-register our process as an input
   client. Unclear if this even works for an arbitrary text field; IMK
   is designed for IME implementations, not consumers.
4. **Re-position / re-parent the polish window onto Glotty's home space**
   when chat focus is gained, forcing the user to follow. Worse UX than
   just asking them to swipe.
5. **Don't use `.fullScreenAuxiliary`** at all — the polish window opens
   on Glotty's home space. User has to swipe to find it (the original
   complaint that motivated adding the flag in the first place), but
   once they're there IME works.
6. **Inline UI hint** explaining the limitation: "Type in chat is
   limited inside full-screen apps — swipe to Glotty's space if
   candidates don't appear." Honest but unsatisfying.

## Specific things to search for

When researching, the following keywords and combinations have been
useful:

- `NSFullScreenAuxiliary` + `NSTextInputContext`
- `NSWindow.CollectionBehavior.fullScreenAuxiliary` + IME / candidate window
- `TISInputSource` per-space
- macOS full-screen space `inputClient`
- Cocoa `_NSContextActivationManager` (private)
- `CGSConnectionID` + `CGSSetActiveSpace` (private)
- Whether `NSPanel` with `.fullScreenAuxiliary` can receive Pinyin /
  Pinyin Simplified / Squirrel / Sogou IME input
- Apple Feedback Assistant bug reports about candidate window not
  appearing for auxiliary panels over full-screen apps

## Reproducer

1. Put Chrome (or any AppKit-based app: Safari, Notes) into full-screen
   mode so it owns a Mission Control space.
2. Select some English text in Chrome.
3. Press Fn → P. Glotty's polish window appears overlaid on Chrome's
   full-screen space.
4. Wait for the polish to complete. Click "Discuss with Glotty" → click
   into the chat field.
5. Switch to a Chinese IME (e.g. ABC → Pinyin Simplified).
6. Type any pinyin letter — `n`, `i`, `h`, `a`, `o`. Observe that no
   candidate window appears. Pressing Space inserts the literal Latin
   letters into the field.
7. Now swipe (4-finger swipe or Ctrl+Arrow) to Glotty's regular desktop
   space. The polish window follows you (`.moveToActiveSpace`).
8. Repeat step 6. The IME candidate window now appears normally.

## Environment

- macOS 26.x (Sonoma successor)
- Apple Silicon Mac
- Glotty target deployment: macOS 14.0+
- App is **not** `LSUIElement` (has a Dock icon and Settings window).
- Source-app: Google Chrome stable, full-screen mode.

## Filed?

Not yet — recording the issue here so it can be researched / submitted
as a Feedback Assistant report against macOS if no public-API workaround
exists.

## Resolution

**Fixed by switching Glotty to an agent app** (`LSUIElement = YES`).

The root cause turned out to be activation policy, not window level or
collection behavior. When a *regular* app (one with a Dock icon) calls
`NSApp.activate` while another regular app owns a full-screen Mission
Control space, macOS's input-method server suppresses the candidate
window for the regular app's auxiliary panels. Agent apps
(`LSUIElement = YES` — Raycast, Alfred, Hammerspoon, etc.) bypass that
suppression entirely; their auxiliary panels receive IME candidates
normally even when overlaid on another app's full-screen space.

Diagnostic that confirmed window level was *not* the cause:

```
beforeShow=3   afterShow=3   afterReassert=3   target=3   popUpMenu=101
becomeKey: level=3   collectionBehavior=266
```

Our panel stayed at `.floating` (3) through every transition, well below
`.popUpMenu` (101), yet candidates still didn't appear. Hypothesis ruled
out. The remaining differentiator vs. Raycast was `LSUIElement`.

### How the agent switch is wired

- `INFOPLIST_KEY_LSUIElement = YES` for both Debug and Release.
- `AppActivation` (Glotty/App/AppActivation.swift) is a refcounted
  helper. While any caller holds a slot, the policy is `.regular` (Dock
  icon, ⌘-Tab, app menu); when the count drops to zero we return to
  `.accessory`.
- `SettingsWindowController` and `MistakeTypeWindowController` call
  `AppActivation.register()` on show and `unregister()` on the
  window's `willClose`. Popups don't register — they're the windows
  that need to stay in agent mode for the IME fix to apply.

### Trade-off accepted

- No persistent Dock icon. The menu-bar mascot is Glotty's only
  always-on UI, which matches the "Glotty lives in your menu bar"
  tagline.
- Settings/Mistake-type windows briefly bring back a Dock icon while
  open, then it disappears on close. Acceptable UX.
