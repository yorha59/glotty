# Release pipeline

How a push to `main` becomes a signed + notarized DMG on the Gitea
`latest-build` release page. End-to-end:

```
git push origin main
        │
        ▼
.gitea/workflows/build.yml fires on the macOS runner
        │
        ▼
scripts/make-dmg-signed.sh
        │
        ├── xcodebuild -configuration Release (unsigned)
        ├── codesign with Developer ID Application + Hardened
        │   Runtime + Secure Timestamp + Glotty-Release.entitlements
        ├── hdiutil create … dist/Glotty-<version>.dmg
        ├── codesign the DMG
        ├── xcrun notarytool submit … --wait
        └── xcrun stapler staple … the DMG
        │
        ▼
Workflow uploads to Gitea Release `latest-build`
```

End result: a DMG that Gatekeeper trusts on any Mac. User
double-clicks, drags to Applications, opens — no warnings.

## Runner setup (one-time)

The macOS runner needs two things in its keychain. Both are
persistent; once installed they survive runs.

### 1. Developer ID Application certificate

The same cert that signs builds locally needs to live on the runner.
Two ways to get it there:

**Option A — export from dev machine, import on runner.**

On your Mac:

```bash
# Find the cert SHA
security find-identity -v -p codesigning
# Note the line for "Developer ID Application: Simon Zu (47D8DFFZQ4)"

# Export cert + private key as .p12
security export -k login.keychain -t identities \
    -f pkcs12 -P "<choose a temporary password>" \
    -o ~/Desktop/glotty-signing.p12
```

Copy `glotty-signing.p12` to the runner Mac (scp, USB, AirDrop —
whatever). On the runner:

```bash
security import ~/glotty-signing.p12 -k login.keychain \
    -P "<the temporary password>" \
    -T /usr/bin/codesign

# Delete the exported file from both machines after import.
rm ~/glotty-signing.p12

# Verify
security find-identity -v -p codesigning
# Should show "Developer ID Application: Simon Zu (47D8DFFZQ4)"
```

**Option B — generate a new cert pinned to the runner.**

Apple lets one Developer Program member have multiple Developer ID
Application certs (they all sign with the same Team ID). Generate a
fresh CSR on the runner, upload at <https://developer.apple.com>,
download, install. The cert never leaves the runner.

Slightly more secure (no .p12 file in transit), slightly more work.

### 2. notarytool credentials

On the runner:

```bash
xcrun notarytool store-credentials "glotty-notary" \
    --apple-id hemoon@outlook.com \
    --team-id 47D8DFFZQ4
# Paste the app-specific password from appleid.apple.com when
# prompted. The password is stored in the runner's keychain under
# the profile name `glotty-notary`.
```

Verify:

```bash
xcrun notarytool history --keychain-profile glotty-notary | head
# Should list any prior submissions, even an empty list with no
# errors confirms credentials work.
```

### Allowing the runner's codesign to use the cert non-interactively

By default the keychain prompts for permission on first use of a
private key. CI runs in a non-interactive shell — the prompt is
fatal. Tell the keychain to skip the prompt for codesign:

```bash
# Unlock the login keychain at boot / before each run if the runner
# autostarts. For act_runner, this can go in a launchd plist or in
# the runner's startup script:
security unlock-keychain -p "<runner-user-login-password>" login.keychain

# Allow codesign to read the private key without prompting:
security set-key-partition-list -S apple-tool:,apple: \
    -s -k "<runner-user-login-password>" login.keychain
```

These two lines should run before any signing operation. The
simplest place is the runner's startup script.

## Inputs the script honors

`scripts/make-dmg-signed.sh` reads these environment variables
(defaults baked in for Glotty):

| Variable | Default | Purpose |
|---|---|---|
| `SIGN_IDENTITY` | `Developer ID Application: Simon Zu (47D8DFFZQ4)` | Full cert name. Match exactly what `security find-identity` reports. |
| `TEAM_ID` | `47D8DFFZQ4` | 10-char team identifier. |
| `NOTARY_PROFILE` | `glotty-notary` | Keychain profile name from `notarytool store-credentials`. |

If the runner uses a different cert / Apple ID / profile name, set
these in the workflow's env block.

## Why an explicit entitlements file

`Glotty/Glotty-Release.entitlements` is empty (no special
capabilities). The point isn't what's in it — it's what's NOT:

```
com.apple.security.get-task-allow
```

Xcode adds that entitlement automatically for any build without an
explicit entitlements file, so the debugger can attach. Apple's
notary service rejects any binary that requests it (debugging
entitlements don't belong in shipped software). Providing an empty
file overrides Xcode's default and produces a notarizable binary.

Debug builds (Xcode's ▶ in the IDE) don't reference this file —
they keep `get-task-allow=YES` and stay debuggable locally.

## Why we build unsigned then sign manually

`xcodebuild` has a habit of merging `get-task-allow=YES` from a
hidden internal default into the signature, even when
`CODE_SIGN_ENTITLEMENTS` is overridden on the command line. Two
notarization rejections confirmed this. The script now builds with
`CODE_SIGNING_REQUIRED=NO`, then issues a single explicit
`codesign` invocation against the entitlements file we actually
want. Single predictable path, no merging.

## Debugging a rejected notarization

If `xcrun notarytool submit` returns `status: Invalid`, fetch the
detailed log:

```bash
xcrun notarytool log <submission-id> --keychain-profile glotty-notary
```

The submission ID is printed by `submit` (look for `id:`). The log
JSON has an `issues` array enumerating each problem with a
`docUrl` to Apple's "Resolving Common Notarization Issues" page.

Common rejections we've seen:

| `message` | Cause | Fix |
|---|---|---|
| `requests the com.apple.security.get-task-allow entitlement` | Xcode's default debug entitlement | Build unsigned + manual sign with `Glotty-Release.entitlements` (this is what the current script does) |
| `not signed with Apple Distribution or Developer ID certificate` | Used the wrong cert (Apple Development isn't notarizable) | Switch to the Developer ID Application cert |
| `not signed with a secure timestamp` | Missing `--timestamp` flag | Add `--timestamp` to the codesign call |
| `not signed with the hardened runtime` | Missing `--options runtime` flag | Add `--options runtime` to the codesign call |

## Releasing a versioned snapshot (future)

`latest-build` is a rolling tag — every push to main overwrites it.
For a stable milestone (e.g. `v0.1.0`):

1. Tag the commit locally: `git tag v0.1.0 && git push origin v0.1.0`
2. Add a `release.yml` workflow that triggers on `push: tags: ['v*']`
   and creates a versioned Gitea Release (separate from
   `latest-build`) with release notes.

Not implemented yet — wait until there's a real semver story.
