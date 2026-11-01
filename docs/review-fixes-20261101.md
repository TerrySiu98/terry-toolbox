# 独立审查修复（2026-11-01）

对 `main`（`a9bbfe1`，即 PR #4 发布版）做全仓库独立审查后提交的修复分支 `review/fixes`。静态审查覆盖 `toolbox.sh`、全部 `modules/`、`scripts/`、`web/` 与 `tests/`；全部结论先对照源码核实，可实证的在专用测试机（Debian 11 / UEFI / util-linux 2.36.1 / KVM）实测。

## 修改

- **Xray pin 失效（线上功能性缺陷）**：上游 `XTLS/Xray-core` 已撤版 `v26.10.29`（v26.10.31 发布说明：因 Linux 内核 MPTCP 远程提权问题默认关闭 MPTCP，"v26.10.29 让位，已被撤版"）。GitHub 上该 tag 与资源均返回 404，A2 / A5 REALITY / A5 VMess+WS 安装会在下载阶段失败；已装 26.10.29 的机器在跑被撤回的构建。pin 升到 `v26.10.31`：amd64 `e4bd9119…`（测试机实际下载哈希一致），arm64 `1811c8f1…`（仅核对上游 `.dgst`）。同步更新 `vmess.sh` 的 URL 校验与预览文案、README、`tests/vmess-protocol-test.py` 的版本断言。
- **`toolbox.sh` 非 root 自动提权重下载允许明文 HTTP**：原为 `curl --proto '=https,http' sh.uw.cx`（无协议、允许 http），首跳明文后 `sudo bash` 执行；路径中间人可替换脚本取得 root。改为 `--proto '=https' --proto-redir '=https' https://sh.uw.cx`。
- **B23 恢复原状错误**：`net_dns_write` 只在 drop-in 已存在且无备份时备份；原机无 drop-in 时第二次切换会把本工具第一次写的文件备份为"原始配置"，恢复落在第一次切换的 DNS 而非原状。现在带本工具标记的文件不作为原始配置备份。
- **`net_port_owned_by` 忽略 proto/port**：原扫描全部监听 socket，只比对 PID / 可执行文件，任何端口的同名进程都算"本服务持有"；现按请求的协议与端口过滤（与 `hy2_port_owned_by` 同判据）。影响 A3 / A5 / B31 的安装回读与状态。
- **B31 卸载按当前 socat 路径判归属**：socat 被卸载或移动后自己的单元会被判成"他人单元"保留；现按单元内固定的 `Description=Terry Toolbox relay ` 标记识别。
- **`apps.sh` 在 `sudo -E` 下创建 root:root 0700 的 `~/.local`**：数据根目录沿用原用户 `$HOME`，`umask 077 mkdir -p` 会把缺失的 `~/.local`、`~/.local/share` 建成 root 0700，用户被挡在自己的目录外。现只补建缺失祖先，归属跟随已存在的父目录（用户家目录归用户、`/root` 归 root），模式 0755；`terry-toolbox/apps` 仍为 root 0700。
- **`deploy-cloudflare.py` token 校验**：`token.strip()` 仅作布尔判断，含 CR/LF 的 token 会让 requests 抛 `InvalidHeader`（`ValueError` 子类）并被顶层打印；改为字符集正则，拒绝即失败、不泄漏。
- **文档**：README / HANDOFF 的测试前置补上 PyYAML（`tests/hy2-test.sh` 依赖，此前未写）。

未改动但已记录的低级项（供后续处理）：`reinstall.sh:401` 未使用的 digest 列表（真实 pin 在 provenance）；prepare 早期失败后 `active/` 无 seal 需人工清理；B16 幂等重放在回滚记录文件缺失时仍返回 0；docker-ipv6 每次 validate 留下 `validate-*.json`；`tls-acme.sh` 一个不可达分支与一行死 stdin 读取；`webssh_status` 在 meta 缺失时返回 1；`net_xray_probe` 未使用的 `negative` 参数、`net_alpine_uninstall` 跳过 `$6`、`net_a5_etc_created` 死分支、`net_brutal_rollback` 无效条件、relay 单元用 `cat >` 覆盖写；deploy 在线上已坏时无法发布修复（无 `--allow-broken-origin`）；`worker-test.mjs` 哈希自引用、`diagnostics-test.sh` 断言近似恒真。

已排除的疑点：浏览器访问根路径返回脚本（路由按 `Accept: text/html` 判定，真实浏览器得到欢迎页，正确）；A2 用 `dest`、A5 用 `target`（v26.10.31 实测两种写法均 `Configuration OK`）。

## 实际验证

- 测试机从源码重建单文件与已发布 `docs/index.html` 字节一致（`2f8f180f…`，705455 字节）；线上 CLI 根路径、`/toolbox.sh`、随机参数、wget UA、`/sha256` 均返回该哈希。
- 基线 `main` 全套默认回归：34 项中 33 项 PASS，唯一 FAIL 为 `hy2-test.sh` 因环境缺 PyYAML（非产品缺陷）。
- 本分支（`d4c47e9` 源码）全套默认回归 **34/34 PASS，0 跳过、0 超时，源码前后哈希一致，子孙进程清理完成**，合计 2592.7 秒；含 apps、network、network-alpine、hy2（装 PyYAML 后转绿）、reinstall、secureboot、system、tls-acme、vmess、webssh 全部套件与 6 项 Python、Worker 测试。
- `tests/vmess-protocol-test.py` 以 v26.10.31 官方二进制（zip 哈希 `e4bd9119…`，可执行文件 `cc4b84d3…`）运行 **8/8 PASS**：正确认证、错误 UUID / WS Host / WS 路径 / 不受信证书拒绝、拒绝后正向对照、重启后正向、默认私网目标阻断、清理。
- 真实主机 M3 只读预检（系统 Python 3.9、util-linux 2.36.1、UEFI、mokutil 报不支持 Secure Boot）通过，走的正是 PR #3 / #4 修复路径。
- 新发布物 `docs/index.html` 由 `scripts/release.sh` 在 Linux 重建：SHA-256 `c9ce5526355f67772df41b6c63aab600fdfd00e156e1030792663e07540536ad`，707564 字节，`bash -n` 通过。

## 边界与状态

未在真实主机安装任何服务、未执行 M3 prepare / 擦盘 / 重启；测试机仅新增隔离的 Python 3.12 / Node 20 工具链目录与测试证据目录。arm64 Xray 哈希仅核对上游 `.dgst`，未在 arm64 机器运行。协议测试是回环私有 CA 验证，不等于 systemd 服务、公网或整机重启验收。`apps.sh` 的父目录归属修复经本地逐级模拟验证，`sudo -E` 真实用户场景未在测试机复现（测试机无非 root 用户）。

**尚未发布**：本分支待 Hermes 合并并按 Workers 流程发布；发布后需更新 README 的"当前发布版本 SHA-256"与发布记录，并提醒已安装 Xray 26.10.29 的用户重装/升级。
