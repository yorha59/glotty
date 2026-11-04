# GitHub release signing

The GitHub release workflow has three separate runners:

1. `build`: XcodeGen, Swift packages, and Xcode run without signing secrets.
   Only the unsigned universal app ZIP leaves this runner.
2. `sign`: only `main` may enter the `release-signing` environment, after
   manual approval by `yorha59`. The downloaded app is validated before
   credentials are loaded. No build or package plugins run here.
3. `publish`: receives the signed package and checksum, verifies the checksum,
   and creates the release. Only this job has `contents: write`.

All Actions are pinned to full commit SHAs; checkout does not persist its
token. The signing helper uses a private temporary directory, a random
keychain password, and non-extractable private keys. It removes P12 files
before signing, unsets credential environment variables, and deletes the
keychain and restores the search list before artifacts are uploaded.
Cleanup failure fails the signing step. Hard VM termination is additionally
covered by using fresh GitHub-hosted runners, not persistent self-hosted ones.

## One-time credential migration (required before the new workflow can sign)

GitHub does not expose existing secret values. In Settings → Environments →
`release-signing`, re-enter the five original values under these new names:

| Old repository secret | New environment secret |
| --- | --- |
| `MACOS_SIGNING_P12_BASE64` | `RELEASE_MACOS_SIGNING_P12_BASE64` |
| `MACOS_INSTALLER_P12_BASE64` | `RELEASE_MACOS_INSTALLER_P12_BASE64` |
| `MACOS_SIGNING_P12_PASSWORD` | `RELEASE_MACOS_SIGNING_P12_PASSWORD` |
| `APPLE_ID` | `RELEASE_APPLE_ID` |
| `APPLE_APP_SPECIFIC_PASSWORD` | `RELEASE_APPLE_APP_SPECIFIC_PASSWORD` |

Use the new names **only as environment secrets**, never repository secrets.
The workflow intentionally does not fall back to the old names.
After entering all five values, delete the five old repository secrets.
Until they are deleted, they remain accessible to other workflows and the
original repository-secret exposure is not fully resolved.
Do not paste credentials into issues, PRs, chat, or command-line arguments.
For a local file, `gh secret set NAME --env release-signing --repo yorha59/glotty
< /secure/path/value` reads the value from stdin without echoing it.

Set the environment to allow the **branch** `main` only (not tags), and
require approval by `yorha59`. With only one collaborator, self-review must
remain allowed; this is a manual gate, not independent two-person approval.
An administrator who controls the repository can still change these policies.
`main` also requires a pull request (including for administrators), with force
pushes and deletion disabled. Since the owner is the only collaborator, this
requires the PR path but does not require another person's approval.

After migration and merging the change, manually run the workflow on `main`
with `dry_run: true`. Approve the environment job, then check the signed
package artifact. Dry-run still signs and notarizes; it skips publishing.
Runs from other branches may build, but cannot sign or publish.

## Local verification

```sh
python3 scripts/test_ci_sign_pkg.py
bash -n scripts/ci-sign-pkg.sh scripts/make-pkg-signed.sh
actionlint .github/workflows/release.yml
```

The Python tests use dummy credentials and tool doubles. They exercise
success, missing credentials, import/notary/signing failures, and cleanup
failure. They verify that no build occurs on the signing path and no raw
credential environment variables reach signing/packaging subprocesses.
They do not contact Apple or use real certificates. Existing local and Gitea
callers can still build/sign via `make-pkg-signed.sh` without a prebuilt app.
