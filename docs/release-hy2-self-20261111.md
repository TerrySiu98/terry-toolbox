# A4 HY2 自签向导 — 2026-11-11

## 状态

**已发布现有 Worker `terry-toolbox` / `sh.uw.cx`。** 北京时间 2026-11-11T12:53:19.073601+08:00。PR [#11](https://github.com/TerrySiu98/terry-toolbox/pull/11) 的 head `23955bcb78466c7a5284594c3dfeefae4482644f` 已合并为 `48205b5b66d2f8cd26262f3cc0ed2bae0769ce1b`，树完全一致，源分支保留。后续文档提交不改变脚本。

- 基线：`520d9f8b8a6a1cf0dd40a7c0ddef51e88852a8b4`。
- 候选脚本 SHA-256：`89b784c7ac51ccec51654a2fa78fd9d3afcc593c355bd88761dc47e2ed6245fa`，765304 字节。
- 功能与操作说明见 [README A4](../README.md#a4hysteria-2-无自有域名自签模式)，机器可读验收摘要见 [JSON](release-hy2-self-20261111.json)。

## 变更与信任边界

无需自有域名的自签安装与已有证书并存；SNI 与连接入口分开。ECDSA P-256/SAN、自签固定 365 天、无自动续期。官方分享 URI、官方 client YAML、Mihomo YAML 以 0600 保存并包含叶证书 pin。旧 CLI、一次 YES 与四字段 metadata 保持兼容；自签路径两次 YES。

子进程清理先以 pidfd/PPID/start-time 确認本轮进程并停止、wait，再删除其文件；无法确认则保留现场。创建 HY2 资源前，对自身执行 pidfd 打开和零信号预检，缺少 API 或内核能力时拒绝继续，不降级为仅按 PID 发信号。普通依赖补装属于独立授权步骤：若缺依赖且用户输入 `y`，可先补装依赖再检查 pidfd；检查失败不会回退已确认安装的普通依赖。并非整个脚本零系统变更。

## 已有验收

- 冻结最终候选：7/7 定向 runner，syntax、build-test.sh、dependencies-test.sh、entry-test.sh、hy2-self-cert-test.sh、hy2-test.sh、menu-test.py；没有源码漂移，子孙清理完整。不是全仓回归。
- Debian 13.7/x86_64 真 KVM：25/25 原生检查，覆盖取消不改系统、自签与旧证书 CLI、IPv4/IPv6 三种导出 TCP/UDP nonce、错误 pin/密码/SNI 明确拒绝、服务重启及卸载。
- 8/8 单文件 smoke，16 组中断子进程控制；pidfd 缺少 API / ENOSYS 等写前拒绝 RED/GREEN 通过。
- 原信号清理阻塞已独立复核关闭；最后 pidfd 能力预检完成独立 changes-only 复核，16 个最小控制中有 1 个确认普通依赖可在检查前经 `y` 授权补装。父级保留原有依赖确认协议，撤回“任何变更前拒绝”的过宽说明；按“HY2 自身文件/服务创建前拒绝”的实际边界，无未解决代码阻塞。原审查发现与证据保留，不将 16 项全部称为安全通过。
- 测试服务已卸载，guest 正常关闭；本次发布只更新分发脚本，不安装或升级用户服务器服务。

## 未验与限制

公网 UDP 入站、手机客户端导入、整机重启后的自启、arm64、旧 Python/内核组合未验证。自签不是公信 CA 证书，SNI 不代表流量经第三方网站。客户端必须支持并保留证书 pin；不支持则不要绕过验证。现有同名安装不能自动接管。

## 发布与回退

沿用现有 Worker 和域名，发布前保留完整旧四模块、settings/annotations、workers.dev、域名/DNS 及公网内容；只允许精确目标单次上传，不重新绑定域名。实际单次完整上传已完成：四模块逐字节匹配，完整 settings/annotations、workers.dev、域名/DNS 保持不变；14 项公网普通/随机参数 URL、路由/哈希及 10 项下载安全 smoke/TLS 通过。欢迎页/router 未改，本轮未重复浏览器 UI。GitHub 没有 checks/status 或 required gates，不称 CI 通过。旧版 SHA-256 为 `405b73b8274b984f42e6f675b3d46556d2eff81071af3895e9cb387c43a03492`；回退仅恢复分发脚本，不卸载用户已安装的 HY2。

私有回退快照与原始证据由维护者保留；原候选验收、审查发现和 scanner 非零报告不覆盖。秘密扫描 index/commit 保留 4 个继承非秘密命中，分别为公开 WebSocket 样例 nonce 和空 Bash 变量；均与基线精确一致，无新增 allowlist。
