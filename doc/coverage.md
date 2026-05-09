# Glotty — Test Coverage

Swift-side unit + integration tests for the spike. Framework: **Swift Testing**
(`import Testing`, `@Test`, `#expect`). Run with:

```sh
xcodebuild test -project Glotty.xcodeproj -scheme Glotty \
  -destination 'platform=macOS,arch=arm64'
```

Or ⌘U inside Xcode.

**Total: 57 tests across 12 suites — all passing.**

---

## 1. Happy-path tests (the main flows users actually hit)

These exercise the real pipeline against real Apple APIs (`DCSCopyTextDefinition`,
`LanguageAvailability`, `CFStringTransform`). They require:
- An English dictionary enabled in Dictionary.app (the system default is fine)
- macOS 14+ Translation framework (we target 26)

### `Happy path — pronunciation` (4 tests)
| Test | What it verifies |
| --- | --- |
| Chinese greeting 你好 produces pinyin starting with 'n' and 'h' | Real CFStringTransform pinyin path |
| English word 'hello' resolves to at least one IPA entry from Dictionary.app | Real DCSCopyTextDefinition lookup |
| Pronouncing an English word produces well-formed phonetic entries when the dict has it | Pronounce() dispatch + parser output shape |
| Japanese word ありがとう produces romaji | Real CFStringTransform romaji path |

### `Happy path — language detection` (5 tests)
| Test | What it verifies |
| --- | --- |
| 'water' (the original bug) detects as English | Regression test for the Dutch-misclassification bug |
| 'translation' detects as English | Common ASCII word doesn't get misrouted |
| '你好' detects as Chinese | CJK source detection |
| 'こんにちは' detects as Japanese | Japanese source detection |
| Real English sentence detects as English with high confidence | Long-text path |

### `Happy path — Apple Translation framework` (3 tests)
| Test | What it verifies |
| --- | --- |
| LanguageAvailability returns a non-empty supported list | Framework is reachable; English is in the list |
| English ↔ Simplified Chinese is at least supported | en→zh-Hans pair is real (installed or downloadable) |
| English ↔ Japanese is at least supported | en→ja pair is real |
| Building a TranslationSession.Configuration retains source + target | Configuration construction pins script + language code correctly |

### `Happy path — settings flow defaults` (3 tests)
| Test | What it verifies |
| --- | --- |
| English source + non-English locale picks the user's locale as target | Auto-target heuristic for non-English users |
| Chinese source goes to English regardless of user locale | The "always go to English" rule |
| English source + English-locale user gets zh-Hans (not identity) | Avoids same-language identity translation |

---

## 2. Pure-logic unit tests (boundaries + invariants)

Smaller, faster, no external dependencies.

### `Pronunciation — dictionary parser` (8 tests)
Pinning down `Pronunciation.parseDictionaryDefinition` (the pure parser extracted
from `Pronunciation.ipa(for:)` so we don't have to mock `DCSCopyTextDefinition`).

| Test | What it pins down |
| --- | --- |
| Empty input returns no entries | |
| Definition without pipes returns no entries | |
| Single IPA produces one unlabeled entry | |
| Two distinct IPAs produce BrE + AmE entries | Convention: BrE first, AmE second, with `en-GB`/`en-US` voices |
| Identical IPAs are deduped to a single entry | |
| Variants differing only in whitespace are deduped | Normalized-key dedupe |
| More than two variants are capped at two | |
| Pre-existing slashes inside the dict block are stripped before re-wrapping | Avoids `//x//` |

### `Pronunciation — transliterate` (3 tests)
| Test | What it pins down |
| --- | --- |
| Simplified Chinese produces pinyin | Diacritic-folded match for `nǐ hǎo` |
| English input returns nil | Latin script bypassed |
| Nil language returns nil | Defensive |

### `LanguagePolicy.isSingleWord` (8 tests)
| Test | What it pins down |
| --- | --- |
| Empty / whitespace-only inputs are not single words | |
| Single ASCII word is detected | |
| Single CJK word is detected | |
| Two whitespace-separated words rejected | |
| Surrounding whitespace is trimmed | |
| 33+ chars rejected | |
| 32-char boundary still counts | |

### `LanguagePolicy.preferredTarget` (6 tests)
Default-target heuristic when no Settings preference exists. Source × locale matrix.

### `LanguagePolicy.detectSourceLanguage` (6 tests)
Biased detector + ASCII-only fallback. Plus the explicit "water" regression.

### `Permission metadata` (6 tests)
Sanity checks on the `Permission` enum used by the onboarding window — display names
non-empty, settings URLs point at the right TCC panes, identifiers are stable.

### `PermissionCheck.tccResetCommand` (2 tests)
The `tccutil` command we surface in the troubleshooting section.

### `PermissionCheck.summary` (2 tests)
The compact "Accessibility ✓ Input Monitoring ✗" status line.

---

## Out of scope (deliberately not unit-tested)

These pieces are inherently system- or UI-dependent. A unit test would either be a
fake-confidence wrapper around an Apple API or require running the full app:

- `FnLeaderHotkey` — needs `CGEventTap` + Input Monitoring TCC grant.
- `SelectionGrabber` — needs Accessibility TCC grant + a real focused window with a selection.
- `HUDController`, `PopupController`, `SettingsWindowController`, `PermissionsWindowController`
  — `NSPanel` / `NSWindow` lifecycle, on-screen positioning.
- `Speaker` — `AVSpeechSynthesizer` plays real audio.
- `TranslationSession.translate` — produces real translations, requires SwiftUI host
  to wire `.translationTask`. Pair availability *is* tested.
- `Permission.isGranted()` and `PermissionCheck.anyMissing()` — depend on host TCC state.

---

## Coverage gaps to fill next

Roughly in priority order:

1. **End-to-end translation test** — host a SwiftUI test harness with `.translationTask`
   and translate a known string (`Hello → 你好`-ish). Today we test pair availability;
   we don't test the actual round-trip output. Needs the language pack pre-installed.
2. **`HUDController` show-delay timing** — the 250ms threshold and cancel-on-Fn-up are
   testable with a fake clock if we extract the timer logic from `FnLeaderHotkey`.
3. **Settings download status reducer** — `(forwardStatus, reverseStatus) → PackStatus`
   in `TranslationSettingsTab.refreshPackStatus` is pure logic that's currently inline;
   lift it out and test the truth table.
4. **Snapshot tests for `PopupView` / `SettingsView`** — needs a snapshot library
   (e.g. `swift-snapshot-testing`); useful once UI design stabilizes.

---

## When the Rust core lands

The Rust crate gets its own `cargo test` setup; nothing in this file changes. Swift-side
tests continue to validate the GUI / FFI binding layer. Cross-boundary integration tests
that call into the real Rust core through uniffi can live in a third suite when there's
something to verify across the seam.
