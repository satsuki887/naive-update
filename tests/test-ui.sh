#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT=$(readlink -f "$(dirname "$0")/../naive-update.sh")
# shellcheck source=naive-update.sh
source "$SCRIPT"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
count=0
ok() { count=$((count+1)); printf 'ok UI %s - %s\n' "$count" "$1"; }
fail() { printf 'UI check failed: %s\n' "$1" >&2; exit 1; }
UI_CACHE=$work/cache; STATE=$work/state; BIN=$work/bin/caddy; CONFIG=$work/Caddyfile
mkdir -p "$UI_CACHE" "$STATE" "$work/bin"
printf 'fixture Caddyfile\n' >"$CONFIG"
cat >"$UI_CACHE/official.json" <<'EOF'
{"tag_name":"v2.11.7-naive2","published_at":"2026-10-22T17:28:00Z"}
EOF
cat >"$UI_CACHE/own.json" <<'EOF'
{"tag_name":"server-v2.11.7-naive2","draft":false,"assets":[{"name":"naive-server-v2.11.7-naive2-linux-amd64.tar.gz"},{"name":"naive-server-v2.11.7-naive2-linux-arm64.tar.gz"},{"name":"SHA256SUMS"}]}
EOF
cat >"$UI_CACHE/tags.json" <<'EOF'
[{"name":"v2.11.7-naive2","commit":{"sha":"e747854e7874000000000000000000000000000000"}},{"name":"v2.11.7-naive","commit":{"sha":"c096d6a00cb2000000000000000000000000000000"}}]
EOF
printf '{"tag_name":"v154.0.8037.49-5"}\n' >"$UI_CACHE/client.json"
printf '{"tag_name":"v2.11.7"}\n' >"$UI_CACHE/caddy.json"
cat >"$work/config.json" <<'EOF'
{"apps":{"http":{"servers":{"srv0":{"listen":[":443"],"protocols":["h1","h2"],"routes":[{"match":[{"host":["proxy.example.test"]}]}]}}},"tls":{"automation":{"policies":[{"subjects":["proxy.example.test"]}]}}}}
EOF
cat >"$BIN" <<'EOF'
#!/usr/bin/env bash
case $1 in
    version) printf 'v2.11.7 h1:fixture\n';;
    build-info) printf 'dep github.com/caddyserver/forwardproxy v0.0.0-20240212043213-bf7eb3105151\n=> github.com/klzgrad/forwardproxy v0.0.0-20261006113151-c096d6a00cb2\n';;
    adapt) cat "$UI_FAKE_CONFIG";;
esac
EOF
cat >"$work/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'ActiveState=active\nMainPID=4242\nUnitFileState=enabled\nExecMainStartTimestampMonotonic=0\nMemoryCurrent=10485760\n'
EOF
cat >"$work/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
case $2 in net.ipv4.tcp_congestion_control) printf 'bbr\n';; net.core.default_qdisc) printf 'fq\n';; esac
EOF
cat >"$work/bin/warp-cli" <<'EOF'
#!/usr/bin/env bash
printf 'Status update: %s\n' "${UI_FAKE_WARP_STATUS:-Disconnected}"
EOF
chmod +x "$work/bin/"*
export UI_FAKE_CONFIG=$work/config.json PATH="$work/bin:$PATH"
ui_load_versions; ui_local_version
[[ $UI_INSTALLED_TAG == v2.11.7-naive && $UI_COMMIT == c096d6a00cb2 ]] || fail 'legacy version identification'
ok 'legacy plugin commit resolves the actual server release'
[[ $UI_PACKAGE_READY == 1 && $UI_OFFICIAL == v2.11.7-naive2 ]] || fail 'package/version comparison'
ok 'official target and current-architecture package readiness'
ui_recommendation >"$work/recommendation"
grep -q '与官方最新不同' "$work/recommendation" || fail 'same Caddy version hides plugin upgrade'
ok 'plugin differences remain visible when Caddy version is unchanged'
ui_system_rows >"$work/status"
grep -q 'BBR 已启用' "$work/status"; grep -q '队列 fq' "$work/status"; grep -q 'WARP 已安装 / 未连接' "$work/status"
ok 'home status includes BBR, queue and disconnected WARP'
export UI_FAKE_WARP_STATUS=Connected
ui_system_rows >"$work/status"
grep -q 'WARP 已连接' "$work/status" || fail 'WARP connection state'
ok 'connected and disconnected WARP are distinguished'
jq -n --arg sha "$(digest "$BIN")" '{release:"v2.11.7-naive2",sha256:$sha,forwardproxy:{commit:"e747854e7874000000000000000000000000000000"}}' >"$STATE/current-build.json"
UI_LOCAL_SIG=''; ui_local_version
[[ $UI_INSTALLED_TAG == v2.11.7-naive2 ]] || fail 'receipt-based version'
ui_recommendation >"$work/recommendation"; grep -q '无需重复更新' "$work/recommendation"
ok 'verified current build is marked up to date'
jq '.sha256="wrong-hash"' "$STATE/current-build.json" >"$work/bad-receipt"; cp "$work/bad-receipt" "$STATE/current-build.json"
UI_LOCAL_SIG=''; ui_local_version
[[ $UI_INSTALLED_TAG == v2.11.7-naive && $UI_ORIGIN == *不匹配* ]] || fail 'bad receipt trusted'
ok 'mismatched provenance is rejected instead of displaying a false version'
ui_fetch() { printf '%s\n' "$2" >>"$work/fetch-count"; printf failed >"$UI_CACHE/$2.failed"; return 1; }
ui_versions 1 >/dev/null; ui_versions 0 >/dev/null
[[ $(wc -l <"$work/fetch-count") == 5 && $UI_OFFICIAL == v2.11.7-naive2 ]] || fail 'cache retry storm or stale cache lost'
ok 'failed refresh keeps cached versions and respects the retry interval'
export NAIVE_OFFLINE=1
ui_versions 1 >/dev/null; [[ $(wc -l <"$work/fetch-count") == 5 ]] || fail 'offline mode accessed network'
ok 'offline status performs no remote queries'
(
    submenu_draw() { printf '%s\n' "$1" >>"$work/menus"; }
    run_menu_command() { printf '%s\n' "$*" >"$work/unexpected-action"; }
    for kind in config service cert warp bbr backup shortcut doctor; do submenu "$kind" <<<0; done
    upgrade_menu <<<0 >/dev/null
)
[[ $(wc -l <"$work/menus") == 8 && ! -f $work/unexpected-action ]] || fail 'submenu return triggered an action'
ok 'every submenu and the upgrade screen return with 0 without side effects'
for kind in config service cert warp bbr backup shortcut doctor; do
    submenu_draw "$kind" >"$work/submenu"
    grep -q '返回主菜单' "$work/submenu" || fail "missing back entry: $kind"
done
ok 'all submenu screens display a visible return entry'
NO_COLOR=1 NAIVE_COLOR=always ui_init
[[ -z $C_ACCENT ]] || fail 'NO_COLOR ignored'
ok 'NO_COLOR keeps output readable without ANSI escapes'
menu_draw >"$work/home"
grep -q '官方服务端' "$work/home"; grep -q '本仓库构建' "$work/home"; grep -q 'BBR' "$work/home"
ok 'dashboard includes operational guidance and version sources'
say "Passed $count UI checks"
