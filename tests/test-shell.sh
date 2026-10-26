#!/usr/bin/env bash
# Test fixtures deliberately contain literal environment syntax.
# shellcheck disable=SC2016
set -Eeuo pipefail
SCRIPT=$(readlink -f "$(dirname "$0")/../naive-update.sh")
# shellcheck source=naive-update.sh
source "$SCRIPT"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
count=0
ok() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
reject() { if bash -c 'source "$1";shift;"$@"' _ "$SCRIPT" "$@" >/dev/null 2>&1; then bad "accepted invalid input: $1"; fi; ok "reject $1"; }
render_config proxy.example.com 443 user 'pass:quote"and space' auto '' local /var/lib/naive-caddy/www >"$work/default"
! grep -Eq 'protocols|remote_ip|acl|http_port|header_up' "$work/default" || bad 'custom restrictions leaked into defaults'
ok 'clean official defaults'
grep -q 'order forward_proxy before file_server' "$work/default"; grep -q 'exclude http.log.error' "$work/default"; ok 'official routing and error-log privacy'
render_config proxy.example.com 8443 user password auto '' https://example.org /unused >"$work/reverse"
grep -q 'reverse_proxy https://example.org' "$work/reverse"; if grep -q header_up "$work/reverse"; then bad 'obsolete upstream Host'; fi; ok 'modern HTTPS upstream without obsolete Host override'
reject render_config example.com 0 user pass auto '' local /tmp
reject render_config 'example.com;touch' 443 user pass auto '' local /tmp
reject render_config example.com 443 'bad:user' pass auto '' local /tmp
reject render_config example.com 443 user $'bad\npassword' auto '' local /tmp
reject render_config example.com 443 user '{$BAD_ENV}' auto '' local /tmp
reject render_config example.com 443 user pass auto '' 'https://user:password@example.org' /tmp
reject latest_tag v154.0.8037.49-5
mkdir -p "$work/src/.github/workflows"
printf 'v2.11.7\n' >"$work/src/CADDY_VERSION"
printf x >"$work/src/a.patch"; printf y >"$work/src/b.patch"
cat >"$work/src/.github/workflows/build.yml" <<'EOF'
      repository: caddyserver/caddy
      go-version: ^1.26.x
      - run: git -C .caddy-bbr apply "$GITHUB_WORKSPACE/a.patch" "$GITHUB_WORKSPACE/b.patch"
      - run: ~/go/bin/xcaddy build "$CADDY_VERSION" --replace "github.com/caddyserver/caddy/v2=$GITHUB_WORKSPACE/.caddy-bbr" --with "github.com/caddyserver/forwardproxy=$GITHUB_WORKSPACE"
EOF
plan "$work/src"; [[ ${PATCHES[*]} == 'a.patch b.patch' && $GO_MIN == 1.26 ]] || bad 'plan mismatch'; ok 'fixed-tag official patch order and Go requirement'
cp "$work/src/.github/workflows/build.yml" "$work/original"
printf '\n      - run: ./new-step.sh\n' >>"$work/src/.github/workflows/build.yml"
reject plan "$work/src"
cp "$work/original" "$work/src/.github/workflows/build.yml"; sed -i 's@/b.patch@/../b.patch@g' "$work/src/.github/workflows/build.yml"
reject plan "$work/src"
cp "$work/original" "$work/src/.github/workflows/build.yml"; rm "$work/src/b.patch"
reject plan "$work/src"
mkdir "$work/artifact"; printf binary >"$work/artifact/caddy"
jq -n --arg sha "$(digest "$work/artifact/caddy")" '{schema:1,release:"v2.11.7-naive2",goarch:"amd64",sha256:$sha,forwardproxy:{repository:"https://github.com/klzgrad/forwardproxy.git"},caddy:{repository:"https://github.com/caddyserver/caddy.git"}}' >"$work/artifact/build.json"
verify_build "$work/artifact"; ok 'valid provenance and hash accepted'
cp "$work/artifact/caddy" "$work/binary"; printf tampered >"$work/artifact/caddy"; reject verify_build "$work/artifact"; cp "$work/binary" "$work/artifact/caddy"
for name in build-info.txt SHA256SUMS LICENSES.txt; do printf x >"$work/artifact/$name"; done
printf 'PRIVATE_SECRET' >"$work/artifact/Caddyfile"
bash "$(dirname "$SCRIPT")/ci/package.sh" "$work/artifact" "$work/dist" >/dev/null
[[ $(tar -tzf "$work/dist/naive-server-v2.11.7-naive2-linux-amd64.tar.gz" | wc -l) == 5 ]] || bad 'package membership'
if tar -tzf "$work/dist/naive-server-v2.11.7-naive2-linux-amd64.tar.gz" | grep -q Caddyfile; then bad 'private config in package'; fi; ok 'package excludes config and secrets'
NAIVE_CONFIG=$work/etc/Caddyfile bash -c 'source "$1"; CONFIG=$NAIVE_CONFIG; examples' _ "$SCRIPT"
[[ -f $work/etc/examples/Caddyfile.standard && ! -f $work/etc/Caddyfile ]] || bad 'examples modified active config'; ok 'optional examples not activated'
! grep -Eq 'exec python|python3 ' "$SCRIPT" || bad 'runtime Python dependency'; ok 'standalone Shell runtime'
bash "$SCRIPT" --help >/dev/null; [[ $(bash "$SCRIPT" --version) == 2.0.0 ]] || bad 'version'; ok 'standalone CLI smoke'
say "Passed $count shell checks"
