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
grep -rhE '(Text|Button|Picker|Label|LabeledContent|sectionLabel)\("([^"\\]|\\.)+"' \
    Glotty --include="*.swift" 2>/dev/null \
    | grep -oE '"([^"\\]|\\.)+"' >> "$TMP_LIST" || true

grep -rhE 'String\(localized:\s*"([^"\\]|\\.)+"' \
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
#   - escape-only strings starting with `\u{`
#   - overlong (likely concatenation noise)
sort -u "$TMP_LIST" \
    | sed 's/^"//;s/"$//' \
    | awk '
        length == 0 { next }
        /^[[:space:][:punct:]]*$/ { next }
        /^\// { next }
        /\\\(/ { next }                # interpolated template — skip
        /^\\u\{/ { next }              # starts with unicode escape
        length > 200 { next }
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
    if key.startswith("\\\\u{"):  # raw unicode escape
        return True
    if len(key) > 200:
        return True
    opens = key.count("(")
    closes = key.count(")")
    if opens != closes:
        return True
    if re.match(r'^[\\s\\W]+$', key):
        return True
    return False

# Cleanup pass — drop junk that prior extractor runs left behind.
all_strings = catalog.setdefault("strings", {})
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

print(f"Catalog now lists {len(all_strings)} strings (+{added} new, -{removed} junk)")
EOF
