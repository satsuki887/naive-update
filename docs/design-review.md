# 2.0：旧 na 功能与现代化评估

## 目标与边界

单文件、可交互、可安装快捷命令；一台新 Linux/systemd 服务器可走完安装流程。已有部署由管理员手工维护 Caddyfile，内核升级必须保留配置和 unit，不以模板回填覆盖。

## 功能映射

| 原功能 | 2.0 实现与改进 |
|---|---|
| 安装 / 部署 | CI 包或官方源码、ACME/外部证书、静态或 HTTPS 反代、独立系统用户、systemd |
| 卸载 | 备份后卸载二进制与本地 unit，保留证书、配置和用户数据，可回滚 |
| 端口 / 多用户 / 伪装 | 手工编辑 Caddyfile；提供副本编辑、验证、重载和独立示例，不对复杂配置做宽泛替换 |
| 启停 / 重启 | systemctl 控制与稳定运行检查，保留既有服务运行方式 |
| 脚本自更新 | 移除自动覆盖；手工获取自己的单文件；快捷命令安装只复制当前正在运行的文件 |
| 内核升级 | 固定官方源码标签、读取配套版本、按官方 CI 应用补丁、验证、原子替换、失败恢复 |
| 链接 / 配置 / 二维码 | 从实际 Caddy 适配后的 JSON 读取，保留含冒号密码，URL 编码，原生客户端 JSON 与分享 URI |
| 日志 | journalctl；新配置默认排除 http.log.error，访问日志过滤作为可选示例 |
| ACME | 新部署优先 Caddy 内建申请和续期；外部证书校验/导入；已有 acme.sh 支持列表/续期 |
| WARP / 检测 | 官方签名源和 MASQUE 本地代理；不引入未知路由脚本，不把网页状态码误称为完整解锁结果 |
| BBR | 检查当前内核支持，独立 sysctl 文件、备份并可恢复，不替换内核或全局网络配置 |
| 快捷方式 | root 交互启动安装 /usr/bin/naive-update；可选备份并接管 /usr/bin/na |

## Caddyfile 兼容性

只读核对的现有生产配置已经正常使用 Caddy 2.11.7，并有自定义 HTTP 端口、h1/h2、地址拦截、私网 ACL、敏感请求头过滤日志和 HTTPS 反代。这些是现有部署的用户策略，不能当作所有新服务器的默认设置。

脱敏测试副本保留这些结构，域名、地址、认证、证书和日志路径替换为测试值。集成测试验证更新前后主配置逐字节一致，并在新内核上验证配置和实际运行；不会把生产配置放入仓库。

新配置按官方当前 README 的 forward_proxy + file_server 结构生成。没有显式 protocols 时采用 Caddy 自身默认协议；不加入拦截或私网 ACL。选择反代伪装时使用 route 保持处理顺序。独立 examples 目录只作参考，不自动 import。

### 已核实的旧方式

- 从 Caddy 2.11 起，HTTPS 上游 Host 会自动调整；旧 `header_up Host {upstream_hostport}` 不是已删除语法，但默认模板中已无必要，不能误称为所有情况下都“废弃”。
- Naive 插件内的 `basic_auth` 与 Caddy 自带站点认证指令是两种上下文，不能因为 Caddy 核心认证语法变化就擅自改写插件子指令。
- `http_port` 仍是有效全局选项；旧脚本随机设置它不是新部署的必要条件。既有值不改。
- `servers { protocols h1 h2 }`、matcher、`abort`、forward_proxy ACL、日志 filter/rolling 均保留兼容测试；不因官方示例简化就删除用户实际策略。
- 不设置旧 TLS ciphers、不关闭 TLS 校验、不伪造 Chrome 或 Chromium 客户端版本。

## 安装与系统改动

基础依赖来自系统仓库。Go 独立工具链来自 go.dev 并校验 SHA256，不再导入过期 Go RPM 密钥或改写 go-repo.repo。当前重复源和 immutable 问题只诊断，不删除名字看似 Go、实际装着 BaseOS 的配置。

新安装使用专用用户组与服务用户、最小监听能力；外部私钥不会直接留在服务不可访问的 /root 路径。已有服务升级不强制改用新用户或改写 unit，避免破坏证书、日志及文件权限。

防火墙和云安全组是独立网络边界；工具不清空它们。DNS、证书挑战公网可达性与云端规则需要管理员准备。CI 能验证本地生成配置和完整服务生命周期，不能替代真实域名所有权验证或生产网络连通性。

## 依据

- https://github.com/klzgrad/naiveproxy#server-setup
- https://github.com/klzgrad/forwardproxy/blob/naive/.github/workflows/build.yml
- https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#https
- https://caddyserver.com/docs/automatic-https
- https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html
- https://pkg.cloudflareclient.com/
- https://developers.cloudflare.com/warp-client/get-started/linux/
- https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/
