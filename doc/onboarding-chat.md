# Onboarding chat

The scripted setup conversation that runs once on first launch, started
from the Welcome window's final step ("Hi, I'm Glotty. Nice to meet
you!"). Lives in `TutorPrompt.onboardingPrompt` and is triggered from
`WelcomeWindow → PopupController.shared.show(mode: .chat, onboarding:
true)`.

The chat asks seven questions, one per turn, and emits a `set_setting`
tool call after each user answer so the existing settings-tool flow
records the value and shows a confirmation card. After all seven are
collected it sends a single warm wrap-up turn (no tool call) and exits.

## Question script

| # | Question (warmly phrased in OS language) | Setting key | Value format | Downstream effect |
|---|---|---|---|---|
| 1 | What should I call you? | `display_name` | plain string | Used in chat replies and practice feedback |
| 2 | Should I address you in a male / female / gender-neutral way? | `pronouns` | `he/him` / `she/her` / `""` | Third-person references in chat and persona text |
| 3 | What's your native language? | `native_language` | BCP-47 (`en`, `zh-Hans`, `ja`, `es`, `fr`, `de`, `ko`, `it`, `pt`, `ru`, `ar`, `hi`, `vi`, `th`, `zh-Hant`) | Drives **Fn → E (Explain) output language**, biases translation defaults, AND becomes Glotty's **UI language on next launch** unless explicitly overridden in Settings |
| 4 | What language are you practicing writing in? | `polish_output_language` | BCP-47 | Target for Fn → P (Polish) rewrites |
| 5 | When you highlight text and press Fn-T, what language is it usually in? (`auto` if it varies) | `default_translation_source` | `auto` / BCP-47 | Pinned source for Fn → T translations |
| 6 | Should I translate INTO `<your native language>` by default? | `default_translation_target` | `auto` / BCP-47 | Pinned target for Fn → T translations |
| 7 | Clean view (top dictionary only) or detailed view (all matching dictionaries)? | `show_all_dictionaries` | `true` / `false` | Translation popup dictionary density |

**Wrap-up turn** — warm congrats plus a one-line reminder of the four
hotkeys (Fn-T translate, Fn-P polish, Fn-E explain, Fn-C chat) and that
any setting can be changed later from the menu bar. No tool call.

## Q3 is special: one answer, three effects

Answering "Chinese (Simplified)" to Q3 sets three things at once:

- **Explain output language** — `PopupView.swift` `.explain` case reads
  `userNativeLanguage()` directly.
- **Translation target fallback** — when `default_translation_target` is
  `auto`, the translation flow falls back to `native_language`.
- **Glotty's UI language at next launch** —
  `SystemLanguageManager.current` falls back to `native_language` when
  no explicit `glotty.systemLanguage` is saved. `applyAtLaunch()` writes
  the resulting locale into `AppleLanguages` on the next start.

This is why the script doesn't ask a separate "what language should
Glotty's UI be in?" question. An explicit Settings → System language
pick is the only thing that overrides the implicit UI fallback.

## Tone guardrails enforced by the prompt

- **Replies in OS language.** The prompt reads `AppleLanguages` via
  `CFPreferencesCopyAppValue(_, kCFPreferencesAnyApplication)` so it
  bypasses Glotty's per-app override (the user hasn't configured one
  yet). The OS-language BCP-47 is resolved to an English language name
  via `PolishPrompt.englishName(for:)` for the model.
- **Never reads internal setting keys out loud.** No `he/him`, no
  `zh-Hans` — always translated to natural phrasing ("address you as
  male", "Chinese").
- **One question per turn, ≤2 sentences,** softened with phrases like
  "if you don't mind me asking".
- **Saved values are paraphrased warmly.** If Q3 was answered in a
  prior session, the model says "Last time you mentioned Chinese was
  your native language — does that still feel right?" rather than
  re-asking from scratch.

## Ephemerality

Onboarding turns are not part of the user's daily chat thread:

- `PopupView.hydrateTodayChat()` is **skipped** when
  `onboarding == true`, so `tutorThread` starts empty and `runTutorTurn`
  fires the scripted opener immediately.
- `PopupView.persistTutorTurn` is a **no-op** when
  `onboarding == true`, so onboarding messages never reach `ChatStore`.

Re-opening Welcome later and clicking the greeting button restarts
onboarding from a fresh "Hello". The user's real daily chat (if any)
keeps its history intact.

## Tool-call shape

The model emits **strict JSON only** (no markdown fences) with this
shape:

```json
{
  "reply": "<short message in the OS language>",
  "corrected_text": null,
  "correction_note": null,
  "tool_calls": [
    {"name": "set_setting", "args": {"key": "...", "value": "..."}}
  ]
}
```

- `tool_calls` is **omitted (or `[]`)** on (a) the very first greeting
  turn, and (b) the final wrap-up turn.
- Every other assistant turn emits exactly one `set_setting` tool call.
- The app shows a confirmation card the user taps to apply each value —
  the model's `reply` field is just the warm acknowledgement.

## Why the chat starts with "Hi, I'm Glotty. Nice to meet you!"

Earlier drafts had a "Start onboarding chat" button which tested as
cold and form-like. The greeting button is intentionally the first
interaction in Glotty's voice — it sets the tone for the rest of the
script and frames the configuration step as a conversation rather than
a wizard.
