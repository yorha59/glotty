#!/bin/bash
# Polls origin/main every 5 minutes. When it sees a new commit,
# runs the same build the CI workflow runs (xcodegen + signed
# PKG via scripts/make-pkg-signed.sh) and uploads the result to
# the Gitea `latest-build` release.
#
# Replaces act_runner here because v0.2.13s Go network stack
# intermittently cannot reach the local Gitea even though curl
# can. Same effective outcome (push to main -> built PKG in
# release) without the unreliable middleman.
#
# The .pkg (not a .dmg) is the artifact: it installs via
# Installer.app, which writes the app to /Applications as root, so
# the installed app carries no quarantine flag even when delivered
# through a sandboxed messenger (Feishu/WeChat). See
# doc/release-pipeline.md. This script and .gitea/workflows/build.yml
# must stay in sync on the artifact type — both publish to the same
# `latest-build` release, so a mismatch makes them clobber each other.
#
# Logs to /tmp/glotty-poll-build.log; rotates by truncation.

set -uo pipefail

LOG=/tmp/glotty-poll-build.log
STATE=$HOME/.glotty-poll-build-state
REPO=$HOME/projects/glotty
GITEA_API="http://192.168.100.150:30008/api/v1/repos/hemoon/glotty"
GITEA_TOKEN_FILE=$HOME/projects/miner/.git-token
KEYCHAIN_PASS_FILE=$HOME/projects/miner/.keychain-pass

export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ts() { date "+%Y-%m-%dT%H:%M:%S"; }
log() { echo "$(ts) $*" >> "$LOG"; }

# Rotate big log
[ -f "$LOG" ] && [ $(wc -c < "$LOG") -gt 524288 ] && tail -c 262144 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

cd "$REPO" || { log "ERROR repo missing"; exit 1; }

REMOTE_SHA=$(git ls-remote origin main 2>/dev/null | awk "NR==1 {print \$1}")
[ -z "$REMOTE_SHA" ] && { log "ERROR cannot fetch remote sha"; exit 1; }

LAST_SHA=$(cat "$STATE" 2>/dev/null || echo "")
if [ "$REMOTE_SHA" = "$LAST_SHA" ]; then
    # Nothing new. Heartbeat once per hour.
    if [ ! -f "$LOG" ] || [ $(find "$LOG" -mmin +60 2>/dev/null | wc -l) -gt 0 ]; then
        log "heartbeat — head=${REMOTE_SHA:0:8} (no change)"
    fi
    exit 0
fi

log "==> New commit ${REMOTE_SHA:0:8} (was ${LAST_SHA:0:8:-none}); building"

git fetch origin main >> "$LOG" 2>&1
git reset --hard origin/main >> "$LOG" 2>&1

xcodegen generate >> "$LOG" 2>&1 || { log "ERROR xcodegen failed"; exit 1; }

# Build + sign + notarize + staple (app + pkg)
KEYCHAIN_PASS_FILE="$KEYCHAIN_PASS_FILE" bash scripts/make-pkg-signed.sh >> "$LOG" 2>&1
BUILD_STATUS=$?
if [ "$BUILD_STATUS" != "0" ]; then
    log "ERROR build/sign/notarize failed status=$BUILD_STATUS"
    exit 1
fi

PKG_FILE=$(ls "$REPO"/dist/*.pkg 2>/dev/null | head -1)
[ -z "$PKG_FILE" ] && { log "ERROR no PKG produced"; exit 1; }
PKG_NAME=$(basename "$PKG_FILE")
log "Built $PKG_NAME ($(du -h "$PKG_FILE" | cut -f1))"

GITEA_TOKEN=$(cat "$GITEA_TOKEN_FILE")
curl -sf --ipv4 -X DELETE -H "Authorization: token $GITEA_TOKEN" \
    "$GITEA_API/releases/tags/latest-build" >> "$LOG" 2>&1 || true
RELEASE_ID=$(curl -sf --ipv4 -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
    -d "{\"tag_name\":\"latest-build\",\"name\":\"Latest Build\",\"body\":\"Built from main (${REMOTE_SHA:0:8})\",\"target_commitish\":\"main\"}" \
    "$GITEA_API/releases" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"id\"])")
[ -z "$RELEASE_ID" ] && { log "ERROR failed to create release"; exit 1; }
curl -sf --ipv4 -X POST -H "Authorization: token $GITEA_TOKEN" -F "attachment=@$PKG_FILE" \
    "$GITEA_API/releases/$RELEASE_ID/assets?name=$PKG_NAME" >> "$LOG" 2>&1

log "==> Published release ${REMOTE_SHA:0:8} $PKG_NAME"
echo "$REMOTE_SHA" > "$STATE"
