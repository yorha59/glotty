# Mac App Store submission

The single source of truth for putting Glotty on the Mac App Store —
feasibility, prerequisites, the upload pipeline, the full release
checklist, and what to do if Apple pushes back. (Supersedes the former
`app-store-feasibility.md` and `release-checklist.md`.) For the
**Developer ID** DMG/pkg distribution track, see
[release-pipeline.md](release-pipeline.md).

App: **歌蒂 (Glotty)** · bundle id `com.ruojunye.glotty` · App Store
Connect app id `6776153971`.
Console: <https://appstoreconnect.apple.com/apps/6776153971>

## Strategy (decided)

Submit the **full-feature** code as-is and let Apple tell us what (if
anything) to change — do **not** pre-strip features based on guesses.
React to actual rejections. The Developer ID `.pkg` stays the primary
channel either way; the App Store is a parallel track.

---

## Does the sandbox break Glotty? — TESTED, and no

An earlier analysis assumed the App Sandbox would block Glotty's core
(global hotkey + reading another app's selection). **That was wrong.**
Verified 2026-06-06 on a real `app-sandbox`-signed build (GlottyLab with
`Glotty-AppStore.entitlements` injected), with the same Accessibility +
Input Monitoring grants the app already requests:

| Capability | Sandboxed result |
|---|---|
| Global Fn-leader `CGEventTap` | ✅ installs, receives, fires |
| AX selection grab (`AXUIElementCreateSystemWide` + `kAXSelectedText`) | ✅ works, clipboard untouched |
| Synthetic Cmd+C fallback grab (`CGEvent.post` into another app) | ✅ works (TextEdit), original clipboard restored |
| Apple Translation | ✅ works |
| Sandbox denials | none in any test |

So sandbox is **not** a capability blocker. (Full detail in
`memory/project_sandbox_mas_capability.md`.) The remaining App Store
concerns are non-capability — see [Known risks](#known-risks) below.

---

## Prerequisites — all DONE ✅

Recorded for disaster recovery; you shouldn't need to redo these.

- [x] **Apple Distribution certificate** (`security find-identity -v -p
      codesigning` → `Apple Distribution: Your Name (TEAMID)`). Distinct
      from the Developer ID cert used by the DMG pipeline. To recreate:
      Keychain Access → Certificate Assistant → request a CSR
      (`hemoon@outlook.com`, CN `Glotty App Store`) →
      <https://developer.apple.com/account/resources/certificates/list> →
      **+** → Software → **Apple Distribution** → upload CSR → install.
- [x] **3rd Party Mac Developer Installer certificate** (signs the `.pkg`
      wrapper App Store Connect expects).
- [x] **App Store Connect app record** — 歌蒂, `com.ruojunye.glotty`,
      id 6776153971. (One-time: Apps → **+** → New App → macOS only.)
- [x] **Mac App Store provisioning profile** (`Glotty Mac App Store`) in
      `~/Library/MobileDevice/Provisioning Profiles/`. (Two copies exist —
      harmless; one is enough.)
- [x] **App Store Connect API key** — `.p8` at
      `~/Library/MobileDevice/AppStoreConnect_AuthKey_<KEY_ID>.p8`, with
      Key ID + Issuer ID in `.env.appstore` (gitignored). App Manager role.

---

## Uploading a build

```bash
bash scripts/upload-appstore.sh
```

It archives `Glotty` (Release) with `Glotty-AppStore.entitlements`
(sandbox on) + Apple Distribution manual signing, then
`xcodebuild -exportArchive` with `destination=upload` pushes it to App
Store Connect via Transporter. On success the build appears under the app
(TestFlight / the version's Build picker) within ~5–30 min.

**Build numbers must be unique per version string.** Before each new
upload, bump `CURRENT_PROJECT_VERSION` in `project.yml`, then
`xcodegen generate`. (`MARKETING_VERSION` is the user-facing version;
`CURRENT_PROJECT_VERSION` is the build number.)

Current state: **build 3 (full-feature) uploaded 2026-06-09** — first
build with the Apple Intelligence (FoundationModels) provider and the
set-level memory injection rules. Cleared the upload-time SPI scan and is
processing → VALID. Builds 1 (2026-06-03) and 2 were earlier experiments;
all three cleared the upload-time private-API scan (Transporter "SPI
analysis").

---

## Release checklist — to actually ship

The **Submit for Review** button stays disabled until every required item
above it is green.

### Phase 1 — App-level info
*(App Store Connect → App → App Information / Pricing / App Privacy. One-time, applies to all versions.)*

- [ ] **Privacy Policy URL** (required) — host `website/privacy.html` and
      paste its URL. See [Hosting the pages](#hosting-the-privacy--support-pages).
- [ ] **App Privacy** questionnaire — suggested answers:
  - Data collected: **User Content → "Other User Content"** (the selected
    text), used for **App Functionality**, **not** linked to identity,
    **not** used for tracking.
  - Everything else **not collected** — no contacts, identifiers, usage,
    or diagnostics. Apple Translation is on-device; dictionaries + learned
    memory stay local; no account, no analytics.
- [ ] **Age Rating** questionnaire — all "None" → 4+.
- [ ] **Pricing and Availability** — price tier (or Free) + territories.
      **Ship all territories EXCEPT China mainland** for now (see
      [Regions & China](#regions--china)).
- [ ] Category — Productivity (already set in `project.yml`).

### Phase 2 — Version page (the "0.1.0" version)

- [ ] **Description** — starter copy in the [appendix](#appendix-listing-copy).
- [ ] **Keywords** (100 chars) — e.g.
      `translate,translation,language,learning,polish,explain,dictionary,vocabulary,AI`
- [ ] **Support URL** (required) — host `website/support.html`, paste URL.
- [ ] **Screenshots** (required) — Mac sizes only: `1280×800`, `1440×900`,
      `2560×1600`, or `2880×1800`. At least 1, up to 10. Capture the popup
      translating/explaining, the leader HUD, and Settings.
- [ ] **Build** — attach **build 3**.
- [ ] **Copyright** — e.g. `© 2026 Your Name`.

### Phase 3 — App Review notes (don't skip — cheapest insurance)
*(Version page → App Review Information → Notes.)* The reviewer needs to
test it, and it needs two permissions plus (for AI features) a key they
don't have. Copy-paste:

```
Glotty is a menu-bar (agent) app. To test:

1. After launch, grant the two permissions Glotty requests:
   • Accessibility  — so it can read the text you select
   • Input Monitoring — so the Fn-leader shortcut works
   (System Settings → Privacy & Security. Glotty shows an in-app
   Permissions screen guiding this.)

2. Select any text in any app, then HOLD the Fn key and press T.
   A popup translates the selection. Translation works with NO
   account and NO API key (Apple's on-device translation), so you
   can verify core functionality immediately.

3. Explain / Polish / Chat use a third-party AI provider the user
   configures with their own API key (Settings → Language Model).
   Test key: <provide a temporary key, or "available on request">.

Glotty has no login and collects no analytics. Selected text is sent
only to the AI provider the user configures, only for Explain/Polish/
Chat, using the user's own key.
```

- [ ] Provide a **test API key** (or "available on request" — but a key
      avoids a round-trip rejection).
- [ ] Reviewer **contact info**; **Sign-in required → No**.

### Phase 4 — Submit

- [ ] Build 3 attached, all sections green.
- [ ] Release option: **Manual** (you press the button after approval).
- [ ] **Add for Review → Submit for Review**.

---

## After submission — where to watch

Version status: `Waiting for Review → In Review → Pending Developer
Release / Ready for Sale` — or **Rejected**.

- **Email** on every state change.
- **Resolution Center** (in App Store Connect, on the app) — rejection
  reason + guideline number lands here; reply/resubmit from here. This is
  where the "react to rejection" loop happens.
- **Live state anytime** — the App Store Connect API (creds in
  `.env.appstore`); ask Claude to query builds/review state, no login.

First human review typically takes 1–3 days.

---

## Known risks

What review *might* flag, and the ready response — apply **only if they
actually flag it**, per the strategy.

| Risk | Likely guideline | Response |
|---|---|---|
| Private dictionary symbols `DCSGetActiveDictionaries` / `DCSCopyTextDefinition` (via `dlsym` in `Glotty/Translation/DictionaryEntry.swift`) | 2.5.1 (non-public API) | `#if !APPSTORE`-guard the `dlsym` paths; add `-D APPSTORE` to the App Store build; popup hides the dictionary section when empty. MAS build then ships without the dictionary pane. ~2h. |
| Input Monitoring (global keystroke tap) on a non-assistive app | 2.5.x / privacy | Justify in Review Notes (above): it's only the Fn-leader shortcut, not logging. If pushed, fall back to `RegisterEventHotKey` with a ⌘⇧ chord (loses the bare-Fn leader). |
| Accessibility reading other apps | 2.5.x | Standard for this app class (Magnet, TextSniper, etc.); usage string + Review Notes explain it. |

Note: the upload-time private-API scan **passed** for builds 1 and 2, so
any private-API objection would come from **human review**, not upload.

If Apple rejects on something deeper and a sandbox-legal variant is
needed, the nuclear fallback is **"Glotty Lite"**: drop the global
hotkey (→ in-window ⌘ shortcuts or a Services-menu provider), drop the
AX/Cmd+C grab (→ paste-driven input), and `#if APPSTORE` out the private
dictionary API. That's a different, weaker product (~2–4 weeks) and only
worth it if there's real App Store demand. Don't build it preemptively.

---

## Regions & China

- App Store availability is per **territory** (~175). You can ship to all.
- **Mainland China is special:** Apple requires an **ICP filing
  (ICP备案)** from MIIT, which normally needs a **Chinese business entity**
  + China-based hosting — an individual developer account can't get one
  without a Chinese company or agent. Without it, you **can't** publish to
  the China mainland storefront.
- **Taiwan, Hong Kong, Macau** are *separate* storefronts and need **no**
  ICP — ship there freely.
- **Plan:** launch all territories **except China mainland** first; treat
  China mainland as a later project (ICP + China-reachable page hosting).

---

## Hosting the privacy + support pages

The two required URLs are static pages in `website/`:
`privacy.html` (Privacy Policy URL) and `support.html` (Support URL),
plus `index.html`. No build step.

**Already published** to GitHub Pages (repo `github.com/yorha59/glotty-site`,
public, serves `main`/root) — paste these into App Store Connect:
- Privacy Policy URL → <https://glotty.hemoon.de/privacy.html>
- Support URL → <https://glotty.hemoon.de/support.html>

The `website/` files here are the source of truth; to update the live
pages, copy them into the `glotty-site` repo and push.

GitHub Pages (free, reachable by App Review — reviewers load from outside
China, so `github.io` is fine for everywhere except mainland-China users):

1. Push `website/`'s contents to a public repo (e.g. `glotty-site`).
2. Repo **Settings → Pages** → Deploy from branch → `main` / root.
3. URLs become `https://<user>.github.io/glotty-site/{privacy,support}.html`.

If you later target **mainland China**, re-host on a China-reachable host
(Gitee Pages / a China VPS / your own public domain). See
`website/README.md`.

---

## Appendix: listing copy

Ready-to-paste App Store Connect fields. Edit freely.

**Name:** Glotty

**Subtitle** (≤30 chars): `Translate & learn anywhere`

**Promotional text** (≤170): Select text in any app, hold Fn, and
translate, explain, polish, or chat — on-device translation plus the AI
provider you choose, with your own key.

**Keywords** (≤100): `translate,translation,language,learning,polish,grammar,explain,dictionary,vocabulary,tutor,AI,proofread`

**What's New** (first version): `First release of Glotty.`

**Description:**

> Glotty is a translation and language-learning companion that lives in
> your menu bar. Select text in any app — browser, PDF, docs, chat — hold
> the Fn key, and press one key:
>
> • T — Translate it into your language
> • E — Explain the meaning, grammar, and nuance
> • P — Polish your own writing into natural, idiomatic phrasing
> • C — Chat with a patient AI language tutor
>
> A small panel appears right where you're working, even over a full-screen
> app, and never steals your place.
>
> TRANSLATE, INSTANTLY
> Translation runs on-device with Apple's translation engine — fast, and
> it works with no account and no setup. You also get dictionary senses
> and a back-translation so you can trust the result.
>
> EXPLAIN, DON'T JUST TRANSLATE
> Glotty breaks down what a word or sentence really means — literal sense,
> implied meaning, real usage examples, and the grammar behind it — so you
> actually learn, not just look up.
>
> POLISH YOUR WRITING
> Drafting in a language you're learning? Polish rewrites your text into a
> few natural, idiomatic versions and shows you exactly which mistakes it
> fixed and why.
>
> PRACTICE BY CHATTING
> Chat opens a friendly tutor that keeps the conversation going in the
> language you're learning, at your level.
>
> REMEMBERS WHAT YOU LEARN
> Glotty keeps the words and phrases you look up so you can review them
> later and build real vocabulary over time.
>
> BRING YOUR OWN AI
> Explain, Polish, and Chat use the AI provider you connect with your own
> API key — OpenAI, DeepSeek, Grok, Z.AI/GLM, Gemini, and more. Your text
> goes straight from your Mac to the provider you choose; it never passes
> through our servers, because we don't run any.
>
> PRIVATE BY DESIGN
> No account. No ads. No analytics. Your API keys and learned words stay
> on your Mac.
>
> Available in English, 简体中文, 繁體中文, 日本語, 한국어, Español,
> Français, and Deutsch.

**Screenshots** (in `appstore-screenshots/`, 2880×1800 — drag into the
macOS screenshot slot in App Store Connect):

| File | Suggested caption |
|---|---|
| `01-translate.png` | Translate anything you select — instantly |
| `02-explain.png` | Meaning, grammar, and nuance — explained |
| `03-polish.png` | Polish your writing into natural phrasing |
| `04-chat.png` | Practice with a patient AI tutor |
| `05-hud.png` | One shortcut. Four ways to learn. |

These are real product captures (the headline is baked into each image).
To regenerate after UI changes, re-run the capture + composite steps; the
raw window captures use `screencapture -o -l <windowID>` and are composited
onto a 2880×1800 gradient with PIL.
