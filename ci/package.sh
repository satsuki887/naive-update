#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../naive-update.sh"
source_dir=$(readlink -f "$1")
dest=$(readlink -m "$2")
verify_build "$source_dir"
release=$(jq -r .release "$source_dir/build.json")
architecture=$(jq -r .goarch "$source_dir/build.json")
[[ $architecture == amd64 || $architecture == arm64 ]] || die 'Invalid architecture'
mkdir -p "$dest"
name=naive-server-$release-linux-$architecture.tar.gz
for file in caddy build.json build-info.txt SHA256SUMS LICENSES.txt; do regular "$source_dir/$file"; done
tar -czf "$dest/$name" --owner=0 --group=0 -C "$source_dir" caddy build.json build-info.txt SHA256SUMS LICENSES.txt
printf '%s  %s\n' "$(digest "$dest/$name")" "$name" >"$dest/$name.sha256"
say "$dest/$name"
