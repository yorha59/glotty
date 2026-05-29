# Polish mistake categories — design

Status: **draft, not implemented**. Captures the design discussion so we
don't lose it before we ship the implementation.

## The problem

Glotty's Polish flow asks the LLM to flag grammar / usage issues in the
user's draft and tag each one with a short `category` label ("Word
choice", "Verb tense", etc.). Those categories are persisted into
`MemoryStore` as part of each `MemoryEvent` and aggregated for the
"Common mistake types" section in Settings → Polish.

Today, the category vocabulary is **hardcoded in English inside the
polish prompt template** (see `PolishPrompt.defaultProofreadTemplate` —
the list interpolated as "Pick one of these when possible: 'Article
usage', 'Subject-verb agreement', …"). This works fine while Glotty only
supports English as a Polish output language. It breaks the moment a
user picks Chinese, Japanese, or anything else:

- The LLM is told to use English category labels even though the rest
  of its output is in the target language → inconsistent and unhelpful.
- Categories themselves are language-specific. Chinese has no
  "Spelling" (alphabetic spelling); English has no "Measure-word
  usage"; Japanese has no "Subject-verb agreement"; etc. A fixed
  English list is the wrong list for most target languages.
- Since categories are stored verbatim, mixing English and target-language
  categories in the same aggregate buckets is meaningless — same kind
  of mistake gets counted under two different labels.

## What "categories" actually do

They serve two purposes simultaneously, and the design has to honor both:

1. **Tag polish issues for aggregation** — so "Common mistake types"
   can show "you keep doing X" trends. Requires stable strings; the
   same kind of mistake must produce the same label across polishes
   so counts add up.
2. **Hint to the LLM what kinds of mistakes to flag** — so the model
   doesn't reinvent its own taxonomy on every call. Requires curated
   lists appropriate to the target language.

## Options considered

### A. Status quo (hardcoded English list in prompt)

- **Where:** `PolishPrompt.defaultProofreadTemplate`
- **When:** at every polish call
- **Pros:** zero infra
- **Cons:** English-only; LLM may invent new strings each call (drift);
  inappropriate for non-English targets

### B. Hand-curated per-language list

- **Where:** Swift dictionary `[lang: [String]]` shipped with the app
- **When:** at build time
- **Pros:** fast, predictable, consistent strings, no extra LLM calls
- **Cons:** requires linguistic expertise per language; new languages
  mean us doing more work; the long tail (Vietnamese, Thai, Arabic, …)
  is hard to staff

### C. LLM-bootstrapped once per language

- **Where:** generated on first polish in that target language,
  persisted to disk so the second polish reuses it
- **When:** lazy — only when a brand-new language is targeted
- **Pros:** scales to any language for free; categories are
  language-appropriate without us knowing the language
- **Cons:** extra LLM call on the very first polish in a new language;
  LLM may produce mediocre / incomplete starter lists; one-shot
  bootstrap may not catch important categories the LLM only learns
  about later

### D. Hybrid (recommended)

Combine B and C:

- Hand-curate categories for the 4–5 polish target languages we
  prioritize (English, Chinese Simplified, Japanese, Spanish, French
  — match the user base we expect at launch). Linguist-grade lists.
- For everything else, fall back to LLM bootstrap (C). Cache the
  result so we only pay the bootstrap cost once per language per user.

## Consistency mechanism (cross-cutting)

Regardless of which option above provides the *seed* list, we need a
mechanism to prevent category drift inside the LLM. Currently the LLM
can invent new labels per call ("Word choice" one time, "Wrong word"
the next, "Lexical mistake" the third). The aggregator treats those as
three different categories.

**Mechanism:** pass the user's already-seen categories for this language
into every polish prompt and tell the LLM "prefer these existing
categories; only invent a new one if none fit." Effectively a one-shot
consistency layer in the prompt itself.

Code sketch:

```swift
let seen = MemoryStore.shared.knownCategories(for: targetLang)
let suggested = PolishCategoryLibrary.suggested(for: targetLang)  // hand-curated OR bootstrapped
let categoriesForPrompt = (seen + suggested).deduplicated()
PolishPrompt.build(text:, mode:, categoryList: categoriesForPrompt)
```

The same category string ends up reused across polishes → aggregates
mean something.

## Storage / scoping (cross-cutting)

Aggregation also needs to be language-scoped. `MemoryEvent.targetLang`
already exists; we just need to use it.

- `MemoryStore.topGrammarIssues(limit:since:language:)` — add a
  `language:` filter so only events whose `targetLang` matches the
  current view contribute to the aggregate.
- `PolishCommonMistakesSection` — pass the active polish output
  language (the `glotty.polishLang` setting) by default. Optionally
  expose a picker if the user wants to inspect mistakes for a
  different language.

Without scoping, an English "Word choice" and a Chinese "用词" would
be aggregated as two distinct buckets — useless.

## Migration / old data

Existing polish events stored in `history.jsonl` use English category
strings (because the current prompt forces English). Don't try to
translate or rewrite them — they're historical records of what the
LLM actually produced at the time. Once language scoping is in place,
those records contribute to the English aggregate and naturally roll
out of recent windows as the user does more polishes in their actual
target language.

## Recommended implementation order

1. `PolishCategoryLibrary` — new module. Hand-curated dictionary for
   en / zh-Hans / ja / es / fr. Public API: `suggested(for: String) -> [String]?`
   returning `nil` when no curated list exists.
2. LLM-bootstrap module — `func bootstrapCategories(for: String) async -> [String]`
   that calls the LLM once, parses a JSON array, caches to
   Application Support / Glotty / polish-categories-<lang>.json.
3. `MemoryStore.knownCategories(for: lang) -> Set<String>` — pulls
   distinct categories from existing events in that language. Used
   by the consistency mechanism.
4. `PolishPrompt.build` — take a `categoryList: [String]` parameter
   instead of hardcoding. Caller resolves which list (seen +
   curated/bootstrapped, deduplicated).
5. `MemoryStore.topGrammarIssues` — add `language:` filter.
6. `PolishCommonMistakesSection` — pass `glotty.polishLang` as the
   filter; optionally add picker for cross-language inspection.

## Open questions

- **Bootstrap quality:** is a one-shot LLM call good enough to produce
  a representative category list, or do we want a small in-prompt
  example set (a few canonical mistakes the LLM categorizes, used as
  evidence)?
- **User-curated categories:** should users be able to add / rename /
  hide categories? Probably yes eventually — but not in v1.
- **Cross-language migration:** if a user changes their polish target
  language, do we surface a hint saying "old mistake aggregates are
  scoped to your previous target"? Or silently let them age out?
  Lean toward the latter; mention in a future Settings tooltip.
