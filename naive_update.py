#!/usr/bin/env python3
"""Build Naive's Caddy server from official sources; activate with rollback."""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid

VERSION = "1.0.0"
FORWARD = "https://github.com/klzgrad/forwardproxy.git"
CADDY = "https://github.com/caddyserver/caddy.git"
API = "https://api.github.com/repos/klzgrad/forwardproxy/releases"
OWN_REPOSITORY = "satsuki887/naive-update"
OWN_API = "https://api.github.com/repos/" + OWN_REPOSITORY + "/releases"
TAG = re.compile(r"v\d+\.\d+\.\d+-naive[\w.-]*\Z", re.ASCII)
SEMVER = re.compile(r"v\d+\.\d+\.\d+(?:[-+][\w.-]+)?\Z", re.ASCII)


class Failure(Exception):
    pass


def say(message):
    print(message, flush=True)


def run(args, *, cwd=None, env=None, log=None, timeout=120, identity=None):
    kwargs = {}
    if identity and os.name == "posix":
        kwargs.update(user=identity[0], group=identity[1], extra_groups=identity[2])
    try:
        result = subprocess.run(
            [str(a) for a in args], cwd=cwd, env=env, timeout=timeout,
            stdout=log if log else subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace",
            **kwargs,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Failure(f"命令无法完成：{args[0]}（{type(exc).__name__}）") from exc
    if result.returncode:
        # Config validation and service environments can contain credentials.
        raise Failure(f"命令失败（退出码 {result.returncode}）：{args[0]}；详情见本地日志")
    return result.stdout or ""


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sync_dir(path):
    if os.name == "posix":
        fd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def atomic_json(path, value):
    path = Path(path)
    fd, temp = tempfile.mkstemp(prefix=".json-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        sync_dir(path.parent)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def load_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def api_json(url):
    # Only public official metadata. No GitHub token is requested or stored.
    req = urllib.request.Request(url, headers={
        "User-Agent": "naive-update/" + VERSION,
        "Accept": "application/vnd.github+json",
    })
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            if exc.code in (403, 404, 429):
                raise Failure(f"官方 GitHub API 返回 {exc.code}；可使用 --release 指定已知发布标签") from exc
            if attempt == 2:
                raise Failure("官方 GitHub API 请求失败") from exc
        except (OSError, ValueError) as exc:
            if attempt == 2:
                raise Failure("无法读取官方 GitHub 元数据，请检查网络和系统 CA") from exc
        time.sleep(attempt + 1)


def release_tag(value):
    tag = api_json(API + "/latest")["tag_name"] if value == "latest" else value
    if not TAG.fullmatch(tag):
        raise Failure("服务端版本必须是官方 forwardproxy 的 vX.Y.Z-naive… 发布标签")
    return tag


def clone_tag(url, tag, destination, log):
    run(["git", "init", "--quiet", destination], log=log)
    run(["git", "-C", destination, "remote", "add", "origin", url], log=log)
    run(["git", "-C", destination, "fetch", "--depth=1", "--no-tags", "origin",
         "refs/tags/" + tag], log=log, timeout=300)
    run(["git", "-C", destination, "checkout", "--quiet", "--detach", "FETCH_HEAD"], log=log)
    commit = run(["git", "-C", destination, "rev-parse", "HEAD"]).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise Failure("无法固定上游提交")
    return commit


def official_plan(source):
    """Understand the known CI recipe, but never execute upstream shell/YAML."""
    source = Path(source)
    version = (source / "CADDY_VERSION").read_text().strip()
    if not SEMVER.fullmatch(version):
        raise Failure("上游 CADDY_VERSION 格式已改变；需要人工审查")
    workflow = (source / ".github/workflows/build.yml").read_text()
    required = ["repository: caddyserver/caddy", "ref: ${{ env.CADDY_VERSION }}",
                "path: .caddy-bbr", 'xcaddy build "$CADDY_VERSION"',
                '--replace "github.com/caddyserver/caddy/v2=$GITHUB_WORKSPACE/.caddy-bbr"',
                '--with "github.com/caddyserver/forwardproxy=$GITHUB_WORKSPACE"']
    if not all(item in workflow for item in required):
        raise Failure("上游 CI 构建结构已变化；停止而不是猜测构建参数")
    steps = re.findall(r"^\s*- run: (.+)$", workflow, re.MULTILINE)
    # Unknown executable steps may carry new mandatory preparation work.
    for step in steps:
        if not any(step.startswith(prefix) for prefix in (
            "printf 'CADDY_VERSION=", "git -C .caddy-bbr apply ",
            "go install github.com/caddyserver/xcaddy/cmd/xcaddy@", "~/go/bin/xcaddy build ")):
            raise Failure("上游新增了未支持的构建步骤，需要更新本工具")
    patch_steps = [step for step in steps if step.startswith("git -C .caddy-bbr apply ")]
    if len(patch_steps) != 1:
        raise Failure("无法唯一确定官方补丁应用步骤")
    tokens = shlex.split(patch_steps[0])
    patches = []
    for token in tokens[4:]:
        prefix = "$GITHUB_WORKSPACE/"
        if not token.startswith(prefix):
            raise Failure("官方补丁路径格式不受支持")
        name = token[len(prefix):]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*\.patch", name):
            raise Failure("拒绝非根目录补丁路径")
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise Failure("官方补丁文件不存在或是符号链接")
        patches.append(name)
    go = re.search(r"go-version:\s*[\"']?\^(\d+)\.(\d+)\.x", workflow)
    if not patches or not go:
        raise Failure("无法读取官方补丁列表或 Go 最低版本")
    return version, patches, tuple(map(int, go.groups()))


def build(args):
    if sys.platform != "linux":
        raise Failure("本地编译命令需要 Linux；Windows 可运行帮助、检查和单元测试")
    for command in ("git", "go"):
        if not shutil.which(command):
            raise Failure(f"缺少 {command}；请通过系统官方软件源或 go.dev 安装")
    tag = release_tag(args.release)
    target = Path(args.output).absolute()
    if target.exists():
        raise Failure(f"输出目录已存在，请换一个 --output 路径：{target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".naive-build-", dir=target.parent))
    os.chmod(work, 0o700)
    say(f"构建官方服务端 {tag}；工作目录：{work}")
    try:
        with open(work / "build.log", "w", encoding="utf-8") as log:
            forward = work / "forwardproxy"
            forward_commit = clone_tag(FORWARD, tag, forward, log)
            caddy_version, patches, minimum_go = official_plan(forward)
            local_go = run(["go", "version"]).strip()
            match = re.search(r"go(\d+)\.(\d+)", local_go)
            if not match or tuple(map(int, match.groups())) < minimum_go:
                raise Failure(f"官方 CI 要求 Go {minimum_go[0]}.{minimum_go[1]}+；当前 {local_go}")
            caddy_source = work / "caddy-source"
            caddy_commit = clone_tag(CADDY, caddy_version, caddy_source, log)
            for name in patches:
                patch = forward / name
                say("检查并应用官方补丁：" + name)
                run(["git", "-C", caddy_source, "apply", "--check", patch], log=log)
                run(["git", "-C", caddy_source, "apply", patch], log=log)
            env = os.environ.copy()
            for key in list(env):
                if key.startswith("XCADDY_"):
                    env.pop(key)
            env.update(GOTOOLCHAIN="local", GO111MODULE="on", CGO_ENABLED="0", GOOS="linux",
                       GOPROXY="https://proxy.golang.org,direct", GOSUMDB="sum.golang.org",
                       GOPRIVATE="", GONOSUMDB="", GONOPROXY="", GOINSECURE="",
                       GOWORK="off", GOFLAGS="", GOEXPERIMENT="",
                       GOENV="off", GOMAXPROCS=str(args.jobs), GOBIN=str(work / "tools"),
                       XCADDY_SETCAP="0")
            # Ignore cross-compilation settings inherited from a login shell.
            for key in ("GOARCH", "GOAMD64", "GOARM", "GOARM64", "XCADDY_GO_BUILD_FLAGS",
                        "XCADDY_RACE_DETECTOR", "XCADDY_SKIP_BUILD", "XCADDY_WHICH_GO"):
                env.pop(key, None)
            env["GOAMD64"] = "v1"
            xcaddy_version = args.xcaddy_version
            if xcaddy_version == "latest":
                info = json.loads(run(["go", "list", "-m", "-json",
                                       "github.com/caddyserver/xcaddy@latest"], env=env, timeout=300))
                xcaddy_version = info["Version"]
            if not SEMVER.fullmatch(xcaddy_version):
                raise Failure("xcaddy 版本必须是 vX.Y.Z 格式")
            say(f"固定 Caddy {caddy_version}、forwardproxy {forward_commit[:12]}、xcaddy {xcaddy_version}")
            run(["go", "install", "github.com/caddyserver/xcaddy/cmd/xcaddy@" + xcaddy_version],
                cwd=work, env=env, log=log, timeout=1800)
            run([work / "tools/xcaddy", "build", caddy_version,
                 "--replace", f"github.com/caddyserver/caddy/v2={caddy_source}",
                 "--with", f"github.com/caddyserver/forwardproxy={forward}",
                 "--output", work / "caddy"], cwd=work, env=env, log=log, timeout=args.timeout)
            modules = run([work / "caddy", "list-modules"])
            if "http.handlers.forward_proxy" not in modules.splitlines():
                raise Failure("编译结果缺少 forward_proxy 模块")
            binary_version = run([work / "caddy", "version"]).strip()
            if binary_version.split()[0] != caddy_version:
                raise Failure("编译结果的 Caddy 版本不匹配")
            provenance = {
                "schema": 1, "tool_version": VERSION, "release": tag,
                "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "forwardproxy": {"repository": FORWARD, "commit": forward_commit},
                "caddy": {"repository": CADDY, "version": caddy_version, "commit": caddy_commit},
                "patches": [{"name": p, "sha256": sha256(forward / p)} for p in patches],
                "go": local_go, "xcaddy": xcaddy_version, "sha256": sha256(work / "caddy"),
                "binary_version": binary_version, "goarch": run(["go", "env", "GOARCH"], env=env).strip(),
            }
            atomic_json(work / "build.json", provenance)
            (work / "build-info.txt").write_text(run([work / "caddy", "build-info"]), encoding="utf-8")
            (work / "LICENSES.txt").write_text(
                "Caddy — Apache-2.0\n\n" + (caddy_source / "LICENSE").read_text()
                + "\n\nForwardproxy / Naive fork\n\n" + (forward / "LICENSE").read_text(),
                encoding="utf-8")
            # Keep upstream source, go.mod/go.sum, patches and logs for investigation.
            (work / "SHA256SUMS").write_text(sha256(work / "caddy") + "  caddy\n", encoding="ascii")
        os.rename(work, target)
        say(f"编译成功，尚未安装：{target}\nSHA256：{provenance['sha256']}")
        return target
    except BaseException:
        say(f"编译失败；现有服务未改动。工作目录和日志保留在：{work}")
        raise


def verify_artifact(directory):
    directory = Path(directory)
    binary = directory / "caddy"
    manifest = directory / "build.json"
    if binary.is_symlink() or manifest.is_symlink() or not binary.is_file():
        raise Failure("构建产物缺失或使用了符号链接")
    info = load_json(manifest)
    if (info.get("schema") != 1 or not TAG.fullmatch(info.get("release", ""))
            or info.get("forwardproxy", {}).get("repository") != FORWARD
            or info.get("caddy", {}).get("repository") != CADDY
            or not re.fullmatch(r"[0-9a-f]{64}", info.get("sha256", ""))
            or sha256(binary) != info["sha256"]):
        raise Failure("构建记录不完整或二进制 SHA256 不匹配")
    return binary, info


def download_file(url, target, limit=150 * 1024 * 1024):
    if not url.startswith("https://github.com/" + OWN_REPOSITORY + "/releases/download/"):
        raise Failure("拒绝非本仓库的下载地址")
    req = urllib.request.Request(url, headers={"User-Agent": "naive-update/" + VERSION})
    try:
        with urllib.request.urlopen(req, timeout=60) as response, open(target, "wb") as stream:
            if not response.url.startswith("https://"):
                raise Failure("下载重定向没有使用 HTTPS")
            total = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > limit:
                    raise Failure("下载文件超出大小限制")
                stream.write(chunk)
    except (OSError, urllib.error.URLError) as exc:
        raise Failure("下载失败；未修改现有服务，可重新执行 download") from exc


def extract_bundle(archive, destination):
    expected = {"caddy", "build.json", "build-info.txt", "SHA256SUMS", "LICENSES.txt"}
    seen = set()
    total = 0
    with tarfile.open(archive, "r|gz") as bundle:
        # Do not use extractall: filenames, modes and owners are untrusted.
        for member in bundle:
            total += member.size
            if member.name not in expected or member.name in seen:
                raise Failure("安装包文件列表不符合约定")
            if not member.isfile() or total > 150 * 1024 * 1024:
                raise Failure("拒绝安装包中的链接、特殊文件或超大文件")
            seen.add(member.name)
            with bundle.extractfile(member) as src, open(Path(destination) / member.name, "wb") as dst:
                shutil.copyfileobj(src, dst)
            os.chmod(Path(destination) / member.name, 0o755 if member.name == "caddy" else 0o600)
    if seen != expected:
        raise Failure("安装包缺少必要文件")


def download(args):
    if sys.platform != "linux":
        raise Failure("download 用于 Linux 服务器；其他系统可直接从 Releases 下载压缩包")
    arch = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    if arch is None:
        raise Failure("预编译包仅支持 amd64/arm64；其他架构请使用 build")
    endpoint = OWN_API + "/latest" if args.release == "latest" else OWN_API + "/tags/server-" + release_tag(args.release)
    release = api_json(endpoint)
    tag = release.get("tag_name", "").removeprefix("server-")
    if not TAG.fullmatch(tag):
        raise Failure("本仓库发布标签格式无效")
    filename = f"naive-server-{tag}-linux-{arch}.tar.gz"
    assets = {a["name"]: a for a in release.get("assets", [])}
    if filename not in assets or "SHA256SUMS" not in assets:
        raise Failure("该发布缺少对应架构的安装包或校验文件")
    target = Path(args.output).absolute()
    if target.exists():
        raise Failure("输出目录已存在，请更换 --output")
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=".naive-download-", dir=target.parent))
    try:
        archive = temp / filename
        download_file(assets[filename]["browser_download_url"], archive)
        download_file(assets["SHA256SUMS"]["browser_download_url"], temp / "checksums", limit=65536)
        sums = {}
        for line in (temp / "checksums").read_text().splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
            if not match or match[2] in sums:
                raise Failure("发布校验文件格式无效")
            sums[match[2]] = match[1]
        actual = sha256(archive)
        if sums.get(filename) != actual:
            raise Failure("下载包 SHA256 校验失败")
        digest = assets[filename].get("digest")
        if digest and digest != "sha256:" + actual:
            raise Failure("下载包与 GitHub 资产摘要不匹配")
        output = temp / "output"
        output.mkdir(mode=0o700)
        extract_bundle(archive, output)
        _, info = verify_artifact(output)
        if info["release"] != tag or info.get("goarch") != arch:
            raise Failure("安装包版本或架构不匹配")
        os.rename(output, target)
        say(f"已下载并校验本仓库 CI 构建的服务端：{target}；尚未安装")
    finally:
        shutil.rmtree(temp)
    return target


def root_linux():
    if sys.platform != "linux" or os.geteuid() != 0:
        raise Failure("安装、回滚和恢复必须以 root 在 Linux 上执行")


def assert_regular(path):
    if Path(path).is_symlink() or not Path(path).is_file():
        raise Failure(f"要求普通文件，拒绝符号链接：{path}")


def assert_mutable(path):
    # Linux FS_IOC_GETFLAGS: reject immutable/append-only before any swap.
    import fcntl
    import array
    flags = array.array("L", [0])
    with open(path, "rb") as stream:
        try:
            fcntl.ioctl(stream.fileno(), 0x80086601, flags, True)
        except OSError as exc:
            if exc.errno not in (25, 95):
                raise
    if flags[0] & (0x10 | 0x20):
        raise Failure(f"文件设置了 immutable/append-only，未自动解除：{path}")


def copy_binary(source, destination, metadata_from):
    """Copy bytes, preserve original owner/mode/capabilities/SELinux context."""
    with open(source, "rb") as reader, open(destination, "wb") as writer:
        shutil.copyfileobj(reader, writer)
        writer.flush()
        os.fsync(writer.fileno())
    info = os.stat(metadata_from)
    os.chown(destination, info.st_uid, info.st_gid)
    shutil.copystat(metadata_from, destination)
    if hasattr(os, "listxattr"):
        for name in os.listxattr(metadata_from):
            value = os.getxattr(metadata_from, name)
            os.setxattr(destination, name, value)
            if os.getxattr(destination, name) != value:
                raise Failure("无法保留原二进制扩展属性：" + name)
    with open(destination, "rb") as stream:
        os.fsync(stream.fileno())


class Service:
    def __init__(self, name, binary, config):
        if not re.fullmatch(r"[A-Za-z0-9_.@-]+", name) or name.startswith("-"):
            raise Failure("systemd 服务名称无效")
        self.name = name
        self.binary = Path(binary).absolute()
        self.config = Path(config).absolute()

    def inspect(self):
        run(["systemctl", "is-active", "--quiet", self.name])
        pid = int(run(["systemctl", "show", self.name, "-p", "MainPID", "--value"]).strip())
        proc = Path("/proc") / str(pid)
        if pid <= 1 or not os.path.samefile(proc / "exe", self.binary):
            raise Failure("服务主进程与目标二进制不一致，拒绝替换")
        argv = (proc / "cmdline").read_bytes().decode().rstrip("\0").split("\0")
        cwd = (proc / "cwd").resolve()
        config = None
        adapter = None
        for i, arg in enumerate(argv):
            if arg in ("--config", "-c") and i + 1 < len(argv):
                config = argv[i + 1]
            elif arg.startswith("--config="):
                config = arg.split("=", 1)[1]
            elif arg in ("--adapter", "-a") and i + 1 < len(argv):
                adapter = argv[i + 1]
            elif arg.startswith("--adapter="):
                adapter = arg.split("=", 1)[1]
        if not config or (cwd / config).resolve() != self.config.resolve() or "run" not in argv:
            raise Failure("运行中服务的配置路径不匹配，或不是直接运行的 caddy run")
        env = {}
        for item in (proc / "environ").read_bytes().split(b"\0"):
            if b"=" in item:
                key, value = item.split(b"=", 1)
                env[os.fsdecode(key)] = os.fsdecode(value)
        status = (proc / "status").read_text()
        uid = int(re.search(r"^Uid:\s+(\d+)", status, re.M)[1])
        gid = int(re.search(r"^Gid:\s+(\d+)", status, re.M)[1])
        groups = list(map(int, re.search(r"^Groups:\s*(.*)$", status, re.M)[1].split()))
        self.runtime = (env, cwd, (uid, gid, groups), adapter)

    def validate(self, candidate, log):
        env, cwd, identity, adapter = self.runtime
        command = [candidate, "validate", "--config", self.config]
        if adapter:
            command += ["--adapter", adapter]
        run(command, env=env, cwd=cwd, identity=identity, log=log, timeout=90)

    def restart(self):
        run(["systemctl", "restart", self.name], timeout=120)

    def snapshot(self, backup):
        # Keep snapshots private; unit files may contain environment secrets.
        fragment = run(["systemctl", "show", self.name, "-p", "FragmentPath", "--value"]).strip()
        dropins = shlex.split(run(["systemctl", "show", self.name, "-p", "DropInPaths", "--value"]))
        unit_dir = Path(backup) / "systemd"
        unit_dir.mkdir(mode=0o700)
        for i, name in enumerate(([fragment] if fragment else []) + dropins):
            path = Path(name)
            if not path.is_file():
                raise Failure("无法备份 systemd 服务文件")
            destination = unit_dir / f"{i}-{path.name}"
            shutil.copy2(path, destination)
            os.chmod(destination, 0o600)

    def healthy(self, digest, seconds=8):
        # Process health only; authenticated proxy traffic must also be tested.
        last_pid = None
        stable = 0
        deadline = time.monotonic() + seconds + 15
        while time.monotonic() < deadline:
            try:
                run(["systemctl", "is-active", "--quiet", self.name], timeout=10)
                pid = int(run(["systemctl", "show", self.name, "-p", "MainPID", "--value"]).strip())
                if pid > 1 and sha256(Path("/proc") / str(pid) / "exe") == digest:
                    stable = stable + 1 if pid == last_pid else 1
                    last_pid = pid
                    if stable >= seconds:
                        return
                else:
                    stable = 0
            except (Failure, OSError, ValueError):
                stable = 0
            time.sleep(1)
        raise Failure("服务未能以目标二进制稳定运行")


class Transaction:
    def __init__(self, state, service):
        self.state = Path(state).absolute()
        self.service = service
        self.pending = self.state / "pending.json"
        self.receipt = self.state / "installed.json"

    @contextlib.contextmanager
    def lock(self):
        import fcntl
        if self.state.resolve() != self.state:
            raise Failure("状态目录路径不能经过符号链接")
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        st = self.state.stat()
        if st.st_uid != 0 or stat.S_IMODE(st.st_mode) & 0o077:
            raise Failure("状态目录必须由 root 拥有且权限为 0700")
        with open(self.state / "lock", "a") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise Failure("另一个安装/回滚操作正在运行") from exc
            yield

    def replace(self, source, metadata_from):
        binary = self.service.binary
        fd, name = tempfile.mkstemp(prefix=".naive-update-", dir=binary.parent)
        os.close(fd)
        try:
            copy_binary(source, name, metadata_from)
            if sha256(source) != sha256(name):
                raise Failure("复制后二进制校验失败")
            os.replace(name, binary)
            sync_dir(binary.parent)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def restore(self, journal):
        backup = Path(journal["backup"])
        if sha256(backup / "caddy") != journal["old_sha256"]:
            raise Failure("回滚备份校验失败；保留 pending.json，需人工恢复")
        self.replace(backup / "caddy", backup / "caddy")
        self.service.restart()
        self.service.healthy(journal["old_sha256"])
        if journal["previous_receipt"] is None:
            self.receipt.unlink(missing_ok=True)
        else:
            atomic_json(self.receipt, journal["previous_receipt"])
        self.pending.unlink()
        sync_dir(self.state)

    def activate(self, source, build_info, *, operation="install"):
        if self.pending.exists():
            raise Failure("检测到未完成事务，请先执行 recover")
        assert_regular(self.service.binary)
        assert_mutable(self.service.binary)
        self.service.inspect()
        ident = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:8]
        backup = self.state / "backups" / ident
        backup.mkdir(parents=True, mode=0o700)
        old_hash = sha256(self.service.binary)
        new_hash = sha256(source)
        copy_binary(self.service.binary, backup / "caddy", self.service.binary)
        if sha256(backup / "caddy") != old_hash:
            raise Failure("旧版本备份校验失败")
        shutil.copy2(self.service.config, backup / "Caddyfile.snapshot")
        os.chmod(backup / "Caddyfile.snapshot", 0o600)
        self.service.snapshot(backup)
        config_hash = sha256(self.service.config)
        previous = load_json(self.receipt) if self.receipt.exists() else None
        metadata = {"schema": 1, "binary": str(self.service.binary), "config": str(self.service.config),
                    "service": self.service.name, "backup": str(backup), "old_sha256": old_hash,
                    "new_sha256": new_hash, "previous_receipt": previous}
        atomic_json(backup / "metadata.json", metadata)
        fd, candidate_name = tempfile.mkstemp(prefix=".naive-validate-", dir=self.service.binary.parent)
        os.close(fd)
        swapped = False
        try:
            copy_binary(source, candidate_name, self.service.binary)
            if sha256(candidate_name) != new_hash:
                raise Failure("候选文件复制校验失败")
            with open(backup / "validate.log", "w", encoding="utf-8") as log:
                self.service.validate(Path(candidate_name), log)
            # Recheck after validation, before committing to the swap.
            self.service.inspect()
            if sha256(self.service.binary) != old_hash or sha256(self.service.config) != config_hash:
                raise Failure("检查期间二进制或主配置被其他程序更改，停止安装")
            atomic_json(self.pending, metadata)
            swapped = True  # journal recovery is safe even if replace itself fails
            os.replace(candidate_name, self.service.binary)
            sync_dir(self.service.binary.parent)
            self.service.restart()
            self.service.healthy(new_hash)
            atomic_json(self.receipt, {"schema": 1, "operation": operation, "build": build_info,
                                      "sha256": new_hash, "backup_id": ident})
            self.pending.unlink()
            sync_dir(self.state)
            say(f"{operation} 完成；备份：{backup}")
            say("进程健康检查通过。请再用 Naive 客户端验证实际代理流量。")
        except BaseException as original:
            if swapped:
                say("切换未完成，正在恢复旧二进制并重启原服务……")
                try:
                    self.restore(metadata)
                    say("旧版本已恢复")
                except BaseException as recovery:
                    raise Failure(f"自动回滚未完成；请执行 recover；状态保留于 {self.pending}") from recovery
            raise original
        finally:
            if os.path.exists(candidate_name):
                os.unlink(candidate_name)

    def check_metadata(self, metadata):
        if (metadata.get("schema") != 1 or metadata.get("binary") != str(self.service.binary)
                or metadata.get("config") != str(self.service.config)
                or metadata.get("service") != self.service.name):
            raise Failure("事务目标与当前 --binary/--config/--service 不匹配")
        backup = Path(metadata["backup"])
        if backup.resolve().parent != (self.state / "backups").resolve():
            raise Failure("备份路径超出状态目录")

    def rollback(self, ident=None):
        if self.pending.exists():
            raise Failure("存在未完成事务，请先执行 recover")
        if ident is None:
            if not self.receipt.exists():
                raise Failure("没有安装记录；可指定 --backup 已存在的备份 ID")
            ident = load_json(self.receipt)["backup_id"]
        if not re.fullmatch(r"\d{8}T\d{6}Z-[0-9a-f]{8}", ident):
            raise Failure("备份 ID 格式无效")
        backup = self.state / "backups" / ident
        metadata = load_json(backup / "metadata.json")
        self.check_metadata(metadata)
        if sha256(backup / "caddy") != metadata["old_sha256"]:
            raise Failure("备份二进制校验失败")
        previous = metadata["previous_receipt"]
        self.activate(backup / "caddy", previous.get("build") if previous else None, operation="rollback")

    def recover(self):
        if not self.pending.exists():
            say("没有未完成事务")
            return
        metadata = load_json(self.pending)
        self.check_metadata(metadata)
        assert_regular(self.service.binary)
        assert_mutable(self.service.binary)
        self.restore(metadata)
        say("中断事务已恢复到切换前的二进制；配置文件未被覆盖")


def doctor(args):
    say(f"naive-update {VERSION}；Python {sys.version.split()[0]}；平台 {sys.platform}")
    for name in ("git", "go", "systemctl"):
        say(f"{name}: {shutil.which(name) or '未安装'}")
    if shutil.which("go"):
        say(run(["go", "version"]).strip())
    if Path(args.binary).is_file():
        say("已安装 Caddy：" + run([args.binary, "version"]).strip())
        say(run([args.binary, "build-info"]).strip())
    repositories = {}
    for path in sorted(Path("/etc/yum.repos.d").glob("*.repo")):
        for section in re.findall(r"^\[([^\]]+)\]", path.read_text(errors="replace"), re.M):
            repositories.setdefault(section, []).append(path.name)
    for section, names in repositories.items():
        if len(names) > 1:
            say(f"警告：软件源 [{section}] 重复：{', '.join(names)}")
    repo = Path("/etc/yum.repos.d/go-repo.repo")
    if repo.exists() and sys.platform == "linux":
        try:
            assert_mutable(repo)
        except Failure as exc:
            say("警告：" + str(exc))
    if Path("/usr/bin/na").exists():
        say("检测到旧 na 管理脚本；其自更新和内核升级可能覆盖本工具管理的版本，请停用这两个入口")
    pending = Path(args.state_dir) / "pending.json"
    if pending.exists():
        say("警告：存在未完成事务，需要 recover")
    say("诊断结束；未修改软件源、文件属性、Go 全局配置或服务")


def parser():
    result = argparse.ArgumentParser(description="Naive 官方源码构建与升级工具（无脚本自更新）")
    result.add_argument("--version", action="version", version=VERSION)
    sub = result.add_subparsers(dest="command")
    for name in ("check", "doctor", "status", "install", "update", "rollback", "recover"):
        command = sub.add_parser(name)
        command.add_argument("--binary", default="/usr/bin/caddy")
        command.add_argument("--config", default="/etc/caddy/Caddyfile")
        command.add_argument("--service", default="caddy")
        command.add_argument("--state-dir", default="/var/lib/naive-update")
        if name in ("install", "update", "rollback", "recover"):
            command.add_argument("--yes", action="store_true", help="确认允许替换二进制及重启服务")
        if name == "install":
            command.add_argument("--build", required=True)
        if name == "rollback":
            command.add_argument("--backup")
    build_parser = sub.add_parser("build")
    download_parser = sub.add_parser("download")
    download_parser.add_argument("--release", default="latest")
    download_parser.add_argument("--output", default="./build")
    for command in (build_parser, sub.choices["update"]):
        command.add_argument("--release", default="latest")
        command.add_argument("--output", default="./build")
        command.add_argument("--jobs", type=int, default=2)
        command.add_argument("--timeout", type=int, default=3600, help="主编译超时秒数")
        command.add_argument("--xcaddy-version", default="latest")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    if args.command is None:
        parser().print_help()
        return 0
    if hasattr(args, "jobs") and (args.jobs < 1 or args.jobs > 256 or args.timeout < 1):
        raise Failure("--jobs 必须在 1–256 之间，--timeout 必须大于 0")
    if args.command == "build":
        build(args)
    elif args.command == "download":
        download(args)
    elif args.command in ("doctor", "status"):
        doctor(args)
        if args.command == "status":
            receipt = Path(args.state_dir) / "installed.json"
            if receipt.exists():
                say(json.dumps(load_json(receipt), ensure_ascii=False, indent=2))
    elif args.command == "check":
        say("官方服务端最新发布：" + release_tag("latest"))
        if Path(args.binary).is_file():
            say("已安装：" + run([args.binary, "version"]).strip())
            say(run([args.binary, "build-info"]).strip())
        say("服务端版本独立于 Naive 客户端的 Chromium 版本；未做升级")
    else:
        root_linux()
        if not args.yes:
            if not sys.stdin.isatty() or input("此操作允许替换 Caddy 并重启服务。输入 yes 继续：") != "yes":
                raise Failure("操作取消；自动化调用需要显式 --yes")
        service = Service(args.service, args.binary, args.config)
        transaction = Transaction(args.state_dir, service)
        with transaction.lock():
            if args.command in ("install", "update"):
                if transaction.pending.exists():
                    raise Failure("存在未完成事务，请先执行 recover")
                directory = build(args) if args.command == "update" else Path(args.build)
                binary, info = verify_artifact(directory)
                transaction.activate(binary, info)
            elif args.command == "rollback":
                transaction.rollback(args.backup)
            else:
                transaction.recover()
    return 0


def interrupted(signum, _frame):
    raise Failure(f"收到信号 {signum}，中断操作")


if __name__ == "__main__":
    if sys.version_info < (3, 9):
        sys.exit("需要 Python 3.9+")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except (Failure, OSError, ValueError, KeyError, tarfile.TarError) as exc:
        print("错误：" + str(exc), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("已中断", file=sys.stderr)
        sys.exit(130)
