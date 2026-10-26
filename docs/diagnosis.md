# 2026-10-26：旧 na 在线编译失败分析

本文使用脱敏信息记录原因和迁移方案，不包含服务器地址、账号、认证材料或完整服务配置。

## 直接原因

旧脚本使用：

```bash
xcaddy build --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive
```

2026-10-22，官方 forwardproxy 提交 `e747854e7874` 引入：

```go
caddyhttp.IdleTimeoutsFromContext(r.Context())
```

原版 Caddy v2.11.7 不提供这个接口，因此出现：

```text
forwardproxy.go:354:31: undefined: caddyhttp.IdleTimeoutsFromContext
```

同一上游提交增加 `caddy-read-idle-timeout.patch`，从 Caddy 开发分支回移接口，并更新官方 CI，在编译前应用此补丁。旧脚本只跟进最新插件，却未跟进 Caddy 补丁流程。

此前可运行的组合为 Caddy v2.11.7 + forwardproxy `c096d6a00cb2`；失败的新组合为原版 Caddy v2.11.7 + forwardproxy `e747854e7874`。所以并非 Go 过旧、配置语法错误或域名证书导致。

来源：

- [引入接口依赖与补丁的提交](https://github.com/klzgrad/forwardproxy/commit/e747854e7874)
- [固定提交的完整构建流程](https://github.com/klzgrad/forwardproxy/blob/e747854e7874/.github/workflows/build.yml)
- [官方服务端 v2.11.7-naive2](https://github.com/klzgrad/forwardproxy/releases/tag/v2.11.7-naive2)

## 同时出现的系统告警

| 现象 | 实际原因 | 新工具的处理 |
|---|---|---|
| Go repo Certificate expired | 旧 Go RPM 仓库的 GPG 证书已过期，不是代理 TLS 证书 | 不导入或使用该仓库；要求现有 Go 满足上游 CI 版本 |
| `tee ... Operation not permitted` | 目标 repo 文件有 immutable 属性 | 不写该文件；doctor 只读报告 |
| BaseOS 仓库重复 | `go-repo.repo` 内含与系统文件重复的 BaseOS 定义 | 不调用 yum/dnf；doctor 列出重复项 |
| 菜单显示 `v154…` | 使用 Naive 客户端版本查询结果标记 Caddy 服务端 | 单独记录服务端标签、两个源码提交、补丁摘要与工具链 |

这些告警值得单独整理，但解除 immutable 或重装 Go 不会补上缺失的 Caddy API。

系统软件源清理应先备份、对比文件，再决定禁用哪份重复定义。不要根据文件名直接删除：名为 `go-repo.repo` 的文件实际内容可能是系统 BaseOS 配置。此项目不提供自动删除或 `chattr -i`，避免破坏管理员已有设置。

## 旧脚本的其他问题

- 预编译包来自博主的 GitLab 仓库，而非 Naive 作者的服务端发布。
- 自更新会重新下载上游脚本，覆盖本地修复。
- 使用移动分支，未固定插件提交和 Caddy 补丁组合。
- 编译之后仅检查 `/root/caddy` 是否存在，可能把残留的旧文件误当作新成果。
- 未先验证当前配置，缺少完整的备份、健康检查和失败恢复。
- 为安装 Go 修改全局源、Go 设置或 shell 配置，扩大了升级影响。

## 新方案

使用独立项目：官方源码 → 固定版本与提交 → 应用官方 CI 补丁 → 编译与校验 → 配置验证 → 备份 → 原子替换 → 重启检查 → 失败回滚。

本地构建和本仓库 GitHub CI 共用相同构建逻辑。CI 定期生成自有仓库的可下载安装包；不自动接入或升级生产服务器。原配置、证书和 unit 保留。
