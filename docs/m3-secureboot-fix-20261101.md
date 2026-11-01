# M3 Secure Boot 未提供变量兼容修复（2026-11-01）

## 问题与处理

M3 → 重装预检 → Alpine 在 `mokutil --sb-state` 返回 `This system doesn't support Secure Boot` 后报告“Secure Boot 状态未知”。真实测试宿主的 mokutil 0.6.0 返回 255；固定 efivarfs 正常挂载，BootCurrent/BootOrder 可读，SecureBoot 和 SetupMode 均精确 ENOENT。

mokutil 0.3.0/0.6.0 在读取 SecureBoot 的任意错误时都可能输出这句“不支持”，所以候选不单凭消息放行。明确成功且 disabled 的输出继续通过；非零返回仅对两种官方拼写及 exit 255 进入额外只读核对：固定 efivarfs 已挂载、目录及变量不是 symlink、全局 BootCurrent/BootOrder 的访问属性、长度与顺序一致、SecureBoot 和 SetupMode 都仅为 ENOENT。权限/I/O 错误、已存在变量、异常数据、其他退出码和未知/已开启状态继续拒绝。mokutil 的 libefivar 路径/backend 环境覆盖已清除。

兼容通过时显示“UEFI（可读固件变量未提供 Secure Boot）”，不会将这种情况写成 disabled。不会安装、挂载 efivarfs，也不更改 Secure Boot、ESP、EFI entries 或 BootOrder；其余磁盘、公钥、双重确认、取消及重启保护保持原流程。

参考官方源码：[mokutil 0.3.0](https://github.com/lcp/mokutil/blob/0.3.0/src/mokutil.c)、[mokutil 0.6.0](https://github.com/lcp/mokutil/blob/0.6.0/src/mokutil.c) 的 main 中 SecureBoot 预读取，以及 sb_state 的 enabled/disabled 处理。上游重装版本/digest/派生内容均未改变。

## 候选与发布边界

基线为 `972c7d0f7a0108f34ef4c415ad9dafde292ec578`，已包含 Hermes 合并并发布的 PR #3 lsblk 修复。新候选分支为 `codex/m3-secureboot-compat`，源码与构建冻结提交 `d5368c9be802531a0b493165af3c7c4d8aeb0c4c`。候选 SHA-256：`02582cdfc6dd42bb14a5710217e8623ea31fc1f93b14db1edf6888b9103d47e6`，705208 字节；15 个内嵌模块与源模块逐字节一致。

**本次尚未合并、未部署。** 线上只读回查仍为 `042bffafc28c9e47c5fddf485a4c60ac7e0d14cae39ae18f677cbea293f40da4`，702279 字节，见[当前 PR #3 发布记录](release-pr3-20261101.md)。Hermes 合并并按[Workers 流程](../HANDOFF.md#workers-发布与失败恢复)备份、上传和完整回读后，原命令才会包含本次修复。托管和域名保持 Cloudflare Workers，GitHub 保存源码。

## 验证范围

最终冻结源 `m3-secure-02` 运行 syntax、build、entry、reinstall、system-reboot-plan、menu、Worker 七项相关检查全部通过；重装套件 85 项模拟边界检查通过，233.76 秒；源码无漂移、子进程清理完成，软件包数据库/日志字节未变。原始运行索引见[机器可读记录](m3-secureboot-fix-20261101.json)。新增模拟覆盖两种官方 unsupported 拼写、后端环境清除、可读变量精确缺失、enabled/shim/矛盾文本拒绝、未挂载或错误 efivarfs、变量/目录 symlink、长度/属性/BootOrder 异常、SecureBoot/SetupMode 存在冲突、EACCES/EIO 和错误退出码拒绝，以及 NO 确认不触发上游/plan 写入。

真实测试宿主 `m3-secure-native-03`：原始 mokutil exit 255；生产 Secure Boot helper exit 0、分类 unsupported；生产完整 Alpine preflight exit 0、stderr 为空。关闭 stdin 并额外拒绝包管理及破坏性命令，包数据库和日志哈希保持相同。仅只读预检，没有执行 prepare、修改引导、擦盘、挂载、重启或新系统启动。本次不能作为 UEFI 实际重装验收；此前 BIOS 三目标范围见维护手册。

早期 `m3-secure-01` 为最终追加 SetupMode/错误注入测试前的冻结源，单独保存，不混计最终结果。原生 `m3-secure-native-02` 收集后，harness 用 check_output 读取 mokutil --version，被该版本即使打印版本也 exit 255 的行为中断；改为记录 stdout 和退出状态后重跑 `m3-secure-native-03`。产品代码未因此修改，早期证据保留。原始磁盘/EFI 身份、包快照和日志不入库；公开 JSON 只保存摘要和校验值。

当前发布记录还列有 loop 父节点未挂载而子分区挂载的既有边界，本次不更改该逻辑；不要把本次检查概括为全部磁盘拓扑支持。
