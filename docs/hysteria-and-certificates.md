# Hysteria、外部证书和系统优化

建议顺序：安装依赖 → 安装 ACME 客户端（菜单 9 可代装）→ 安装 Naive / Hysteria → 配置续期钩子 → 按需启用 BBR/FQ 和 UDP 优化。

## Hysteria 2

菜单 **15** 提供首次安装、更新、服务管理、配置编辑、证书部署说明和备份恢复。原有独立更新脚本的功能已并入本工具，可以删除该脚本；不要同时运行旧脚本和本工具，两者的锁相互独立。

默认兼容 `/usr/local/bin/hysteria`、`/etc/hysteria/config.yaml` 和 `hysteria-server.service`。首次安装使用独立用户、已有证书和随机密码（也可自填），默认 **UDP 8443**，避免与 Naive HTTP/3 的 UDP 443 冲突。需自行放行防火墙/云安全组。

```bash
sudo naive-update hysteria install
sudo naive-update hysteria update
sudo naive-update hysteria edit
sudo naive-update hysteria backups
sudo naive-update hysteria rollback
sudo naive-update hysteria recover
```

更新固定到同一发行标签下载官方二进制和 `hashes.txt`，核对 SHA256 和版本。运行中的服务在更新失败时恢复旧二进制；停止的服务保持停止。已有配置与 unit 保留。配置编辑通过真实重启验证，失败恢复，会短暂中断，因此编辑前要求服务正在运行。

Hysteria 备份独立存放在 `/var/lib/naive-update/hysteria`；菜单 12 属于 Naive/系统变更，Hysteria 使用菜单 15 内的恢复操作。可用 `HYSTERIA_BIN/CONFIG/SERVICE/UNIT/STATE/USER/CERT_ROOT` 环境变量指定自定义部署，恢复和续期时须保持一致。`--release app/v2.x.y` 可指定官方稳定标签。

客户端使用安装时填写的域名和端口，密码保存在配置的 `auth.password`，默认不打印到日志；已有复杂 YAML 不会被自动重写。首次生成的是最小 TLS + 密码配置，伪装、ACL、端口跳跃等通过配置编辑按需添加。

## 安装 acme.sh 与 NameSilo 示例

菜单 9 → 7（或 `naive-update cert acme-install`）会从官方 GitHub 仓库克隆并安装 acme.sh，创建续期 cron，并写入 shell 启动文件。已安装时可以选择重新安装/更新，或直接查看示例。邮箱可用 `ACME_EMAIL` 环境变量提供，否则交互询问。

安装完成后会打印两组可复制命令。NameSilo 的 API Key 变量名固定为 `Namesilo_Key`（大小写敏感）：

```bash
export Namesilo_Key='你的 NameSilo API Key'
/root/.acme.sh/acme.sh --issue --dns dns_namesilo -d example.com -d '*.example.com'
```

续期时用 `--install-cert` 把证书写到暂存路径，再用 reloadcmd 调用本工具。Naive 示例：

```bash
mkdir -p /var/lib/naive-update/acme-staging/example.com
/root/.acme.sh/acme.sh --install-cert -d example.com \
  --key-file       /var/lib/naive-update/acme-staging/example.com/private.key \
  --fullchain-file /var/lib/naive-update/acme-staging/example.com/cert.crt \
  --reloadcmd      '/usr/bin/naive-update cert deploy --cert /var/lib/naive-update/acme-staging/example.com/cert.crt --key /var/lib/naive-update/acme-staging/example.com/private.key --domain example.com --yes'
```

Hysteria 将 reloadcmd 换成 `naive-update hysteria cert-deploy ...`，暂存目录默认在 `/var/lib/naive-update/hysteria/acme-staging`。`naive-update cert acme-example` 或 `hysteria cert-hook` 会按当前服务打印对应版本。

默认 CA 为 ZeroSSL；如需 Let's Encrypt，在 `--issue` 命令加 `--server letsencrypt`。DNS-01 不依赖 80/443 端口，但需要 NameSilo API Key 的 DNS 编辑权限。首次部署必须使用“已有证书”模式，才会生成 `managed-certs/current`；否则 `cert deploy` 会拒绝执行。

## 固定证书路径与续期

ACME 由你安装配置。Naive 向导默认选择已有证书，仍可选择 Caddy 自动 ACME。外部证书的新安装使用：

| 服务 | 完整链 | 私钥 |
|---|---|---|
| Naive | `/etc/caddy/managed-certs/current/cert.crt` | `/etc/caddy/managed-certs/current/private.key` |
| Hysteria | `/etc/hysteria/managed-certs/current/cert.crt` | `/etc/hysteria/managed-certs/current/private.key` |

acme.sh 的 `--install-cert` 先把文件写到你指定的暂存目录，再通过 `--reloadcmd` 调用下列命令，替换路径和域名：

```bash
naive-update cert deploy --cert /你的路径/fullchain.pem --key /你的路径/key.pem --domain example.com --yes
naive-update hysteria cert-deploy --cert /你的路径/fullchain.pem --key /你的路径/key.pem --domain example.com --yes
```

命令需要 root。两个服务共用证书时，续期钩子需要调用两条命令。使用自定义环境变量时，钩子也必须传入相同变量。

**不要让 ACME 直接写入 `current`**。部署先校验有效期、域名和密钥匹配，在仅服务用户组可读的新目录中准备证书对，再原子切换链接。Naive 验证并重载，Hysteria 重启；失败恢复旧证书。原先停用的服务不会被自动启动。旧版本保留用于回滚，清理前需考虑相关备份是否仍会使用。

此流程用于本次新安装。已有部署保持原证书配置，不自动迁移；原来的 `cert import` 仍是手工导入，续期需按照原路径处理。`cert hook` / `hysteria cert-hook` 显示本机路径说明。

## 有边界的系统优化

```bash
sudo naive-update bbr enable
sudo naive-update tune status
sudo naive-update tune udp
sudo naive-update backups
sudo naive-update rollback BACKUP_ID
```

菜单 11 管理 BBR/FQ；菜单 16 只把不足的 UDP 接收/发送缓冲区上限提高至 16 MiB，保留已有较大值，并备份原运行值和独立 sysctl 文件。它提高 socket 上限，不预分配整块内存。

新建服务设置 `LimitNOFILE=1048576`；已有 unit 保持不变。BBR 是内核 TCP 拥塞控制，Hysteria QUIC 的拥塞控制由应用管理。实际速度仍受线路、CPU 和服务商限制。脚本不替换内核、不批量覆盖 sysctl、不修改 SSH 或防火墙。

依据：[Hysteria 官方性能说明](https://v2.hysteria.network/docs/advanced/Performance/)、[服务端配置](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)。
