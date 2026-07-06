# App Store screenshots

Five Mac App Store screenshots, **2880×1800** (a valid macOS size — the
2× of 1440×900). Drag them into the macOS screenshot slot of the version
page in App Store Connect.

| File | Caption | Feature |
|---|---|---|
| `01-translate.png` | Translate anything you select — instantly | Fn+T translate (on-device) |
| `02-explain.png` | Meaning, grammar, and nuance — explained | Fn+E explain |
| `03-polish.png` | Polish your writing into natural phrasing | Fn+P polish |
| `04-chat.png` | Practice with a patient AI tutor | Fn+C chat |
| `05-hud.png` | One shortcut. Four ways to learn. | Fn-leader HUD |

Real product captures (popup shown in the user's locale, zh-Hans), each
composited onto a soft gradient with the headline baked in. The dark
popups are captured window-only (`screencapture -o -l <windowID>`, alpha
preserved) so they keep their shadow.

To regenerate after a UI change: capture the popup windows again and
re-composite (see the listing appendix in `doc/app-store-submission.md`).
For localized listings you'd recapture with the app in that UI language.
