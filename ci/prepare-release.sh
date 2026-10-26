#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=naive-update.sh
source "$(dirname "${BASH_SOURCE[0]}")/../naive-update.sh"
latest_tag "${REQUESTED_RELEASE:-latest}"
upstream=$REPLY
tag=server-$upstream
needed=true
if metadata=$(gh api "repos/$REPO/releases/tags/$tag" 2>/dev/null); then
    if jq -e --arg a "naive-server-$upstream-linux-amd64.tar.gz" --arg b "naive-server-$upstream-linux-arm64.tar.gz" '.draft==false and ([.assets[].name] as $names|[$a,$b,"SHA256SUMS"]|all(. as $n|$names|index($n)!=null))' <<<"$metadata" >/dev/null; then needed=false; fi
fi
printf 'upstream=%s\ntag=%s\nneeded=%s\n' "$upstream" "$tag" "$needed" >>"$GITHUB_OUTPUT"
say "Official server $upstream; build needed: $needed"
