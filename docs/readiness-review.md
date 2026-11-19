# 上线前审视（2026-11-19）

## Actions 失败证据

[运行 44391396225](https://github.com/satsuki887/naive-update/actions/runs/44391396225) 的 discover job `135109722261`：checkout 成功，2026-11-18 20:28:42 UTC 执行 `ci/prepare-release.sh` 时出现 `curl: (22) The requested URL returned error: 403`，进程退出 4。build/publish 未执行。

工作流虽然传入 GH_TOKEN，原 `api()` 的 curl 并未使用 token；查询上游 latest 失败后，jq 因没有有效输入退出。匿名额度耗尽与现象相符，但日志没有响应头，不能确认 403 的唯一原因是限流。它不是本机 Git 或 checkout 故障。

修复：发现阶段改用自动读取 GH_TOKEN 的 `gh api`；运行时 API 支持 GH_TOKEN；相关 CI job 传入只读 token；API 失败时给出明确错误。另修复集成测试写死 `v2.11.7-naive2` 的问题，改为比较实际 build.json。测试改为使用本次 amd64/arm64 构建产物，避免依赖已有 Release。checkout 的 Node 20 弃用警告不是本次失败原因。

## 功能审视与取舍

| 项目 | 处理 |
|---|---|
| Naive 安装/更新 | 保留官方配套 Caddy、补丁、摘要验证、配置保留和事务回滚 |
| 手工 Caddyfile | 保留编辑副本→验证→应用流程，避免正则批量修改复杂配置 |
| 外部 ACME | 默认已有证书；新安装使用固定路径、成对切换和续期部署命令，解决一次性复制后的续期断链 |
| Hysteria | 集成安装、校验更新、独立备份、服务管理、配置编辑和证书部署；原独立脚本已移除，功能并入本工具 |
| UDP 端口 | 默认 8443，避免与 Caddy HTTP/3 的 443 冲突；安装检查本地 UDP 占用 |
| BBR/优化 | 保留当前内核 BBR/FQ，新增可恢复 UDP 上限；不修改全局文件句柄、SSH、防火墙 |
| UI | 主页面缩短版本信息、任务分区、Hysteria 状态、窄终端单列；完整版本信息在更新页 |

## 验证边界

本地环境为 Windows/Git Bash，无 Linux/systemd。Bash 语法、ShellCheck、现有功能/UI 检查及新增下载校验、二进制保留/恢复、UDP 参数恢复、CI 发现回归可在本地执行。Linux 专属的 BBR 测试由 CI 执行。

新增 `tests/integration-hysteria.sh` 在一次性 Linux runner 上覆盖独立用户安装、相同版本更新、证书切换/恢复、无效配置自动恢复及中断事务恢复，配置于 amd64/arm64 CI。真正的 systemd、证书权限、内核参数和网络端到端可用性需以 CI 与目标机器结果为准；新增测试文件不等于已执行通过。

服务健康检查确认进程持续运行和实际可执行文件摘要，不等于外网客户端代理请求已经通过。正式上线前仍需从客户端验证域名、证书链、TCP/UDP 放行及真实代理连接。

证书、网页和导入的其他配置不属于全盘备份。证书部署事务通过保留旧证书目录恢复；不要删除仍被备份引用的目录。Hysteria 与 Naive 的备份和恢复命令分开。
