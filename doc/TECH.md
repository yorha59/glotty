# Glotty — Technical Report

**Author:** Engineering
**Date:** 2026-05-05
**Status:** Draft v0.1
**Target Platform:** **macOS 26 Tahoe (26.0+), Apple Silicon only.** Reference development device: MacBook Pro, Apple M3 Pro, macOS 26.3.1. Targeting the user's own machine eliminates back-compat hedging — every framework discussed below ships in the v1 baseline.

---

## 1. Executive Summary

Glotty is a system-wide macOS utility that combines an instant translation engine with a persistent "cyber pet" companion. The user highlights text in any application, triggers a global hotkey, and a non-intrusive popup delivers the translation, phonetic transcription, and a personalized message from Glotty. All translations are stored locally so Glotty can adapt its greetings, surface struggling words for review, and grow alongside the user.

This report describes the proposed architecture, technology stack, core subsystems, data model, integration points, risks, and a phased delivery plan.

---

## 2. Goals & Non-Goals

### 2.1 Goals
- Sub-300ms perceived latency from hotkey press to popup render (cached translations).
- Work in any focused application (Chrome, Word, PDF readers, Terminal, etc.) without stealing focus.
- Persist 100% of translation events locally; survive app restart and reboot.
- Provide phonetic pronunciation + TTS audio playback on demand.
- Personality layer: adaptive greetings, streaks, review prompts.

### 2.2 Non-Goals (v1)
- Cross-device sync / cloud account.
- OCR of images or live video.
- Offline neural translation (network required for v1).
- Windows / Linux support.

---

## 3. System Architecture

### 3.1 High-Level Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                       User's macOS Session                          │
│                                                                      │
│   [Any App: Chrome / PDF / Word]                                    │
│         │ selection                                                  │
│         ▼                                                            │
│  ╔══════════════════════════ Swift (GUI shell) ══════════════════╗  │
│  ║  ┌─────────────────────────┐                                  ║  │
│  ║  │  CGEventTap (leader Fn) │  Input Monitoring permission     ║  │
│  ║  └────────────┬────────────┘                                  ║  │
│  ║               ▼                                                ║  │
│  ║  ┌─────────────────────────┐                                  ║  │
│  ║  │  Selection Grabber      │  AXUIElement + pasteboard fb     ║  │
│  ║  └────────────┬────────────┘                                  ║  │
│  ║               │ raw text + lang hint                           ║  │
│  ║               ▼                                                ║  │
│  ║  ┌──────────────────────────────────────────────────────┐    ║  │
│  ║  │              FFI BOUNDARY (uniffi)                   │    ║  │
│  ║  └──────────────────────────────────────────────────────┘    ║  │
│  ╚════════════════════════════ ▼ ════════════════════════════════╝  │
│                                ▼                                     │
│  ╔══════════════════════════ Rust (glotty-core) ═════════════════╗  │
│  ║  ┌──────────┐  ┌───────────┐  ┌──────────────┐  ┌─────────┐  ║  │
│  ║  │  Cache + │  │Translation│  │ Personality  │  │ Review  │  ║  │
│  ║  │  SQLite  │◄─┤  Service  │  │   Engine     │  │ (SM-2)  │  ║  │
│  ║  │ (rusqlite)│  │ (reqwest) │  │ (templates)  │  │         │  ║  │
│  ║  └──────────┘  └─────┬─────┘  └──────────────┘  └─────────┘  ║  │
│  ║                      │                                        ║  │
│  ║         CredentialProvider callback (→ Swift Keychain)        ║  │
│  ╚══════════════════════ │ ═════════════════════════════════════╝  │
│                          ▼                                          │
│                  [DeepL] [Google] [LLM]                             │
│                                                                      │
│  ╔══════════════════════════ Swift (GUI shell) ══════════════════╗  │
│  ║  ┌─────────────────────────┐  ┌─────────────────────────┐    ║  │
│  ║  │  Glotty Popup (SwiftUI) │  │  Menu Bar (NSStatusItem)│    ║  │
│  ║  │  - translation          │  │  - history / review /   │    ║  │
│  ║  │  - phonetic + 🔊  TTS   │  │    settings             │    ║  │
│  ║  │  - Glotty comment       │  │                         │    ║  │
│  ║  └─────────────────────────┘  └─────────────────────────┘    ║  │
│  ║  AVSpeechSynthesizer · Keychain · NSPanel · Sparkle · TCC    ║  │
│  ╚════════════════════════════════════════════════════════════════╝  │
└────────────────────────────────────────────────────────────────────┘
```

### 3.2 Process Model
Single foreground app, `LSUIElement = true` (no Dock icon). The Rust core ships as a static library (`libglotty_core.a`) linked into the Swift app — **one process, no IPC**, FFI boundary only. This preserves the sub-300ms latency target while giving us a portable core.

### 3.4 Reference User & Validation Targets
Development is anchored to the user's own machine (M3 Pro / macOS 26.3.1). Concretely this means:
- Performance budgets in §9 are measured on M3 Pro silicon; the dev machine *is* the lower bound, not an upper bound.
- The smoke-test language pair set must include **Chinese ↔ English** as a primary case (inferred from username `若君叶`); validate that Apple `Translation` covers it on macOS 26 before we ship, and route to DeepL only if it doesn't.
- All onboarding screenshots and TCC permission flows captured on macOS 26 Tahoe — no need to QA the macOS 14/15 settings panes.

### 3.3 Language Boundary — What Lives Where

| Concern                                | Side    | Why                                                        |
|----------------------------------------|---------|------------------------------------------------------------|
| Global hotkey (`CGEventTap`)           | Swift   | macOS-only API; needs main-thread RunLoop integration.     |
| Selection grab (Accessibility, pboard) | Swift   | `AXUIElement` is Objective-C / `NSPasteboard` is AppKit.   |
| Language detection (`NLLanguageRecognizer`) | Swift | Apple's detector beats `whatlang` in accuracy and is free. |
| TTS (`AVSpeechSynthesizer`)            | Swift   | System framework, zero-cost.                               |
| Keychain access                        | Swift   | Security framework only.                                   |
| All UI (NSPanel, SwiftUI, menu bar)    | Swift   | Native is the only sane path.                              |
| Sparkle auto-update, notarization      | Swift   | Tooling expects a Swift/ObjC bundle.                       |
| Translation HTTP clients               | **Rust**| `reqwest` + provider trait, easy to add providers.         |
| SQLite + FTS5 + migrations             | **Rust**| `rusqlite` is mature; schema lives next to the code that owns it. |
| Cache (LRU + persistent)               | **Rust**| Pure-data; no OS coupling.                                 |
| Personality engine + template loader   | **Rust**| Deterministic logic; easy to unit-test off-device.         |
| Spaced-repetition (SM-2)               | **Rust**| Pure algorithm.                                            |
| Settings model + validation            | **Rust**| Single source of truth; Swift reads via FFI.               |
| Credential **storage** *(only if user enables a cloud provider — see §7)* | Swift | Keychain. **Not used in the default install on macOS 26.** |
| Credential **lookup at call time**     | **Rust** calls a Swift `CredentialProvider` callback (no-op when no cloud providers configured) | Keeps secrets out of Rust memory longer than necessary.    |

---

## 4. Technology Stack

| Layer              | Choice                                     | Rationale                                                                          |
|--------------------|--------------------------------------------|------------------------------------------------------------------------------------|
> **Versioning policy:** every dependency below is pinned to its **latest stable release as of 2026-05-05**. CI runs `cargo update` weekly against a mirror branch so we catch breaking upstream changes early. Swift toolchain follows the current Xcode release.

| Layer              | Choice                                     | Rationale                                                                          |
|--------------------|--------------------------------------------|------------------------------------------------------------------------------------|
| Core language      | **Rust** edition **2024**, MSRV **1.85+**; CI tracks current stable (~1.95, 2026-04 release) | Edition 2024 unlocks `if let` chains, RPIT lifetime capture, `unsafe extern` blocks, async closure ergonomics — all useful in FFI/provider code. |
| GUI language       | **Swift 6.x** with **strict concurrency on** (`-strict-concurrency=complete`) | Sendable / actor isolation catches data races at compile time — critical for the event-tap → async-translate → MainActor pipeline. |
| Xcode              | **Xcode 26.x** (the version shipping with macOS 26 Tahoe) | Ships Swift 6.x, macOS 26 SDK, current `notarytool`.                       |
| Deployment target  | **macOS 26.0** (Tahoe), **arm64 only**     | No Intel slice in the universal binary; no SDK availability checks needed for `Translation` / `FoundationModels`. |
| FFI bridge         | **uniffi 0.29+** (Mozilla)                 | Idiomatic Swift bindings from a `.udl` file; async + callback interfaces stable since 0.27. |
| Build glue         | `cargo` + Xcode "Run Script" + `uniffi-bindgen-swift` (modern path; replaces UDL-only flow) | Universal binary via two `cargo` targets + `lipo`.       |
| UI                 | SwiftUI + AppKit interop (`NSPanel`); state via Swift **`@Observable`** macro | `@Observable` (Swift 5.9+) replaces `ObservableObject`; less boilerplate, fewer view re-renders. |
| Tests (Swift)      | **Swift Testing** (`import Testing`) — not XCTest | Modern macro-based framework, parallel by default, parameterized tests. |
| Hotkey             | `CGEventTap` (Swift, see §5.1)             | Only path that sees the `Fn` key; required by leader-key model.                    |
| Selection capture  | Accessibility API (`AXUIElement`) + Cmd+C fallback (Swift) | AX gives selection without mutating clipboard; fallback for non-AX apps.   |
| **Translation backends** *(user-selectable per §5.3)* | **Default:** Apple `Translation` framework (Swift, on-device, free, ~10ms). **Alternatives:** DeepL · Google Translate v3 · Anthropic Claude · OpenAI GPT (all Rust-side, cloud, API key required) | User picks the active backend in Settings; can also configure a fallback chain. LLM backends produce higher-quality results on idioms / context but cost ~$0.0001–0.001 per call and add latency. |
| **Personality / example-sentence backends** *(user-selectable per §5.5)* | **Default:** Apple `FoundationModels` (Swift, on-device, free). **Alternatives:** template engine (Rust, no LLM) · Anthropic Claude · OpenAI GPT (Rust, cloud) | Same `LLMProvider` callback abstraction (§5.5) supports all three modes. |
| Async runtime (Rust) | `tokio` 1.42+ (multi-thread)              | Standard. `reqwest` requires it.                                                   |
| HTTP client (Rust) | `reqwest` 0.12+ with `rustls-tls`          | `rustls` avoids OpenSSL link dance.                                                |
| Storage            | **SQLite via `rusqlite` 0.33+** (Rust), bundled SQLite ≥3.46 | FTS5 + JSON1 baked in; migrations via `refinery` 0.8+.              |
| Hashing            | `blake3` 1.5+ (cache keys)                 | Faster than SHA-256, no crypto-correctness needs here.                             |
| Cache              | `lru` 0.12+ (in-memory)                    | Simple, no async lock contention.                                                  |
| Serialization      | `serde` 1.x + `serde_json` 1.x             | Universal.                                                                         |
| **TTS backends** *(user-selectable)* | **Default:** `AVSpeechSynthesizer` (Swift, on-device, free, instant; macOS 26 ships Personal Voice / Premium voices). **Alternative:** ElevenLabs (Rust HTTP, cloud, API key, much more natural voices, ~500–1500ms + audio download). | Settings exposes a per-language voice picker for both backends. ElevenLabs results are cached as audio files keyed by `(text, voice, lang)` to avoid repeat synthesis cost. |
| Lang detection     | `NLLanguageRecognizer` (Swift) → passed across FFI | Higher accuracy than pure-Rust `whatlang`.                                 |
| Phonetics          | Apple `Translation` provides IPA for many pairs; CMU dict fallback (Rust) | Avoid bespoke phonetic services.                              |
| Keychain (conditional) | Swift `Security` framework + Rust `CredentialProvider` callback | **Only loaded when the user enables a cloud provider in Settings.** No Keychain access at all in the default on-device flow. |
| Auto-update        | **Sparkle 2.6+**                           | Industry-standard; supports modern signing (`EdDSA`).                              |
| Packaging          | Xcode 17 + `notarytool` + Sparkle          | Both the `.app` and the embedded Rust artifact signed; notarized.                  |
| Telemetry          | None in v1 (privacy)                       | Translation text is sensitive; opt-in only post-v1.                                |

---

## 5. Core Components

### 5.0 FFI Boundary (Rust ↔ Swift)

The Rust core is built as a **`staticlib`** and linked into the Swift `.app`. Bindings are generated by **uniffi** from a single `.udl` interface file, producing both a Rust `pub extern` surface and a Swift module the GUI imports as `import GlottyCore`.

#### 5.0.1 Build pipeline
1. `cargo build --release --target aarch64-apple-darwin` and `--target x86_64-apple-darwin`.
2. `lipo -create` merges the two into a universal `libglotty_core.a`.
3. `uniffi-bindgen generate` emits `GlottyCore.swift` + a modulemap.
4. Xcode "Run Script" build phase invokes the above before linking; outputs are tracked so incremental builds work.
5. Both the Swift `.app` and any embedded dylib are signed with the Developer ID and notarized via `notarytool`.

#### 5.0.2 Interface sketch (`glotty.udl`)

```
namespace glotty {
    [Throws=GlottyError]
    Engine open(string db_path, Settings settings, CredentialProvider creds);
};

interface Engine {
    [Async, Throws=GlottyError]
    TranslationResult translate(string text, string source_lang_hint, string target_lang);

    [Async, Throws=GlottyError]
    string example_sentence(string text, string lang);

    sequence<HistoryEntry> search_history(string query, u32 limit);
    sequence<ReviewItem> review_due(u32 limit);
    void record_review(string source_text, i32 score);
    string personality_message(PersonalityContext ctx);
};

callback interface CredentialProvider {
    string? secret_for(string provider_id);
};

dictionary TranslationResult {
    string translated_text;
    string? phonetic;
    string detected_source_lang;
    string provider;
    boolean from_cache;
};
```

#### 5.0.3 Threading & async
- Rust runs on its own `tokio` runtime, owned by `Engine`.
- uniffi marshals Swift `async` calls into tokio futures and back; results land on whatever `DispatchQueue` the caller awaits on.
- The Swift GUI **always** awaits Rust calls off the main thread and dispatches UI updates to `MainActor`.

#### 5.0.4 Error model
Single `GlottyError` enum exposed as a Swift error type (network / provider-rejected / cache-miss-and-offline / db-corrupt / config). Swift maps these to user-facing strings — the Rust core is locale-agnostic.

#### 5.0.5 Why uniffi over swift-bridge or hand-rolled cbindgen
- **uniffi**: declarative IDL, async support, callback interfaces, used in Firefox iOS at scale → mature, predictable.
- **swift-bridge**: more idiomatic Rust-side, but smaller community, async still maturing.
- **cbindgen + hand-written Swift wrappers**: maximum control, maximum maintenance burden — only worth it if uniffi blocks a specific type. Reserved as escape hatch.

---

### 5.1 Global Hotkey Listener (Leader-Key Model) **[Swift]**

Glotty uses a **two-press leader-key pattern**, not a single chord:

1. User taps **`Fn`** (the leader / "wake key") → Glotty enters *command mode* and shows a small HUD listing available actions.
2. Within a short timeout (default **600ms**), user taps a **command key** to pick the action.
3. If no command key arrives within the timeout, Glotty exits command mode silently and the original `Fn` behavior is passed through to macOS (emoji picker / dictation / etc., per the user's System Settings).

#### 5.1.1 Why a `CGEventTap` instead of Carbon hotkeys
The PRD's `Fn` trigger cannot be implemented with `RegisterEventHotKey` — the Fn (🌐 / Globe) key is reserved by macOS and is not exposed as a registrable modifier. The only supported path is a low-level **`CGEventTap`** at `kCGSessionEventTapLocation`, which:
- Sees every keyboard event in the user's session, including `Fn`.
- Can selectively *consume* events (so the second keypress doesn't leak into the focused app) or pass them through.
- Requires the **Input Monitoring** TCC permission (macOS 10.15+). Onboarding must explain this clearly.

#### 5.1.2 Command Vocabulary

**Principle:** every command has a built-in default key **and** is rebindable by the user. Defaults exist so a fresh install is usable immediately; Settings exposes a per-command rebind UI for everything.

**Default mappings (locked for v1):**

| Press         | Command id     | Action                                  | Notes                                  |
|---------------|----------------|-----------------------------------------|----------------------------------------|
| `Fn` → `T`    | `translate`    | Translate selection                     | Core flow from PRD.                    |
| `Fn` → `E`    | `example`      | Generate example sentence               | Uses LLM provider (see §5.5).          |
| `Fn` → `S`    | `speak`        | Speak (TTS) the selection               | Pronunciation only, no popup chrome.   |
| `Fn` → `R`    | `review`       | Open today's flashcards                 | Opens review window.                   |
| `Fn` → `H`    | `history`      | Open searchable history                 | Same as menu-bar history item.         |
| `Fn` → `?`    | `help`         | Show full command HUD                   | Discovery aid; not rebindable.         |
| `Fn` → `Esc`  | `cancel`       | Cancel command mode                     | Or any unmapped key.                   |

**How rebinding works:**

- Commands are registered in code with a stable `command_id` (e.g. `translate`, `example`). The id never changes; only the keybind does.
- Default mappings ship in a JSON resource (`commands.default.json`) embedded in the app bundle.
- User overrides are stored in `commands.user.json` under `~/Library/Application Support/Glotty/`. The runtime merges the user file over the defaults at startup.
- Settings → **Hotkey** pane shows every registered `command_id` with its current key, a "rebind" button, and a "reset to default" button per row.
- Conflict detection at rebind time: if the user picks a key already bound to another command, Settings warns and offers to swap (or unbind the other).
- Reserved keys that can't be rebound: `Esc` (always = cancel), `?` (always = help HUD). Documented in the rebind UI as greyed-out rows.
- A user can also **disable** a command (clear its binding entirely) — useful if they don't want, say, the review hotkey.

**Adding new commands:** the mapping table is data-driven; a new command needs (1) a Swift handler registered with the `CommandRegistry` at startup, and (2) an entry in `commands.default.json`. No UI changes.

#### 5.1.3 Coexisting with macOS's native `Fn` behavior
This is the trickiest UX problem. If the user has `Fn` set to "Show Emoji & Symbols" in System Settings, we must not break that.

**Strategy:**
- On `Fn`-down, do **not** consume the event. Start two timers: a **120ms HUD-show delay** and a **600ms command-mode timeout**.
- If a registered command key arrives before the **120ms** mark, the HUD never appears at all (zero flicker for power users). The command runs and the original Fn action is suppressed by injecting `Esc` to dismiss any picker macOS opened.
- If a registered command key arrives between **120–600ms**, the HUD is visible by then; the command runs and the HUD is dismissed.
- If the **600ms** timeout fires with no command key, silently dismiss the HUD and let macOS's Fn behavior stand.
- Provide a Settings toggle: **"Take exclusive control of Fn"** — when on, we consume Fn unconditionally and the user loses native Fn behavior in exchange for zero-flicker activation.

The 120ms threshold is configurable in advanced Settings (range 0–300ms).

#### 5.1.4 Alternative trigger modes (configurable)
Some users will dislike the leader pattern or the Input Monitoring permission. Settings will offer:
- **Leader mode** (default): `Fn` → command key, as above.
- **Chord mode**: hold `Fn` + command key simultaneously (still requires event tap, but no timeout window).
- **Classic mode**: a single Carbon-registered chord (e.g. `⌃⌥T`) for translate only — no leader, no Input Monitoring permission needed, but loses the multi-command vocabulary.

#### 5.1.5 Debounce & safety
- 250ms debounce on the leader to prevent double-fires.
- Command mode auto-exits on focus change, screen lock, or any modifier-key chord (so `Fn` followed by `Cmd+Q` is not hijacked).

### 5.2 Selection Grabber **[Swift]**
Two-stage strategy:
1. **Primary:** Use `AXUIElementCopyAttributeValue(kAXSelectedTextAttribute)` against the focused element. Zero clipboard pollution, no app focus shift.
2. **Fallback:** Synthesize `Cmd+C`, read `NSPasteboard.general`, then restore prior pasteboard contents. Used when AX returns nil (Electron, some Java apps).

Requires the user to grant **Accessibility permission** on first launch (TCC prompt). Without it, only the fallback works.

The grabbed string + a Swift-side `NLLanguageRecognizer` source-language hint are passed across the FFI to `Engine.translate(...)`.

### 5.3 Translation Service **[Swift + Rust split]**

Provider-pluggable, user-selectable. Settings lets the user pick:
- **Active provider** (the one tried first for any new translation), and
- An optional **fallback chain** (e.g. *Apple → DeepL → Claude*).

#### 5.3.1 Available providers

| Provider                  | Side     | Cost       | Latency       | Notes                                      |
|---------------------------|----------|------------|---------------|---------------------------------------------|
| **Apple `Translation`** *(default)* | Swift  | free | ~10ms       | On-device. Limited to Apple's bundled pairs. |
| DeepL API                 | Rust   | per char   | ~150–400ms   | High quality on EU pairs.                   |
| Google Translate v3       | Rust   | per char   | ~150–400ms   | Broadest pair coverage.                      |
| Anthropic Claude          | Rust   | per token  | ~400–1500ms (streamed) | Best for idioms / context / 中↔英. Single call returns translation + phonetic + example via structured output. |
| OpenAI GPT                | Rust   | per token  | ~400–1500ms (streamed) | Same shape as Claude.                        |

#### 5.3.2 Caching & request shape (Rust)
- Cache key: `blake3(source_text || source_lang || target_lang || provider_id)`.
- Two-layer: in-process LRU (1k entries) + persistent SQLite. Provider-tagged so a re-pick doesn't pollute hits.
- LLM providers are called with a structured-output prompt that asks for JSON `{translation, phonetic, literal, notes}` so one call covers what would otherwise need two.
- LLM responses are **streamed** (SSE) into the popup via a Rust→Swift async iterator; first token target ~600ms.

#### 5.3.3 Why this split
Apple's framework is Swift-only. Everything else (HTTP, streaming parser, cache, provider routing, prompt templates) lives in Rust where it's testable off-device. The Swift side is a thin call-through plus the `Translation` adapter.

#### 5.3.4 Prompt Architecture (LLM providers)

LLM prompts compose two layers:

**Core prompt (embedded, hidden from user):**
- Ships in the Rust crate via `include_str!` from `core/glotty-core/src/translation/prompts/`.
- Versioned with the app — updates ship through Sparkle.
- Owns: response schema (the `{translation, phonetic, literal, notes}` JSON contract), refusal handling, length / safety guardrails, source/target language injection, formatting rules, structured-output instructions.
- The user **never sees this** and **cannot edit it**. Surfacing it would let users break the JSON contract and cause parse failures — rather than expose a footgun, we keep this internal.

**User overlay (exposed in Settings → Personality):**
- Free-text fields the user can edit:
  - **Persona** — who Glotty *is* (e.g. "a patient tutor", "a sarcastic friend", "a formal interpreter").
  - **Style** — tone and register (e.g. "casual", "academic", "playful").
  - **Pretense** — framing / roleplay context (e.g. "treat me as a beginner", "I work in finance").
  - **Manner** — etiquette norms (e.g. "always include cultural notes", "never explain unless asked").
- Concatenated under a stable header at request time (`# User preferences\n...`) and appended to the core prompt.
- Validated for length (max ~500 chars per field) and stripped of any tokens that look like role tags (`assistant:`, `system:`) to prevent prompt injection of system-level instructions.

This separation means the core contract stays stable across user customization, and breakage from a malformed user overlay is contained — at worst the LLM still returns valid JSON, just with the wrong tone.

### 5.4 Glotty Popup **[Swift]**
- `NSPanel` with `.nonactivatingPanel` style mask so the source app keeps focus and selection.
- Positioned near the cursor with screen-edge clamping.
- ESC dismisses; click-outside dismisses; auto-dismiss after 8s of inactivity (configurable).
- Renders `TranslationResult` from Rust + a string from `Engine.personality_message(...)`. UI is reactive: shows a spinner while the Rust async call is in flight.

### 5.5 Personality Engine **[Rust core + Swift LLM hook]**

Because the deployment target is macOS 26 on Apple Silicon, **`FoundationModels` is baseline, not a stretch goal**. Two backends, both available on day one:

**Primary — Apple `FoundationModels` (Swift):** Rust requests a free-form message via a Swift `LLMProvider` callback that wraps `LanguageModelSession`. Free, on-device, ~3B-param model. Default for the personality message and `Fn → E` (example sentence).

**Fallback — Templates (Rust):** Used if the user disables Apple Intelligence in System Settings, or if a `FoundationModels` call fails. Rule-based, deterministic. Inputs carried in `PersonalityContext` over FFI:
- total translation count
- current streak (consecutive days with ≥1 translation)
- recent target languages
- whether the current word has been seen before
- time of day (Swift passes `Date.now`; Rust does no clock reads, for testability)

Templates ship as a JSON resource embedded via `include_str!`.

**Optional — Cloud LLM (Claude / GPT):** Same `LLMProvider` callback, backed by an HTTP client. Off by default, requires API key + privacy disclosure. Rationale: only if the user wants something richer than `FoundationModels` produces.

The Rust core is agnostic about which backend served the message — it calls `LLMProvider.generate(prompt)` and gets a string. The `personality_message(...)` FFI surface is stable across all three modes.

### 5.6 Memory & Review **[Rust]** (UI **[Swift]**)
- Every translation event written by Rust to SQLite (`translations` table).
- SM-2-lite scheduler in Rust updates `review_state` on each grading.
- Swift menu bar → "Review" calls `Engine.review_due(20)` and renders a SwiftUI flashcard view that posts grades back via `Engine.record_review(...)`.

### 5.7 Menu Bar Item **[Swift]**
- History search → `Engine.search_history(query, limit)` (FTS5 query lives in Rust).
- Settings UI in SwiftUI; values serialized to a `Settings` struct passed back to Rust on change.
- Stats page reads aggregate counts from a Rust-side `Engine.stats()` call.

**Settings panes:**
- *Languages* — native language + study languages list (see §5.8). Active study language selector.
- *Hotkey* — leader vs chord vs classic, key bindings (per-command rebind UI per §5.1.2), Fn passthrough mode.
- *Translation provider* — picker for active provider (Apple / DeepL / Google / Claude / GPT) + fallback chain editor + API key entry per cloud provider.
- *Personality / LLM* — picker for `FoundationModels` / templates / Claude / GPT + persona/style/pretense/manner overlay editor (§5.3.4).
- *TTS* — picker for `AVSpeechSynthesizer` / ElevenLabs + voice selection per language.
- *Privacy* — clear-history button + running monthly cost meter for cloud providers (informational only, no cap — §12.3 #9). (Private-mode toggle deferred — see §12.)
- *About* — version, update channel.

### 5.8 Onboarding & Language Settings **[Swift]**

First launch presents a 3-step wizard, then the app drops into the menu bar.

**Step 1 — Permissions:**
- Explain what Accessibility and Input Monitoring are for, with screenshots of the prompt destinations in System Settings.
- Two "Open System Settings" deep links, one per permission.
- "Skip for now" option (some commands will degrade — explained in copy).

**Step 2 — Languages:**
- **Native language** — single-select. Pre-filled from `NSLocale.current` as a hint, but the user must explicitly confirm. Used as the default *target* for translations (i.e. translate *into* the user's native language).
- **Study languages** — multi-select list, ordered. The first one is the *active* study language (the default *source* for translations); others are alternates the user can quick-switch between via the Languages settings pane or a `Fn → L` cycle command (future).
- Both lists fully editable post-onboarding in Settings → Languages. Study languages can be added, removed, or reordered at any time without touching translation history.
- Glotty is **language-pair-agnostic**: there is no special-cased pair anywhere in code. Adding a new study language adds it everywhere automatically.

**Step 3 — Provider defaults:**
- Confirm the default backends (Apple `Translation` + `FoundationModels` + `AVSpeechSynthesizer`) — single screen with "Use defaults" or "Customize now."
- Customize now jumps to the Provider settings pane; Use defaults closes the wizard.

The wizard never asks for an API key — that's deferred until the user actively switches to a cloud provider.

---

## 6. Data Model (SQLite)

```sql
CREATE TABLE translations (
  id              INTEGER PRIMARY KEY,
  source_text     TEXT    NOT NULL,
  source_lang     TEXT    NOT NULL,   -- BCP-47
  target_lang     TEXT    NOT NULL,
  translated_text TEXT    NOT NULL,
  phonetic        TEXT,
  provider        TEXT    NOT NULL,
  created_at      INTEGER NOT NULL,   -- unix epoch
  app_bundle_id   TEXT                -- where user grabbed it from
);

CREATE TABLE review_state (
  source_text     TEXT PRIMARY KEY,
  source_lang     TEXT NOT NULL,
  ease            REAL NOT NULL DEFAULT 2.5,
  interval_days   INTEGER NOT NULL DEFAULT 1,
  due_at          INTEGER NOT NULL,
  reps            INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- User language profile (set during onboarding §5.8, mutable in Settings)
CREATE TABLE user_languages (
  bcp47       TEXT    PRIMARY KEY,        -- e.g. "zh-Hans", "en", "es"
  role        TEXT    NOT NULL CHECK(role IN ('native', 'study')),
  position    INTEGER NOT NULL,           -- ordering within role; role='native' has only one row
  added_at    INTEGER NOT NULL
);

CREATE VIRTUAL TABLE translations_fts USING fts5(
  source_text, translated_text, content='translations', content_rowid='id'
);
```

DB lives at `~/Library/Application Support/Glotty/glotty.sqlite`. Encrypted at rest via macOS FileVault (default on modern Macs); no app-level encryption in v1.

---

## 7. External Integrations

| Service       | Purpose                  | Auth                | Tier | Failure mode                                            |
|---------------|--------------------------|---------------------|------|----------------------------------------------------------|
| (none)        | Apple `Translation` framework — primary translation | n/a (on-device)    | 1   | Apple model unavailable for pair → fall to DeepL.        |
| (none)        | Apple `FoundationModels` — personality + examples    | n/a (on-device)    | 1   | Intel Mac / AI disabled → fall to template engine.       |
| DeepL API     | Cloud translation fallback | API key (Keychain)  | 2   | Fall back to Google.                                     |
| Google Translate v3 | Cloud translation last resort | API key (Keychain) | 3   | Show error in popup; queue for retry.                   |
| Anthropic / OpenAI | Optional cloud LLM for personality + examples | API key (Keychain) | opt-in | Fall back to template engine; user notified once.   |
| ElevenLabs    | Optional premium TTS      | API key (Keychain)  | opt-in | Fall back to `AVSpeechSynthesizer`.                    |

All API keys stored in macOS Keychain (`kSecClassGenericPassword`), never in plist or DB. **The default v1 install needs zero API keys** — Tier 1 covers the happy path entirely on-device.

---

## 8. Security & Privacy

- **TCC permissions requested:** Accessibility (selection grab + injected `Esc` for Fn passthrough suppression), **Input Monitoring** (required by the `CGEventTap` that implements the leader-key model — see §5.1).
- **Data egress (default settings):** **none.** Default backends are all on-device (Apple `Translation`, `FoundationModels`, `AVSpeechSynthesizer`).
- **Data egress (when user picks a cloud backend):** highlighted text + language pair sent to the chosen provider only. Each provider switch in Settings shows a one-time disclosure of where data will go. No telemetry, no analytics ever.
- **Local storage:** plain SQLite under user's home directory; relies on FileVault.
- **Keychain:** used **only when the user adds a cloud provider API key**. No Keychain entries are created in the default install. When used: stored as `kSecClassGenericPassword` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **Privacy policy:** can state truthfully that v1 makes no network calls in the default configuration. Cloud providers' data-retention terms only need disclosure once the user opts in.

---

## 9. Performance Budget

| Stage                            | Target  |
|----------------------------------|---------|
| `Fn` press → command HUD visible | < 50ms  |
| Command key → selection captured | < 30ms  |
| Cache hit → popup visible        | < 80ms  |
| Cache miss → popup visible       | < 600ms (network bound) |
| Leader timeout (passthrough)     | 600ms (configurable 300–1000ms) |
| Memory footprint (idle)          | < 60MB  |
| CPU (idle, no popup)             | < 0.2% (event tap adds slight overhead vs. Carbon) |

---

## 10. Risks & Mitigations

| Risk                                                     | Likelihood | Impact | Mitigation                                                                  |
|----------------------------------------------------------|------------|--------|------------------------------------------------------------------------------|
| Accessibility permission friction                        | High       | High   | First-run onboarding screen with clear "why," deep link to System Settings.  |
| Some apps refuse AX selection reads (Electron, Java)     | Medium     | Medium | Cmd+C fallback with pasteboard restore.                                      |
| `Fn` not registrable via Carbon hotkey API               | Confirmed  | Med    | Use `CGEventTap` + Input Monitoring permission (§5.1); document in onboarding. |
| `Fn` leader collides with native macOS Fn behavior        | High       | Med    | 600ms passthrough timer + opt-in "exclusive Fn" mode + Classic-mode fallback (§5.1.3, §5.1.4). |
| Input Monitoring permission scares users off              | Med        | High   | Onboarding screen explains exactly what we read and that nothing leaves the device unprompted; offer Classic mode as no-permission opt-out. |
| Translation provider rate limits / outages               | Medium     | Medium | Multi-provider fallback chain; cache hits unaffected.                        |
| Notarization rejection due to entitlements               | Low        | High   | Use only documented entitlements; test notarytool in CI early.               |
| User pastes sensitive text → leaves provider history     | Medium     | Medium | Disclose in onboarding; offer "private mode" toggle that disables logging.   |
| Rust ↔ Swift FFI boundary adds build / debug complexity   | High       | Med    | Pin uniffi version; treat the bridge as a first-class module with its own tests; CI builds both arches end-to-end.                          |
| uniffi limitation forces hand-rolled C bindings for a type | Med        | Med    | Reserve `cbindgen` + manual Swift wrappers as escape hatch (§5.0.5).         |
| Universal binary build slows iteration                    | Med        | Low    | Dev builds use host arch only; universal binary built only for release.      |
| Dual codesign (app + Rust dylib) trips notarization        | Med        | High   | Validate signing in M1; script the full `notarytool` path in CI.             |

---

## 11. Roadmap

### Milestone 1 — Spike (Week 1–3)
- Cargo workspace + `glotty-core` crate skeleton.
- `CGEventTap` Fn-leader prototype in Swift.
- AX selection grab POC.
- **uniffi bridge bring-up**: Swift calls a Rust `translate(text)` that does a hardcoded DeepL request and returns a struct.
- Validate the universal-binary build + codesign + `notarytool` end-to-end with a stub app.
- Validate sub-300ms cached path across the FFI.

### Milestone 2 — MVP (Week 4–7)
- SwiftUI popup, menu bar item.
- Rust: SQLite persistence (rusqlite + refinery migrations) + FTS history.
- Provider trait + DeepL & Google implementations in Rust; failover chain.
- `CredentialProvider` Swift callback wired to Keychain.
- Settings UI: hotkey rebind, target language, API keys.
- Notarized DMG build.

### Milestone 3 — Cyber Pet (Week 7–9)
- Personality engine + template pack.
- Streaks, stats page.
- Spaced-repetition review window.

### Milestone 4 — Polish & Beta (Week 10–12)
- Sparkle auto-update.
- Voice playback (system TTS + optional ElevenLabs).
- Onboarding flow.
- TestFlight-equivalent beta via Sparkle appcast.

---

## 12. Resolved Decisions & Remaining Questions

### 12.1 Resolved (locked)

| # | Decision                                          | Captured in           |
|---|---------------------------------------------------|-----------------------|
| 1 | App is **language-pair-agnostic**. No Chinese-specific code paths. Apple `Translation` coverage is verified empirically for whichever pairs the user picks; DeepL is a routine fallback, not a special case. | §3.4, §5.3, §5.8 |
| 2 | Default target language = **prompted on first run**. User picks native language + ordered list of study languages; study languages mutable any time. | §5.8, schema `user_languages` |
| 3 | "Private mode" — **deferred to post-v1.** v1 is fully localized in default config (no network), so the original motivation doesn't apply. | §8, §12.2 |
| 4 | Hotkeys — every command has a built-in default **and** is rebindable per `command_id`. Defaults locked for v1 (T/E/S/R/H/?/Esc). | §5.1.2 |
| 5 | Leader HUD — **120ms show delay** so a fast `Fn`→key never flickers a HUD. Configurable 0–300ms in advanced Settings. | §5.1.3 |
| 6 | Distribution — **Developer-ID-signed `.dmg` + Sparkle** for v1. Mac App Store deferred (sandbox rules out `CGEventTap` + AX anyway). | §10, §11 |
| 7 | Provider choice is first-class — native Apple stack is the **default** but every cloud alternative is a peer in Settings, not a buried fallback. | §4, §5.3, §5.5 |
| 8 | LLM prompt architecture — **two-layer**: core prompt is embedded, hidden, versioned with the app; user overlay (persona / style / pretense / manner) is editable in Settings and concatenated at request time. | §5.3.4 |

### 12.2 Remaining

1. **Private mode** (deferred from §12.1 #3) — when we revisit, the candidate triggers are: explicit toggle in menu bar, auto-engage in known-sensitive bundle ids (1Password, banking apps, Mail compose windows). Will need a heuristic list and a "tell me when you skipped a translation" UX.

### 12.3 Newly resolved (2026-05-08)

| # | Decision                                          | Captured in   |
|---|---------------------------------------------------|---------------|
| 9 | **Cloud cost: informational only.** Surface the running monthly total in Settings → Privacy when a cloud provider is enabled. **No spend cap, no warning thresholds, no hard-stop.** Trust the user. | §5.7 |

---

## 13. Repository Layout (proposed)

```
glotty/
├── core/                              # Rust workspace
│   ├── Cargo.toml                     # workspace root
│   ├── glotty-core/
│   │   ├── Cargo.toml                 # crate-type = ["staticlib", "rlib"]
│   │   ├── glotty.udl                 # uniffi interface definition
│   │   ├── build.rs                   # invokes uniffi-bindgen-rs
│   │   ├── src/
│   │   │   ├── lib.rs                 # uniffi::include_scaffolding!
│   │   │   ├── engine.rs              # public Engine type
│   │   │   ├── translation/
│   │   │   │   ├── mod.rs
│   │   │   │   ├── provider.rs        # trait
│   │   │   │   ├── deepl.rs
│   │   │   │   └── google.rs
│   │   │   ├── storage/
│   │   │   │   ├── mod.rs
│   │   │   │   ├── migrations/        # refinery .sql files
│   │   │   │   └── models.rs
│   │   │   ├── cache.rs
│   │   │   ├── personality/
│   │   │   │   ├── mod.rs
│   │   │   │   └── templates.json
│   │   │   ├── review.rs              # SM-2
│   │   │   ├── settings.rs
│   │   │   ├── credential.rs          # CredentialProvider callback trait
│   │   │   └── error.rs
│   │   └── tests/
│   └── target/
├── Glotty.xcodeproj
├── Glotty/                            # Swift app
│   ├── App/                           # @main, AppDelegate
│   ├── Hotkey/                        # CGEventTap, leader-key state machine
│   ├── Selection/                     # AX + pasteboard grabbers
│   ├── LanguageDetect/                # NLLanguageRecognizer wrapper
│   ├── TTS/                           # AVSpeechSynthesizer wrapper
│   ├── Keychain/                      # CredentialProvider impl
│   ├── UI/
│   │   ├── Popup/                     # NSPanel + SwiftUI view
│   │   ├── MenuBar/
│   │   ├── Settings/
│   │   └── Review/                    # flashcards
│   ├── Bridge/                        # generated GlottyCore.swift + modulemap
│   └── Resources/
├── scripts/
│   ├── build-rust.sh                  # cargo + lipo + bindgen
│   └── notarize.sh
├── GlottyTests/                       # Swift tests
├── GlottyUITests/
└── doc/
    ├── PRD.md
    └── TECH.md
```

---

*End of report.*
