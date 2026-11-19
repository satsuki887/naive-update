#!/usr/bin/env bash
# Run only on disposable hosted Linux runners; never production.
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && $EUID == 0 ]] || { echo 'CI root only' >&2; exit 1; }
SCRIPT=$(readlink -f "$(dirname "$0")/../naive-update.sh")
BASE=$(mktemp -d /opt/hysteria-ci.XXXXXX); chmod 755 "$BASE"
suffix=$(openssl rand -hex 4)
export HYSTERIA_BIN=$BASE/bin/hysteria HYSTERIA_CONFIG=$BASE/etc/config.yaml HYSTERIA_STATE=$BASE/state HYSTERIA_CERT_ROOT=$BASE/certs
export HYSTERIA_SERVICE=hysteria-ci-$suffix.service HYSTERIA_UNIT=/etc/systemd/system/hysteria-ci-$suffix.service HYSTERIA_USER=hysteria-ci-$suffix
export NAIVE_TOOL=$BASE/bin/naive-update
cleanup() {
    systemctl disable --now "$HYSTERIA_SERVICE" 2>/dev/null || :
    rm -f "$HYSTERIA_UNIT"; systemctl daemon-reload
    userdel "$HYSTERIA_USER" 2>/dev/null || :
    [[ $BASE == /opt/hysteria-ci.* ]] && rm -rf -- "$BASE"
}
trap cleanup EXIT
mkdir -p "$BASE/bin" "$BASE/etc"; chmod 755 "$BASE/bin" "$BASE/etc"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=proxy.example.test -addext subjectAltName=DNS:proxy.example.test -keyout "$BASE/key" -out "$BASE/cert" >/dev/null 2>&1
printf 'proxy.example.test\n18444\n%s\n%s\nci-password\nhttps://example.org\n' "$BASE/cert" "$BASE/key" | bash "$SCRIPT" hysteria install --yes
service_user=$(systemctl show "$HYSTERIA_SERVICE" -p User --value)
[[ $service_user == "$HYSTERIA_USER" ]] || { echo "unexpected service user: [$service_user]" >&2; exit 1; }
systemctl is-active --quiet "$HYSTERIA_SERVICE" || {
    systemctl status "$HYSTERIA_SERVICE" --no-pager || :
    journalctl -u "$HYSTERIA_SERVICE" -n 50 --no-pager || :
    exit 1
}
for expected in 'ignoreClientBandwidth: false' 'udpIdleTimeout: 60s' 'https://example.org' 'rewriteHost: true'; do
    grep -q "$expected" "$HYSTERIA_CONFIG" || { echo "missing from config: $expected" >&2; cat "$HYSTERIA_CONFIG"; exit 1; }
done
original=$(sha256sum "$HYSTERIA_CONFIG")
bash "$SCRIPT" hysteria update --yes
[[ $(sha256sum "$HYSTERIA_CONFIG") == "$original" ]]
echo 'Hysteria real non-root install and same-version update passed'
previous=$(readlink "$HYSTERIA_CERT_ROOT/current")
bash "$SCRIPT" hysteria cert-deploy --cert "$BASE/cert" --key "$BASE/key" --domain proxy.example.test --yes
[[ $(readlink "$HYSTERIA_CERT_ROOT/current") != "$previous" ]]
bash "$SCRIPT" hysteria rollback --yes
[[ $(readlink "$HYSTERIA_CERT_ROOT/current") == "$previous" ]]
echo 'Certificate pair deployment and rollback passed'
cat >"$BASE/bad-editor" <<'EOF'
#!/usr/bin/env bash
printf 'listen: "not-a-valid-address"\n' >"$1"
EOF
chmod +x "$BASE/bad-editor"
if EDITOR=$BASE/bad-editor VISUAL=$BASE/bad-editor bash "$SCRIPT" hysteria edit --yes; then echo 'Invalid config accepted' >&2; exit 1; fi
[[ $(sha256sum "$HYSTERIA_CONFIG") == "$original" && ! -f $HYSTERIA_STATE/pending.json ]]
systemctl is-active --quiet "$HYSTERIA_SERVICE"
echo 'Invalid Hysteria configuration restored automatically'
latest=$(jq -r .id "$HYSTERIA_STATE/latest.json")
cp "$HYSTERIA_STATE/backups/$latest/meta.json" "$HYSTERIA_STATE/pending.json"
bash "$SCRIPT" hysteria recover --yes
[[ ! -f $HYSTERIA_STATE/pending.json ]]
echo 'Hysteria persisted transaction recovery passed'
