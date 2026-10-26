# naive-update

按 NaiveProxy 官方服务端构建流程升级 **Caddy + Naive forwardproxy**。

提供本地源码编译，以及本仓库 GitHub Actions 自动编译的 Linux amd64 / arm64 安装包。支持安装前验证、备份、原子替换、失败回滚和中断恢复。

本项目是独立的第三方升级工具，不是 NaiveProxy 官方项目，不包含原一键脚本代码。没有脚本自更新功能，也不下载原博主的程序或安装包。

## 适用范围

- 已经安装并通过 systemd 运行的 Caddy / Naive 服务端。
- 默认路径：`/usr/bin/caddy`、`/etc/caddy/Caddyfile`、`caddy.service`。
- Linux，Python **3.9+**。本地编译另需 Git 和满足官方 CI 要求的 Go。
- 安装要求 root；服务必须正在运行，且主进程直接执行目标 `caddy run --config ...`。
- 支持沿用现有域名、账号、证书、端口、伪装站和 systemd 配置。
- 不负责首次安装、证书签发、客户端配置、卸载、网络加速或 BBR 内核设置。

## 快速使用

先获取工具。脚本与 Python 文件应保留在同一目录：

```bash
git clone https://github.com/satsuki887/naive-update.git
cd naive-update
bash naive-update.sh doctor
bash naive-update.sh check
```

### 方式一：使用本仓库 CI 编译包

```bash
# 只下载，不替换程序、不重启服务；自动匹配 amd64 / arm64
bash naive-update.sh download --output ./build

# 安装已有构建，明确允许替换二进制并重启
sudo bash naive-update.sh install --build ./build --yes
```

下载地址固定为本仓库 Releases。工具校验压缩包 SHA256、GitHub 提供的资产摘要（若存在）、包内二进制 SHA256，以及版本和架构。

也可以在 [Releases](https://github.com/satsuki887/naive-update/releases) 手动下载压缩包与 `SHA256SUMS`，核对后解压，再通过 `install --build 解压目录` 安装。

> 本仓库的包由本仓库 CI 从官方源码编译，并不是官方签名的二进制。SHA256 用于完整性检查，不等于独立的发布者签名。请只安装自己信任来源的构建目录；安装阶段会执行其中的 Caddy 来验证配置。

### 方式二：在服务器本地编译

```bash
# 普通用户也可编译。--output 必须是尚不存在的目录
bash naive-update.sh build --output ./build-local --jobs 2

# 检查后再安装
sudo bash naive-update.sh install --build ./build-local --yes
```

也可以合并执行：

```bash
sudo bash naive-update.sh update --output ./build-new --jobs 2 --yes
```

指定已知官方**服务端**发布标签，可避免 latest 查询受 GitHub API 限流影响：

```bash
bash naive-update.sh build --release v2.11.7-naive2 --output ./build-pinned
```

每次编译使用新的输出目录，避免把上次残留程序误当作本次成果。编译失败时保留独立工作目录及 `build.log`；不会进入安装阶段。

## GitHub 自动编译

`.github/workflows/release.yml` 每 **6 小时**检查一次 `klzgrad/forwardproxy` 的最新稳定服务端发布。GitHub 定时任务可能延迟，非即时通知。

1. 发现尚未完整发布的官方版本。
2. 在原生 amd64、arm64 Linux runner 上分别编译；使用官方标签的 `CADDY_VERSION` 和补丁应用顺序。
3. 执行测试及隔离配置验证。
4. 两个架构都成功后，发布到本仓库 `server-官方版本` Release。

每个 Release 包含：

```text
naive-server-vX.Y.Z-naiveN-linux-amd64.tar.gz
naive-server-vX.Y.Z-naiveN-linux-arm64.tar.gz
SHA256SUMS
```

压缩包内仅含 `caddy`、`build.json`、`build-info.txt`、`SHA256SUMS`、`LICENSES.txt`。不会打包服务器配置、账号密码、私钥、构建缓存或完整日志。

也可在 **Actions → Build official Naive server → Run workflow** 手动触发，输入指定官方服务端标签。相同版本已有完整发布时跳过编译。新建仓库需启用 Actions；组织策略可能禁止定时任务或 ARM runner。公开仓库长期无活动时 GitHub 可能暂停定时任务，届时需在 Actions 页面重新启用。

发布只使用 GitHub 内置 `GITHUB_TOKEN`，不需要填写个人 PAT；只有发布 job 获得 `contents: write`。构建不会连接你的服务器。

## 本地编译流程

1. 从官方 `klzgrad/forwardproxy` 获取稳定标签并记录实际提交。
2. 读取该标签的 `CADDY_VERSION` 与官方 CI 支持的构建配方。
3. 从 `caddyserver/caddy` 获取指定标签并记录提交。
4. 依序检查、应用官方 CI 使用的补丁。
5. 将 xcaddy 版本解析并固定后安装至独立工作目录；可以用 `--xcaddy-version vX.Y.Z` 手动固定。
6. 使用本地已打补丁的 Caddy 和本地 forwardproxy 源码构建。
7. 检查 Caddy 版本与 `http.handlers.forward_proxy` 模块，生成构建记录和摘要。

当前配方包含 `caddy-sing-quic-bbrv1.patch` 与 `caddy-read-idle-timeout.patch`。补丁列表来自固定标签的 CI，不是单纯跟踪移动分支。遇到不认识的准备步骤、结构或补丁失败时停止，避免继续生成缺少必要补丁的程序。

使用进程级 Go 环境，不执行 `go env -w`，不修改 `/etc/profile`，不导入旧 Go 仓库 GPG 密钥。Go 工具链不足时明确报错，不自动覆盖系统 Go。默认关闭 CGO，amd64 使用通用 v1 指令集；默认两路并行，可通过 `--jobs` 调整。

源码构建会使用当前用户的 Go 下载/编译缓存。Go 模块来自 `proxy.golang.org` 或模块源站，校验使用 `sum.golang.org`；此工具不会把依赖复制到第三方镜像。本地构建记录保证版本可追踪，不承诺跨工具链的逐字节可重现。

## 安装、回滚与恢复

安装会检查运行进程与目标二进制、配置路径一致，并沿用该进程的环境、工作目录和用户身份执行 `caddy validate`。环境变量仅在内存中使用，不写入构建记录。

验证通过后才在同一文件系统中原子替换二进制，保留原属主、权限、扩展属性（包括 capabilities / SELinux 标签），并重启服务。检查服务稳定运行且运行进程的二进制摘要符合预期；失败则恢复备份并再次启动旧版。**进程健康检查不替代客户端代理连通性测试**，升级后仍应实际连接测试。

默认备份目录：

```text
/var/lib/naive-update/                 # root:root，0700
  installed.json                     # 当前安装及来源记录
  pending.json                       # 仅在未完成事务期间存在
  backups/<时间戳-ID>/
    caddy                            # 切换前的二进制
    Caddyfile.snapshot                # 主配置快照，0600
    systemd/                         # unit 和 drop-in 快照
    metadata.json
    validate.log
```

快照可能含密码或证书路径，勿上传 GitHub。备份不自动删除，由管理员自行管理磁盘空间。证书、导入配置文件、systemd EnvironmentFile 和网站文件不在备份范围内；工具也不修改它们。

```bash
# 显示本工具安装记录与当前程序信息
sudo bash naive-update.sh status

# 回到最近一次切换之前的二进制
sudo bash naive-update.sh rollback --yes

# 指定本工具已保存的备份 ID
sudo bash naive-update.sh rollback --backup 20261026T120000Z-1234abcd --yes

# 断电、SIGKILL 或自动回滚未完成后，先恢复中断事务
sudo bash naive-update.sh recover --yes
```

回滚仅恢复二进制，不覆盖之后手工修改过的配置或证书。回滚本身也会备份当前二进制。存在未完成事务时禁止继续安装，需先执行 `recover`。若 systemd 或旧服务自身已损坏，自动恢复可能失败；事务和备份会保留，便于人工处理。

修改路径的示例（选项放在子命令之后）：

```bash
sudo bash naive-update.sh install --build ./build --yes \
  --binary /usr/local/bin/caddy \
  --config /etc/caddy/Caddyfile \
  --service caddy.service \
  --state-dir /var/lib/naive-update
```

执行回滚、恢复时需使用相同路径和服务名称。当前安装器拒绝符号链接二进制、immutable / append-only 二进制、停止中的服务，以及无法确认主进程或配置路径的包装启动方式。使用动态 systemd 用户、沙盒路径或复杂命名空间的服务，需要管理员单独评估；工具不会改写 unit 来绕过限制。

## 从旧 `na` 脚本迁移

新工具使用自己的名称和目录，不会自动覆盖 `/usr/bin/na`，也不执行旧脚本。请停止使用旧 `na` 的“更新脚本”“更新内核”两个入口，避免它再次下载旧逻辑或覆盖新二进制。

旧菜单中的 Chromium `v154…` 版本标记不会由本工具伪造更新。服务端升级依据 `forwardproxy` 的 `v2.x.y-naive…` 发布；Naive 客户端版本独立管理。

关于编译报错、Go 软件源失效、仓库重复以及文件 immutable，见 [故障分析](docs/diagnosis.md)。本工具通过不依赖旧软件源避开这些问题；`doctor` 只读报告，不擅自解除文件属性或删除系统仓库。

## 测试与限制

```bash
python3 -m unittest discover -s tests -v
bash -n naive-update.sh
```

自动测试覆盖补丁解析、未知配方拒绝、来源和 SHA256 校验、压缩包路径与链接拒绝、安装前验证失败、重启失败恢复、恢复失败保留事务、手动回滚、配置并发变更和备份损坏。Linux CI 另外测试文件权限及扩展属性，并从真实上游源码编译。编译后还会在 runner 内创建临时 systemd 服务，实测安装、手动回滚及启动失败恢复；不会连接生产服务器。

工具不会重写所有系统源来“消除告警”，也没有自动升级正在运行服务器的定时任务。GitHub 定时任务只构建和发布包；服务器是否安装由你决定。

## 上游来源

- [NaiveProxy 官方服务端说明](https://github.com/klzgrad/naiveproxy#server-setup)
- [Naive forwardproxy 服务端发布](https://github.com/klzgrad/forwardproxy/releases)
- [官方服务端构建流程](https://github.com/klzgrad/forwardproxy/blob/naive/.github/workflows/build.yml)
- [Caddy 源码](https://github.com/caddyserver/caddy)
- [xcaddy](https://github.com/caddyserver/xcaddy)

本工具代码采用 MIT 许可证。构建产物内附上游许可证；上游组件保留各自的许可证。
