# Glotty

A macOS menu-bar app for reading and writing in a foreign language. Select text
in any app — or open a book in the built-in reader — and translate, explain,
polish, or discuss it, then hear it read aloud. Built for language learners who
want a fast, in-place tutor rather than a separate translation window.

> Status: a personal project, shared as-is under the GPL. Expect rough edges.

## Features

- **Translate / Explain / Polish / Chat / Speak** on the current selection, via
  a leader hotkey (`Fn` then a letter) or a hover menu that appears over a
  selection.
  - **Translate** — Apple's on-device Translation + macOS dictionaries, with an
    optional LLM gloss.
  - **Explain** — an LLM explanation in your native language.
  - **Polish** — an LLM rewrite into more idiomatic target-language phrasing.
  - **Chat** — a follow-up tutor conversation about the text.
  - **Speak** — text-to-speech via the built-in macOS voice, or ElevenLabs.
- **Built-in EPUB / PDF reader** — open a DRM-free book, tap any word to look it
  up, and mark vocabulary you want to remember (it underlines in the text).
  Registers as an "Open With" handler for `.epub` / `.pdf`.
- **Memory** — optionally learns durable glossary terms, preferences, and
  background facts from your chats to personalize later answers.
- **Bring-your-own LLM** — OpenAI, DeepSeek, and other OpenAI-compatible
  providers, plus on-device Apple Intelligence. Keys are stored in the macOS
  **Keychain**, never in the app's files.
- **Localized** across several languages.

## Requirements

- macOS 15+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) —
  the `.xcodeproj` is generated, not checked in.

## Build & run

```sh
xcodegen generate          # produces Glotty.xcodeproj from project.yml
open Glotty.xcodeproj       # then Run in Xcode
```

or from the command line (unsigned dev build):

```sh
xcodegen generate
xcodebuild -project Glotty.xcodeproj -scheme Glotty -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

For a **signed** build, set your own Apple Developer identity — `project.yml`
ships with an empty `DEVELOPMENT_TEAM`; add yours (and adjust `CODE_SIGN_*`) or
override on the `xcodebuild` command line.

## Configuration

- Add an LLM provider + API key in **Settings → Language Model** (stored in
  Keychain).
- Optional ElevenLabs voice key in **Settings → Voice**.
- Glotty is a menu-bar agent (no Dock icon). Reading the selection in other apps
  needs **Accessibility**; the leader hotkey needs **Input Monitoring**;
  proactive reminders need **Notifications** — grant these in System Settings
  when prompted (see the in-app **Permissions** pane).

## Localization

UI strings live in `Glotty/Resources/Localizable.xcstrings`.
`scripts/extract-strings.sh` scans the source for translatable literals and
`scripts/translate-catalog.py` fills the catalog across languages (it uses an
LLM key of your own).

## License

[GPL-3.0](LICENSE).
