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
│ ┌─ source dict (monolingual src lang) ────────┐ │
│ │   noun  1. a plan of work to be done        │ │   ← POS + English defs
│ │   verb  1. arrange for something to happen  │ │
│ └─────────────────────────────────────────────┘ │
│ ┌─ target dict (bilingual gloss) ─────────────┐ │
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
| 3 | **Source dict** | The monolingual same-language dictionary entry. For English source, this is the New Oxford American or similar. POS + numbered English definitions. | Hidden when no monolingual source-language dict matches. |
| 4 | **Target dict** | The bilingual dictionary entry (e.g. Oxford Chinese-English). POS labels in the source language, gloss in the target language. Each `;`-separated gloss within a sense renders on its own line. | Hidden when no bilingual dict has the word. |
| 5 | **Translation row** | The translated text, larger font. No speak button — bare result. | Always visible. |
| 6 | **Footer** | `source → target` indicator, target-language switcher (per-popup override), timing, Esc hint. | Always visible. |
| 7 | **Speak buttons** | 🔊 next to each phonetic row — pronounces with the dialect-matching voice. | Only on phonetics rows. |

### Behavior rules
- **Two dict blocks**: source dict (source-language definitions) sits above the target dict (target-language gloss). They come from different macOS dictionaries; either can be missing depending on what the word exists in.
- **Single-word vs sentence**: phonetics and dict blocks only appear for single words. Sentences just show source row → translation row → footer.
- **Per-popup target override**: the language picker in the footer changes the target *for this popup only*. Settings → Translation owns the persistent default.
- **Multi-dict lookup**: queries every enabled macOS dictionary via `DCSGetActiveDictionaries`. Entries with non-Latin content go to the target dict block; entries that are pure Latin go to the source dict block.
