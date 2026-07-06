# Localization strategy

How every user-facing string in Glotty ends up in the user's language. Read
this before touching `Localizable.xcstrings`, `LocalizationCache`, or any
new `Text(...)` site.

## Two-layer lookup

Every UI string is resolved in this order:

1. **`LocalizationCache`** — LLM-filled translations persisted to
   `~/Library/Application Support/Glotty/ui-translations.json`. Shape:
   `[language: [sourceString: translation]]`.
2. **Foundation's `Localizable.xcstrings`** — hand / script-curated
   translations bundled with the app.

Order is deliberate: Foundation wins when it has a translation. The LLM
cache only fills strings the catalog hasn't shipped a translation for.
This guards against a bad LLM rewrite clobbering a carefully-worded
catalog entry.

## Bundle swizzling does the routing

`BundleSwizzle.installOnce()` runs at launch and swaps
`Bundle.localizedString(forKey:value:table:)` with a hook that:

- Records every key into `LocalizationCache.encounteredSources` — the
  "what does this app actually display" set, persisted alongside the
  cache so a language switch can pre-translate everything we've ever
  rendered.
- Returns a cache hit if present.
- Falls through to Foundation. If Foundation returns the key unchanged
  (= no translation shipped for this language), queues the string for
  LLM filling via `LocalizationCache.queueMissingForTranslation` and
  returns the English fallback in the meantime.
- A `LocalizationCache.didUpdateNotification` fires when an LLM fill
  batch completes; the `.localizationAware()` view modifier
  re-renders SwiftUI roots so the English-fallback strings flip to
  the new language without a restart.

## SwiftUI binding rules

The Foundation hook only fires for code paths that actually go through
`Bundle.localizedString`. SwiftUI takes some of these but not others:

- `Text("literal")` — Swift infers `LocalizedStringKey`, routes through
  the swizzle. **Translates.** ✅
- `Text(variable)` where `variable: String` — uses the
  `StringProtocol` overload, **bypasses** the swizzle. Won't
  translate.
- Same bypass applies to `Button(variable)`,
  `LabeledContent("Label", value: variable)`, `Picker` row labels
  built from `option.name`, `NSAlert.messageText`, enum methods that
  `return "Some string"`.

For these bypass cases, opt in explicitly:

- Wrap with the `String.t` extension: `Text(variable.t)`.
- Or use `String(localized: "…")` at the source of the string so the
  literal goes through the catalog at construction time, not at
  render time. Prefer this for enum `displayName` / `description`
  switches.

## Format strings, not prefix concat

Any string that interpolates dynamic content must use a single format
string with `%@` / `%d` placeholders. **Never** glue a localized
prefix in front of a value with `+` or `\()` — word order isn't
universal.

Cautionary tales we hit in this codebase:

- ❌ `"\(String(localized: "Explain in")) \(lang)"` →
  Chinese translation came out as `"解释（用" + "中文"` = a literal
  stray `(`. The translator put an opening paren on the prefix
  expecting the language to close it, but Swift's `+` doesn't.
- ✅ `String(format: String(localized: "Explain in %@"), lang)` →
  Chinese key `"用%@解释"` puts the placeholder before the verb.
- ❌ `"\(n) memor\(n == 1 ? "y" : "ies") · always injected"` →
  English-specific plural switch baked into the key. Catalog gets
  two near-identical entries; Chinese / Japanese / Korean don't
  distinguish.
- ✅ `String(format: String(localized: "%d memories · always injected"), n)` →
  one key per locale, plural irrelevant.

## Two unrelated "language" axes

Deliberately separate, with separate `UserDefaults` keys:

- **`glotty.user.nativeLanguage`** — what the user *speaks*. Drives
  translation direction, prompt content, default polish target, etc.
  Picker lives in Profile.
- **`SystemLanguageManager`** — what Glotty's *own UI renders in*.
  Writes `AppleLanguages` at launch via `applyAtLaunch()` so
  Foundation localization picks up the choice on the next bundle
  resolution. Picker lives in System.

Switching the UI language kicks off an LLM batch translation of
everything `encounteredSources` has recorded, then relaunches.

## One language list app-wide

`LanguageOptions.all` is the single source of truth for every picker
(Profile native, Translation source/target, Polish output, popup
"Reply in", popup footer target swap). Use
`LanguageOptions.localizedName(for: identifier)` for the row label —
that's a thin wrapper over `Locale.current.localizedString` (which
already knows every language name in every locale), not `.t` or the
LLM cache.

The only exception is `SystemLanguage.displayName`, which uses
autoglossonyms ("中文", "English", "日本語") so users can find their
own language even if they can't read the current UI.

## Manual override paths

When the LLM produces a poor translation:

- **`scripts/patch-translations.py`** — Python helper to upsert /
  delete entries in `Localizable.xcstrings` directly. Used when we
  notice a bad translation in a screenshot and want to lock in the
  fix.
- **Settings → System → "Refresh translations"** — re-runs the LLM
  filler against the current language ignoring the cached results.
  The prompt picks up the user's accepted memories
  (Settings → Memory → Accepted), so a memory like
  `prefer 「润色」 over 「打磨」 for Polish` steers wording.

## Auditing workflow

`SettingsSnapshotter` captures bitmaps of any Settings tab plus the
Fn-leader HUD into `/tmp/glotty-screenshots/`. Triggered from bash
via `DistributedNotificationCenter` — no UI button, no special
permissions, agent-friendly.

```bash
# All tabs + HUD
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.ruojunye.glotty.captureAllSettingsTabs"), object: nil, userInfo: nil, deliverImmediately: true)'

# Specific tabs, skip HUD
swift -e 'import Foundation; let info: [String: String] = ["tabs": "memory,polish", "includeHUD": "false"]; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.ruojunye.glotty.captureAllSettingsTabs"), object: nil, userInfo: info, deliverImmediately: true)'
```

Comparing the PNGs against the expected locale is how we spot
leftover English. **There is no user-facing "capture" button** —
end users never need it.

Caveat: the bitmap path doesn't capture `NavigationSplitView`
sidebar labels reliably. Sidebar tab names are translated at
runtime through `.t`, they just don't show up in audit shots.

## What we deliberately don't translate

- Dictionary product names from macOS (`Oxford Dictionary of English`,
  `Simplified Chinese - English`) — those come from system, not us.
- LLM-produced mistake category labels (`Word choice`, `Verb tense`,
  `用词不当`) — stored verbatim as historical data; translating them
  would break aggregation and rewrite past records.
- User-typed content: display names, "notes for Glotty", chat history
  text, polish source / output.

The catalog stays focused on strings Glotty itself authors.

## Will piecemeal fixes hold up when the user switches UI language?

A practical concern: when we patch a specific string (typically only
adding `en` + `zh-Hans` to the catalog), what happens for a user who
runs Glotty in Japanese / Korean / etc.?

### What auto-works for any UI language

No extra work needed for these — they're language-agnostic by
construction:

- **`LanguageOptions.localizedName(for:)`** — backed by
  `Locale.current.localizedString(forIdentifier:)`, which knows every
  language name in every locale. The Polish-output picker, popup
  footer, Translation defaults — all show the right names without us
  shipping per-locale rows.
- **Date / time formatting** — anywhere we use
  `.dateTime.month(.abbreviated).day()` or similar Foundation format
  styles, the rendered text follows the active locale. The polish
  trend chart's x-axis is the working example: Chinese gets
  `5月18日`, English gets `May 18`, Japanese gets `5月18日`.
- **Format-string *structures*** — any string built with
  `String(format: String(localized: "Explain in %@"), value)` is
  inherently locale-friendly because each locale can put `%@` where
  its grammar wants it. The structural fix is independent of which
  locales have hand translations yet.

### What only has `zh-Hans` until someone runs the new language

Catalog entries we patched in these sessions only ship
`en` + `zh-Hans`:

- HUD format keys: `Translate to %@`, `Explain in %@`,
  `Polish to idiomatic %@`, `Chat with Glotty in %@`
- Memory section: `%d memories`, `%d memories · always injected`,
  `No suggestions yet.`, the three `MemoryExtractor.Mode`
  descriptions, `Automatic` / `Manual` / `Off`
- System tab footers: the shortened "UI language" + "Re-translates
  the UI" blurbs

When a user switches to (say) Korean, the swizzle finds no catalog
entry and queues these for `LocalizationFiller`. The filler's prompt
**explicitly instructs the LLM to keep `%@` / `%d` placeholders in
place**, so the format-string mechanics carry over.

### Failure modes to watch for in a new language

1. **Placeholder dropped** by the LLM (e.g. Korean comes back as
   `"한국어로 설명"` with no `%@`). Then `String(format:)` renders
   the format verbatim and the language name disappears. Visible
   bug, easy to spot in a screenshot.
2. **Stylistically wrong but not broken** (e.g. unnatural particle
   choice). Functional; recoverable via Refresh translations + a
   steering memory like *"prefer X over Y"*.

Both are recoverable via `scripts/patch-translations.py` once
spotted.

### How to verify for a new UI language

1. Switch UI language in Settings → System → Glotty's UI language.
2. Wait for the LLM batch fill to complete (progress shown inline).
3. The app relaunches automatically.
4. Trigger a snapshot audit:
   ```bash
   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.ruojunye.glotty.captureAllSettingsTabs"), object: nil, userInfo: nil, deliverImmediately: true)'
   ```
5. Open the relevant PNGs in `/tmp/glotty-screenshots/`
   (`hud.png`, `system.png`, `memory.png`, …).
6. For each broken entry, run `scripts/patch-translations.py` to
   lock in the right wording.

### Bottom line

- Structural fixes (single format strings, Foundation-backed names,
  unified language list) → language-agnostic, work everywhere.
- String-content fixes (catalog entries) → only verified for the
  locale we tested in (currently `zh-Hans`). Other locales inherit
  the same correct *structure* via the LLM filler, but the
  *resulting translations* need a one-time per-language audit to
  catch dropped placeholders or awkward wording.
