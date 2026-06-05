# Release pipeline

How a push to `main` becomes a signed + notarized DMG on the Gitea
`latest-build` release page. End-to-end:

```
git push origin main
        │
        ▼  (within 5 min)
poll-build LaunchAgent on the macOS runner (alex-mini.local)
checks `git ls-remote origin main` and sees a new SHA
        │
        ▼
scripts/runner-mac/glotty-poll-build.sh
        │
        ├── git fetch + reset --hard origin/main
        ├── xcodegen generate
        ├── scripts/make-dmg-signed.sh
        │       ├── xcodebuild -configuration Release (unsigned)
        │       ├── codesign with Developer ID Application +
        │       │   Hardened Runtime + Secure Timestamp +
        │       │   Glotty-Release.entitlements
        │       ├── hdiutil create … dist/Glotty-<version>.dmg
        │       ├── codesign the DMG
        │       ├── xcrun notarytool submit … --wait
        │       └── xcrun stapler staple … the DMG
        └── curl → DELETE old `latest-build` release, POST new,
            upload the DMG as the asset
        │
        ▼
http://truenas.local:30008/hemoon/glotty/releases/tag/latest-build
```

End result: a DMG that Gatekeeper trusts on any Mac. User
double-clicks, drags to Applications, opens — no warnings.

## Why poll-and-build, not Gitea Actions / act_runner

The original setup was Gitea Actions with `act_runner` reading
`.gitea/workflows/build.yml` and running it as steps. That config
is still committed; it just isn't the active path.

The active path is a launchd-managed shell script that polls
every 5 minutes because `act_runner` v0.2.13's Go networking
stack on this runner fails to dial Gitea even when `curl` to the
same IP returns HTTP 200 in 9ms. Diagnosed at length and never
root-caused — likely a Go resolver / happy-eyeballs bug on
networks where mDNS returns an unreachable IPv6 link-local. The
poll-and-build LaunchAgent uses plain `bash`, `git`, and `curl`,
all of which work fine on this host.

If you later upgrade `act_runner` (or replace it) and want to
switch back to Gitea Actions: `launchctl unload` the poll-build
agent, re-enable the runner's LaunchAgent / startup config, and
the existing `build.yml` does the rest.

## Runner setup (one-time)

The macOS runner needs the keychain set up (below) plus the
poll-build LaunchAgent installed. Both are persistent; once
installed they survive reboots.

### Install the poll-build LaunchAgent

The script and the plist live in this repo under
`scripts/runner-mac/` so they're version-controlled. Install:

```bash
ssh <runner>
mkdir -p ~/bin
cp ~/projects/glotty/scripts/runner-mac/glotty-poll-build.sh ~/bin/
chmod +x ~/bin/glotty-poll-build.sh
cp ~/projects/glotty/scripts/runner-mac/com.glotty.poll-build.plist \
    ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.glotty.poll-build.plist
```

Verify:

```bash
launchctl list | grep glotty
# Expect: -  0  com.glotty.poll-build
#         ^         ^-- last exit code (0 = healthy)
#         not running between ticks is normal

tail /tmp/glotty-poll-build.log
# Expect periodic "heartbeat" lines and "==> Published release …"
# entries when commits ship.
```

State files:

| Path | What |
|---|---|
| `/tmp/glotty-poll-build.log` | Per-tick log (heartbeats + build/publish output). Auto-rotates at 512 KB. |
| `~/.glotty-poll-build-state` | Last-built commit SHA. The poller skips re-builds while the remote SHA matches. |
| `/tmp/glotty-poll-build.stdout` + `.stderr` | launchd-captured streams. Should be empty in steady state. |

Force a build right now (bypass the timer):

```bash
~/bin/glotty-poll-build.sh
```

## What broke act_runner and how to maybe restore it

The act_runner LaunchAgent and Gitea's `build.yml` workflow are
still committed and would work if the runner can dial Gitea
reliably. As of 2026-06-04 it can't, and the dive turned up two
distinct problems:

### Problem 1 (fixable, fixed): mDNS publishes a bad link-local IPv6

Symptom: `act_runner` on alex-mini dials
`fe80::2472:b1ff:fefc:afea%en1`, gets "no route to host" —
even though `truenas.local` has a working IPv4 address.

Cause: avahi-daemon on truenas was including its br0 link-local
IPv6 in mDNS responses sent over IPv4 multicast, even though its
config has `use-ipv6=no`. That setting only controls IPv6
sockets, not which addresses get published. Alex-mini's mDNS
cached both records; Go's `net.Dial` picks IPv6 first per RFC
8305 happy-eyeballs; NDP for the link-local fails (likely a
Docker bridge sysctl on truenas suppressing NDP); Go errors out
before falling back to v4.

Fix (already applied to truenas's `/etc/avahi/avahi-daemon.conf`):

```ini
[publish]
publish-aaaa-on-ipv4=no
```

After `systemctl restart avahi-daemon`, alex-mini's mDNS
returns only IPv4 for `truenas.local`. Verify with
`dscacheutil -flushcache && dscacheutil -q host -a name
truenas.local` — should show only `ip_address: 192.168.100.150`.

### Problem 2 (not root-caused): act_runner-specific IPv4 dial failure

Even with mDNS clean, `act_runner` on alex-mini still gets
"no route to host" dialing `192.168.100.150:30008` directly,
while `curl` and `ping` from the same shell on the same Mac
reach the same IP in 2-10ms. Something specific to act_runner's
Go networking stack (possibly the wrong egress interface
selection in the presence of Tailscale's utun12) is failing.
Not root-caused; not fixed.

This is the immediate reason CI runs through poll-build instead
of act_runner. If you upgrade act_runner to a newer release or
find a fix, re-enabling Gitea Actions CI is mechanical: install
the `com.glotty.actrunner` LaunchAgent (template was at
`~/Library/LaunchAgents/`, removed in cleanup), unload
`com.glotty.poll-build`, and the existing `build.yml` runs.

### Keychain prerequisites

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

### 3. Developer ID Installer certificate (for the .pkg)

The release artifact is a signed + notarized + stapled **.pkg**
(`make-pkg-signed.sh`, the "Build, sign, notarize, staple PKG" step).
A `.pkg` is the zero-Terminal distribution format: Installer.app writes
the app to `/Applications` as root, so the installed app carries **no
quarantine flag** even when the `.pkg` is delivered through a sandboxed
messenger (Feishu/WeChat) that otherwise stamps a sandbox-origin
quarantine Gatekeeper refuses to launch. Proven end-to-end 2026-06-05.

Signing a `.pkg` needs a **`Developer ID Installer`** certificate —
a SEPARATE cert from the Application one in section 1. (The app payload
is still signed with the Application cert; only the pkg wrapper uses the
Installer cert.) Without it, signing fails with `No installer signing
identity found`.

**This was set up on the runner 2026-06-05** — recorded here for
disaster recovery. Into the dedicated CI keychain
`glotty-ci.keychain-db` (the one `make-pkg-signed.sh` uses when
`KEYCHAIN_PASS_FILE` is set):

```bash
# On the dev Mac, export the identity (cert + private key). CLI -t
# identities exports ALL identities into the p12; that's fine — only
# the Installer one is needed on the runner.
security export -k login.keychain-db -t identities \
    -f pkcs12 -P "<temp password>" -o /tmp/glotty-installer.p12
# (A keychain auth dialog pops; enter the login password to allow.)
```

```bash
# On the runner, import with -A (any tool may use the key, no prompt),
# then pin the partition list. -A matters: a -T-only import still
# blocked on an auth prompt at sign time in the headless session.
security unlock-keychain -p "$(cat ~/projects/miner/.keychain-pass)" \
    ~/Library/Keychains/glotty-ci.keychain-db
security import /tmp/glotty-installer.p12 -k glotty-ci.keychain-db \
    -P "<temp password>" -A
security set-key-partition-list -S apple-tool:,apple: \
    -s -k "$(cat ~/projects/miner/.keychain-pass)" \
    glotty-ci.keychain-db
rm /tmp/glotty-installer.p12   # delete from both machines after import

# Verify
security find-identity -v glotty-ci.keychain-db | grep "Developer ID Installer"
# Should show "Developer ID Installer: Simon Zu (47D8DFFZQ4)"
```

**Critical: sign the pkg with `productsign --keychain`, NOT
`pkgbuild --sign`.** `pkgbuild` has no `--keychain` flag, so in CI it
searches keychains ambiguously and blocks forever on a keychain auth
prompt the headless act_runner session can't answer (the build hangs).
`productsign` honors `--keychain`, pinning the signing keychain exactly
like the `codesign --keychain` calls — and signs non-interactively.
`make-pkg-signed.sh` already does this (pkgbuild builds an unsigned pkg,
productsign signs it). Diagnosed 2026-06-05: `pkgbuild --sign` hung even
with `-A` + partition list and even with `--timestamp=none`, while
`codesign --timestamp` with the Application key succeeded in the same
session — isolating the cause to `pkgbuild`'s keychain search.

### Allowing the runner's codesign to use the cert non-interactively

Two things have to be true at signing time on the runner:

**1. Keychain is unlocked from the act_runner session.**

`act_runner` spawns its own session per job; that session sees the
login keychain as **locked** even after the user has unlocked it
interactively or via `set-keychain-settings -l`. The reliable fix
is to unlock at the start of each job, from inside the workflow.

`scripts/make-dmg-signed.sh` looks for `KEYCHAIN_PASS_FILE` env
var. If it's set and the file is readable, the script unlocks the
login keychain at job start using the file contents as the
password. The workflow points it at `~/projects/miner/.keychain-pass`
on the runner (chmod 600, password in plaintext at rest — runner's
filesystem encryption is the protection here).

Create the password file on the runner once:

```bash
echo "<runner-user-login-password>" > ~/projects/miner/.keychain-pass
chmod 600 ~/projects/miner/.keychain-pass
```

**2. codesign is allowed to use the private key without prompting.**

Grant the partition-list permission once:

```bash
security set-key-partition-list -S apple-tool:,apple: \
    -s -k "<runner-user-login-password>" login.keychain
```

This is persistent until the cert is reimported.

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
