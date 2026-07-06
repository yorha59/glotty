#!/bin/bash
# Scan every .swift file under Glotty/ for localizable string
# literals and merge them into Localizable.xcstrings so the LLM
# filler picks them up on next language switch.
#
# Patterns recognized:
#   Text("…")              SwiftUI text labels
#   Button("…")            single-string Button initializer
#   Button("…", role: …)
#   Picker("…", …)
#   Label("…", …)
#   LabeledContent("…", …)
#   sectionLabel("…")      Glotty internal helper
#   Section("…")           Form/List section header
#   Toggle("…", …)         toggle label
#   Stepper("…", …)        stepper label
#   TextField("…", …)      field label / placeholder
#   SecureField("…", …)    secure field label / placeholder
#   Menu("…")              menu label
#   DisclosureGroup("…")   disclosure group label
#   GroupBox("…")          group box label
#   Link("…", …)           hyperlink label
#   summary: "…"           LLM model-preset blurb (shown via Text(.t))
#   .navigationTitle("…")  window / pane title
#   .navigationSubtitle("…")
#   .help("…")             tooltip / accessibility help
#   .confirmationDialog("…", …) dialog title
#   .alert("…", …)         alert title
#   String(localized: "…") explicit Foundation localization
#   NSMenuItem(title: "…", …)
#   addButton(withTitle: "…")
#   .title = "…"           NSWindow.title and friends
#
# Caveats:
#   - Only catches LITERAL strings. Interpolated / computed
#     strings (Text(varName)) need .t wrapping at the call site;
#     they're invisible to this scanner.
#   - Doesn't deal with multi-line "…" string literals (rare in
#     UI code).
#
# Run:
#   bash scripts/extract-strings.sh
#
# Idempotent — entries already in the catalog are left alone
# (translations preserved); new strings get added with empty
# localizations so the LLM filler covers them on next switch.

set -euo pipefail
cd "$(dirname "$0")/.."

CATALOG="Glotty/Resources/Localizable.xcstrings"
TMP_LIST=$(mktemp)
trap 'rm -f "$TMP_LIST"' EXIT

# Regexes for each recognized call site. Each emits the string
# literal between the quotes. Tuned to skip strings that look
# like format placeholders, file paths, or debug logging
# (heuristic: skip strings containing only whitespace, only
# punctuation, or starting with a slash).
grep -rhE '(Text|Button|Picker|Label|LabeledContent|sectionLabel|Section|Toggle|Stepper|TextField|SecureField|Menu|DisclosureGroup|GroupBox|Link|navigationTitle|navigationSubtitle|help|confirmationDialog|alert)\("([^"\\]|\\.)+"' \
    Glotty --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

# Model-preset `summary:` descriptions. These are struct fields, not
# SwiftUI call sites, but they ARE shown in the Language Model tab
# (each preset's blurb under the model picker) via `Text(summary.t)`,
# so they need catalog coverage. Interpolated summaries (containing
# `\(…)`) are dropped by the junk filter below.
grep -rhE 'summary:\s*"([^"\\]|\\.)+"' \
    Glotty --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

grep -rhE 'String\(localized:\s*"([^"\\]|\\.)+"' \
    Glotty --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

# "literal".t — the app's PRIMARY localization call (the `.t` String
# extension routes through Bundle.localizedString). These often sit
# off a recognized SwiftUI call site — assigned to a var, returned,
# passed as an arg, used in String(format:) — so catch the literal
# directly by its `.t` suffix. Without this, `.t` strings are only
# covered by the runtime LLM cache, so a fresh install shows them in
# English. The `\.t` is anchored with a following non-identifier
# char so `.title` / `.trimmingCharacters` don't false-match.
grep -rhoE '"([^"\\]|\\.)+"\.t([^A-Za-z]|$)' \
    Glotty --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

# Ternary inside `.t` — `Text((cond ? "A" : "B").t)`. The `.t` sits
# after the closing paren, so the plain `"…".t` rule above misses the
# two branch literals. Capture both.
grep -rhoE '\?[[:space:]]*"([^"\\]|\\.)+"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)+"\)\.t' \
    Glotty --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

# Permission enum displayName / purpose — localizable strings the
# enum returns, shown via `.t` (Settings) or OSLocalizer (Welcome)
# at the call site with a VARIABLE, so the literal lives in the enum
# `return "…"` and isn't at any recognized call site. Scoped to
# Glotty/Permissions so we don't sweep in internal return strings
# from elsewhere.
grep -rhE 'return "([^"\\]|\\.)+"' \
    Glotty/Permissions --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

# OSLocalizer.string("…") — the Welcome / Translate-guide windows
# localize against the OS-preferred language (not the in-app picker)
# via this helper instead of `.t`. Same need for catalog coverage:
# a fresh install resolves these from the bundled .lproj, so they
# must be pre-translated rather than relying on the runtime LLM fill.
grep -rhE 'OSLocalizer\.string\(\s*"([^"\\]|\\.)+"' \
    Glotty --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

grep -rhE 'NSMenuItem\(title:\s*"([^"\\]|\\.)+"' \
    Glotty --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

grep -rhE 'addButton\(withTitle:\s*"([^"\\]|\\.)+"' \
    Glotty --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

grep -rhE '\.title\s*=\s*"([^"\\]|\\.)+"' \
    Glotty --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

# Dedup, strip quotes, filter junk:
#   - empty / whitespace-only
#   - pure punctuation
#   - paths
#   - interpolated fragments (contain `\(` or unbalanced `(` / `)`)
#   - SF Symbol names (e.g. `arrow.clockwise`): swept in from
#     `Label("…", systemImage: "…")` lines but never displayed as
#     text, so they must not be translated
#   - overlong (likely concatenation noise)
#
# Swift string escapes (`\u{XXXX}`, `\"`, `\\`, `\/`, `\n`, `\t`) are
# DECODED to the actual character: at runtime SwiftUI resolves the
# literal before localization, so the catalog key must hold the real
# char (e.g. `Export…`, or a straight `"`) — the raw `Export\u{2026}`
# / `\"` forms would never be looked up. `\(` is deliberately NOT
# decoded so the interpolation-fragment filter below still catches it.
sort -u "$TMP_LIST" \
    | sed 's/^"//;s/"$//' \
    | perl -CSD -pe 's{\\(u\{[0-9A-Fa-f]+\}|["\\/nt])}{my $e=$1; if($e=~/^u\{([0-9A-Fa-f]+)\}$/){chr hex $1}elsif($e eq "n"){"\n"}elsif($e eq "t"){"\t"}else{$e}}ge' \
    | awk '
        length == 0 { next }
        /^[[:space:][:punct:]]*$/ { next }
        # Symbol-only strings with no ASCII letter/digit — e.g. the
        # Unicode arrows / ellipsis (→ ▸ …) swept in from chord labels.
        # The source language is English, so every real UI string has
        # at least one ASCII alphanumeric; a string with none is a
        # bare glyph that renders identically in every locale and must
        # not be sent for translation. (ASCII [[:punct:]] above misses
        # these because they are non-ASCII symbols.)
        !/[[:alnum:]]/ { next }
        /^\// { next }
        /\\\(/ { next }                # interpolated template — skip
        /^[a-z][a-z0-9]*(\.[a-z0-9]+)+$/ { next }  # SF Symbol name — skip
        # TCC service token returned by Permission.tccServiceName: swept
        # in by the Permissions return-literal rule but used only as a
        # tccutil argument, never displayed, so it must not be translated.
        # (Accessibility is intentionally NOT skipped here: it doubles as
        # the permission display name.)
        $0 == "ListenEvent" { next }
        length > 400 { next }
        # Heuristic: real UI strings have balanced parentheses or
        # none. Fragments captured mid-interpolation often have
        # unbalanced ones. Counting is awk-friendly.
        {
            opens = gsub(/\(/, "(")
            closes = gsub(/\)/, ")")
            if (opens != closes) next
            print
        }
    ' > "${TMP_LIST}.cleaned"

echo "Discovered $(wc -l < "${TMP_LIST}.cleaned") candidate strings"

# Use Python to merge into the JSON catalog — bash + jq would
# work but Python is more readable for the merge logic and is
# present on every macOS install.
python3 - <<EOF
import json, re

CATALOG = "$CATALOG"
SOURCES_FILE = "${TMP_LIST}.cleaned"

with open(CATALOG, "r", encoding="utf-8") as f:
    catalog = json.load(f)

with open(SOURCES_FILE, "r", encoding="utf-8") as f:
    sources = [line.rstrip("\n") for line in f if line.strip()]

def is_junk(key: str) -> bool:
    """True for keys that snuck in from interpolation fragments
    or other regex noise. Filters them out from the catalog."""
    if not key.strip():
        return True
    if "\\\\(" in key:           # interpolated template fragment
        return True
    if re.match(r'^[a-z][a-z0-9]*(\\.[a-z0-9]+)+$', key):  # SF Symbol name
        return True
    if key == "ListenEvent":     # TCC service token, never displayed
        return True
    if len(key) > 400:
        return True
    opens = key.count("(")
    closes = key.count(")")
    if opens != closes:
        return True
    if re.match(r'^[\\s\\W]+$', key):
        return True
    return False

def decode_escapes(key: str) -> str:
    """Decode Swift string escapes (unicode, quote, backslash, slash,
    newline, tab) to the actual character, so a catalog key migrated
    from an older run matches the runtime-resolved localization key.
    Mirrors the perl decode applied to freshly-extracted strings."""
    def repl(m):
        e = m.group(1)
        if e.startswith("u{"):
            return chr(int(e[2:-1], 16))
        return {"n": chr(10), "t": chr(9)}.get(e, e)
    return re.sub(r'\\\\(u\{[0-9A-Fa-f]+\}|["\\\\/nt])', repl, key)

all_strings = catalog.setdefault("strings", {})

# Migration pass — older runs stored keys with raw \u{…} escapes
# that never matched at runtime. Decode them to the real character,
# carrying the existing (good) translations onto the correct key.
migrated = 0
for key in list(all_strings.keys()):
    decoded = decode_escapes(key)
    if decoded == key:
        continue
    entry = all_strings.pop(key)
    # If the decoded key already exists, keep whichever has more
    # filled-in localizations (prefer the migrated entry's data
    # only for languages the existing one lacks).
    if decoded in all_strings:
        dst = all_strings[decoded].setdefault("localizations", {})
        for lang, loc in entry.get("localizations", {}).items():
            dst.setdefault(lang, loc)
    else:
        all_strings[decoded] = entry
    migrated += 1

# Cleanup pass — drop junk that prior extractor runs left behind.
removed = 0
for key in list(all_strings.keys()):
    if is_junk(key):
        del all_strings[key]
        removed += 1

existing = set(all_strings.keys())
added = 0
for src in sources:
    if src in existing:
        continue
    all_strings[src] = { "localizations": {} }
    added += 1

with open(CATALOG, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)

print(f"Catalog now lists {len(all_strings)} strings (+{added} new, -{removed} junk, ~{migrated} migrated)")
EOF
