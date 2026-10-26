#!/usr/bin/env bash
# Only executed in disposable GitHub-hosted Linux runners.
# Fixtures deliberately preserve literal environment syntax and generated shell code.
# shellcheck disable=SC2016
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && $EUID == 0 ]] || { echo 'CI root only' >&2; exit 1; }
SCRIPT=$(readlink -f "$(dirname "$0")/../naive-update.sh")
BUILD=$(readlink -f "$1")
BASE=$(mktemp -d /opt/naive-ci.XXXXXX); chmod 755 "$BASE"
suffix=$(openssl rand -hex 4)
export NAIVE_BIN=$BASE/bin/caddy NAIVE_CONFIG=$BASE/etc/caddy/Caddyfile NAIVE_STATE=$BASE/state NAIVE_DATA=$BASE/data
export NAIVE_SERVICE=naive-ci-$suffix.service NAIVE_UNIT=/etc/systemd/system/naive-ci-$suffix.service NAIVE_USER=naive-ci-$suffix NAIVE_TOOL=$BASE/bin/naive-update
mkdir -p "$BASE/bin" "$BASE/etc/caddy"; chmod 755 "$BASE/bin" "$BASE/etc" "$BASE/etc/caddy"
cleanup() {
    systemctl stop "$NAIVE_SERVICE" 2>/dev/null || :
    systemctl disable "$NAIVE_SERVICE" 2>/dev/null || :
    rm -f "$NAIVE_UNIT"; systemctl daemon-reload
    userdel "$NAIVE_USER" 2>/dev/null || :
    [[ $BASE == /opt/naive-ci.* ]] && rm -rf -- "$BASE"
}
trap cleanup EXIT
cat >"$BASE/initial.Caddyfile" <<'EOF'
{
    auto_https off
    admin 127.0.0.1:2019
}
http://127.0.0.1:18181 {
    route {
        forward_proxy {
            basic_auth ci-user ci-password
            hide_ip
            hide_via
            probe_resistance
        }
        respond "ci"
    }
}
EOF
bash "$SCRIPT" deploy --build "$BUILD" --config-source "$BASE/initial.Caddyfile" --yes
[[ $("$NAIVE_TOOL" --version) == 2.0.0 ]]
[[ $(systemctl show "$NAIVE_SERVICE" -p User --value) == "$NAIVE_USER" ]]
curl -fsS http://127.0.0.1:18181/ | grep -q ci
echo 'Fresh install with non-root systemd user and standalone shortcut passed'

mkdir -p "$BASE/certs" "$BASE/log"; chmod 755 "$BASE/certs"; chown "$NAIVE_USER" "$BASE/log"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=proxy.example.test -addext subjectAltName=DNS:proxy.example.test -keyout "$BASE/certs/key" -out "$BASE/certs/cert" >/dev/null 2>&1
chown "root:$(id -gn "$NAIVE_USER")" "$BASE/certs/key"; chmod 640 "$BASE/certs/key"; chmod 644 "$BASE/certs/cert"
sed -e 's@{$NAIVE_TEST_CERT}@'"$BASE/certs/cert"'@g' -e 's@{$NAIVE_TEST_KEY}@'"$BASE/certs/key"'@g' -e 's@{$NAIVE_TEST_LOG}@'"$BASE/log/access.log"'@g' "$(dirname "$SCRIPT")/tests/fixtures/custom.Caddyfile" >"$NAIVE_CONFIG"
bash "$SCRIPT" config reload --yes
original_hash=$(sha256sum "$NAIVE_CONFIG")
bash "$SCRIPT" install --build "$BUILD" --yes
[[ $(sha256sum "$NAIVE_CONFIG") == "$original_hash" ]]
if ! bash -x "$SCRIPT" share --yes >"$BASE/share-output" 2>"$BASE/share-trace"; then
    tail -n 100 "$BASE/share-trace"; cat "$BASE/share-output"; exit 1
fi
if ! grep -q 'ci-user:ci-password%3Anot-a-secret@proxy.example.test:18443' "$BASE/share-output"; then
    # This file contains only the public dummy credentials defined in the fixture.
    cat "$BASE/share-output"; echo 'Fixture sharing export did not match' >&2; exit 1
fi
echo 'Custom h1/h2, block matcher, private ACL, filtered access logging and credentials preserved'

cp "$NAIVE_BIN" "$BASE/validator"
mkdir "$BASE/broken"
printf '#!/usr/bin/env bash\nif [[ ${1:-} == validate ]]; then exec "%s" "$@"; fi\nexit 1\n' "$BASE/validator" >"$BASE/broken/caddy"
chmod 755 "$BASE/broken/caddy"
jq --arg sha "$(sha256sum "$BASE/broken/caddy" | cut -d' ' -f1)" '.sha256=$sha' "$BUILD/build.json" >"$BASE/broken/build.json"
if bash "$SCRIPT" install --build "$BASE/broken" --yes; then echo 'broken restart unexpectedly succeeded' >&2; exit 1; fi
[[ ! -f $NAIVE_STATE/pending.json ]]
cmp "$BASE/validator" "$NAIVE_BIN"
systemctl is-active --quiet "$NAIVE_SERVICE"
[[ $(sha256sum "$NAIVE_CONFIG") == "$original_hash" ]]
echo 'Real startup failure restored old binary without rewriting custom config'
bash "$SCRIPT" rollback --yes
[[ $(sha256sum "$NAIVE_CONFIG") == "$original_hash" ]]
echo 'Manual binary rollback preserved custom config'

# Simulate a persisted journal after an interrupted transaction, without touching production.
latest=$(jq -r .id "$NAIVE_STATE/latest.json")
cp "$NAIVE_STATE/backups/$latest/meta.json" "$NAIVE_STATE/pending.json"
bash "$SCRIPT" recover --yes
[[ ! -f $NAIVE_STATE/pending.json ]]
echo 'Persisted journal recovery passed'
