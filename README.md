# naive-update

独立的交互式 **Bash 运维工具**：全新安装 Naive 服务端、管理 Caddy、升级内核、证书与分享、BBR 和 WARP。运行时只需一个 `naive-update.sh`，无需 Python 或其他配套源码文件。

本工具由第三方维护，服务端使用 Naive 官方 `klzgrad/forwardproxy` 源码及其 Caddy 版本和补丁。GitHub Actions 定时编译 Linux amd64 / arm64 安装包。没有脚本自更新，也不使用原博主的脚本或二进制。

## 获取并运行

```bash
curl -fL --proto '=https' --proto-redir '=https' \
  https://raw.githubusercontent.com/satsuki887/naive-update/main/naive-update.sh \
  -o naive-update.sh
sudo bash naive-update.sh
```

首次以 root 打开交互菜单会把当前单文件安装为 **`/usr/bin/naive-update`**。以后直接输入：

```bash
sudo naive-update
```

默认不会覆盖旧 `/usr/bin/na`。菜单 13 可以备份旧脚本后接管 `na` 命令。工具不自动下载自身更新；手工下载新单文件并再次运行即可安装新工具版本。

基础依赖是常见系统工具：Bash 4.3+、curl、jq、OpenSSL、GNU tar/coreutils、util-linux（flock/setpriv）、systemd。本地编译另需 Git、Go；二维码需要可选的 qrencode。菜单会检查依赖，可通过系统源安装。Go 不足时可安装 go.dev 提供、经过摘要校验的独立工具链，不覆盖系统 Go，也不写旧 Go 软件源。

## 交互菜单

| 编号 | 功能 |
|---|---|
| 1 | 全新安装：CI 包或本地编译、域名和凭证、自动 ACME 或已有证书、静态/反代伪装、systemd |
| 2 | 卸载二进制和本地 unit，保留配置、证书、用户数据及恢复备份 |
| 3 | Caddyfile 手工编辑、验证、重载、写入可选示例 |
| 4 | 启动、停止、重启、开机启动及状态 |
| 5 | 官方服务端版本检查与工具信息 |
| 6 | CI 包升级、本地源码编译升级、安装已有构建 |
| 7 | 分享链接、Naive 客户端 JSON、可选终端二维码 |
| 8 | systemd 日志 |
| 9 | 证书状态、重载、导入、已有 acme.sh 的列表/续期 |
| 10 | Cloudflare 官方 WARP 安装、状态、本地代理连接/断开、出口可达性检测 |
| 11 | BBR + FQ、cubic + fq_codel、从备份恢复原网络参数 |
| 12 | 备份与回滚、中断事务恢复 |
| 13 | 安装快捷命令、可选接管 na |
| 14 | 系统诊断、安装依赖 |

## 新服务器安装

准备域名，先把 A/AAAA 记录指向这台服务器。下载单文件，打开菜单 1。选择使用本仓库 CI 包或按官方源码本地编译，然后填写域名、监听端口、用户名和密码。

证书优先使用 **Caddy 自带 ACME 自动申请与续期**，不需要再安装 acme.sh；也可导入已有完整链证书和无口令私钥。自动 ACME 需要域名解析正确，公网 80 或 443 能完成挑战。外部证书会检查有效期、域名和公私钥匹配，复制到服务可读的专用目录。

全新安装使用独立 `naive-caddy` 用户和用户组，以 `CAP_NET_BIND_SERVICE` 绑定低端口，启用 systemd `NoNewPrivileges`、`PrivateTmp`、`ProtectHome` 等设置。数据放在 `/var/lib/naive-caddy`；管理状态及备份放在 root 私有的 `/var/lib/naive-update`。

部署向导不会关闭防火墙或替你操作云安全组。按实际端口放行 TCP；默认 Caddy 支持 HTTP/3，需要时放行相同 UDP 端口。自动 HTTP 重定向和 HTTP ACME 挑战通常需要 TCP 80。

### 默认 Caddyfile

本地静态伪装模式按官方当前示例生成：

```caddyfile
{
    order forward_proxy before file_server
    log {
        exclude http.log.error
    }
}
:443, example.com {
    forward_proxy {
        basic_auth "user" "password"
        hide_ip
        hide_via
        probe_resistance
    }
    encode
    file_server {
        root /var/lib/naive-caddy/www
    }
}
```

向导填写 ACME 邮箱时加 `tls 邮箱`；使用外部证书时加 `tls 证书 私钥`。默认不限制 h1/h2/h3、不拦截 IP、不额外放行私网目标，也不使用旧脚本的随机 HTTP 端口或冗余 HTTPS 上游 Host 覆盖。

选择 HTTPS 反代伪装时，使用显式 `route` 依序运行 forward_proxy 和 reverse_proxy。Caddy 2.11+ 会自动处理 HTTPS 上游 Host，不重新添加旧模板的 `header_up Host {upstream_hostport}`。

主配置在 **`/etc/caddy/Caddyfile`**。示例在 **`/etc/caddy/examples/`**，包括标准模板和可选的 h1/h2、地址拦截、私网 ACL、隐私访问日志、多用户、多端口、WARP upstream 片段。示例不被主配置自动 import。

## 现有部署与手工编辑

已有 Caddy 二进制、Caddyfile 或同名服务时，禁止通过菜单 1 覆盖安装。直接使用管理/升级功能。

**内核升级只替换二进制，不重写 Caddyfile 或 unit**。现有协议限制、matcher、ACL、日志过滤、证书路径与反代设置都保留。可以继续用自己的编辑器编辑文件，然后：

```bash
sudo naive-update config validate
sudo naive-update config reload
```

也可以用 `config edit`：在同目录副本中调用 `$VISUAL` / `$EDITOR`（默认 vi），验证通过后备份并应用。失败时不替换原文件。工具不做宽泛 sed 替换，也不按新模板覆盖用户维护的配置。

外部直接编辑之后的 `reload` 会备份当时磁盘文件；它无法凭空找回编辑之前的内容。需要原文件恢复点时，请先自行备份，或使用菜单的副本编辑方式。

## 内核升级

```bash
# 分两步：只获取，审核后再安装
bash naive-update.sh download --output ./build
sudo bash naive-update.sh install --build ./build --yes

# 或服务器本地编译
bash naive-update.sh build --release v2.11.7-naive2 --output ./build-local --jobs 2
sudo bash naive-update.sh install --build ./build-local --yes

# 获取并安装
sudo naive-update update --source download --output /var/lib/naive-update/artifacts/new-version --yes
```

输出目录必须尚不存在，避免将旧残留程序误判为新构建。编译会固定官方服务端发布标签、forwardproxy 提交、Caddy 版本与提交、xcaddy 版本；按该标签的官方 CI 顺序应用补丁。遇到未知 CI 步骤、缺少补丁或补丁应用失败时停止。Go 使用进程级环境、官方模块代理和校验数据库，不执行 `go env -w`，不修改 `/etc/profile`。

服务端版本采用 `v2.x.y-naive…`，与 Naive 客户端的 Chromium `v154…` 版本独立。

CI 包来自本仓库 Releases，是本仓库从官方源码编译的产物，并非 Naive 官方签名二进制。工具检查压缩包摘要、GitHub 资产摘要（若提供）、包内二进制摘要和版本/架构。摘要代表完整性，不等于独立签名；请只安装信任来源的构建目录，因为验证配置时会执行其中的 Caddy。

## 备份与恢复

安装/配置变更会保留备份，验证后才原子替换目标文件。验证使用运行中服务的用户、组、环境与工作目录。新版本启动失败时自动恢复旧版；状态目录为 root:root、0700。二进制升级的回滚只恢复二进制，不覆盖后来手工修改的配置。

```bash
sudo naive-update backups
sudo naive-update rollback --yes          # 恢复最近一次操作前状态
sudo naive-update rollback BACKUP_ID --yes
sudo naive-update recover --yes           # 断电/SIGKILL 等留下 pending.json 后
```

恢复遇到文件损坏、文件不可写或 systemd 自身异常时可能需要人工处理；事务和备份保留。不会自动解除 immutable，不会自动删除备份。

备份含主配置、二进制、本地 unit 及 unit 展开快照，可能包含密码。证书、网站文件、导入配置与 EnvironmentFile 不属于完整恢复范围；它们不会因内核升级被改写。默认卸载保留这些内容和管理工具，便于恢复。

原 Python 1.x 管理器的未完成事务应先用原版本恢复；2.x 使用新的事务格式，不直接解释旧事务。

## 证书、WARP、BBR

- Caddy 自动 ACME 按自身策略续期，不定时删除证书强制重签。`cert status` 查看外部证书及服务数据，`cert reload` 验证后重载。
- `cert import` 复制和验证证书，输出可加入 Caddyfile 的 tls 行；按你的习惯由你编辑文件。
- 已安装的 root 自有 acme.sh 可通过菜单列出/续期；不再下载旧博客的 ACME 包装脚本。外部证书由你配置 acme.sh 的 install-cert 目标路径与成功 reload 钩子。
- WARP 使用 Cloudflare 官方签名仓库。仅在所装客户端支持 CLI proxy 模式时连接本地代理，并使用 MASQUE；不自动切换整机默认路由。Naive 需要使用该出口时，可手工添加示例中的 `upstream socks5://127.0.0.1:40000`。
- WARP 发行版/架构支持和模式以 Cloudflare 当前客户端为准，受管理的 Zero Trust 客户端可能禁止本地模式修改。RPM 依赖可能需要 EPEL。
- 出口检查显示 IP/地区、WARP 状态、ChatGPT/Netflix HTTP 可达性；HTTP 403 与反爬有关，不能简单当作地区封锁或播放授权结论。
- BBR 使用当前系统内核，写入独立 sysctl 文件并保存修改前参数。不会装来源不明的 BBR Plus 内核、刷写整份 sysctl、清空防火墙或改变 SSH 配置。

## GitHub CI

每 6 小时检查官方 forwardproxy 新稳定发布，分别在原生 amd64 / arm64 runner 上编译，两个架构都成功后才发布 `server-*` Release。可手动 Run workflow。定时任务可能延迟；公开仓库长期无活动时 GitHub 可能暂停，需要重新启用。

测试包含 ShellCheck、输入与配方验证、包内容/摘要检查、真实新安装（非 root 服务）、自定义配置保留、启动失败恢复、手动回滚和事务恢复。测试仅在一次性 runner 中创建服务，不连接生产服务器。

`tool-v*` 标签发布单文件工具和摘要，且不抢占服务端包的 latest 标记。脚本安装到服务器后不会自动更新自身。

```bash
bash tests/test-shell.sh
shellcheck naive-update.sh ci/*.sh tests/*.sh
```

默认路径可用 `NAIVE_BIN`、`NAIVE_CONFIG`、`NAIVE_SERVICE`、`NAIVE_UNIT`、`NAIVE_STATE`、`NAIVE_TOOL`、`NAIVE_DATA` 调整；路径与服务名称必须在备份/恢复时保持一致。主配置需是 Caddyfile，当前不支持 --resume/--envfile、符号链接二进制或无法确认的包装主进程。

## 评估与上游来源

- [完整功能与兼容性评估](docs/design-review.md)
- [旧版本编译故障分析](docs/diagnosis.md)
- [Naive 官方服务端说明](https://github.com/klzgrad/naiveproxy#server-setup)
- [官方构建流程](https://github.com/klzgrad/forwardproxy/blob/naive/.github/workflows/build.yml)
- [Caddy HTTPS 上游行为](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#https)
- [Caddy 自动 HTTPS / ACME](https://caddyserver.com/docs/automatic-https)
- [Cloudflare 官方软件源](https://pkg.cloudflareclient.com/)

工具采用 MIT 许可证；服务端包附上游许可证。公开仓库不含生产认证材料；本地交接记录 `LOCAL_NOTES.md` 不进入 Git。