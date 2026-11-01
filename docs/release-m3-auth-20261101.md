# M3 三系统密码 / SSH 密钥选择发布

**已合并并发布，仍为开发预览。** 北京时间 `2026-11-01T17:02:08.405826+08:00`（UTC `2026-11-01T09:02:08.405826+00:00`）。

- PR：[#6](https://github.com/TerrySiu98/terry-toolbox/pull/6)；复审：[精确 head 评论](https://github.com/TerrySiu98/terry-toolbox/pull/6#pullrequestreview-5727301310)。
- 已审 head：`34f4bc87ba4d18609c2277873960299bbbb774f6`；合并源码：`8e73adbfa8012539018e0e8c0a18dce42d7a5c9c`。合并树与已审树一致，源码分支保留。
- 线上 Worker `terry-toolbox` / `sh.uw.cx`；没有切换托管或 DNS。
- 单文件 `docs/index.html`：SHA-256 `114640dc498b6861d6679ad89b5a8ca7edd4eff941ebec541197c23f25ac6abf`，`728768` 字节。
- 旧版 SHA-256 `8ceed7f82f0bf76cc15bbeab76ae5c599186bc1666cf117c6fb66194998b00df` 已保存在私有部署快照。
- [机器可读发布记录](release-m3-auth-20261101.json)。文档后续提交不改变已验脚本。

## 使用

退出旧脚本后重新运行：

```bash
bash <(curl -fsSL https://sh.uw.cx)
```

输入 `4` 或 `M3`，选 `2 准备重装`，选择 Debian 13 / Ubuntu 24.04 / Alpine 3.24，完成预检后出现：

```text
登录方式：1 密码 / 2 SSH 密钥（推荐） / 0 取消
```

- **密码**：真实交互终端隐藏输入两次，一致且为 12–256 字节；保留空格/特殊字符，多字节字符按字节计数。不提供明文参数、环境变量或管道接口。输入空值、未完成输入、不一致或取消不会执行上游。
- **密钥**：提供本机绝对路径 `ssh-ed25519` 公钥 `.pub` 文件，自己持有配套私钥；不是输入登录密码。旧 `TOOLBOX_REINSTALL_SSH_KEY_FILE` 调用保留；可选模式变量 `TOOLBOX_REINSTALL_AUTH_MODE` 仅接受 `password` / `key`，密码仍须 TTY 隐藏输入。
- 配置的是新系统 **root SSH 登录方式**，只配置所选模式。两次 `YES`、物理盘逐字确认、准备/状态/取消归属与不自动重启规则不变。

**只能在可丢弃测试机试用。** prepare 成功并非安装完成；真实擦盘由重启后的上游执行。已有失败/中断/未知计划不要盲目重启，先核实并按取消流程处理。loop 父设备未挂载但子分区已挂载的既有边界仍保留，此类布局不要准备重装。

## 实现与秘密保护

固定上游仍为 `54fae2067557b3c0ca49e7c9ce03bca63c793f8c`，原始 SHA-256 `3ca358bf065ebd3ecb2f727e152a4b4fb9b154398abc1b9a5fe0b599f1027d7a`，派生 SHA-256 `f51939ced0634c1a12f429e94a58e10c7b939b88ff4ea3ca9240f748b90be663`。

新增适配器专用、固定 Linux/root 的 `--toolbox-password-hash-file` 接口，只传受保护的 sibling 文件路径，跳过原上游明文 prompt、fallback hashing 和密码回显。安装、bootloader 和 runtime auth helper 主体仍由固定上游负责；没有改为自写安装器。

TTY 在提示发布前关 echo；EOF/信号恢复终端状态，收集前禁止继承 xtrace/debug hooks。密码经 stdin、空环境 OpenSSL SHA512 crypt，确认后经 FD3 独占写入 owned0600 私有文件。原生 libcrypt 验证完整输入；超过 256 字节拒绝，避免 OpenSSL 静默截断。

私有 plan、上游工作目录和最终 newc 都验证所选认证：错值、缺失、相反/额外配置、symlink/hardlink、owner/mode 异常拒绝。schema3 记录 auth_mode，旧 sealed schema1/2 默认 key，严格 status 首行不改。hash 允许存在私有文件和 initrd 中，请保护 boot/整盘备份；不声称内存零化，也不把抽样 argv/env 检查说成完整 syscall 追踪。

## 实际验证

- **父冻结定向 runner 13/13**：syntax、build、entry、dependencies、dependency-entrypoints、reinstall、reinstall-auth、Secure Boot、reboot-plan、menu、runner、deploy-cloudflare、Worker；原85检查、新20组认证。全部 exit0，无跳过/timeout/源码漂移/遗留子孙。不是全仓复跑。
- **独立安全复核3组/5个session与父原样复跑**：真实派生/隐藏输入/native crypt 正向与错误 sibling 拒绝；workspace0644、最终newc相反配置实际 prepare=1/failed；旧key/schema1/2、密码 prepared 错盘阻断 reboot、cancelled mock reboot 正向。无有界范围内阻塞项。两个私有审查 harness 错误已修正，未改产品；首轮未标记 scratch fixture 未能可靠定位，保留未批删，不称全部历史 scratch 清理。
- **三系统真实用户态21项 SSH 控制**：固定上游认证 helper 配合原生 chpasswd/sshd，正确密码/密钥通过、错误及key模式密码拒绝、拒绝后正向恢复通过。仅证明认证 helper，不等同于本候选磁盘写入/安装/initrd启动。
- **秘密扫描**：官方 checksum 核实的 Gitleaks 8.30.1，暂存6文件与实际提交扫描无泄漏；已知 CF/GH key exact-byte 无匹配，无私钥块。宿主包数据库/日志字节未变。发布文档扫描有一处 generic-api-key 提示，值经独立核对为公开认证测试文件的 SHA-256，而非凭据；保留该 digest 和原扫描结果，未放宽扫描规则。
- **GitHub**：checks/status均为空且无required gates，不称 CI 通过；作者同账号提交 COMMENT，不自 APPROVE。精确head合并，合并树/父提交/main已回读。
- **发布**：单次受限 full upload，完整四模块、settings/annotations、workers.dev、域名/DNS精确回读。14项公网原URL/随机参数/HEAD/404/405/跳转与9项下载syntax/help/list/退出/M3/预留/relay/DIAG/bash-s均通过，stderr空、系统TLS信任正常。欢迎页/router字节未变，不重复浏览器UI、不将旧结果当本轮验收。

## 未验与恢复

本候选未执行真实擦盘、完整重装、initrd启动或 UEFI/arm64/长期验收。首次交付公钥版的完整三目标KVM/BIOS擦盘记录仅为历史，不能当成本密码路径验收。仍保留已有应用/网络及PR #5/#4/#3/#2修复；没有升级已安装服务、操作用户机器或改业务配置。

私有证据根 `/root/.hermes/state/terry-toolbox-cf/m3-auth-20261101`：`final-focused/`、`native/`、`independent/`、`secret-scan/`、`merge-readback.json`、`public-readback/`。`deployment/` 保存旧版完整 Worker multipart/Content-Type、原配置/域名/公网及新候选；`preflight/` 额外保存 DNS。受限 adapter 绑定本候选 SHA，不能盲目重复、自动回滚或重新绑定。失败恢复先核对实时内容与原备份，按 [维护手册](../HANDOFF.md#workers-发布与失败恢复)验证精确目标，再受控恢复并回读；不能放宽配置门禁。

Terry's Hermes
