# App Store submission

> **Status note (2026-06-06):** the four prerequisites below are all DONE,
> and **build 2 is uploaded and VALID** on App Store Connect. For the
> remaining steps to actually ship (metadata, App Privacy, screenshots,
> review notes, Submit for Review) see **[release-checklist.md](release-checklist.md)**.
> Also: the "What we don't know yet" section at the bottom is now
> answered — the sandboxed event tap, AX grab, and Cmd+C fallback were
> all verified working (see `memory/project_sandbox_mas_capability.md`).
> This file is kept for the one-time portal setup history.

How to take Glotty's current code and put it in front of Apple's
App Review process. The goal of the first submission is empirical:
learn what Apple actually flags (likely the Dictionary Services
`dlsym` calls, possibly the `CGEventTap` hotkey) rather than rely
on speculation. After we see what they reject, we can decide
whether to rework or shelve the App Store track.

The code in `scripts/upload-appstore.sh` builds + signs + uploads.
Before it can run, you need to set up four things at Apple's
developer portals. Each is ~5 minutes of clicking.

## 1. Apple Distribution certificate

Different from your Developer ID Application cert (which the
Dev ID DMG pipeline uses). The naming is similar enough to be
confusing — Apple Distribution is what App Store submissions sign
against.

1. Make sure you're on this Mac (the one with your Apple ID +
   keychain set up).
2. **Keychain Access** → menu bar → **Certificate Assistant** →
   **Request a Certificate From a Certificate Authority…**
3. Same form as for Developer ID:
   - User Email: `hemoon@outlook.com`
   - Common Name: `Glotty App Store`
   - **Saved to disk**
4. Save the `.certSigningRequest` file.
5. Go to <https://developer.apple.com/account/resources/certificates/list>
6. **+** button → under **Software**, select **Apple Distribution**
   (this is the option that says "Sign your apps for submission to
   the App Store"). Click Continue.
7. Upload the CSR, download the `.cer`, double-click to install.
8. Verify: `security find-identity -v -p codesigning` should now
   show:
   ```
   "Apple Distribution: Simon Zu (47D8DFFZQ4)"
   ```

If the menu doesn't show "Apple Distribution" as an option:
- You might need to be the Account Holder of the Developer Program
  account (typically yes for individual accounts).
- Some older Apple Developer accounts had "Mac App Distribution"
  as a separate option; the modern unified name is "Apple
  Distribution" and works for both iOS and macOS App Stores.

## 2. App Store Connect record

This is the "app listing" Apple needs to associate uploads with.

1. Go to <https://appstoreconnect.apple.com> → **Apps** → **+** →
   **New App**.
2. Fill the form:
   - **Platforms**: macOS (only macOS; not iOS/iPadOS for this app)
   - **Name**: `Glotty` (or whatever you want shown on the store)
   - **Primary Language**: English (or Simplified Chinese — Apple
     will let users see other localized listings if you add them)
   - **Bundle ID**: select `com.ruojunye.glotty` from the dropdown.
     If it's not there, click "Register a new bundle ID" — should
     match what's in `project.yml`.
   - **SKU**: anything unique, e.g. `glotty-mac-001`. This is your
     internal identifier; users never see it.
   - **User Access**: Full Access
3. Click **Create**.

The record's enough to allow uploads. You don't need to fill in
screenshots, description, etc. until you're ready to actually
submit for review. Uploads land in TestFlight first regardless.

## 3. Mac App Store provisioning profile

This is what Xcode uses to know "the binary I'm about to sign is
allowed to be installed under this bundle ID."

Easiest path — let Xcode manage it:

1. Open `Glotty.xcodeproj` in Xcode.
2. Select the **Glotty** target → **Signing & Capabilities** tab.
3. Check **Automatically manage signing**.
4. Team: select your Developer Program team (will show "Simon Zu").
5. Xcode should now fetch/generate a "Mac App Store" provisioning
   profile pointing at `com.ruojunye.glotty`. You'll see green text
   confirming "Profile: Mac App Store".

If Automatic doesn't work, manual:

1. <https://developer.apple.com/account/resources/profiles/list>
2. **+** → under **Distribution**, select **Mac App Store** →
   Continue.
3. App ID: `com.ruojunye.glotty`.
4. Certificate: select your **Apple Distribution** cert.
5. Profile Name: `Glotty Mac App Store`.
6. Download the `.provisionprofile` file.
7. Double-click → Xcode imports it into
   `~/Library/MobileDevice/Provisioning Profiles/`.

The upload script sets `signingStyle=automatic` so it'll use
whatever profile Xcode resolves for the team + bundle ID +
distribution cert combination.

## 4. App Store Connect API key

For uploads. The script authenticates to App Store Connect with
this key (no Apple ID password needed, no 2FA loop).

1. <https://appstoreconnect.apple.com/access/api>
2. **Generate API Key** or **+** button.
3. Name: `Glotty Upload`.
4. Access: **App Manager** (broadest role for upload work; you
   can later restrict if you create per-app keys).
5. **Generate**.
6. Apple shows a one-time **Download** button for the `.p8` private
   key file. **Click it now** — Apple deletes the file after one
   download and you can't get it again.
7. Move the downloaded file to:
   ```
   ~/Library/MobileDevice/AppStoreConnect_AuthKey_<KEY_ID>.p8
   ```
   The filename pattern matters — `xcodebuild` looks for it there.
   Apple's UI shows the Key ID (10-char alphanumeric) right after
   creation.
8. Note both the **Key ID** and the **Issuer ID** (UUID at the top
   of the Keys page). You'll set these as env vars.

## 5. Tell the upload script about the API key

Create `.env.appstore` in the repo root (gitignored):

```bash
# .env.appstore — never commit. App Store Connect API credentials.
APP_STORE_KEY_ID=ABCD123456
APP_STORE_ISSUER_ID=00000000-0000-0000-0000-000000000000
```

The script sources this file automatically before invoking
`xcodebuild`.

Make sure it's gitignored — `.env.*` should be in `.gitignore`
already; if not, add it.

## Running the upload

```bash
bash scripts/upload-appstore.sh
```

What happens:

1. **Cleans `build/`** → fresh start every time.
2. **`xcodebuild archive`** with `Glotty-AppStore.entitlements`
   (sandbox on). If the validator catches a problem with the
   private Dictionary Services API or any other issue, it fails
   here with a specific error.
3. **`xcodebuild -exportArchive` with `destination=upload`** — this
   single command exports the archive into App Store Connect's
   `.pkg` format AND uploads it via Transporter using the API
   credentials.
4. On success: the build appears in App Store Connect under
   **Glotty → TestFlight** within 5-30 minutes. Apple's automated
   review runs there.

## What we'll learn from the first run

| Outcome | What it tells us |
|---|---|
| `archive` fails locally | Code/entitlements problem we control. Specific error message points at the line. |
| `archive` succeeds, `exportArchive` upload fails with "Invalid Bundle" | Apple's pre-upload validator catches private API or other policy violation. Specific text in stderr. |
| Upload succeeds, automated processing rejects | Apple's deeper static analysis (private API scanner) catches the dictionary calls. Email arrives within ~30 min with the specific symbol named. |
| Upload succeeds, processing completes | Build is in TestFlight. We can install via TestFlight on a Mac and test that hotkeys + selection grab actually work under sandbox. |
| Processing completes, manual review accepts | Best case. We ship. |
| Processing completes, manual review rejects | We get a written rejection citing specific guidelines. Decide rework vs. shelve. |

The first three outcomes all happen within minutes. Outcomes 4-6
take days because manual review is human-paced.

## If automated review rejects on the dictionary

The expected message is something like:

> Guideline 2.5.1 - Performance - Software Requirements
> Your app uses or references the following non-public symbols:
> `DCSGetActiveDictionaries`, `DCSCopyTextDefinition`

If we want to iterate, the fix is `#if !APPSTORE` guards around
the `dlsym` paths in `Glotty/Translation/DictionaryEntry.swift`,
add `APPSTORE` to the App Store build's `OTHER_SWIFT_FLAGS`
(`-D APPSTORE`), and the popup conditionally hides the dictionary
section when results are empty. ~2 hours of focused work.

## What we *don't* know yet

- Whether `CGEventTap` actually fails to install under sandbox at
  runtime. Could be yes, could be no — Apple's docs are ambiguous
  and behavior has changed across macOS versions. If it works, the
  Fn-leader chord stays. If not, we swap to `RegisterEventHotKey`
  with a Cmd+Shift+chord.
- Whether `AXUIElement` selection grab needs any extra entitlements
  for sandboxed apps. Magnet does this without any special
  entitlement; I expect we don't either, but we'll see.
- Whether the `Localization.framework` / `Translation.framework`
  reach is OK in sandbox. Should be — they're Apple-public APIs —
  but it'll show up in TestFlight if not.

Run the script, see what breaks, iterate.
