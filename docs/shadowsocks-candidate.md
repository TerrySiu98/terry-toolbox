# A6 / A7 Shadowsocks — 未发布候选

此变更位于 `feature/shadowsocks` 工作区，尚未提交、推送或发布。当前 `sh.uw.cx` 仍为 README 顶部记录的 PR #12 版本。

## 分开入口，共用单文件

- `A6`：Alpine + 已运行的 OpenRC。
- `A7`：Debian + 已运行的 systemd。Ubuntu 和其他发行版目前不接受，不能把主菜单可进入等同为 SS 支持。
- 两项各有安装、卸载、状态管理；原 A1–A5 编号不变。源码、按需加载、构建器和单文件包含同一 `shadowsocks` 模块。

## 使用方法与影响

完成发布后，运行既有统一入口，进入网络服务的 `6` 或 `7`（或直接输入 A6/A7），再选择 `1 安装`。输入本服务器 IPv4 或解析至 IPv4 的域名和 TCP/UDP 端口，默认 `8388`；两次完整的 `YES` 才写入。

使用固定 SHA-256 校验的 Xray 26.10.31，单用户 `chacha20-ietf-poly1305`、TCP + 原生 UDP，无 TLS 证书、插件或 REALITY 回落。该组合用于客户端兼容，上游已标为弃用且没有前向保密；不保证比 HY2 或 VLESS 更快。

- 仅 IPv4 监听；当前拒绝 IPv6 字面入口。amd64/arm64 有固定上游产物校验值，实际运行仅验证 x86_64。
- 新建专用 `/etc/terry-toolbox-shadowsocks`（0700）、`/usr/local/bin/terry-toolbox-shadowsocks` 与独立 systemd unit/OpenRC init。
- 端口同时检查 TCP 和 UDP，占用或状态未知则拒绝，不接管已有安装。不改防火墙、安全组、DNS 或其他 HY2/Xray 服务。
- 安装会启动独立服务，但默认不设置开机自启。请自行在服务器防火墙和云安全组放行所选 TCP/UDP 端口。
- 成功安装后，仅 stdin/stdout 都是终端时显示随机密码，并提前说明屏幕/日志风险；非交互、重定向不显示。分享链接和导出文件本身就是凭据，请勿公开。
- 导出为 `0600` 的 `shadowsocks.txt`（SIP002 URI）、`mihomo.yaml`（代理条目）与 `client.json`（Xray 客户端）。Mihomo 条目仍需加入现有配置的代理组和规则；本地验证不等于所有手机 App 可导入。
- 状态只读；卸载仅删除精确归属资源。文件改动、未知依赖、停止失败或监听未消失时保留现场。默认运行期锁与临时私有目录不属于现有节点配置。

源码接口：

```bash
# 正常使用菜单；以下接口需先按 toolbox.sh 的顺序加载模块。
toolbox_network A6 install example.com 8388
toolbox_network A7 status
toolbox_network A7 uninstall
# 额外源码动作：仅交互终端查看已有密码，不重设。
toolbox_shadowsocks systemd show
```

## 证据边界

作者已在独立 Alpine 3.24.4 与 Debian 13 / x86_64 / KVM guest 运行安装、状态、服务重启、卸载，以及 Mihomo TCP/UDP 正向、错误密码拒绝和随后正向控制；端口占用、取消、未知资源保留、停止失败与 PTY 密码显示也有原生命令输出。最终作者模块 SHA-256 `359e66ceb2032fd0b51f84b5cba439de42a906bd36907a4cd306e6053c4e3e7f`。该记录是作者原生证据，尚未整理成独立完整证据包；父级不会用自报代替精确候选的复核。

父级已在修复版模块上完成 Alpine 3.24.4/OpenRC 与 Debian 13.7/systemd 的 KVM 重验：安装、状态、服务重启、卸载，Xray/Mihomo 实际导出对应的 TCP/UDP nonce 正向、错误密码零目标命中及随后正向控制均通过。清理 EXIT trap 转换边界实际注入 TERM 时，取消保留退出码 1、卸载保留退出码 0，均释放全局锁；两台 guest 已停止、服务及本轮代理进程已卸载。最新模块 SHA-256 `a3d2c9ff2cb1fdbb2fc0895af4303086405e82c935291d1596831a9f6b0832dd`。

此前 11 项相关回归通过；此次清理补丁新增确定性 RED 后，修复版 5 项受影响回归（syntax、build、SS 安全回归、配置/端口、A6/A7 dispatch）全部通过，runner 无漂移、无残留后代。此前基线 `network-alpine-feedback-test.sh` 失败不改写为通过。新的单文件构建及全部 16 个模块字节比对通过，重建一致。

独立复核已确认旧两项锁登记和同 inode 残留进程修复有效；其后发现的清理 trap 顺序窗口已修复并完成上述受影响验证，最终有界补丁独立复审已 approve，确认此前 TERM 永久锁阻塞关闭。范围内 4 项验证通过；独立完整 review runner 在新增回归 PASS 后于 90 秒超时，保留记录、不计入完整通过。父级相同修复源码的 5 项受影响 runner 已完整通过。原始失败证据保留，不用旧候选审批覆盖新字节。

未提交、推送或发布。未验证公网入站、用户手机、YouTube 性能、整机开机自启、arm64、Ubuntu、IPv6 或完整竞态/信号矩阵；SS 不能据此保证提速。
