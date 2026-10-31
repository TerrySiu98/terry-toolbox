# 缺失依赖确认补装修复

> **2026-11-01 已上线。** PR #2 已合并，Worker 与公网已精确回读，见 [当前发布记录](release-20261101.md)。下方候选、回归及 VM 数据保留原始验收时间边界。

## 原因与行为

Hermes 已把 PR #1 及重装重启门禁补丁部署到 Cloudflare Workers。本次从 `sh.uw.cx` 读回的脚本 SHA-256 为 `e6b0641d725550245fe18c154321cd3e59e0ef199d63732ee60f5d3c157f6155`，与发布记录一致。其 M3 缺 `virt-what` 时只有拒绝逻辑，因此用户无法继续；主菜单“重装系统（开发中）”也是该版本留下的标签。

本候选基于 `58a5a7171432c6980f860795a13ff60a681504c2`，按功能收集缺失普通命令，列出发行版软件包后接受 `y`/`Y`/`yes`/`YES`，默认取消。Debian/Ubuntu 使用现有 APT 软件源，Alpine 使用现有 APK 软件源。安装成功后重新检查命令，再继续原操作；安装失败、取消、EOF、未换行确认或命令仍不可用都会停止依赖该工具的操作；DIAG 体检保留降级行为，拒绝补装后继续显示可读取的信息。包管理器的标准输入与菜单隔离，不能吞掉下一步的重装确认。

共享处理覆盖系统工具、网络服务、VMess/TLS、WebSSH、Docker 应用、IPv6、Alpine swap 和 M3；安装、卸载和已有安装的状态读取所需工具均纳入对应检查。B6 在创建目录/锁前补齐工具，B23 在读取配置归属前检查 `readlink` 等命令；缺普通工具不会再被解释为锁占用、CPU 不支持、证书不匹配或外部配置接管。B8 缺 `passwd` 使用 Debian/Ubuntu 的 `passwd` 包或 Alpine 现有仓库中的 `shadow` 包。缺 Docker 转入原 B1 安装流程并保留原有确认；B12 只尝试当前运行内核精确版本的 headers。缺下载/TLS 工具时一并检查发行版 CA 包，缺包才安装，不改用户 CA 路径覆盖。不会执行整机升级、替换现有 Python 版本或安装/转换 init、GRUB。缺包和系统能力不符分别报告。

M3 普通依赖只需一次确认，包括需要时的 EFI 检查工具。安装完毕仍须通过原磁盘/引导预检；真正准备重装仍要求两次 `YES`、公钥和精确磁盘确认。保留 Hermes 对失败、中断、未知计划的重启拒绝及 cancelled 引导状态回读。菜单移除旧“开发中”标签，功能的未验平台范围仍如实保留。

## 验证与候选

本修复起于 2026-10-31，补充验证跨至 2026-11-01（北京时间）。

产品源码与构建冻结提交：`f229d25ae66ba0929d3805f0d170ad294ac0ba38`；最终测试提交：`971d4f3f76eb1a9d36e0fb5a813030a8cc42715f`（只修正网络测试断言，产品源码和构建字节相同）；[PR #2](https://github.com/TerrySiu98/terry-toolbox/pull/2)。

单文件候选 SHA-256：`f1a84fed003b0fc344006a6a82ce63a2b42ce552ce9b4301c63ca3e321956777`（701519 字节）。由冻结源码在 Linux 构建，脚本与 Worker 的 `toolbox.txt` 字节一致。

真实安装验证直接使用冻结提交 `f229d25ae66ba0929d3805f0d170ad294ac0ba38`，在全新 Debian 13.7 / x86_64 / KVM / BIOS GRUB VM 上完成。原镜像缺 `virt-what`，输入 `n` 或 EOF 均未安装；输入一次 `y`，真实 APT 安装 `virt-what 1.27-1` 后，同次 `preflight alpine` 退出 0。原镜像已有 `cpio 2.15+dfsg-2`，缺失 `cpio` 的场景仅由离线模拟覆盖。

最终 M3 prepare 已到达原重装确认提示，`NO` 与 EOF 均在上游 prepare 前退出。引导文件、磁盘首 MiB、boot ID、原系统标记和无计划状态的四次快照逐字节相同；测试 VM 正常关闭后，独立回读确认无 QEMU 进程、guest SSH 监听或 pidfile，原基础镜像摘要不变。此轮不声明实际擦盘、安装完成或重启验证，既有三系统重装证据仍归属于历史版本。

Linux 最终回归合计 **33 项有效通过、0 跳过**，由四次冻结运行组成：`deps-quick-07` 取 11 项、`deps-network-08` 取 1 项、`deps-remaining-08` 取 20 项、`deps-syntax-08` 取 1 项。最终测试源码提交为 `971d4f3`；quick07 与其唯一差异是网络测试的七处 Bash 条件包装，所选 11 项及其调用源码未变，旧语法和失败网络结果未复用。每次运行前后源码无漂移，子进程清理完成，四份软件包数据库/日志的原始字节和哈希均不变。逐项命令、时间、日志摘要、选择依据及原始失败见[机器可读证据](dependency-fix-20261031.json)。

独立审查发现 B15 补包后过早主动启用 vnstat，最终修正为 Token/Chat 校验、业务双确认及归属复检全部通过后启用，增加 EOF、NO、冲突和事务失败的拒绝覆盖。发行版软件包本身的维护脚本仍遵循该系统的安装行为，不保证安装包没有服务启动副作用。

## 测试修正与失败记录

`deps-quick-07` 原始结果为 12/13 通过，网络套件因测试断言中的 `builtin command grep` 在 `set -e` 下提前退出；移除七处测试包装后，同一产品源码的完整网络套件通过。最终汇总保留这条失败及旧语法结果，只选取修正后的对应检查。更早 `deps-final-06` 的 33/33 属于 `8b1c98e`，因后续补齐依赖清单未用于最终计数；`deps-quick-05` 的 9 项同样仅作历史记录。

首轮全仓运行保留为 `deps-final-04`。Alpine swap 的 127 个场景均结束为 exit 0，但末尾将 `/proc/swaps` 的易变 Used 列也作原始字节比较，导致宿主状态总断言失败；旧测试未保存精确前后值，不能反推该次逐字段差异。修复后的测试保存前后原始证据，严格比较 swap 路径、Type、Size、Priority 和条目顺序，仅允许 Used 正常变化，系统配置文件仍逐字节比较。

网络 Alpine 反馈测试未隔离新增的依赖执行边界，旧 `YES` 输入被用于安装确认，导致可丢弃测试宿主真实安装 `gawk` 和 `libsigsegv2`。发现后停止 runner，确认子进程清理完成，保留 APT/dpkg 日志，并仅移除这两个本次新增包（未 autoremove）。该轮被中止的 M3 不计通过。随后补齐测试的包管理函数与 PATH 拒绝替身，并为后续运行保存软件包数据库、APT/dpkg 历史日志的前后哈希；原失败记录不覆盖。

## 试用固定候选

以下固定候选已完成上述回归与原生补装验证，HTTPS 下载也已回读核对。

下方命令下载 PR #2 的固定提交，校验后运行同一文件。HTTPS 证书验证及公开下载回读已通过，701519 字节和 15 个内嵌模块逐字节匹配冻结提交。此命令适用于 Linux；非 root 用户按脚本提示通过 sudo 运行同一文件，避免流式入口提权时重新下载线上旧版。

```bash
candidate=$(mktemp /tmp/terry-toolbox-candidate.XXXXXX) &&
curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL \
  --connect-timeout 15 --max-time 120 \
  'https://raw.githubusercontent.com/TerrySiu98/terry-toolbox/f229d25ae66ba0929d3805f0d170ad294ac0ba38/docs/index.html' \
  -o "$candidate" &&
printf '%s  %s\n' \
  'f1a84fed003b0fc344006a6a82ce63a2b42ce552ce9b4301c63ca3e321956777' \
  "$candidate" | sha256sum -c - &&
bash "$candidate"
```

`bash <(curl -fsSL sh.uw.cx)` 现已读取包含此次修复的发布版本，线上哈希与上述固定候选一致。

## 发布与维护

本候选已于 2026-11-01 部署并完成精确回读。继续使用 Cloudflare Workers 承载 `sh.uw.cx`，GitHub 保存源码和版本；不涉及 DNS 或托管迁移。

发布前按 [HANDOFF.md](../HANDOFF.md#workers-发布与失败恢复) 保存生产快照，并处理 [Hermes 发布记录](release-20261031.md#线上回读与实际发布异常) 中 `/content` 清除版本 annotations 的已知限制。上传成功不等于发布完成，必须精确回读 Worker 内容、既有配置、域名绑定和公网脚本/哈希。更新公开线上哈希之前，不得把候选测试结果写成线上已修复。
