#!/usr/bin/env bash
# NAIVE_SINGLE_FILE=1 — standalone Bash runtime, no Python or companion files.
# MIT License; https://github.com/satsuki887/naive-update
# Upstream recipes are literal text; validation intentionally isolates HOME in a subshell.
# shellcheck disable=SC2016,SC2030,SC2031
set -Eeuo pipefail
umask 077
VERSION=2.0.0
REPO=satsuki887/naive-update
UPSTREAM=klzgrad/forwardproxy
BIN=${NAIVE_BIN:-/usr/bin/caddy}
CONFIG=${NAIVE_CONFIG:-/etc/caddy/Caddyfile}
SERVICE=${NAIVE_SERVICE:-caddy.service}
UNIT=${NAIVE_UNIT:-/etc/systemd/system/$SERVICE}
STATE=${NAIVE_STATE:-/var/lib/naive-update}
TOOL=${NAIVE_TOOL:-/usr/bin/naive-update}
DATA=${NAIVE_DATA:-/var/lib/naive-caddy}
RUN_USER=${NAIVE_USER:-naive-caddy}
SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
YES=0 RELEASE=latest OUTPUT=./build JOBS=2 BUILD_DIR='' CONFIG_SOURCE=''
TX='' TX_DONE=0
TEMPS=()
say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少 $1；请运行 deps 安装基础依赖"; }
root() { [[ $EUID == 0 && $(uname -s) == Linux ]] || die '此操作需要 Linux root'; }
ask() { local answer; [[ $YES == 1 ]] && return 0; [[ -t 0 ]] || die '非交互执行需要 --yes'; read -r -p "$1 [y/N]：" answer; [[ $answer == y || $answer == Y ]]; }
prompt() { local value; read -r -p "$2${3:+ [$3]}：" value; printf -v "$1" '%s' "${value:-${3:-}}"; }
digest() { sha256sum -- "$1" | awk '{print $1}'; }
now() { date -u +%Y%m%dT%H%M%SZ; }
tmpdir() { REPLY=$(mktemp -d); TEMPS+=("$REPLY"); }
valid_tag() { [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+-naive[a-zA-Z0-9._-]*$ ]]; }
regular() { [[ -f $1 && ! -L $1 ]] || die "要求普通文件，拒绝符号链接：$1"; }
mutable() { local flags; if command -v lsattr >/dev/null; then flags=$(lsattr -d -- "$1" 2>/dev/null | awk '{print $1}') || return 0; [[ $flags != *i* && $flags != *a* ]] || die "文件 immutable/append-only：$1"; fi; }
download_url() { curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 --proto '=https' --proto-redir '=https' --max-filesize 157286400 "$1" -o "$2"; }
api() { curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 --proto '=https' --proto-redir '=https' -H 'Accept: application/vnd.github+json' -H "User-Agent: naive-update/$VERSION" "https://api.github.com/$1"; }
latest_tag() { REPLY=$1; [[ $REPLY != latest ]] || REPLY=$(api "repos/$UPSTREAM/releases/latest" | jq -er '.tag_name'); valid_tag "$REPLY" || die '需要服务端 vX.Y.Z-naive… 标签，不能使用 Chromium 客户端版本'; }
arch() { case $(uname -m) in x86_64) REPLY=amd64;; aarch64|arm64) REPLY=arm64;; *) die '目前仅支持 amd64、arm64';; esac; }
state_init() {
    root
    [[ $SERVICE =~ ^[a-zA-Z0-9_@.-]+\.service$ && $SERVICE != -* ]] || die '服务名称无效'
    [[ $STATE == /* && $(readlink -m -- "$STATE") == "$STATE" && ! -L $STATE ]] || die '状态目录必须为无符号链接的绝对路径'
    [[ -d $STATE ]] || mkdir -p -- "$STATE"
    [[ $(stat -c %u "$STATE") == 0 && $(stat -c %a "$STATE") == 700 ]] || die '状态目录必须 root:root、0700'
    exec 9>"$STATE/lock"; flock -n 9 || die '另一个管理操作正在运行'
    [[ ! -e $STATE/pending.json || ${1:-} == recover ]] || die '存在未完成事务，请先执行 recover'
}
json_atomic() { local dest=$1 temp; temp=$(mktemp "$(dirname "$dest")/.naive-json.XXXXXX"); cat >"$temp"; jq -e . "$temp" >/dev/null; chmod 600 "$temp"; mv -fT "$temp" "$dest"; sync -f "$(dirname "$dest")"; }
active() { systemctl is-active --quiet "$SERVICE"; }
health() {
    local expected=${1:-} count=0 previous='' pid attempt
    for ((attempt=0; attempt<25; attempt++)); do
        pid=$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null) || pid=0
        if active && [[ $pid =~ ^[0-9]+$ && $pid -gt 1 && -f /proc/$pid/exe ]] && { [[ -z $expected ]] || [[ $(digest "/proc/$pid/exe") == "$expected" ]]; }; then
            if [[ $previous == "$pid" ]]; then count=$((count+1)); else count=1; fi
            previous=$pid; ((count >= 5)) && return 0
        else count=0; fi
        sleep 1
    done
    return 1
}
copy_atomic() {
    local source=$1 dest=$2 temp oldcap newcap
    [[ ! -L $dest ]] || die "目标是符号链接：$dest"
    [[ ! -e $dest ]] || mutable "$dest"
    mkdir -p -- "$(dirname "$dest")"; temp=$(mktemp "$(dirname "$dest")/.naive-stage.XXXXXX"); cp -- "$source" "$temp"
    if [[ -e $dest ]]; then
        cp --attributes-only --preserve=all "$dest" "$temp"
        if command -v getcap >/dev/null; then oldcap=$(getcap "$dest" | cut -d' ' -f2-); newcap=$(getcap "$temp" | cut -d' ' -f2-); [[ $oldcap == "$newcap" ]] || die '无法保留 capabilities'; fi
    else chmod 755 "$temp"; fi
    [[ $(digest "$source") == "$(digest "$temp")" ]] || die '原子复制校验失败'
    sync -f "$temp"; mv -fT "$temp" "$dest"; sync -f "$(dirname "$dest")"
}
snapshot() {
    local kind=$1 id backup was_active=false enabled=false f had_bin=false had_config=false had_unit=false
    id="$(now)-$(openssl rand -hex 4)"; backup=$STATE/backups/$id; mkdir -p "$backup"
    if [[ $kind != bbr ]]; then
        active && was_active=true
        systemctl is-enabled --quiet "$SERVICE" 2>/dev/null && enabled=true
        for f in "$BIN" "$CONFIG" "$UNIT"; do [[ ! -e $f ]] || { regular "$f"; mutable "$f"; }; done
        if [[ -f $BIN ]]; then cp --preserve=all "$BIN" "$backup/caddy"; had_bin=true; fi
        if [[ -f $CONFIG ]]; then cp --preserve=all "$CONFIG" "$backup/Caddyfile"; had_config=true; fi
        if [[ -f $UNIT ]]; then cp --preserve=all "$UNIT" "$backup/unit"; had_unit=true; fi
        systemctl cat "$SERVICE" >"$backup/unit-complete.txt" 2>/dev/null || :
        [[ ! -f $STATE/current-build.json ]] || cp "$STATE/current-build.json" "$backup/build.json"
    fi
    jq -n --arg id "$id" --arg kind "$kind" --arg binary "$BIN" --arg config "$CONFIG" --arg service "$SERVICE" --arg unit "$UNIT" \
        --argjson had_binary "$had_bin" --argjson had_config "$had_config" --argjson had_unit "$had_unit" --argjson active "$was_active" --argjson enabled "$enabled" \
        --arg binary_sha "$([[ $had_bin == false ]] || digest "$backup/caddy")" --arg config_sha "$([[ $had_config == false ]] || digest "$backup/Caddyfile")" --arg unit_sha "$([[ $had_unit == false ]] || digest "$backup/unit")" \
        '{schema:2,id:$id,kind:$kind,binary:$binary,config:$config,service:$service,unit:$unit,had_binary:$had_binary,had_config:$had_config,had_unit:$had_unit,active:$active,enabled:$enabled,binary_sha:$binary_sha,config_sha:$config_sha,unit_sha:$unit_sha}' >"$backup/meta.json"
    REPLY=$id
}
check_snapshot() {
    local id=$1 backup=$STATE/backups/$1 f key
    [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$ ]] || die '无效的备份 ID'
    regular "$backup/meta.json"
    jq -e --arg b "$BIN" --arg c "$CONFIG" --arg s "$SERVICE" --arg u "$UNIT" '.schema==2 and .binary==$b and .config==$c and .service==$s and .unit==$u and (.kind|IN("binary","config","deploy","uninstall","bbr"))' "$backup/meta.json" >/dev/null || die '备份目标不匹配'
    for f in caddy Caddyfile unit; do
        case $f in caddy) key=binary;; Caddyfile) key=config;; unit) key=unit;; esac
        if [[ $(jq -r ".had_$key" "$backup/meta.json") == true ]]; then regular "$backup/$f"; [[ $(digest "$backup/$f") == "$(jq -r ".${key}_sha" "$backup/meta.json")" ]] || die "备份损坏：$f"; fi
    done
}
begin_tx() { TX=$1; TX_DONE=0; json_atomic "$STATE/pending.json" <"$STATE/backups/$TX/meta.json"; }
commit_tx() {
    local id=$TX
    jq -n --arg id "$id" --arg kind "$(jq -r .kind "$STATE/backups/$id/meta.json")" '{id:$id,kind:$kind}' | json_atomic "$STATE/latest.json"
    rm -f "$STATE/pending.json"; sync -f "$STATE"; TX_DONE=1; TX=''; say "操作完成，备份：$STATE/backups/$id"
}
restore_snapshot() (
    set -Eeuo pipefail
    trap - EXIT INT TERM
    local id=$1 backup=$STATE/backups/$1 kind had path file key
    check_snapshot "$id"; kind=$(jq -r .kind "$backup/meta.json")
    if [[ $kind == bbr ]]; then restore_bbr_files "$backup"; return; fi
    for key in binary config unit; do
        case $kind:$key in binary:config|binary:unit|config:binary|config:unit) continue;; esac
        case $key in binary) path=$BIN; file=caddy;; config) path=$CONFIG; file=Caddyfile;; unit) path=$UNIT; file=unit;; esac
        had=$(jq -r ".had_$key" "$backup/meta.json")
        if [[ $had == true ]]; then copy_atomic "$backup/$file" "$path"; cp --attributes-only --preserve=all "$backup/$file" "$path"
        else [[ ! -e $path ]] || { regular "$path"; rm -f -- "$path"; }; fi
    done
    if [[ $kind != config ]]; then if [[ -f $backup/build.json ]]; then json_atomic "$STATE/current-build.json" <"$backup/build.json"; else rm -f "$STATE/current-build.json"; fi; fi
    systemctl daemon-reload
    if [[ $(jq -r .active "$backup/meta.json") == true ]]; then systemctl restart "$SERVICE"; health "$(jq -r .binary_sha "$backup/meta.json")"
    else systemctl stop "$SERVICE" 2>/dev/null || :; fi
    if [[ $kind == deploy || $kind == uninstall ]]; then
        if [[ $(jq -r .enabled "$backup/meta.json") == true ]]; then systemctl enable "$SERVICE"; else systemctl disable "$SERVICE" 2>/dev/null || :; fi
    fi
)
on_exit() {
    local code=$? p
    trap - EXIT INT TERM
    if [[ -n $TX && $TX_DONE == 0 ]]; then
        say '操作未完成，正在恢复切换前状态……' >&2
        # Run a separate strict shell: calling a function in `if` disables errexit.
        if bash "$SELF" internal-restore "$TX"; then rm -f "$STATE/pending.json"; say '恢复完成' >&2
        else say "自动恢复未完成；保留 pending.json 和备份，请执行 recover：$STATE" >&2; code=1; fi
    fi
    for p in "${TEMPS[@]}"; do [[ ! -d $p || $p != /tmp/tmp.* ]] || rm -rf -- "$p"; done
    exit "$code"
}
validate_config() (
    set -Eeuo pipefail
    local executable=$1 candidate=$2 log=$3 pid arg prev='' actual_config='' uid gid groups cwd var user runtime_home
    if active; then
        pid=$(systemctl show "$SERVICE" -p MainPID --value); [[ $pid =~ ^[0-9]+$ && $pid -gt 1 ]] || die '服务主进程无效'
        [[ /proc/$pid/exe -ef $BIN ]] || die '服务主进程不是目标 Caddy'
        while IFS= read -r -d '' arg; do
            case $arg in --resume|--envfile|--envfile=*) die '不支持 --resume/--envfile 启动';; esac
            if [[ $prev == --config || $prev == -c ]]; then actual_config=$arg; fi
            case $arg in --config=*) actual_config=${arg#*=};; esac; prev=$arg
        done <"/proc/$pid/cmdline"
        cwd=$(readlink -f "/proc/$pid/cwd"); [[ $actual_config == /* ]] || actual_config=$cwd/$actual_config
        [[ $(readlink -m "$actual_config") == "$(readlink -m "$CONFIG")" ]] || die '运行配置路径不匹配'
        uid=$(awk '/^Uid:/{print $3}' "/proc/$pid/status"); gid=$(awk '/^Gid:/{print $3}' "/proc/$pid/status")
        groups=$(awk '/^Groups:/{for(i=2;i<=NF;i++)printf "%s%s",(i==2?"":","),$i}' "/proc/$pid/status")
        while IFS= read -r -d '' var; do [[ $var != *=* ]] || export "${var?}"; done <"/proc/$pid/environ"
    else
        user=${VALIDATE_USER:-$(systemctl show "$SERVICE" -p User --value 2>/dev/null || :)}; user=${user:-root}
        [[ -n ${VALIDATE_USER:-} || -z $(systemctl show "$SERVICE" -p EnvironmentFiles --value 2>/dev/null || :) ]] || die '服务停止且有 EnvironmentFile；请先启动再验证'
        uid=$(id -u "$user"); gid=$(id -g "$user"); groups=$(id -G "$user" | tr ' ' ','); cwd=${VALIDATE_CWD:-/}; runtime_home=$(getent passwd "$user" | cut -d: -f6); export HOME=$runtime_home
    fi
    cd "$cwd"
    if [[ -n $groups ]]; then setpriv --reuid "$uid" --regid "$gid" --groups "$groups" -- "$executable" validate --config "$candidate" --adapter caddyfile >"$log" 2>&1
    else setpriv --reuid "$uid" --regid "$gid" --clear-groups -- "$executable" validate --config "$candidate" --adapter caddyfile >"$log" 2>&1; fi
)

verify_build() {
    local dir=$1
    regular "$dir/caddy"; regular "$dir/build.json"
    jq -e '.schema==1 and .forwardproxy.repository=="https://github.com/klzgrad/forwardproxy.git" and .caddy.repository=="https://github.com/caddyserver/caddy.git" and (.sha256|test("^[a-f0-9]{64}$"))' "$dir/build.json" >/dev/null || die '构建记录格式或来源无效'
    [[ $(digest "$dir/caddy") == "$(jq -r .sha256 "$dir/build.json")" ]] || die '二进制 SHA256 不匹配'
    valid_tag "$(jq -r .release "$dir/build.json")" || die '构建标签无效'
}
fetch_build() {
    local tag=$RELEASE meta name url sums hash actual asset_digest machine listing expected work
    arch; machine=$REPLY
    if [[ $tag == latest ]]; then meta=$(api "repos/$REPO/releases/latest"); tag=$(jq -r .tag_name <<<"$meta"); tag=${tag#server-}
    else valid_tag "$tag" || die '服务端标签无效'; meta=$(api "repos/$REPO/releases/tags/server-$tag"); fi
    valid_tag "$tag" || die '下载版本无效'; [[ ! -e $OUTPUT ]] || die "输出目录已存在：$OUTPUT"
    tmpdir; work=$REPLY; name=naive-server-$tag-linux-$machine.tar.gz
    url=$(jq -er --arg name "$name" '.assets[]|select(.name==$name)|.browser_download_url' <<<"$meta")
    sums=$(jq -er '.assets[]|select(.name=="SHA256SUMS")|.browser_download_url' <<<"$meta")
    [[ $url == "https://github.com/$REPO/releases/download/"* && $sums == "https://github.com/$REPO/releases/download/"* ]] || die '拒绝非本仓库发布地址'
    say "下载 $tag / $machine"; download_url "$url" "$work/bundle.tar.gz"; download_url "$sums" "$work/SHA256SUMS"
    hash=$(awk -v name="$name" '$2==name&&length($1)==64&&$1!~/[^0-9a-f]/{print $1;n++} END{if(n!=1)exit 1}' "$work/SHA256SUMS")
    actual=$(digest "$work/bundle.tar.gz"); [[ $hash == "$actual" ]] || die '压缩包 SHA256 校验失败'
    asset_digest=$(jq -r --arg name "$name" '.assets[]|select(.name==$name)|.digest//empty' <<<"$meta")
    [[ -z $asset_digest || $asset_digest == "sha256:$actual" ]] || die 'GitHub 资产摘要不匹配'
    listing=$(timeout 60 tar -tzf "$work/bundle.tar.gz" | LC_ALL=C sort)
    expected=$(printf '%s\n' LICENSES.txt SHA256SUMS build-info.txt build.json caddy | LC_ALL=C sort)
    [[ $listing == "$expected" ]] || die '安装包文件列表不符'
    timeout 60 tar -tvzf "$work/bundle.tar.gz" | awk 'substr($1,1,1)!="-"{bad=1}{size+=$3} END{exit(bad||size>157286400)}' || die '安装包含链接、特殊文件或过大内容'
    mkdir -m700 "$work/artifact"; tar -xzf "$work/bundle.tar.gz" --no-same-owner --no-same-permissions -C "$work/artifact"
    chmod 755 "$work/artifact/caddy"; verify_build "$work/artifact"
    [[ $(jq -r .goarch "$work/artifact/build.json") == "$machine" && $(jq -r .release "$work/artifact/build.json") == "$tag" ]] || die '版本或架构不符'
    mkdir -p "$(dirname "$OUTPUT")"; cp -R "$work/artifact" "$OUTPUT"; say "已校验，尚未安装：$OUTPUT"
}
clone_tag() { git init -q "$3"; git -C "$3" remote add origin "$1"; git -C "$3" fetch --depth=1 --no-tags origin "refs/tags/$2"; git -C "$3" checkout -q --detach FETCH_HEAD; }
plan() {
    local src=$1 line tokens cleaned go_line
    CADDY_VERSION=$(tr -d '\r\n' <"$src/CADDY_VERSION")
    [[ $CADDY_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '上游 Caddy 版本无法识别'
    grep -Fq 'repository: caddyserver/caddy' "$src/.github/workflows/build.yml" || die '官方 CI 结构变化'
    grep -Fq -- '--replace "github.com/caddyserver/caddy/v2=$GITHUB_WORKSPACE/.caddy-bbr" --with "github.com/caddyserver/forwardproxy=$GITHUB_WORKSPACE"' "$src/.github/workflows/build.yml" || die '官方 CI 参数变化'
    line=$(grep -E '^ *- run: git -C \.caddy-bbr apply ' "$src/.github/workflows/build.yml")
    [[ $(printf '%s\n' "$line" | wc -l) == 1 ]] || die '官方补丁步骤不唯一'
    tokens=${line#*apply }; cleaned=$(sed -E 's/"\$GITHUB_WORKSPACE\/[A-Za-z0-9_.-]+\.patch"//g;s/[[:space:]]//g' <<<"$tokens")
    [[ -z $cleaned ]] || die '官方补丁语法改变'
    mapfile -t PATCHES < <(grep -oE '\$GITHUB_WORKSPACE/[A-Za-z0-9_.-]+\.patch' <<<"$tokens" | cut -d/ -f2)
    ((${#PATCHES[@]})) || die '补丁列表为空'; for line in "${PATCHES[@]}"; do regular "$src/$line"; done
    while IFS= read -r line; do
        # This matches the literal upstream CI command, not an executable home path.
        # shellcheck disable=SC2088
        case $line in "printf 'CADDY_VERSION="*|"git -C .caddy-bbr apply "*|"go install github.com/caddyserver/xcaddy/cmd/xcaddy@"*|'~/go/bin/xcaddy build "$CADDY_VERSION"'*) :;; *) die '上游 CI 新增步骤，需要人工适配';; esac
    done < <(sed -nE 's/^ *- run: (.*)$/\1/p' "$src/.github/workflows/build.yml")
    go_line=$(grep 'go-version:' "$src/.github/workflows/build.yml"); [[ $go_line =~ ([0-9]+)\.([0-9]+)\.x ]] || die '无法识别 Go 要求'
    GO_MIN=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}
}
go_toolchain() {
    local min=$1 version='' machine metadata name sha cache dir work
    if command -v go >/dev/null; then version=$(GOTOOLCHAIN=local go version | awk '{print $3}' | sed 's/^go//'); fi
    if [[ -n $version && $(printf '%s\n' "$min.0" "$version" | sort -V | head -n1) == "$min.0" ]]; then return; fi
    ask "需要 Go $min+，是否从 go.dev 安装独立工具链（不替换系统 Go）？" || die 'Go 版本不足'
    arch; machine=$REPLY
    metadata=$(curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 'https://go.dev/dl/?mode=json&include=all')
    metadata=$(jq -ec --arg min "go$min." --arg arch "$machine" '[.[]|select(.stable and (.version|startswith($min)))|.version as $v|.files[]|select(.os=="linux" and .arch==$arch and .kind=="archive")|{version:$v,filename,sha256}][0]//error("no matching Go")' <<<"$metadata")
    version=$(jq -r .version <<<"$metadata"); name=$(jq -r .filename <<<"$metadata"); sha=$(jq -r .sha256 <<<"$metadata")
    [[ $name =~ ^go[0-9.]+\.linux-(amd64|arm64)\.tar\.gz$ && $sha =~ ^[a-f0-9]{64}$ ]] || die 'Go 元数据无效'
    cache=${XDG_CACHE_HOME:-$HOME/.cache}/naive-update/toolchains; mkdir -p "$cache"; dir=$cache/$version-$machine
    if [[ ! -x $dir/bin/go ]]; then
        tmpdir; work=$REPLY; download_url "https://go.dev/dl/$name" "$work/go.tar.gz"
        [[ $(digest "$work/go.tar.gz") == "$sha" ]] || die 'Go 校验失败'
        tar -xzf "$work/go.tar.gz" -C "$work"; [[ ! -e $dir ]] || die '工具链目录异常'; mv "$work/go" "$dir"
    fi
    export PATH="$dir/bin:$PATH"; unset GOROOT
}
build_source() {
    need git; arch; local machine=$REPLY tag work target patch xcaddy_version fc cc
    latest_tag "$RELEASE"; tag=$REPLY; [[ ! -e $OUTPUT ]] || die "输出目录已存在：$OUTPUT"
    mkdir -p "$(dirname "$OUTPUT")"; target=$(readlink -m "$OUTPUT"); work=$(mktemp -d "$(dirname "$target")/.naive-build.XXXXXX")
    say "构建 $tag；诊断日志：$work/build.log"
    clone_tag "https://github.com/$UPSTREAM.git" "$tag" "$work/forwardproxy" >>"$work/build.log" 2>&1
    plan "$work/forwardproxy"; go_toolchain "$GO_MIN"
    (
        set -Eeuo pipefail
        clone_tag https://github.com/caddyserver/caddy.git "$CADDY_VERSION" "$work/caddy-source"
        for patch in "${PATCHES[@]}"; do git -C "$work/caddy-source" apply --check "$work/forwardproxy/$patch"; git -C "$work/caddy-source" apply "$work/forwardproxy/$patch"; done
        local key; while IFS= read -r key; do [[ $key != XCADDY_* ]] || unset "$key"; done < <(compgen -e)
        export GOTOOLCHAIN=local GOENV=off GO111MODULE=on CGO_ENABLED=0 GOOS=linux GOARCH="$machine" GOAMD64=v1
        export GOPROXY=https://proxy.golang.org,direct GOSUMDB=sum.golang.org GOPRIVATE='' GONOPROXY='' GONOSUMDB='' GOINSECURE='' GOWORK=off GOFLAGS='' GOEXPERIMENT=''
        export GOMAXPROCS=$JOBS GOBIN=$work/tools XCADDY_SETCAP=0
        cd "$work"; xcaddy_version=$(go list -m -json github.com/caddyserver/xcaddy@latest | jq -er .Version)
        [[ $xcaddy_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'xcaddy 版本异常'
        go install "github.com/caddyserver/xcaddy/cmd/xcaddy@$xcaddy_version"
        "$work/tools/xcaddy" build "$CADDY_VERSION" --replace "github.com/caddyserver/caddy/v2=$work/caddy-source" --with "github.com/caddyserver/forwardproxy=$work/forwardproxy" --output "$work/caddy"
        "$work/caddy" list-modules | grep -Fx 'http.handlers.forward_proxy'
        [[ $("$work/caddy" version | awk '{print $1}') == "$CADDY_VERSION" ]] || die 'Caddy 版本不符'
        fc=$(git -C "$work/forwardproxy" rev-parse HEAD); cc=$(git -C "$work/caddy-source" rev-parse HEAD)
        for patch in "${PATCHES[@]}"; do jq -n --arg name "$patch" --arg sha "$(digest "$work/forwardproxy/$patch")" '{name:$name,sha256:$sha}'; done | jq -s . >"$work/patches.json"
        jq -n --arg release "$tag" --arg tool "$VERSION" --arg sha "$(digest "$work/caddy")" --arg go "$(go version)" --arg arch "$machine" --arg xcaddy "$xcaddy_version" --arg caddy "$CADDY_VERSION" --arg fc "$fc" --arg cc "$cc" --slurpfile patches "$work/patches.json" \
            '{schema:1,release:$release,tool_version:$tool,sha256:$sha,go:$go,goarch:$arch,xcaddy:$xcaddy,forwardproxy:{repository:"https://github.com/klzgrad/forwardproxy.git",commit:$fc},caddy:{repository:"https://github.com/caddyserver/caddy.git",version:$caddy,commit:$cc},patches:$patches[0]}' >"$work/build.json"
        "$work/caddy" build-info >"$work/build-info.txt"
        { cat "$work/caddy-source/LICENSE"; printf '\n\nForwardproxy / Naive fork\n\n'; cat "$work/forwardproxy/LICENSE"; } >"$work/LICENSES.txt"
        printf '%s  caddy\n' "$(digest "$work/caddy")" >"$work/SHA256SUMS"
    ) >>"$work/build.log" 2>&1
    verify_build "$work"; mv "$work" "$target"; say "编译成功，尚未安装：$target"
}
install_binary() {
    local dir=$1 id stage expected
    verify_build "$dir"; regular "$BIN"; regular "$CONFIG"; mutable "$BIN"
    ask '替换 Caddy 并重启服务？主配置保持原样' || return 0
    snapshot binary; id=$REPLY
    stage=$(mktemp "$(dirname "$BIN")/.naive-validate.XXXXXX"); cp "$dir/caddy" "$stage"; cp --attributes-only --preserve=all "$BIN" "$stage"
    expected=$(jq -r .sha256 "$dir/build.json"); [[ $(digest "$stage") == "$expected" ]] || die '候选程序在校验后变化'
    validate_config "$stage" "$CONFIG" "$STATE/backups/$id/validate.log" || { rm -f "$stage"; die "配置验证失败，服务未动：$STATE/backups/$id/validate.log"; }
    [[ $(digest "$BIN") == "$(jq -r .binary_sha "$STATE/backups/$id/meta.json")" && $(digest "$CONFIG") == "$(jq -r .config_sha "$STATE/backups/$id/meta.json")" ]] || die '验证期间程序或配置已改变'
    begin_tx "$id"; mv -fT "$stage" "$BIN"; sync -f "$(dirname "$BIN")"
    if [[ $(jq -r .active "$STATE/backups/$id/meta.json") == true ]]; then systemctl restart "$SERVICE"; health "$expected"; fi
    json_atomic "$STATE/current-build.json" <"$dir/build.json"; commit_tx; say '请再用 Naive 客户端验证代理流量。'
}
apply_config() {
    local candidate=$1 id stage
    regular "$CONFIG"; snapshot config; id=$REPLY
    stage=$(mktemp "$(dirname "$CONFIG")/.naive-config.XXXXXX"); cp "$candidate" "$stage"; cp --attributes-only --preserve=all "$CONFIG" "$stage"
    validate_config "$BIN" "$stage" "$STATE/backups/$id/validate.log" || { rm -f "$stage"; die "配置无效，原文件未替换：$STATE/backups/$id/validate.log"; }
    [[ $(digest "$CONFIG") == "$(jq -r .config_sha "$STATE/backups/$id/meta.json")" ]] || die '编辑期间原文件已被其他程序修改'
    begin_tx "$id"; mv -fT "$stage" "$CONFIG"; sync -f "$(dirname "$CONFIG")"
    if active; then systemctl reload "$SERVICE"; health "$(digest "$BIN")"; fi; commit_tx
}
edit_config() {
    local candidate; local -a editor
    regular "$CONFIG"; candidate=$(mktemp "$(dirname "$CONFIG")/.naive-edit.XXXXXX"); cp --preserve=all "$CONFIG" "$candidate"
    read -r -a editor <<<"${VISUAL:-${EDITOR:-vi}}"; "${editor[@]}" "$candidate"
    ask '验证并应用编辑结果？' || { rm -f "$candidate"; return; }
    apply_config "$candidate"; rm -f "$candidate"
}
reload_config() {
    local id; snapshot config; id=$REPLY
    validate_config "$BIN" "$CONFIG" "$STATE/backups/$id/validate.log" || die "配置无效，不重载：$STATE/backups/$id/validate.log"
    ask '重新加载现有 Caddyfile？' || return 0
    systemctl reload "$SERVICE"; health "$(digest "$BIN")"; say '验证并重载完成，配置未重写'
}
quote() { jq -Rs .; }
valid_domain() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && $1 == *.* && $1 != *..* && ${#1} -le 253 ]]; }
valid_credential() { [[ -n $1 && $1 != *'{'* && $1 != *'}'* && ! $1 =~ [[:cntrl:]] ]]; }
render_config() {
    local domain=$1 port=$2 username=$3 password=$4 mode=$5 tls_value=$6 camouflage=$7 www=$8
    valid_domain "$domain" || die '域名无效'; [[ $port =~ ^[0-9]+$ && $port -gt 0 && $port -le 65535 ]] || die '端口无效'
    if ! valid_credential "$username" || [[ $username == *:* ]] || ! valid_credential "$password"; then die '凭证不能为空或含控制字符、花括号；用户名不能含冒号'; fi
    printf '{\n'; [[ $camouflage != local ]] || printf '\torder forward_proxy before file_server\n'
    printf '\tlog {\n\t\texclude http.log.error\n\t}\n}\n'
    if [[ $port == 443 ]]; then printf ':443, %s {\n' "$domain"; else printf ':%s, %s:%s {\n' "$port" "$domain" "$port"; fi
    case $mode in auto) [[ -z $tls_value ]] || printf '\ttls %s\n' "$(printf %s "$tls_value" | quote)";; manual) printf '\ttls %s %s\n' "$(printf %s "$tls_value/cert.crt" | quote)" "$(printf %s "$tls_value/private.key" | quote)";; *) die '证书模式无效';; esac
    if [[ $camouflage == local ]]; then printf '\tencode\n'; else printf '\troute {\n'; fi
    printf '\tforward_proxy {\n\t\tbasic_auth %s %s\n\t\thide_ip\n\t\thide_via\n\t\tprobe_resistance\n\t}\n' "$(printf %s "$username" | quote)" "$(printf %s "$password" | quote)"
    if [[ $camouflage == local ]]; then printf '\tfile_server {\n\t\troot %s\n\t}\n' "$(printf %s "$www" | quote)"
    else [[ $camouflage =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || die '伪装站须为 HTTPS 域名地址，不带路径或凭证'; printf '\treverse_proxy %s\n\t}\n' "$camouflage"; fi
    printf '}\n'
}
examples() {
    local dir; dir=$(dirname "$CONFIG")/examples; mkdir -p "$dir"; chmod 755 "$dir"
    render_config example.com 443 CHANGE_ME CHANGE_ME auto '' local /var/lib/naive-caddy/www >"$dir/Caddyfile.standard"
    cat >"$dir/optional-snippets.txt" <<'EOF'
# 可选片段，不会被主配置自动加载。请手工复制所需内容并验证。
# 默认不限制 HTTP 协议，不拦截 IP，不放行额外私网地址。

# 全局 options 块中限制 HTTP/1.1 + HTTP/2（关闭 HTTP/3）
# servers {
#     protocols h1 h2
# }

# 在站点中声明 matcher；在 route 内 forward_proxy 之前执行 abort
# @denied remote_ip 203.0.113.0/24 198.51.100.0/24
# route {
#     abort @denied
#     forward_proxy { ... }
#     reverse_proxy https://example.org
# }

# 在 forward_proxy 中仅放行确有需要的私网目标
# acl {
#     allow 172.20.0.2
# }

# 站点级访问日志；先创建服务用户可写的目录
# log {
#     output file /var/log/naive-caddy/access.log {
#         roll_size 20mb
#         roll_keep 5
#     }
#     format filter {
#         wrap json
#         fields {
#             request>headers delete
#             request>tls delete
#             resp_headers delete
#         }
#     }
# }

# 多用户：forward_proxy 中添加多行 basic_auth "user" "password"
# 多监听端口：:443, example.com:443, :8443, example.com:8443 {
# ports 子指令限制出站目标端口，不是监听端口。
# HTTPS 伪装站：reverse_proxy https://example.org
# Caddy 2.11+ 自动设置 HTTPS 上游 Host，不必添加旧 header_up Host {upstream_hostport}。
# 可选：forward_proxy 中添加 upstream socks5://127.0.0.1:40000
# 这才会把代理出站送入已启用的 WARP 本地代理；不会自动添加。
EOF
    chmod 644 "$dir/Caddyfile.standard" "$dir/optional-snippets.txt"
}
new_user() {
    if ! id "$RUN_USER" >/dev/null 2>&1; then useradd --system --user-group --home-dir "$DATA" --shell /usr/sbin/nologin "$RUN_USER"; fi
    mkdir -p "$DATA/www"; chown "$RUN_USER:$(id -gn "$RUN_USER")" "$DATA" "$DATA/www"; chmod 750 "$DATA"; chmod 755 "$DATA/www"
    [[ -f $DATA/www/index.html ]] || printf '<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>\n' >"$DATA/www/index.html"
    chmod 644 "$DATA/www/index.html"
}
check_cert_pair() {
    local cert=$1 key=$2 domain=${3:-} public_cert public_key
    regular "$cert"; regular "$key"; openssl x509 -in "$cert" -noout -checkend 0 >/dev/null || die '证书无效或已过期'
    public_cert=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)
    public_key=$(openssl pkey -in "$key" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum)
    [[ $public_cert == "$public_key" ]] || die '证书/私钥不匹配，或私钥仍被口令加密'
    [[ -z $domain ]] || openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null || die '证书域名不匹配'
}
install_tool() {
    root; regular "$SELF"; bash -n "$SELF"
    if [[ $SELF != "$TOOL" ]]; then
        if [[ -e $TOOL ]]; then regular "$TOOL"; grep -q 'NAIVE_SINGLE_FILE=1' "$TOOL" || die "快捷路径被其他程序占用：$TOOL"; fi
        copy_atomic "$SELF" "$TOOL"; chmod 755 "$TOOL"
    fi
    say "快捷命令：$TOOL（输入 naive-update 打开菜单）"
}
install_na_alias() {
    install_tool; ask '接管 /usr/bin/na？旧脚本会备份，服务配置不变' || return 0
    if [[ -e /usr/bin/na ]]; then regular /usr/bin/na; cp --preserve=all /usr/bin/na "$STATE/old-na-$(now).sh"; fi
    copy_atomic "$SELF" /usr/bin/na; chmod 755 /usr/bin/na
}
deploy() {
    local dir=$BUILD_DIR id candidate domain port username password certmode email='' cert='' key='' camouflage choice certdir='' group stage
    [[ ! -e $BIN && ! -e $CONFIG && ! -e $UNIT ]] || die '检测到现有部署，请使用升级/配置管理，不覆盖安装'
    [[ $(systemctl show "$SERVICE" -p LoadState --value 2>/dev/null || :) != loaded ]] || die '已存在同名 systemd 服务，不覆盖部署'
    ask '安装全新服务端、创建独立运行用户和 systemd 服务并启动？' || return 0
    if [[ -z $dir ]]; then
        prompt choice '程序来源：1 本仓库 CI 包，2 本地官方源码编译' 1
        OUTPUT=$STATE/artifacts/$(now); mkdir -p "$STATE/artifacts"
        case $choice in 1) fetch_build;; 2) build_source;; *) die '无效选项';; esac; dir=$OUTPUT
    fi
    verify_build "$dir"; new_user; group=$(id -gn "$RUN_USER")
    mkdir -p "$(dirname "$CONFIG")" "$(dirname "$BIN")" "$(dirname "$UNIT")"; chmod 755 "$(dirname "$CONFIG")"
    candidate=$(mktemp "$(dirname "$CONFIG")/.naive-new.XXXXXX")
    if [[ -n $CONFIG_SOURCE ]]; then regular "$CONFIG_SOURCE"; cp "$CONFIG_SOURCE" "$candidate"
    else
        prompt domain '域名（先解析到本服务器）'; valid_domain "$domain" || die '无效域名'
        prompt port 'HTTPS 端口' 443; prompt username '代理用户名'
        read -r -s -p '代理密码（留空随机生成）：' password; say ''; [[ -n $password ]] || password=$(openssl rand -hex 16)
        prompt choice '证书：1 Caddy 自动 ACME，2 已有完整链证书和私钥' 1
        case $choice in
            1) certmode=auto; prompt email 'ACME 邮箱（可留空）'; say '自动签发需域名解析正确，公网 80 或 443 可完成验证。';;
            2) certmode=manual; prompt cert '完整链证书文件'; prompt key '无口令私钥文件'; check_cert_pair "$cert" "$key" "$domain"
               certdir=$(dirname "$CONFIG")/naive-certs/$(now); mkdir -p "$certdir"; chmod 750 "$(dirname "$certdir")" "$certdir"; chgrp "$group" "$(dirname "$certdir")" "$certdir"
               install -m640 -o root -g "$group" "$cert" "$certdir/cert.crt"; install -m640 -o root -g "$group" "$key" "$certdir/private.key";;
            *) die '无效证书选项';;
        esac
        prompt camouflage '伪装：local 本地静态页，或 https://域名' local
        if [[ $certmode == auto ]]; then render_config "$domain" "$port" "$username" "$password" auto "$email" "$camouflage" "$DATA/www" >"$candidate"
        else render_config "$domain" "$port" "$username" "$password" manual "$certdir" "$camouflage" "$DATA/www" >"$candidate"; fi
    fi
    chmod 640 "$candidate"; chown "root:$group" "$candidate"; snapshot deploy; id=$REPLY
    stage=$(mktemp "$(dirname "$BIN")/.naive-new-bin.XXXXXX"); install -m755 "$dir/caddy" "$stage"
    VALIDATE_USER=$RUN_USER VALIDATE_CWD=$DATA validate_config "$stage" "$candidate" "$STATE/backups/$id/validate.log" || die "配置验证失败：$STATE/backups/$id/validate.log"
    [[ $(digest "$stage") == "$(jq -r .sha256 "$dir/build.json")" ]] || die '程序校验后改变'
    begin_tx "$id"; mv -fT "$stage" "$BIN"; mv -fT "$candidate" "$CONFIG"
    cat >"$UNIT" <<EOF
[Unit]
Description=Naive Caddy forwardproxy
Documentation=https://github.com/klzgrad/naiveproxy
After=network-online.target
Wants=network-online.target
[Service]
Type=notify
User=$RUN_USER
Group=$group
WorkingDirectory=$DATA
ExecStart=$BIN run --config $CONFIG --adapter caddyfile
ExecReload=$BIN reload --config $CONFIG --adapter caddyfile
TimeoutStopSec=30s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
Restart=on-failure
RestartSec=3s
[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$UNIT"; systemctl daemon-reload; systemctl enable --now "$SERVICE"; health "$(digest "$BIN")"
    json_atomic "$STATE/current-build.json" <"$dir/build.json"; commit_tx; examples; install_tool
    say "安装成功；主配置：$CONFIG；可选示例：$(dirname "$CONFIG")/examples/"
    say '请按监听配置放行系统防火墙/云安全组的 TCP；需要 HTTP/3 时另放行对应 UDP。'
}
adapt_json() { tmpdir; ADAPTED=$REPLY/config.json; "$BIN" adapt --config "$CONFIG" --adapter caddyfile >"$ADAPTED"; }
share() {
    local domain ports entry username password port proxy link credentials
    ask '显示包含代理密码的分享信息？' || return 0
    adapt_json
    [[ $(jq '[..|objects|select(.handler? == "forward_proxy")]|length' "$ADAPTED") == 1 ]] || die '分享导出仅支持单个 forward_proxy 站点；多独立站点请分别手工导出'
    domain=$(jq -r '[..|objects|.host? // empty|select(type=="array")|.[]][0] // empty' "$ADAPTED")
    [[ -n $domain ]] || prompt domain '未自动识别域名，请输入证书域名'
    valid_domain "$domain" || die '域名无效'
    ports=$(jq -r '[.apps.http.servers[]?.listen[]?|capture(":(?<port>[0-9]+)$").port]|unique|.[]' "$ADAPTED")
    [[ -n $ports ]] || die '无法识别监听端口'
    credentials=$(jq -er '[..|objects|select(.handler? == "forward_proxy")|.auth_credentials[]?|@base64d|@base64d]|if length>0 then .[] else error("no naive credentials") end' "$ADAPTED")
    while IFS= read -r entry; do
        username=${entry%%:*}; password=${entry#*:}
        username=$(printf %s "$username" | jq -sRr @uri); password=$(printf %s "$password" | jq -sRr @uri)
        while IFS= read -r port; do
            proxy=https://$username:$password@$domain:$port
            link=naive+$proxy
            say "$link"
            printf '%s' "$proxy" | jq -Rs '{listen:"socks://127.0.0.1:1080",proxy:.}'
            if command -v qrencode >/dev/null; then qrencode -t ANSIUTF8 "$link"; fi
        done <<<"$ports"
    done <<<"$credentials"
}
cert_status() {
    local cert key
    adapt_json
    while IFS=$'\t' read -r cert key; do
        [[ -f $cert ]] || continue
        openssl x509 -in "$cert" -noout -subject -issuer -dates -ext subjectAltName
        [[ -z $key ]] || check_cert_pair "$cert" "$key"
    done < <(jq -r '.apps.tls.certificates.load_files[]?|[.certificate,.key]|@tsv' "$ADAPTED")
    say '自动 ACME：由 Caddy 按自身策略续期；请结合服务日志查看签发/续期结果。'
    find "$DATA" -type f -name '*.crt' -print 2>/dev/null || :
}
acme_existing() {
    local action=$1 domain client=${ACME_HOME:-$HOME/.acme.sh}/acme.sh
    regular "$client"; [[ $(stat -c %u "$client") == 0 ]] || die 'acme.sh 必须由 root 拥有'
    case $action in list) "$client" --list;; renew) prompt domain '已有 acme.sh 证书域名'; valid_domain "$domain" || die '域名无效'; ask '调用已有 acme.sh 执行续期（不强制重签）？' || return; "$client" --renew -d "$domain";; esac
    say '如使用外部证书，请在 Caddyfile 指向 acme.sh 的 install-cert 输出路径，并配置成功后 reload 的续期钩子。'
}
bbr_status() { sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc; }
BBR_FILE=${NAIVE_BBR_FILE:-/etc/sysctl.d/90-naive-update-bbr.conf}
restore_bbr_files() {
    local backup=$1
    regular "$backup/bbr.json"
    [[ $(jq -r .path "$backup/bbr.json") == "$BBR_FILE" ]] || die 'BBR 恢复路径不匹配'
    if [[ -f $backup/bbr.conf ]]; then copy_atomic "$backup/bbr.conf" "$BBR_FILE"; cp --attributes-only --preserve=all "$backup/bbr.conf" "$BBR_FILE"; else [[ ! -e $BBR_FILE ]] || { regular "$BBR_FILE"; rm -f "$BBR_FILE"; }; fi
    sysctl -w "net.core.default_qdisc=$(jq -r .qdisc "$backup/bbr.json")" "net.ipv4.tcp_congestion_control=$(jq -r .congestion "$backup/bbr.json")"
}
bbr_set() {
    local algorithm=$1 qdisc=$2 id backup
    ask "设置 $algorithm + $qdisc，并写入独立 sysctl 文件？不替换内核" || return 0
    [[ ! -e $BBR_FILE ]] || { regular "$BBR_FILE"; mutable "$BBR_FILE"; }
    if [[ $algorithm == bbr ]]; then
        if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then modprobe tcp_bbr; fi
        sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr || die '当前内核不支持 BBR'
    fi
    snapshot bbr; id=$REPLY; backup=$STATE/backups/$id
    [[ ! -f $BBR_FILE ]] || cp --preserve=all "$BBR_FILE" "$backup/bbr.conf"
    jq -n --arg path "$BBR_FILE" --arg congestion "$(sysctl -n net.ipv4.tcp_congestion_control)" --arg qdisc "$(sysctl -n net.core.default_qdisc)" '{path:$path,congestion:$congestion,qdisc:$qdisc}' >"$backup/bbr.json"
    begin_tx "$id"; mkdir -p "$(dirname "$BBR_FILE")"
    printf '# Managed by naive-update; rollback restores previous settings\nnet.core.default_qdisc = %s\nnet.ipv4.tcp_congestion_control = %s\n' "$qdisc" "$algorithm" >"$backup/new-bbr.conf"
    copy_atomic "$backup/new-bbr.conf" "$BBR_FILE"; chmod 644 "$BBR_FILE"; sysctl -p "$BBR_FILE"
    [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "$algorithm" ]] || die '拥塞控制设置未生效'; commit_tx
}
deps() {
    root; ask '通过系统软件源安装 Bash 工具依赖（不添加旧 Go 源）？' || return 0
    if command -v apt-get >/dev/null; then apt-get update; apt-get install -y bash curl jq ca-certificates tar gzip coreutils util-linux openssl git qrencode gnupg
    elif command -v dnf >/dev/null; then dnf install -y bash curl jq ca-certificates tar gzip coreutils util-linux openssl git; say '二维码可选：系统仓库提供 qrencode 时可自行安装。'
    else die '请手工安装 bash curl jq ca-certificates tar gzip coreutils util-linux openssl git'; fi
}
warp_install() {
    local work id codename version os_values
    local -a os_info
    ask '添加 Cloudflare 官方软件源并安装 WARP？不会连接或修改默认路由' || return 0
    tmpdir; work=$REPLY
    # /etc/os-release is a root-owned operating-system file, not remote input.
    # shellcheck disable=SC1091
    os_values=$(. /etc/os-release; printf '%s\n%s\n%s\n' "$ID" "${VERSION_CODENAME:-}" "${VERSION_ID%%.*}")
    mapfile -t os_info <<<"$os_values"; id=${os_info[0]}; codename=${os_info[1]}; version=${os_info[2]}
    if command -v apt-get >/dev/null; then
        [[ $id == debian || $id == ubuntu ]] || die '请按 Cloudflare 官方文档为该发行版安装 WARP'
        [[ $codename =~ ^[a-z]+$ ]] || die '发行版代号无法识别'; need gpg
        download_url https://pkg.cloudflareclient.com/pubkey.gpg "$work/pubkey.gpg"
        gpg --batch --yes --dearmor -o "$work/keyring.gpg" "$work/pubkey.gpg"
        install -m644 "$work/keyring.gpg" /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$codename" >"$work/warp.list"
        install -m644 "$work/warp.list" /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update; apt-get install -y cloudflare-warp
    elif command -v dnf >/dev/null; then
        [[ $version -ge 9 ]] || die '当前官方 RPM 流程面向 RHEL 9/10 及兼容系统'
        if ! rpm -q epel-release >/dev/null; then ask 'Cloudflare RHEL 包需要 EPEL；安装系统提供的 epel-release？' || return; dnf install -y epel-release; fi
        download_url https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo "$work/warp.repo"
        grep -Fq 'https://pkg.cloudflareclient.com/' "$work/warp.repo" || die 'Cloudflare repo 内容无效'
        grep -Eq '^gpgcheck *= *1' "$work/warp.repo" || die 'Cloudflare repo 未启用 GPG 校验'
        [[ ! -e /etc/yum.repos.d/cloudflare-warp.repo ]] || cp --preserve=all /etc/yum.repos.d/cloudflare-warp.repo "$STATE/warp-repo-$(now).bak"
        install -m644 "$work/warp.repo" /etc/yum.repos.d/cloudflare-warp.repo
        dnf install -y cloudflare-warp
    else die '该平台请按 Cloudflare 官方文档安装 WARP'; fi
    say '已安装。连接前请在 WARP 菜单选择本地代理模式。'
}
warp_connect() {
    local port
    need warp-cli; prompt port 'WARP 本地代理端口' 40000
    [[ $port =~ ^[0-9]+$ && $port -gt 1024 && $port -le 65535 ]] || die '端口无效'
    warp-cli mode --help | grep -qw proxy || die '该客户端不支持 CLI proxy 模式；请按 Cloudflare 当前设备配置管理，不切换全局隧道'
    ask '接受 Cloudflare 服务条款并连接本地代理？不使用全局隧道模式' || return 0
    if ! warp-cli registration show >/dev/null 2>&1; then warp-cli --accept-tos registration new; fi
    warp-cli tunnel protocol set MASQUE; warp-cli mode proxy; warp-cli proxy port "$port"; warp-cli connect
    warp-cli status; say "本地 SOCKS5 代理：127.0.0.1:$port"
}
network_check() {
    local port=${1:-} url code; local -a proxy=()
    if [[ -n $port ]]; then [[ $port =~ ^[0-9]+$ && $port -gt 0 && $port -le 65535 ]] || die '代理端口无效'; proxy=(--socks5-hostname "127.0.0.1:$port"); fi
    curl -fsS --max-time 20 "${proxy[@]}" https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp)=' || :
    for url in https://chatgpt.com/ https://www.netflix.com/; do
        code=$(curl -sSL --max-time 20 "${proxy[@]}" -o /dev/null -w '%{http_code}' "$url") || code=network-error
        say "$url HTTP $code"
    done
    say '这些结果表示出口与网页可达性；403 可能是反爬验证，不能单凭状态码认定 ChatGPT 地区支持或 Netflix 播放授权。'
}
doctor() {
    local cmd file
    say "naive-update $VERSION / $(uname -srmo)"
    for cmd in curl jq openssl systemctl setpriv flock git go qrencode warp-cli; do say "$cmd: $(command -v "$cmd" || printf '未安装')"; done
    if [[ -x $BIN ]]; then "$BIN" version; "$BIN" build-info; fi
    [[ ! -f $STATE/current-build.json ]] || jq '{release,caddy,forwardproxy,tool_version}' "$STATE/current-build.json"
    for file in /etc/yum.repos.d/*.repo; do [[ -f $file ]] || continue; awk -v f="$file" '/^\[/{print $0,f}' "$file"; done | awk '{n[$1]++;p[$1]=p[$1]" "$2} END{for(k in n)if(n[k]>1)print "重复仓库：",k,p[k]}'
    if [[ -f /etc/yum.repos.d/go-repo.repo ]]; then lsattr /etc/yum.repos.d/go-repo.repo 2>/dev/null || :; fi
    [[ ! -e $STATE/pending.json ]] || say '存在未完成事务：请运行 recover'
    say "主配置：$CONFIG；诊断未重写配置、软件源或 Go 全局设置。"
}
rollback() {
    local id=${1:-} kind current
    if [[ -z $id ]]; then regular "$STATE/latest.json"; id=$(jq -r .id "$STATE/latest.json"); fi
    check_snapshot "$id"; kind=$(jq -r .kind "$STATE/backups/$id/meta.json")
    ask "恢复备份 $id（$kind）？" || return 0
    snapshot "$kind"; current=$REPLY
    if [[ $kind == bbr ]]; then
        [[ ! -f $BBR_FILE ]] || cp --preserve=all "$BBR_FILE" "$STATE/backups/$current/bbr.conf"
        jq -n --arg path "$BBR_FILE" --arg congestion "$(sysctl -n net.ipv4.tcp_congestion_control)" --arg qdisc "$(sysctl -n net.core.default_qdisc)" '{path:$path,congestion:$congestion,qdisc:$qdisc}' >"$STATE/backups/$current/bbr.json"
    fi
    begin_tx "$current"; restore_snapshot "$id"; commit_tx
}
recover() { if [[ ! -f $STATE/pending.json ]]; then say '没有未完成事务'; return; fi; local id; id=$(jq -r .id "$STATE/pending.json"); check_snapshot "$id"; ask "恢复中断事务 $id？" || return; restore_snapshot "$id"; rm -f "$STATE/pending.json"; say '中断事务已恢复'; }
uninstall() {
    local id; regular "$BIN"; regular "$CONFIG"
    ask '停止并卸载 Caddy 二进制和本地 service unit？保留配置、证书、用户数据与备份' || return 0
    [[ -f $UNIT ]] || die '没有本地 unit；不移除由系统软件包管理的服务'
    snapshot uninstall; id=$REPLY; begin_tx "$id"; systemctl disable --now "$SERVICE"
    rm -f -- "$BIN" "$UNIT"; systemctl daemon-reload; rm -f "$STATE/current-build.json"; commit_tx
    say '配置和证书已保留；需要恢复可运行 rollback。'
}
cert_import() {
    local cert=$CERT_FILE key=$KEY_FILE domain=$DOMAIN user group dir
    [[ -n $cert ]] || prompt cert '完整链证书路径'; [[ -n $key ]] || prompt key '无口令私钥路径'
    check_cert_pair "$cert" "$key" "$domain"; ask '复制到独立证书目录？不会自动改写 Caddyfile' || return
    user=$(systemctl show "$SERVICE" -p User --value 2>/dev/null || :); user=${user:-root}; group=$(id -gn "$user")
    dir=$(dirname "$CONFIG")/naive-certs/$(now)-$(openssl rand -hex 2); mkdir -p "$dir"
    chmod 750 "$(dirname "$dir")" "$dir"; chgrp "$group" "$(dirname "$dir")" "$dir"
    install -m640 -o root -g "$group" "$cert" "$dir/cert.crt"; install -m640 -o root -g "$group" "$key" "$dir/private.key"
    say '请手工把站点 tls 行改为以下内容，再验证、重载：'
    printf 'tls "%s/cert.crt" "%s/private.key"\n' "$dir" "$dir"
}
run_menu_command() { local result; set +e; bash "$SELF" "$@"; result=$?; set -e; [[ $result == 0 ]] || say "操作退出码：$result"; }
menu_draw() {
    say '════════════════════════════════════════════════════════════'
    say " Naive 管理工具 v$VERSION — 独立 Shell / 官方源码构建"
    if [[ -x $BIN ]]; then printf ' 已安装 Caddy：'; "$BIN" version; fi
    if command -v systemctl >/dev/null; then printf ' 服务：'; systemctl is-active "$SERVICE" || :; fi
    say ' 1. 全新安装与部署 Naive 服务端'
    say ' 2. 卸载服务端（保留配置、证书、备份）'
    say ' 3. Caddyfile：手工编辑 / 验证 / 重载 / 示例'
    say ' 4. 服务：启动 / 停止 / 重启 / 开机启动'
    say ' 5. 版本检查与工具信息（无脚本自更新）'
    say ' 6. 更新内核：本仓库 CI 包 / 官方本地编译'
    say ' 7. 分享链接 / Naive 客户端 JSON / 二维码'
    say ' 8. 查看运行日志'
    say ' 9. 证书：Caddy ACME / 导入 / 已有 acme.sh'
    say '10. WARP 管理与 ChatGPT / Netflix 出口检测'
    say '11. BBR + FQ / cubic / 恢复网络参数'
    say '12. 备份回滚 / 中断恢复'
    say '13. 安装快捷命令 / 可选接管 na'
    say '14. 系统诊断 / 安装依赖'
    say ' 0. 退出'
    say '════════════════════════════════════════════════════════════'
}
menu() {
    local choice sub source path port id missing=0 cmd
    root
    for cmd in jq curl openssl flock setpriv; do command -v "$cmd" >/dev/null || missing=1; done
    if [[ $missing == 1 ]]; then ask '缺少基础依赖，先使用系统源安装？' || return; run_menu_command deps --yes; fi
    run_menu_command install-tool --yes
    while :; do
        menu_draw; read -r -p '请输入编号：' choice || break
        case $choice in
            0) break;;
            1) run_menu_command deploy;;
            2) run_menu_command uninstall;;
            3) say "配置：$CONFIG"; say '1 编辑副本并验证应用  2 验证  3 重载手工修改的配置  4 写入可选示例（不加载）'; prompt sub '选择' 2
               case $sub in 1) run_menu_command config edit;; 2) run_menu_command config validate;; 3) run_menu_command config reload;; 4) run_menu_command config examples;; esac;;
            4) say '1 状态  2 启动  3 停止  4 重启  5 开机启动  6 禁用开机启动'; prompt sub '选择' 1
               case $sub in 1) run_menu_command service status;; 2) run_menu_command service start;; 3) run_menu_command service stop;; 4) run_menu_command service restart;; 5) run_menu_command service enable;; 6) run_menu_command service disable;; esac;;
            5) run_menu_command check; say "工具 v$VERSION：手工下载自己的仓库新脚本后运行即可更新工具，不会自行下载覆盖。";;
            6) say '1 下载本仓库 CI 包并安装  2 本地官方源码编译并安装  3 安装已有构建目录'; prompt source '选择' 1
               case $source in 1) run_menu_command update --source download --output "$STATE/artifacts/$(now)";; 2) run_menu_command update --source build --output "$STATE/artifacts/$(now)";; 3) prompt path '构建目录'; run_menu_command install --build "$path";; esac;;
            7) run_menu_command share;;
            8) run_menu_command logs;;
            9) say '1 证书状态  2 重载现有证书  3 导入证书（只给出 tls 行）  4 已有 acme.sh 列表  5 已有 acme.sh 续期'; prompt sub '选择' 1
               case $sub in 1) run_menu_command cert status;; 2) run_menu_command cert reload;; 3) run_menu_command cert import;; 4) run_menu_command cert acme-list;; 5) run_menu_command cert acme-renew;; esac;;
            10) say '1 状态  2 从 Cloudflare 官方源安装  3 连接本地代理  4 断开  5 直连出口检测  6 本地代理出口检测'; prompt sub '选择' 1
                case $sub in 1) run_menu_command warp status;; 2) run_menu_command warp install;; 3) run_menu_command warp connect;; 4) run_menu_command warp disconnect;; 5) run_menu_command network-check;; 6) prompt port 'SOCKS5 端口' 40000; run_menu_command network-check "$port";; esac;;
            11) say '1 状态  2 启用 BBR + FQ  3 cubic + fq_codel  4 恢复某次修改前参数'; prompt sub '选择' 1
                case $sub in 1) run_menu_command bbr status;; 2) run_menu_command bbr enable;; 3) run_menu_command bbr disable;; 4) find "$STATE/backups" -name bbr.json -print 2>/dev/null || :; prompt id '备份目录 ID'; run_menu_command rollback "$id";; esac;;
            12) say '1 列出备份  2 恢复最近一次操作前状态  3 指定备份恢复  4 恢复中断事务'; prompt sub '选择' 1
                case $sub in 1) run_menu_command backups;; 2) run_menu_command rollback;; 3) prompt id '备份 ID'; run_menu_command rollback "$id";; 4) run_menu_command recover;; esac;;
            13) say '1 安装 /usr/bin/naive-update  2 备份并接管 /usr/bin/na'; prompt sub '选择' 1
                case $sub in 1) run_menu_command install-tool;; 2) run_menu_command install-na;; esac;;
            14) say '1 系统诊断  2 安装依赖'; prompt sub '选择' 1; case $sub in 1) run_menu_command doctor;; 2) run_menu_command deps;; esac;;
            *) say '编号无效';;
        esac
        read -r -p '按回车返回菜单……' sub || break
    done
}
usage() {
    cat <<'EOF'
naive-update — 独立交互式 Shell 管理工具
无参数：交互菜单；第一次以 root 打开菜单自动安装 /usr/bin/naive-update。
deploy                  全新部署（向导）；已有部署不会被覆盖
download|build           下载 CI 构建 / 本地源码编译
install --build DIR      安装已有构建，不重写 Caddyfile
update --source download|build   获取新内核并安装
config edit|validate|reload|examples
service status|start|stop|restart|enable|disable
cert status|reload|import|acme-list|acme-renew
share|logs|doctor|check|backups|rollback [ID]|recover
bbr status|enable|disable
warp status|install|connect|disconnect
network-check [SOCKS_PORT]
install-tool|install-na|deps|uninstall
选项：--yes --release TAG --output DIR --jobs N --build DIR
      --config-source FILE（仅全新部署） --cert FILE --key FILE --domain DOMAIN
路径可通过 NAIVE_BIN/CONFIG/SERVICE/UNIT/STATE/TOOL/DATA 环境变量指定。
EOF
}
main() {
    local command=${1:-menu} sub='' source=download backup_id='' network_port='' id
    CERT_FILE='' KEY_FILE='' DOMAIN=''
    case $command in --help|-h) usage; return;; --version) say "$VERSION"; return;; esac
    [[ $# == 0 ]] || shift
    case $command in config|service|cert|bbr|warp) sub=${1:-status}; [[ $# == 0 ]] || shift;; rollback|internal-restore) if [[ ${1:-} != --* ]]; then backup_id=${1:-}; [[ $# == 0 ]] || shift; fi;; network-check) if [[ ${1:-} != --* ]]; then network_port=${1:-}; [[ $# == 0 ]] || shift; fi;; esac
    while (($#)); do
        case $1 in
            --yes) YES=1; shift;;
            --release|--output|--jobs|--build|--source|--config-source|--cert|--key|--domain)
                (($# >= 2)) || die "缺少 $1 参数"
                case $1 in --release) RELEASE=$2;; --output) OUTPUT=$2;; --jobs) JOBS=$2;; --build) BUILD_DIR=$2;; --source) source=$2;; --config-source) CONFIG_SOURCE=$2;; --cert) CERT_FILE=$2;; --key) KEY_FILE=$2;; --domain) DOMAIN=$2;; esac; shift 2;;
            *) die "未知参数：$1";;
        esac
    done
    [[ $JOBS =~ ^[1-9][0-9]*$ && $JOBS -ge 1 && $JOBS -le 256 ]] || die 'jobs 必须为 1–256'
    export NAIVE_BIN=$BIN NAIVE_CONFIG=$CONFIG NAIVE_SERVICE=$SERVICE NAIVE_UNIT=$UNIT NAIVE_STATE=$STATE NAIVE_TOOL=$TOOL NAIVE_DATA=$DATA NAIVE_USER=$RUN_USER NAIVE_BBR_FILE=$BBR_FILE
    trap on_exit EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
    case $command in
        menu) if [[ -t 0 ]]; then menu; else menu_draw; usage; fi; return;;
        deps) deps; return;;
        doctor) doctor; return;;
        internal-restore) root; [[ -e /proc/self/fd/9 ]] || die '内部恢复缺少事务锁'; restore_snapshot "$backup_id"; return;;
    esac
    need jq; need curl; need openssl
    case $command in
        download) fetch_build; return;; build) [[ $(uname -s) == Linux ]] || die '构建需要 Linux'; build_source; return;;
        check) latest_tag latest; say "官方服务端：$REPLY"; [[ ! -x $BIN ]] || "$BIN" version; say 'Chromium 客户端版本独立管理。'; return;;
    esac
    need systemctl; need flock; need setpriv; state_init "$command"
    case $command in
        deploy) deploy;;
        install) [[ -n $BUILD_DIR ]] || die '需要 --build DIR'; install_binary "$BUILD_DIR";;
        update) ask '下载/编译并安装新内核，验证后重启？' || return; YES=1; case $source in download) fetch_build;; build) build_source;; *) die 'source 必须为 download 或 build';; esac; install_binary "$OUTPUT";;
        config) case $sub in edit) edit_config;; validate) snapshot config; id=$REPLY; validate_config "$BIN" "$CONFIG" "$STATE/backups/$id/validate.log"; say '配置验证通过';; reload) reload_config;; examples) examples; say "示例已写入 $(dirname "$CONFIG")/examples；未自动加载";; *) die '未知 config 操作';; esac;;
        service) case $sub in status) systemctl status "$SERVICE" --no-pager;; start|restart) ask "$sub $SERVICE？" || return; systemctl "$sub" "$SERVICE"; health "$(digest "$BIN")";; stop|enable|disable) ask "$sub $SERVICE？" || return; systemctl "$sub" "$SERVICE";; *) die '未知 service 操作';; esac;;
        cert) case $sub in status) cert_status;; reload) reload_config;; import) cert_import;; acme-list) acme_existing list;; acme-renew) acme_existing renew;; *) die '未知 cert 操作';; esac;;
        bbr) case $sub in status) bbr_status;; enable) bbr_set bbr fq;; disable) bbr_set cubic fq_codel;; *) die '未知 bbr 操作';; esac;;
        warp) case $sub in status) need warp-cli; warp-cli status; warp-cli settings;; install) warp_install;; connect) warp_connect;; disconnect) need warp-cli; ask '断开 WARP？' || return; warp-cli disconnect;; *) die '未知 warp 操作';; esac;;
        network-check) network_check "$network_port";; share) share;; logs) journalctl -u "$SERVICE" --no-pager -n 100;;
        backups) find "$STATE/backups" -mindepth 2 -maxdepth 2 -name meta.json -exec jq -r '[.id,.kind]|@tsv' {} \; 2>/dev/null || :;;
        rollback) rollback "$backup_id";; recover) recover;; uninstall) uninstall;; install-tool) install_tool;; install-na) install_na_alias;;
        *) die '未知命令，请使用 --help';;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
