# 独立审查修复（2026-11-01）

对 `main`（`a9bbfe1`，即 PR #4 发布版）做全仓库独立审查后提交的修复分支 `review/fixes`（PR #5）。静态审查覆盖 `toolbox.sh`、全部 `modules/`、`scripts/`、`web/` 与 `tests/`；全部结论先对照源码核实，可实证的在专用测试机（Debian 11 / UEFI / util-linux 2.36.1 / KVM）实测。

## 修改

- **Xray pin 失效（线上功能性缺陷）**：上游 `XTLS/Xray-core` 已撤版 `v26.10.29`（v26.10.31 发布说明：因 Linux 内核 MPTCP 远程提权问题默认关闭 MPTCP，"v26.10.29 让位，已被撤版"）。GitHub 上该 tag 与资源均返回 404，A2 / A5 REALITY / A5 VMess+WS 安装会在下载阶段失败；已装 26.10.29 的机器在跑被撤回的构建。pin 升到 `v26.10.31`：amd64 `e4bd9119…`（测试机实际下载哈希一致），arm64 `1811c8f1…`（仅核对上游 `.dgst`）。同步更新 `vmess.sh` 的 URL 校验与预览文案、README、`tests/vmess-protocol-test.py` 的版本断言。
- **`toolbox.sh` 非 root 自动提权重下载允许明文 HTTP**：原为 `curl --proto '=https,http' sh.uw.cx`（无协议、允许 http），首跳明文后 `sudo bash` 执行；路径中间人可替换脚本取得 root。改为 `--proto '=https' --proto-redir '=https' https://sh.uw.cx`。
- **B23 恢复原状错误**：`net_dns_write` 只在 drop-in 已存在且无备份时备份；原机无 drop-in 时第二次切换会把本工具第一次写的文件备份为"原始配置"，恢复落在第一次切换的 DNS 而非原状。现在带本工具标记的文件不作为原始配置备份。
- **`net_port_owned_by` 忽略 proto/port**：原扫描全部监听 socket，只比对 PID / 可执行文件，任何端口的同名进程都算"本服务持有"；现按请求的协议与端口过滤（与 `hy2_port_owned_by` 同判据）。影响 A3 / A5 / B31 的安装回读与状态。
- **B31 归属与停止门禁**（PR #5 两轮审查后重做）：安装时在单元目录之外的 `/var/lib/terry-toolbox/relay/<proto>-<port>.ledger` 记录单元身份（dev:inode、大小、权限、属主、链接数、sha256），单元先写临时名、完整校验后用不覆盖的硬链接原子落位再写台账。**回滚只认本次 per-attempt claim**：`ln -T` 独占创建成功后才记录本次身份，回滚仅核对它；无 claim（ln 失败、落位前失败）则不 disable、不 reset-failed、不删任何既有资源，持久台账"像 ours"也不算数；拿锁后、写入前再复核单元仍不存在且端口未占用，等待确认期间被他人装好的同名单元直接拒绝且不触碰。卸载只对"台账逐字段一致"的单元动手：无台账、注释伪装标记、保留 Description 但改了 ExecStart、inode 被换、被硬链接的一律列为保留且**不执行停止**。**停止确认不再只看 ActiveState**：尝试过启动的单元要求 `disable --now` 返回 0，再一次性读取 `LoadState/ActiveState/SubState/MainPID/Job` 快照须为 inactive|failed + dead|failed + PID 0 + 无待处理 job，且该协议端口无任何监听，删除前再核一次归属；从未尝试启动的允许 not-found 或 inactive+dead+0+无 job。disable 非零、读回失败、超时、残留 job 或监听一律保留单元与台账并返回非零，卸载与回滚同一门禁。socat 被卸载或移动后仍按台账识别自己的单元（原缺陷）。文件内的任何标记都不再作为归属依据。
- **`apps.sh` 数据目录父级**（PR #5 审查后重做）：`sudo -E` 提权时 HOME 属原用户，原代码 `umask 077 mkdir -p` 会把缺失的 `~/.local`、`~/.local/share` 建成 root:root 0700 把用户锁在外面；首版修复用"检查不存在后 `install -d -o/-g/-m`"，在用户可写的 HOME 下存在被换入符号链接/目录导致既有 root 目标被改属主与权限的竞态。现在不做任何 chown/chmod：缺失祖先以 **HOME 属主身份**（`setpriv --reuid/--regid`；属主为 root 时直接 root）执行**非 `-p` 的 `mkdir -m`** 独占创建，内核保证"谁建的归谁"（用户 0755 / root 0700）；已存在的目录原样跳过，符号链接或非目录拒绝，mkdir 因竞态失败时已是目录就保留并继续、其余拒绝。用户对既有 root 0700 `.local` 无权限时直接拒绝不改动。`terry-toolbox/apps` 仍由 `umask 077` 建为 root 0700。
- **`deploy-cloudflare.py` token 校验**：`token.strip()` 仅作布尔判断，含 CR/LF 的 token 会让 requests 抛 `InvalidHeader`（`ValueError` 子类）并被顶层打印；改为字符集正则，拒绝即失败、不泄漏。
- **文档**：README / HANDOFF 的测试前置补上 PyYAML（`tests/hy2-test.sh` 依赖，此前未写）。

未改动但已记录的低级项（供后续处理）：`reinstall.sh:401` 未使用的 digest 列表（真实 pin 在 provenance）；prepare 早期失败后 `active/` 无 seal 需人工清理；B16 幂等重放在回滚记录文件缺失时仍返回 0；docker-ipv6 每次 validate 留下 `validate-*.json`；`tls-acme.sh` 一个不可达分支与一行死 stdin 读取；`webssh_status` 在 meta 缺失时返回 1；`net_xray_probe` 未使用的 `negative` 参数、`net_alpine_uninstall` 跳过 `$6`、`net_a5_etc_created` 死分支、`net_brutal_rollback` 无效条件；deploy 在线上已坏时无法发布修复（无 `--allow-broken-origin`）；`worker-test.mjs` 哈希自引用、`diagnostics-test.sh` 断言近似恒真。

已排除的疑点：浏览器访问根路径返回脚本（路由按 `Accept: text/html` 判定，真实浏览器得到欢迎页，正确）；A2 用 `dest`、A5 用 `target`（v26.10.31 实测两种写法均 `Configuration OK`）。

## 新增回归

- `tests/apps-test.sh`：普通用户 HOME 正向（`.local`、`.local/share` 归用户 0755，`terry-toolbox`、`apps` 为 root 0700）；既有 `.local` root 0711 与 `.local/share` 用户 0750 原样不变；用户无权限的既有 root 0700 `.local` 拒绝且不创建 `share`、不调用 docker；`.local` 预置为指向 root 目录的符号链接、`.local/share` 为符号链接两种均拒绝且目标不变；用 `mkdir` 垫片在模块检查之后、创建之前换入目录（保留并继续，属主/权限不变）与换入符号链接（拒绝，目标不变）。非 root 用户场景放在 `/tmp` 下 0711 的临时目录（scratch 根为 root 0700 不可穿越），trap 中清理。
- `tests/network-test.sh`：安装写台账、卸载后单元与台账同时消失；socat 缺失时仍按台账卸载自己的单元；仅注释带标记的外来单元不停止、不删除、inode/大小/mtime 不变；保留 Description 但改 ExecStart 的单元不停止、不删除，同名再安装被拒；注入停止失败（`disable --now` 返回 1、`ActiveState` 保持 active）保留单元与台账并返回非零，恢复后可正常卸载。第二轮新增：**两个完整 installer 真实 FIFO/flock 并发**（A 卡在二次确认、B 完整安装；A 继续后被拒，B 的单元 inode/大小/mtime、台账、active 与监听全部不变，A 未发出 disable/reset-failed；A 退出码经 `set +e` 子 shell 真实记录并断言非零）；**ln 失败**（锁内复核之后用 `ln` 垫片植入 B 的单元、与之匹配的持久台账与运行态；无 claim 的回滚不停止、不删除、不改动，无临时文件残留）；**脏 enable 失败**（留下监听与待处理 job 且 disable 非零：单元与台账保留、不 reset-failed，清除后可卸载）；卸载时 **disable 成功但残留 job**、**inactive 但端口仍有监听**、**状态读回失败**三种均保留并返回非零，清除后正常卸载；正常停止控制贯穿全部用例。mock `systemctl` 增加 `show -p LoadState,ActiveState,SubState,MainPID,Job --value` 快照（MainPID 仅 active 时有效）、`enable_fail_dirty`/`pending_job`/`listener_stays`/`show_fail`/`stop_fail` 注入，relay 单元 `disable --now` 成功时释放其端口监听；`assert_clean` 同时检查台账目录。

## 实际验证

- 测试机从源码重建单文件与已发布 `docs/index.html` 字节一致（`2f8f180f…`，705455 字节）；线上 CLI 根路径、`/toolbox.sh`、随机参数、wget UA、`/sha256` 均返回该哈希。
- 基线 `main` 全套默认回归：34 项中 33 项 PASS，唯一 FAIL 为 `hy2-test.sh` 因环境缺 PyYAML（非产品缺陷）。
- 首版分支（`d4c47e9`）全套回归 34/34 PASS（2592.7 秒）；`tests/vmess-protocol-test.py` 以 v26.10.31 官方二进制（zip `e4bd9119…`，可执行文件 `cc4b84d3…`）**8/8 PASS**：正确认证、错误 UUID / WS Host / WS 路径 / 不受信证书拒绝、拒绝后正向对照、重启后正向、默认私网目标阻断、清理。
- **审查修正后（源码 `4993524`）**：受影响套件直接运行 `apps-test.sh`、`network-test.sh`（含全部新增用例）通过；完整默认回归 **34/34 PASS，0 跳过、0 超时，源码前后哈希一致，子孙进程清理完成**，合计 2600.8 秒。
- **第二轮修正后（源码 `d728ecf`）**：`network-test.sh` 直接运行通过且输出中无任何被吞的 shell 错误（`No such file`/`command not found`/`unbound variable` 零命中）；完整默认回归 **34/34 PASS，0 跳过、0 超时，源码无漂移，子孙进程清理完成**，合计 2612.3 秒。
- 真实主机 M3 只读预检（系统 Python 3.9、util-linux 2.36.1、UEFI、mokutil 报不支持 Secure Boot）通过，走的正是 PR #3 / #4 修复路径。
- 发布物 `docs/index.html` 由 `scripts/release.sh` 在 Linux 自源码 `d728ecf` 重建：SHA-256 `a1984856c863c05139b6e2e3de8455c50719b6b43cc7fc3ff6a8422715fa5ffe`，715802 字节，`bash -n` 通过。

## 边界与状态

未在真实主机安装任何服务、未执行 M3 prepare / 擦盘 / 重启；测试机仅新增隔离的 Python 3.12 / Node 20 工具链目录与测试证据目录。arm64 Xray 哈希仅核对上游 `.dgst`，未在 arm64 机器运行。协议测试是回环私有 CA 验证，不等于 systemd 服务、公网或整机重启验收。B31 旧版（无台账）安装的单元在新版卸载时会被列为保留，需人工 `systemctl disable --now` 后删除，这是有意的 fail-closed。B31 并发与故障用例用真实 FIFO/flock/ln 加 mock systemd 复现，不是真实 systemd 的 job/监听注入；停止快照依赖 `systemctl show` 的字段语义。`apps.sh` 的竞态回归用垫片在用户态复现，不等于内核级并发注入。

**尚未发布**：待 Hermes 复审、合并并按 Workers 流程发布；发布后需更新 README 的"当前发布版本 SHA-256"与发布记录，并提醒已安装 Xray 26.10.29 的用户重装/升级。
