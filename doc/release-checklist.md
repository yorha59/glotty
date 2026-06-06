# Glotty — Mac App Store release checklist

Everything left to take Glotty from "build uploaded" to "live on the
Mac App Store." Work top to bottom; the **Submit for Review** button
stays disabled until every required item above it is green.

App: **歌蒂 (Glotty)** · bundle id `com.ruojunye.glotty` · App Store
Connect app id `6776153971`.
Console: <https://appstoreconnect.apple.com/apps/6776153971>

Strategy (decided): submit the **full-feature** code as-is and let Apple
tell us what (if anything) to change — do **not** pre-strip features. See
the risk table at the bottom for the two things most likely to come back.

---

## Status — already done ✅

- [x] Apple Distribution cert + 3rd Party Mac Developer Installer cert in keychain
- [x] Mac App Store provisioning profile (`Glotty Mac App Store`)
- [x] App Store Connect API key (`.p8` + `.env.appstore`)
- [x] App Store Connect **app record** exists (歌蒂, id 6776153971)
- [x] **Build 2 uploaded and VALID** (full-feature, current code, sandboxed)
- [x] Sandbox capability verified locally — event tap, AX grab, Cmd+C
      fallback, Apple Translation all work (see
      `memory/project_sandbox_mas_capability.md`)

To upload a **new** build later: bump `CURRENT_PROJECT_VERSION` in
`project.yml` (build numbers must be unique per version), `xcodegen
generate`, then `bash scripts/upload-appstore.sh`.

---

## Phase 1 — App-level info
*(one-time; applies to every version. App Store Connect → App → "App Information" / "Pricing and Availability" / "App Privacy")*

- [ ] **Privacy Policy URL** — required. Needs a publicly hosted page.
      Minimum it must state: Glotty sends the text you select to the
      LLM provider **you** configure (OpenAI/DeepSeek/Grok/etc.) only
      when you invoke Explain/Polish/Chat; translation uses Apple's
      on-device framework; learned vocabulary/memory is stored locally
      on your Mac; Glotty has no account and collects no analytics.
- [ ] **Subtitle** (30 chars, optional but recommended)
- [ ] **Category** — Productivity (already set in `project.yml`); confirm
      a secondary category if you want one (Reference / Education fit).
- [ ] **App Privacy** questionnaire — see the suggested answers below.
- [ ] **Age Rating** questionnaire — Glotty has no objectionable content;
      answer all "None" → expect 4+. (Note: user-entered text goes to a
      third-party LLM, but that's not an age-rating field.)
- [ ] **Pricing and Availability** — set price tier (or Free) and
      territories. Required before submission.

### Suggested App Privacy answers

Glotty has no account and no analytics SDK. The one data flow is: the
**text you select** is transmitted to the LLM provider you configured
(with your own API key) when you run Explain/Polish/Chat.

Conservative, defensible declaration:

- **Data collected:** *User Content → "Other User Content"* (the
  selected text).
  - Used for: **App Functionality**.
  - Linked to identity: **No** (no account, no identifier sent by Glotty).
  - Used for tracking: **No**.
- Everything else: **not collected** — no contact info, no identifiers,
  no usage data, no diagnostics. Apple Translation is on-device;
  dictionaries and learned memory stay local.

(If you'd rather argue you don't "collect" it at all — the text goes
directly from the user's Mac to the provider they chose, with their key,
never to your servers — that's a reasonable position, but the line above
is the safer one and won't trigger follow-up questions.)

---

## Phase 2 — Version page (the "0.1.0" version)
*(App Store Connect → App → the version in the left sidebar)*

- [ ] **Promotional text** (170 chars, optional, editable without review)
- [ ] **Description** — what Glotty does. Draft starter below.
- [ ] **Keywords** (100 chars, comma-separated) — e.g.
      `translate,translation,language,learning,polish,explain,dictionary,vocabulary,LLM,AI`
- [ ] **Support URL** — required (a page where users can get help; can be
      a simple GitHub/site page).
- [ ] **Marketing URL** (optional)
- [ ] **Screenshots** — **required**. Mac screenshots must be exactly one
      of: `1280×800`, `1440×900`, `2560×1600`, `2880×1800`. At least 1,
      up to 10. Capture the popup translating/explaining, the leader HUD,
      and Settings.
- [ ] **App icon** — pulled from the build automatically; confirm it shows.
- [ ] **Build** — click "Add Build" / the (+) and select **build 2**.
- [ ] **Copyright** — e.g. `© 2026 Simon Zu`
- [ ] **What's New** — only required for updates, not the first version.

### Description (starter — edit freely)

> Glotty is a translation and language-learning companion that lives in
> your menu bar. Select text in any app, hold the Fn key, and press one
> key:
>
> • **T — Translate** into your language, with dictionary senses
> • **E — Explain** the meaning, grammar, and nuance
> • **P — Polish** your own writing into natural, idiomatic phrasing
> • **C — Chat** with a patient language tutor
>
> Translation runs on-device with Apple's translation engine. Explain,
> Polish, and Chat use the AI provider you connect (OpenAI, DeepSeek,
> Grok, and more) with your own API key — your text goes straight to the
> provider you choose, never through our servers. Glotty remembers the
> words you look up so you can review them later.

---

## Phase 3 — App Review notes (do not skip — cheapest insurance)
*(Version page → "App Review Information" → Notes)*

The reviewer needs to be able to actually test Glotty, and it needs two
system permissions plus (for AI features) an API key they don't have.
Spell it out. Copy-paste starter:

```
Glotty is a menu-bar (agent) app. To test:

1. After launch, grant the two permissions Glotty requests:
   • Accessibility  — so it can read the text you select
   • Input Monitoring — so the Fn-leader shortcut works
   (System Settings → Privacy & Security. Glotty shows an in-app
   Permissions screen guiding this.)

2. Select any text in any app, then HOLD the Fn key and press T.
   A popup translates the selection. Translation works with NO
   account and NO API key (it uses Apple's on-device translation),
   so you can verify core functionality immediately.

3. The Explain / Polish / Chat features use a third-party AI provider
   that the user configures with their own API key (Settings →
   Language Model). A working OpenAI-compatible test key:
   <provide a temporary key here, or say "available on request">.

Glotty has no login. It does not collect analytics. Selected text is
sent only to the AI provider the user configures, only for Explain/
Polish/Chat, using the user's own key.
```

- [ ] Fill in a **test API key** (or write "available on request" — but a
      key avoids a round-trip rejection).
- [ ] **Contact info** (first/last name, phone, email) for the reviewer.
- [ ] **Sign-in required?** → **No** (Glotty has no account).

---

## Phase 4 — Submit

- [ ] Confirm **build 2** is attached and all sections show green.
- [ ] Choose release option: **Manual release** (recommended — you press
      the button after approval) vs. Automatic.
- [ ] Click **Add for Review** → **Submit for Review**.

---

## After submission — where to watch & what to expect

Version page status moves through:
`Waiting for Review → In Review → Pending Developer Release / Ready for Sale`
— or **Rejected**.

- **Email** — Apple notifies on every state change.
- **Resolution Center** (in App Store Connect, on the app) — if rejected,
  the **reason + guideline number** appears here; you reply and resubmit
  from here. This is where the "react to rejection" loop happens.
- **Live state anytime** — ask Claude to query the App Store Connect API
  (no login needed); see `scripts/upload-appstore.sh` env for creds.

First human review typically takes 1–3 days.

---

## Known risk items (what review might flag, and the ready response)

| Risk | Likely guideline | Response (only if they actually flag it) |
|---|---|---|
| Private dictionary symbols `DCSGetActiveDictionaries` / `DCSCopyTextDefinition` (via `dlsym` in `Glotty/Translation/DictionaryEntry.swift`) | 2.5.1 (non-public API) | `#if !APPSTORE`-guard the `dlsym` paths; add `-D APPSTORE` to the App Store build; popup hides the dictionary section when empty. ~2h. MAS build then ships without the dictionary pane. |
| Input Monitoring (global keystroke tap) on a non-assistive app | 2.5.x / privacy | Justify in Review Notes (already covered above): it's only the Fn-leader shortcut, not logging. If pushed, fall back to `RegisterEventHotKey` with a ⌘⇧ chord (loses the bare-Fn leader). |
| Accessibility used to read other apps | 2.5.x | Standard for this app class (Magnet, TextSniper, etc.); the usage string + Review Notes explain it. |

Note: the upload-time private-API scan (Transporter "SPI analysis")
**passed** for both build 1 and build 2 — so any private-API objection
would come from **human review**, not the upload.

---

## One-time housekeeping (optional, low priority)

- [ ] Remove the **duplicate** `Glotty Mac App Store` provisioning
      profile (two exist; harmless, but one is enough) at
      <https://developer.apple.com/account/resources/profiles/list>.
- [ ] Decide whether the MAS build and the Developer ID `.pkg` track stay
      dual-track long-term (recommended: Dev ID primary, MAS secondary).
