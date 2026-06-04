#!/usr/bin/env python3
"""Fill `Localizable.xcstrings` with LLM translations for every
shipped language, so the bundled app starts in a properly localized
state without needing the user to configure an LLM key first.

Reads source strings from the catalog, identifies entries missing
translations for any of the languages listed in `TARGET_LANGUAGES`,
sends batches to an OpenAI-compatible chat-completions endpoint,
and writes the responses back into the catalog. Existing
translations are preserved — we only fill empty entries unless
`--force` is passed.

Credentials default to picking up your in-app provider's API key
from the macOS keychain (`security find-generic-password -s
com.ruojunye.glotty -a <provider>`); override with env vars:

    OPENAI_API_KEY      — required if keychain lookup misses
    OPENAI_BASE_URL     — defaults to ZAI's coding endpoint
    OPENAI_MODEL        — defaults to glm-4.5-air (cheap + fast)

Run:
    python3 scripts/translate-catalog.py            # fill missing
    python3 scripts/translate-catalog.py --force    # overwrite all

The script is idempotent (skips already-translated entries) so it's
safe to wire into the release pipeline or run on every push.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pathlib
import subprocess
import sys
import time

import requests

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG_PATH = REPO_ROOT / "Glotty" / "Resources" / "Localizable.xcstrings"

# Languages we ship .lproj for, in priority order. Source language
# `en` is the catalog's developmentLanguage — never translated to
# itself.
TARGET_LANGUAGES = ["zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de"]

# Human-readable names the LLM understands. Used in the system
# prompt; mapping kept inline so the script has no extra deps.
LANG_NAMES = {
    "zh-Hans": "Simplified Chinese",
    "zh-Hant": "Traditional Chinese",
    "ja": "Japanese",
    "ko": "Korean",
    "es": "Spanish",
    "fr": "French",
    "de": "German",
}

# Default API config (ZAI's OpenAI-compatible coding endpoint). The
# user's keychain almost certainly has a ZAI key; if not, set
# OPENAI_API_KEY env var to whatever you have.
DEFAULT_BASE_URL = "https://api.z.ai/api/coding/paas/v4"
# glm-4.5-flash — the fast, non-reasoning model that actually works
# here. Tradeoffs found the hard way:
#   - glm-4.5-air / glm-4.5: reasoning models that burn the whole
#     max_tokens budget on hidden reasoning_content and return EMPTY
#     content (finish_reason=length) → nothing gets written.
#   - glm-4.6: returns real content but is SLOW — a single long
#     (200+ char) UI string can take >60s, and a batch of them blew
#     past even a 180s timeout, stalling on retries.
#   - glm-4.5-flash: returns the translation directly, ~20s for a
#     long string, fast enough to batch under the timeout.
DEFAULT_MODEL = "glm-4.5-flash"

# Batch size — the LLM gets N strings per call and returns N
# translations. Smaller batches use more API calls but tolerate
# parse failures better; larger batches are faster but a single
# malformed JSON wastes the whole call. 8 keeps each request well
# under the timeout even for long multi-sentence UI strings (the
# welcome-page bodies run 200+ chars; a batch of 25 of those made
# glm-4.6 exceed 60s and the whole batch timed out + retried,
# burning ~7 min and writing nothing).
BATCH_SIZE = 8
# Generous per-request timeout — a batch of long strings can take
# 60-120s on glm-4.6. Better one 120s response than five 60s
# timeouts with exponential backoff (which wrote zero).
REQUEST_TIMEOUT = 180


def load_api_key() -> str:
    """Resolve the API key from env first, falling back to
    `security find-generic-password` against Glotty's keychain.
    """
    env_key = os.environ.get("OPENAI_API_KEY")
    if env_key:
        return env_key
    for provider in ("zai", "deepseek", "openai"):
        try:
            result = subprocess.run(
                ["security", "find-generic-password",
                 "-s", "com.ruojunye.glotty",
                 "-a", provider, "-w"],
                capture_output=True, text=True, check=True,
            )
            key = result.stdout.strip()
            if key:
                sys.stderr.write(f"==> Using {provider} key from keychain\n")
                return key
        except subprocess.CalledProcessError:
            continue
    sys.exit(
        "No API key found. Set OPENAI_API_KEY, or configure a provider "
        "in Glotty (Settings → Language Model) which stores the key in "
        "keychain at com.ruojunye.glotty.<provider>."
    )


def load_catalog() -> dict:
    return json.loads(CATALOG_PATH.read_text())


def merge_into_catalog(lang: str, translations: dict[str, str]) -> int:
    """Atomically load the catalog from disk, merge `translations`
    into its `lang` localizations, write it back. Uses an advisory
    file lock (fcntl.flock) so concurrent runs targeting different
    languages don't trample each other's writes — without this, two
    parallel jobs each load the catalog, each patch their own
    language, then the second-to-save overwrites the first's work
    because their in-memory copies were stale.

    Returns the number of translations written.
    """
    if not translations:
        return 0
    # Open with r+ so we can both read and write while holding the lock.
    with open(CATALOG_PATH, "r+", encoding="utf-8") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            cat = json.load(f)
            written = 0
            for source, trans in translations.items():
                entry = cat["strings"].setdefault(
                    source, {"extractionState": "manual", "localizations": {}}
                )
                localizations = entry.setdefault("localizations", {})
                localizations[lang] = {
                    "stringUnit": {"state": "translated", "value": trans}
                }
                written += 1
            f.seek(0)
            f.truncate()
            json.dump(cat, f, indent=2, ensure_ascii=False, sort_keys=True)
            f.write("\n")
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)
    return written


def missing_for_language(cat: dict, lang: str, force: bool) -> list[str]:
    """Return source strings that lack a non-empty translation for
    `lang`. With `force=True`, returns every source string regardless.
    """
    out: list[str] = []
    for source, entry in cat.get("strings", {}).items():
        if not source:
            continue
        if force:
            out.append(source)
            continue
        unit = (entry.get("localizations", {})
                     .get(lang, {})
                     .get("stringUnit", {}))
        if not unit.get("value"):
            out.append(source)
    return out


def translate_batch(
    sources: list[str], lang: str, lang_name: str,
    base_url: str, api_key: str, model: str,
) -> dict[str, str]:
    """Send one batch of strings to the LLM and return
    {source: translation}. Translations the model couldn't produce
    (returned null or unparseable) are silently dropped — the
    catalog stays untouched for those entries and next run will
    retry them.
    """
    system_prompt = (
        f"You are a senior UI translator. Translate the given English UI "
        f"strings into {lang_name}. Rules:\n"
        f"  - Preserve placeholders like %@, %d, %1$@, {{name}}, {{0}}.\n"
        f"  - Preserve leading/trailing punctuation, ellipses (…), "
        f"newlines (\\n), tabs.\n"
        f"  - Match the formality of macOS system UI in {lang_name}.\n"
        f"  - Keep proper nouns (Glotty, App Store, macOS, iCloud) "
        f"in English.\n"
        f"  - Keep keyboard shortcut notation (Cmd, Shift, Fn, Return, "
        f"the arrows ⌘ ⇧ ⌃ ⌥ ↩) in their existing form.\n"
        f"  - For very short strings (a button label, a setting name), "
        f"use the noun/verb form that matches macOS's own translations "
        f"if a standard one exists.\n"
        f"  - Do NOT translate technical identifiers like en, zh-Hans, "
        f"set_setting, BCP-47, UUID, JSON, API.\n"
        f"  - Do NOT add quotes around the translation.\n"
        f"  - Do NOT include the English source in your output.\n"
        f"Respond ONLY with valid JSON of shape: "
        f'{{"translations": ["translated1", "translated2", ...]}} — '
        f"one entry per source string in the same order, no extra fields, "
        f"no markdown code fence."
    )
    user_payload = {
        "sources": sources,
        "target_language": lang_name,
    }
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": json.dumps(user_payload, ensure_ascii=False)},
        ],
        "temperature": 0,
        "max_tokens": 4096,
    }
    # Retry on transient errors (rate-limit + network timeout) with
    # exponential backoff. 429 is the killer when parallel jobs hit
    # the same provider — without backoff the script burns through
    # every batch in seconds and writes nothing.
    backoff = 5
    for attempt in range(5):
        try:
            r = requests.post(
                f"{base_url.rstrip('/')}/chat/completions",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json=body, timeout=REQUEST_TIMEOUT,
            )
        except (requests.Timeout, requests.ConnectionError) as e:
            sys.stderr.write(f"  ! Network error (attempt {attempt + 1}): {e}\n")
            time.sleep(backoff)
            backoff = min(backoff * 2, 120)
            continue
        if r.status_code == 429:
            sys.stderr.write(
                f"  ! Rate-limited (attempt {attempt + 1}), backing off {backoff}s\n"
            )
            time.sleep(backoff)
            backoff = min(backoff * 2, 120)
            continue
        if r.status_code >= 400:
            sys.stderr.write(f"  ! API {r.status_code}: {r.text[:200]}\n")
            return {}
        break
    else:
        sys.stderr.write("  ! All retries exhausted, skipping batch\n")
        return {}
    try:
        text = r.json()["choices"][0]["message"]["content"]
    except (KeyError, IndexError, ValueError) as e:
        sys.stderr.write(f"  ! Bad API response shape: {e}\n")
        return {}
    # Some providers wrap JSON in markdown fences even when asked
    # not to; strip defensively.
    text = text.strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.startswith("json"):
            text = text[4:].lstrip()
    try:
        parsed = json.loads(text)
        translated = parsed.get("translations", [])
    except json.JSONDecodeError as e:
        sys.stderr.write(f"  ! JSON decode failed: {e}\n  raw: {text[:300]}\n")
        return {}
    if len(translated) != len(sources):
        sys.stderr.write(
            f"  ! Length mismatch: sent {len(sources)} got {len(translated)} "
            "— skipping batch\n"
        )
        return {}
    return {
        src: trans for src, trans in zip(sources, translated)
        if isinstance(trans, str) and trans.strip()
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--force", action="store_true",
        help="Re-translate every string even if it already has a "
             "translation. Use sparingly — overwrites curated entries.",
    )
    parser.add_argument(
        "--language", default=None,
        help=f"Translate only this language (e.g. zh-Hans). "
             f"Default: all of {','.join(TARGET_LANGUAGES)}.",
    )
    parser.add_argument(
        "--batch-size", type=int, default=BATCH_SIZE,
        help=f"Strings per API call (default {BATCH_SIZE})",
    )
    args = parser.parse_args()

    base_url = os.environ.get("OPENAI_BASE_URL", DEFAULT_BASE_URL)
    model = os.environ.get("OPENAI_MODEL", DEFAULT_MODEL)
    api_key = load_api_key()
    sys.stderr.write(f"==> Endpoint {base_url}  model {model}\n")

    languages = [args.language] if args.language else TARGET_LANGUAGES
    for lang in languages:
        if lang not in LANG_NAMES:
            sys.stderr.write(f"  ! Unknown language '{lang}' — skipping\n")
            continue
        lang_name = LANG_NAMES[lang]
        # Re-read catalog at the start of each language so we see
        # any writes other concurrent processes have made.
        cat = load_catalog()
        missing = missing_for_language(cat, lang, args.force)
        if not missing:
            sys.stderr.write(f"==> {lang} ({lang_name}): nothing to do\n")
            continue
        sys.stderr.write(
            f"==> {lang} ({lang_name}): {len(missing)} strings to translate\n"
        )
        total_written = 0
        for i in range(0, len(missing), args.batch_size):
            batch = missing[i:i + args.batch_size]
            sys.stderr.write(
                f"    batch {i // args.batch_size + 1}/"
                f"{(len(missing) + args.batch_size - 1) // args.batch_size} "
                f"({len(batch)} strings)... "
            )
            sys.stderr.flush()
            t0 = time.time()
            translations = translate_batch(
                batch, lang, lang_name, base_url, api_key, model,
            )
            elapsed = time.time() - t0
            sys.stderr.write(f"{len(translations)} translated in {elapsed:.1f}s\n")
            # Save atomically via merge — concurrent runs on other
            # languages won't trample this language's writes.
            total_written += merge_into_catalog(lang, translations)
        sys.stderr.write(
            f"    {lang}: wrote {total_written} translations\n"
        )

    sys.stderr.write("\nDone. Diff Localizable.xcstrings to review, then commit.\n")


if __name__ == "__main__":
    main()
