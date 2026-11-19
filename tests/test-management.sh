#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT=$(readlink -f "$(dirname "$0")/../naive-update.sh")
# shellcheck source=naive-update.sh
source "$SCRIPT"
TEST_WORK=$(mktemp -d)
trap 'rm -rf -- "$TEST_WORK" "${TEMPS[@]}"' EXIT
if [[ $(uname -s) != Linux ]]; then mutable() { :; }; fi
YES=1; RELEASE=latest
cat >"$TEST_WORK/server" <<'EOF'
#!/usr/bin/env bash
printf 'Version: v2.14.0\n'
EOF
chmod +x "$TEST_WORK/server"
uname() { printf 'x86_64\n'; }
api() { printf '{"tag_name":"app/v2.14.0"}\n'; }
download_url() {
    printf '%s\n' "$1" >>"$TEST_WORK/urls"
    case $1 in
        */hysteria-linux-amd64) cp "$TEST_WORK/server" "$2";;
        */hashes.txt) printf '%s  build/hysteria-linux-amd64\n' "$(digest "$TEST_WORK/server")" >"$2";;
        *) return 1;;
    esac
}
# shellcheck disable=SC2218 # the real function is provided by the sourced script
hysteria_fetch
[[ $(hysteria_version "$REPLY") == v2.14.0 ]]
[[ $(wc -l <"$TEST_WORK/urls") == 2 ]]
if grep -q '/latest/' "$TEST_WORK/urls"; then exit 1; fi
echo 'ok - Hysteria download pins both files to one release and accepts build/ hashes'
(
    download_url() {
        case $1 in */hashes.txt) printf '%064d  hysteria-linux-amd64\n' 0 >"$2";; *) cp "$TEST_WORK/server" "$2";; esac
    }
    if (hysteria_fetch) >"$TEST_WORK/reject" 2>&1; then exit 1; fi
)
echo 'ok - mismatched Hysteria checksum is rejected before execution'
# Exercise actual backup/copy/restore code without touching a real service.
STATE=$TEST_WORK/state; BIN=$TEST_WORK/installed; CONFIG=$TEST_WORK/config.yaml; UNIT=$TEST_WORK/service
mkdir -p "$STATE"; cp "$TEST_WORK/server" "$BIN"; printf 'original config\n' >"$CONFIG"; printf 'original unit\n' >"$UNIT"
systemctl() {
    case $1 in
        show) printf '{ path=%s ; argv[]=%s server ; }\n' "$BIN" "$BIN";;
        is-active|is-enabled) return 1;;
        *) return 0;;
    esac
}
hysteria_fetch() { REPLY=$TEST_WORK/candidate; }
printf 'new binary\n' >"$TEST_WORK/candidate"
hysteria_update
[[ $(cat "$BIN") == 'new binary' && $(cat "$CONFIG") == 'original config' && $(cat "$UNIT") == 'original unit' ]]
id=$(jq -r .id "$STATE/latest.json")
restore_snapshot "$id"
cmp "$BIN" "$TEST_WORK/server"
[[ $(cat "$CONFIG") == 'original config' ]]
echo 'ok - Hysteria update preserves stopped state and config; binary rollback restores bytes'
UDP_FILE=$TEST_WORK/sysctl/udp.conf
# Native jq rewrites MSYS paths in arguments; store a native path so restore compares equal.
if command -v cygpath >/dev/null 2>&1; then UDP_FILE=$(cygpath -m "$UDP_FILE"); fi
printf 212992 >"$TEST_WORK/rmem"; printf 33554432 >"$TEST_WORK/wmem"
sysctl() {
    local entry key value
    case $1 in
        -n) case $2 in net.core.rmem_max) cat "$TEST_WORK/rmem";; net.core.wmem_max) cat "$TEST_WORK/wmem";; esac;;
        -w) shift; for entry in "$@"; do case $entry in net.core.rmem_max=*) printf %s "${entry#*=}" >"$TEST_WORK/rmem";; net.core.wmem_max=*) printf %s "${entry#*=}" >"$TEST_WORK/wmem";; esac; done;;
        -p) while IFS='=' read -r key value; do sysctl -w "${key// /}=${value// /}"; done <"$2";;
    esac
}
udp_tune
[[ $(cat "$TEST_WORK/rmem") == 16777216 && $(cat "$TEST_WORK/wmem") == 33554432 ]]
id=$(jq -r .id "$STATE/latest.json"); restore_snapshot "$id"
[[ $(cat "$TEST_WORK/rmem") == 212992 && $(cat "$TEST_WORK/wmem") == 33554432 && ! -e $UDP_FILE ]]
echo 'ok - UDP tuning preserves larger limits and restores original runtime values and file absence'
COLUMNS=48 ui_pair 1 Install 2 Update >"$TEST_WORK/narrow"
[[ $(wc -l <"$TEST_WORK/narrow") == 2 ]]
echo 'ok - narrow terminals use one menu column'
mkdir "$TEST_WORK/mock-bin"
cat >"$TEST_WORK/mock-bin/gh" <<'EOF'
#!/usr/bin/env bash
case $2 in
    repos/klzgrad/forwardproxy/releases/latest) printf 'v2.11.7-naive2\n';;
    repos/satsuki887/naive-update/releases/tags/server-v2.11.7-naive2)
        printf '{"draft":false,"assets":[{"name":"naive-server-v2.11.7-naive2-linux-amd64.tar.gz"},{"name":"naive-server-v2.11.7-naive2-linux-arm64.tar.gz"},{"name":"SHA256SUMS"}]}\n';;
    *) exit 1;;
esac
EOF
chmod +x "$TEST_WORK/mock-bin/gh"
PATH="$TEST_WORK/mock-bin:$PATH" REQUESTED_RELEASE='' GITHUB_OUTPUT="$TEST_WORK/discover" bash "$(dirname "$SCRIPT")/ci/prepare-release.sh"
grep -q '^needed=false$' "$TEST_WORK/discover"
echo 'ok - empty scheduled/manual release uses authenticated gh discovery and skips complete releases'
