# Glotty Glossary

Plain-English definitions for terms we use a lot. If a word in our conversation
isn't clear, check here first — and tell me to add it if it's missing.

---

## Testing

| Term | Meaning |
| --- | --- |
| **Unit test** | A small test for one function in isolation. Fast, no system dependencies. |
| **Integration test** | A test that runs the real pipeline (e.g. real Apple Translation) — slower, more realistic. |
| **Happy path** | The main flow when everything works. "User picks a word → gets a translation." |
| **Edge case** | A boundary condition. Empty input, exactly 32 characters, only-whitespace string. |
| **Regression** | A bug that came back. A *regression test* is the test you write to make sure it doesn't return. |
| **Coverage** | How much of the code is exercised by tests. Higher coverage = more bugs caught early. |
| **Mock / stub / fake** | A fake replacement for a real dependency, so tests don't need the real thing. We mostly avoid this — see *out of scope* in coverage.md. |
| **Suite** | A group of related tests. e.g. `Pronunciation — dictionary parser` is a suite of 8 tests. |

## Translation & dictionaries

| Term | Meaning |
| --- | --- |
| **Source language** | The language of the text you selected. (English in `English → Chinese`.) |
| **Target language** | The language you want the translation in. (Chinese in `English → Chinese`.) |
| **Monolingual dictionary** | One language. Defines English words using English. *"hello: a greeting."* |
| **Bilingual dictionary** | Two languages. Defines an English word by giving its Chinese equivalent. *"hello: 问候."* |
| **POS** (part of speech) | Word class — noun, verb, adjective, adverb, exclamation, etc. |
| **Headword** | The word being defined at the top of a dictionary entry. |
| **Gloss** | A short translation or definition (the meat of a definition). |
| **Sense** | One numbered meaning of a word. *Translation sense 1 = act of translating; sense 4 = biology term.* |
| **IPA** | International Phonetic Alphabet. *"schedule" → /ˈʃɛdjuːl/.* The standard way to write English pronunciation. |
| **Pinyin** | The Latin spelling of Mandarin syllables with tone marks. *"你好" → "nǐ hǎo".* |
| **Romaji** | The Latin spelling of Japanese. *"ありがとう" → "arigatō".* |
| **Transliteration** | Writing a word in a different script while keeping its sound. Pinyin and romaji are transliterations. |
| **BrE / AmE** | British English / American English. Different pronunciation traditions for the same word. |
| **Language pack** | The on-device data Apple Translation needs to translate one pair (e.g. en↔zh-Hans). Must be downloaded the first time you use a pair. |

## App architecture

| Term | Meaning |
| --- | --- |
| **Hotkey** | A keyboard shortcut. Glotty's hotkey is Fn → T. |
| **Leader key** | The first key in a two-step hotkey. Fn is Glotty's leader; you press it, then T (or other commands later). |
| **Event tap** | A low-level macOS hook that lets us see every keystroke. Used to detect Fn → T. Needs Input Monitoring permission. |
| **Status item** | The icon in the macOS menu bar. Glotty's is the 🌐 globe. |
| **HUD** | Heads-Up Display. The small floating panel that appears when you hold Fn. |
| **Popup / panel** | The translation window that appears on Fn → T. Technically an `NSPanel`. |
| **TCC** | Apple's privacy permission system (Transparency, Consent, and Control). Tracks which apps you've granted Accessibility, Input Monitoring, etc. |
| **AX (Accessibility)** | The macOS API used to read text from other apps. Needs Accessibility TCC permission. |
| **Code signing** | Tagging a built app with a cryptographic identity. macOS uses this to know "is this the same app I gave permission to last time?" |
| **Bundle ID** | A reverse-DNS app identifier. Glotty's is `com.ruojunye.glotty`. |

## Project flow

| Term | Meaning |
| --- | --- |
| **Spike** | A throwaway-ish prototype to validate that something is technically possible. Glotty's spike (v0.1.0-spike) proved Fn-leader + selection grab + Apple Translation all work together. |
| **MVP** | Minimum Viable Product. The smallest shippable thing that's actually useful. Spike → MVP is the next phase. |
| **Milestone** | A meaningful checkpoint in the project (e.g. "spike validated", "MVP shipped"). |
| **Tag** | A named pointer to a specific commit in git. We tagged `v0.1.0-spike` at the spike's final commit. |
| **Annotated tag** | A tag with a message attached (description, reason). Better for milestones than a bare tag. |
| **PRD** | Product Requirements Document. *What* the product does. → `doc/PRD.md`. |
| **TECH** | Technical doc. *How* it's built. → `doc/TECH.md`. |
| **xcodegen** | The tool that generates `Glotty.xcodeproj` from `project.yml`. We don't commit the .xcodeproj — only the project.yml is the source of truth. |

## Code conventions

| Term | Meaning |
| --- | --- |
| **Pure function** | A function whose output depends only on its inputs (no global state, no system calls). Easy to test. `LanguagePolicy.preferredTarget` is pure. |
| **Side effect** | When a function changes state outside itself (writes a file, plays audio, sends a network request). Side-effecty code is hard to test. |
| **Test seam** | A place in the code where you can swap in a fake for testing. We rarely use these in this project. |
| **Heuristic** | A rule of thumb that's usually right but not provably correct. The 0.85 confidence threshold for "is this English?" is a heuristic. |
| **Refactor** | Changing the structure of code without changing its behavior. Renaming, splitting a function, extracting a helper. |
| **Regression** (in code) | When new changes break behavior that used to work. (Same word as in testing — different context.) |

---

## Things that look similar but aren't

- **Source language vs source code** — *source language* is the language of the text you're translating; *source code* is the program. Same word, very different meaning.
- **Bundle ID vs bundle loader** — *bundle ID* is the app's unique name; *bundle loader* is a build setting that lets test code run inside the app process.
- **Edition (Rust)** vs **Edition (Swift)** — Rust has language editions (2018, 2021, 2024). Swift has versions (5, 6). Both are about language compatibility but the words don't match.

---

If you encounter a word in my messages that you'd like added — say "add X to glossary" and I'll write a short, plain definition for it.

---

## Translation result panel (the popup)

This is the window that appears on Fn → T. We have names for every region so we
can talk about them precisely.

```
┌─ Translation result panel ──────────────────────┐
│ ┌─ source row ────────────────────────────────┐ │
│ │ schedule                                    │ │   ← headword only (Esc closes)
│ └─────────────────────────────────────────────┘ │
│ ┌─ source phonetics ──────────────────────────┐ │
│ │ BrE  /ˈʃɛdjuːl/   🔊                        │ │   ← per-dialect row
│ │ AmE  /ˈskɛdʒuːl/  🔊                        │ │
│ └─────────────────────────────────────────────┘ │
│ ┌─ source language explanation ──────────────┐ │
│ │   noun  1. a plan of work to be done        │ │   ← POS + English defs
│ │   verb  1. arrange for something to happen  │ │
│ └─────────────────────────────────────────────┘ │
│ ┌─ bilingual dictionary ─────────────────────┐ │
│ │   noun  1. 时间表                            │ │   ← POS + Chinese gloss
│ │           日程                               │ │      (each ;-separated gloss
│ │   verb  1. 安排                              │ │       on its own line)
│ └─────────────────────────────────────────────┘ │
│ ┌─ translation row ───────────────────────────┐ │
│ │ 日程                                          │ │   ← translated text only
│ └─────────────────────────────────────────────┘ │
│ ┌─ footer ────────────────────────────────────┐ │
│ │ en → [zh-Hans ▾]              200ms · Esc   │ │   ← lang pair + meta
│ └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

| Region | Name | What it shows | Notes |
| --- | --- | --- | --- |
| 1 | **Source row** | The word/phrase you selected. | Always visible. No buttons — Esc closes the popup. |
| 2 | **Source phonetics** | Pronunciation of the source word — IPA for English, pinyin for Chinese, romaji for Japanese. Each row has its own 🔊 (BrE → British voice, AmE → American voice). | Only for single words. |
| 3 | **Source language explanation** | The highest-priority monolingual same-language dictionary entry. For English source, this is usually New Oxford American or similar. POS + numbered English definitions. | Hidden when no selected monolingual source-language dict matches. The block is tagged with the source dictionary name. |
| 4 | **Bilingual dictionary** | The highest-priority bilingual dictionary entry (e.g. Oxford Chinese-English). POS labels in the source language, gloss in the target language. Each `;`-separated gloss within a sense renders on its own line. | Hidden when no selected bilingual dict has the word. The block is tagged with the source dictionary name. |
| 5 | **Translation row** | The translated text, larger font. No speak button — bare result. | Always visible. |
| 6 | **Footer** | `source → target` indicator, target-language switcher (per-popup override), timing, Esc hint. | Always visible. |
| 7 | **Speak buttons** | 🔊 next to each phonetic row — pronounces with the dialect-matching voice. | Only on phonetics rows. |

### Behavior rules
- **Two dictionary blocks**: source language explanation sits above bilingual dictionary. They come from different macOS dictionaries; either can be missing depending on what the word exists in.
- **Single-word vs sentence**: phonetics and dict blocks only appear for single words. Sentences just show source row → translation row → footer.
- **Per-popup target override**: the language picker in the footer changes the target *for this popup only*. Settings → Translation owns the persistent default.
- **Priority dictionary lookup**: queries selected macOS dictionaries via `DCSGetActiveDictionaries` in Settings top-to-bottom order. The first monolingual match fills source language explanation; the first bilingual match fills bilingual dictionary. Entries with non-Latin content go to the bilingual dictionary block; entries that are pure Latin go to the source language explanation block.

---

## Settings page

This is the preferences window opened from the menu-bar globe → **Settings…**.
For now it is one compact page, grouped into sections.

```
┌─ Glotty Settings ──────────────────────────────┐
│ Translation                                     │
│ ┌─ Language defaults ────────────────────────┐ │
│ │ Default source language   [Auto detect ▾]  │ │
│ │ Default target language   [Auto based ▾]   │ │
│ │ Pack action row           Download / ...   │ │
│ └────────────────────────────────────────────┘ │
│ ┌─ Backend ──────────────────────────────────┐ │
│ │ Translation engine       Apple Translation │ │
│ │ Other engines are post-spike work.         │ │
│ └────────────────────────────────────────────┘ │
│                                                 │
│ Dictionary library                              │
│ ┌────────────────────────────────────────────┐ │
│ │ [Install Dictionary]                       │ │
│ └────────────────────────────────────────────┘ │
│                                                 │
│ Installed dictionaries                          │
│ ┌────────────────────────────────────────────┐ │
│ │ Bilingual dictionaries                     │ │
│ │ Oxford Chinese-English              [on] ≡ │ │
│ │ Monolingual dictionaries                   │ │
│ │ New Oxford American                 [on] ≡ │ │
│ └────────────────────────────────────────────┘ │
│                                                 │
│ Hotkey                                          │
│ ┌─ Current bindings ─────────────────────────┐ │
│ │ Leader key      Fn                         │ │
│ │ Translate       Fn → T                     │ │
│ └────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

| Region | Name | What it controls | Notes |
| --- | --- | --- | --- |
| 1 | **Translation section** | Persistent language defaults and translation backend. | This is where the popup gets its saved source/target preferences. |
| 2 | **Default source language** | The language Glotty assumes selected text starts in. | `Auto detect` is the normal setting; pin it only if you mostly translate from one language. |
| 3 | **Default target language** | The persistent translation destination. | `Auto (based on source)` means English source goes to the user locale, and non-English source goes to English. |
| 4 | **Pack action row** | A problem/action row for Apple Translation language packs. | Hidden when everything is installed. Shows download, downloading, unsupported, or an error when action is needed. |
| 5 | **Download button** | Starts Apple's language-pack download flow for the selected pair. | Appears only when a default target is selected and the pack is missing. |
| 6 | **Backend section** | The active translation engine. | Today this is fixed to Apple Translation (on-device). DeepL, Google, Claude, and GPT are planned after the spike. |
| 7 | **Dictionary library section** | Opens the Install Dictionary dialog. | The dialog lists dictionaries that match the current Translation source/target languages and are not already installed. |
| 8 | **Installed dictionaries section** | The macOS dictionaries Glotty can query for the selected default language pair. | Checked dictionaries are used by the popup. Auto source is treated as English for this display. |
| 9 | **Dictionary list** | Enabled dictionaries that match Settings → Translation defaults and search text. | Split into Bilingual dictionaries and Monolingual dictionaries areas. Each row has the dictionary title, a right-side toggle switch, and a three-bar drag handle for priority. |
| 10 | **Hotkey section** | Shows the current keyboard command model. | Customization is not implemented yet. |
| 11 | **Leader key** | The wake key for command mode. | Fixed to Fn for now. |
| 12 | **Translate binding** | The command that translates the current selection. | Fixed to Fn → T for now. |

### Behavior rules
- **Settings are persistent**: Translation choices are stored in `UserDefaults` and survive relaunch.
- **Popup override vs saved default**: the popup footer target picker changes only the current popup; Settings → Translation changes the default for future popups.
- **Source Auto detect**: with source set to Auto, the popup runs `NLLanguageRecognizer` on selected text every time.
- **Pack checking**: when source is Auto, Settings checks English ↔ target as the representative Apple Translation pair. The row stays hidden when the pair is already installed.
- **Dictionary library**: Install Dictionary opens a dialog filtered to new dictionary sources for the current Translation source/target languages. Installed dictionaries stay in the Installed dictionaries section below.
- **Dictionary lookup**: Glotty uses checked macOS dictionaries for the selected default language pair. The popup queries them in Settings top-to-bottom priority order.
- **Dictionary filtering/grouping**: Settings filters and labels dictionaries by installed dictionary name/path. This is a display hint; popup source/target classification still comes from actual lookup content.
- **Hotkey display only**: the Hotkey tab documents the current binding; rebinding is planned but not part of the current spike.
