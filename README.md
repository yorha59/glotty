<div align="center">
  <img src="Glotty/Assets.xcassets/AppIcon.appiconset/icon-256@2x.png" width="128" alt="Glotty icon">
  <h1>Glotty</h1>
  <p>
    <b>Translate</b>, <b>explain</b>, <b>polish</b>, <b>chat</b>, and <b>speak</b> any text —
    <br>right where you're reading or writing.
  </p>
  <p>
    <img src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white" alt="macOS 15+">
    <img src="https://img.shields.io/badge/License-GPLv3-3b82f6.svg" alt="License: GPL v3">
    <img src="https://github.com/yorha59/glotty/actions/workflows/build.yml/badge.svg" alt="Build">
  </p>
  <p>
    <b>English</b> ·
    <a href="doc/README.zh-CN.md">简体中文</a> ·
    <a href="doc/README.zh-TW.md">繁體中文</a> ·
    <a href="doc/README.ja.md">日本語</a> ·
    <a href="doc/README.ko.md">한국어</a>
  </p>
</div>

**Glotty** is a macOS menu-bar app for reading and writing in a foreign language. Select
text in *any* app — or open a book in the built-in reader — and translate it, get a
plain-language explanation, polish your own draft into natural phrasing, chat with a tutor
about it, or hear it read aloud. It's built for learners who want a fast, in-place tutor
instead of a separate translation window: no app-switching, no copy-paste.


## ✨ Highlights

- 🌐 **Translate** — Apple's on-device Translation + macOS system dictionaries, with an optional LLM gloss.
- 💡 **Explain** — a plain-language explanation in your native language: nuance, usage, and context.
- ✏️ **Polish** — rewrite your own draft into more idiomatic target-language phrasing.
- 💬 **Chat** — a follow-up tutor conversation about the word, sentence, or your writing.
- 🔊 **Speak** — text-to-speech via the built-in macOS voice, or ElevenLabs.
- 🧠 **Memory** — optionally learns durable glossary terms, preferences, and background facts from your chats to personalize later answers.
- 🔑 **Bring your own LLM** — keys stay in the macOS **Keychain**, never in the app's files.
- 🌍 **Localized** across several languages.

## 📸 Screenshots

|  Translate  |  Explain  |
| :---------: | :-------: |
| ![Translate](appstore-screenshots/01-translate.png) | ![Explain](appstore-screenshots/02-explain.png) |
|  **Polish**  |  **Chat**  |
| ![Polish](appstore-screenshots/03-polish.png) | ![Chat](appstore-screenshots/04-chat.png) |

## ⌨️ How to trigger it

Two ways, both working across every app:

- **Leader hotkey** — hold the leader key (`Fn` by default), then tap a letter: `T` translate, `E` explain, `P` polish, `C` chat, `V` speak, `R` correct spelling. A heads-up menu shows the choices while you hold.
- **Hover menu** — rest the pointer on a selection and a compact bar pops up with the same actions.

<div align="center">
  <img src="appstore-screenshots/05-hud.png" width="440" alt="Leader hotkey menu">
  <br><br>
  <img src="appstore-screenshots/06-hover.png" width="560" alt="Hover menu">
</div>

## 🧩 Providers

Bring your own key for a hosted model, or run on-device — configure it in **Settings → Language Model**:

- **OpenAI-compatible** — OpenAI or any OpenAI-compatible endpoint (set the base URL + key)
- **DeepSeek**
- **Kimi For Coding** (Moonshot)
- **MiniMax**
- **Apple Intelligence** — on-device (Foundation Models), no key or network needed
- **Custom** — add any other OpenAI-compatible provider

Translate can also run fully offline via Apple's Translation framework + macOS dictionaries — no LLM required.

## 📄 License

[GPL-3.0](LICENSE).
