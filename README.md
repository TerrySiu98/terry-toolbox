<div align="center">

# Terry Toolbox

**Linux 服务器工具箱**

系统管理 · 网络服务 · 常用应用

[使用方法](#使用方法) · [功能列表](#功能列表) · [安全提示](#安全提示) · [开发与测试](#开发与测试)

</div>

---

> **开发预览，尚非稳定版。** 源码与单文件脚本已公开。下方功能表同时列出已实测、待真机验收及计划项目，不能视为全部完成；首次使用请选测试机。

> **2026-11-01 当前已发布到 `sh.uw.cx`：** PR #3 的旧版 lsblk 兼容修复已上线，包含 PR #2 的缺失依赖确认补装。M3 重装与重启门禁保持原样；Worker 内容、原配置、域名/DNS 和公网下载已精确回读。见[当前发布记录](docs/release-pr3-20261101.md)、[维护手册](HANDOFF.md)和[历史验收索引](docs/acceptance-20261031.json)。仍是开发预览。

> **M3 旧版 lsblk 兼容修复已上线：** 使用 `MOUNTPOINT` 并归一字段，避免旧版 util-linux 不支持 `MOUNTPOINTS` 的采集报错。相关回归及公网发布通过；作者原生只读验证与本轮边界见[修复记录](docs/m3-lsblk-fix-20261101.md)。现有 loop 父设备未挂载但子分区已挂载的过滤边界仍保留，此类布局不要执行 M3 prepare。

> **依赖补装修复已上线：** 缺普通工具时列出命令与发行版包，按 `y` 确认补装并回读后继续当前操作；M3 菜单移除旧“开发中”标签，原重装确认不变。范围、原始失败和限定复验记录见[本次修复记录](docs/dependency-fix-20261031.md)。

## 简介

Terry Toolbox 是一个面向 Linux 服务器的中文菜单工具箱。登录服务器后运行脚本，输入编号就能进入相应功能。

启动时检查基础工具，进入具体功能时继续检查该功能的依赖。缺普通工具会列出缺少的命令和对应软件包，按 `y` 确认补装，成功并回读后继续当前操作；直接回车、`n` 或输入结束会取消。依赖齐全时不重复询问，不执行系统全量升级。涉及安装服务、修改系统或重启的操作仍会显示内容并单独确认。体检拒绝补装后继续显示可读取的信息。B18 暂时保留，以后再补。

## 开发进度

- **当前源码**：VMess 生命周期、自启与换证；Certbot HTTP-01、续期与 VMess 同步；Docker 默认 bridge IPv6；WebSSH 个人版/Easynode；Debian 13、Ubuntu 24.04、Alpine 3.24 重装准备与取消均已接入菜单。B18 保留。
- **首次交付原生验收**：Debian 13.7 / x86_64 / KVM 已通过 B1 安装 Docker Engine 29.9.2，以及 IPv6 应用配置、双容器 ULA nonce 传输、整机重启后同一容器再传输、恢复到原先不存在 `daemon.json` 的状态。WebSSH 个人版和 Easynode 已完成真实正反登录、SSH/SFTP、容器重启持久化与卸载保留数据。Debian 13、Ubuntu 24.04、Alpine 3.24 已分别完成全新磁盘实际重装、公钥 SSH 与旧系统清除核对。VMess 已通过两次整机重启；真实 ACME 定时续期已恢复过期证书并同步 VMess；原 Python WebSSH 已通过认证、真实 SSH、服务重启和卸载。完整范围见维护手册；这些历史记录不能代替当前依赖补装改动的复验。
- **历史证据**：Alpine swap 模块的历史版本曾在 Alpine 3.24.2 / KVM 通过实际换页、服务重启、整机自启和卸载。部分原有应用与网络服务有真实运行记录；这些记录不能替代本次修改后的验收。
- **本次依赖修复回归**：33 项有效通过、0 跳过，按源码哈希合并四次冻结运行，全部完成进程清理且包数据库/日志字节未变；全新 VM 验证一次 `y` 补装 `virt-what` 后同次 Alpine 预检成功。详见[本次修复记录](docs/dependency-fix-20261031.md)。
- **首次交付自动化回归**：30 项取得有效通过、0 跳过：完整冻结运行的 16 项未变依赖结果，加最终源码的 14 项受影响补跑。覆盖特权边界模拟、真实 PTY、离线 APT 来源、单文件构建和 Worker 路由；源码哈希、原始失败/超时及合并依据见[验收索引](docs/acceptance-20261031.json)。真实 VM 生命周期另行记录。

B1 既有 `daemon.json` 的字节与权限恢复目前由模拟覆盖，未作公网 IPv6 或其他系统/架构的原生验收声明。B10 个人版/Easynode 通过回环 HTTP API 验证；浏览器界面、MFA、RDP、公网 TLS/反代、整机重启与 arm64 尚未验收。

## 使用方法

### 一键入口

```bash
bash <(curl -fsSL sh.uw.cx)
```

非 root 用户需要已有 `sudo` 及相应权限；脚本会通过它提权。没有 curl 时，先用 wget 保存为文件再运行：

```bash
toolbox_file=$(mktemp /tmp/terry-toolbox.XXXXXX) &&
wget -qO "$toolbox_file" https://sh.uw.cx/ &&
bash "$toolbox_file"
```

`bash <(...)` 保留菜单输入；不要改成 `curl | bash`。非 root 的流式入口提权时会重新下载线上脚本，试用未发布候选请用上方链接中的固定文件下载命令。

想先看代码再跑：

```bash
curl -fsSL sh.uw.cx -o toolbox.sh
less toolbox.sh
bash toolbox.sh
```

也可以先核对哈希：

```bash
curl -fsSL sh.uw.cx | sha256sum
```

先与 `https://sh.uw.cx/sha256` 及[当前发布记录](docs/release-pr3-20261101.md)核对。当前线上脚本绑定发布源码 `37b0ebb365ebcd8f43873238368b9a7e1cf3cd33` 的 `docs/index.html`；后续文档提交不改变该脚本。**当前发布版本的 SHA-256**：`042bffafc28c9e47c5fddf485a4c60ac7e0d14cae39ae18f677cbea293f40da4`（2026-11-01 PR #3 发布）。

服务端下载的是单文件版本，全部模块已经打包进去，不需要准备其他文件。Debian / Ubuntu 为当前主要支持环境，Alpine 仅部分功能。

网站与脚本由 **Cloudflare Workers** 托管，HTTPS 证书由 Cloudflare 提供；GitHub 用于保存源码。
- 浏览器访问 [https://sh.uw.cx](https://sh.uw.cx)：欢迎页、复制命令、下载入口。
- curl / wget 访问相同地址：返回脚本，保留短命令。HTTP 会重定向到 HTTPS；希望首个请求也加密，可写 `bash <(curl -fsSL https://sh.uw.cx)`。
- 明确下载脚本：[https://sh.uw.cx/toolbox.sh](https://sh.uw.cx/toolbox.sh)，不依赖请求头；校验值：[https://sh.uw.cx/sha256](https://sh.uw.cx/sha256)。

### 启动与菜单

启动时先识别系统与架构，只缺依赖时才提示安装（`Y`/`y` 确认，其他键跳过；只补齐缺失项，安装后重新检查命令，不升级系统）。Alpine 的 `ss` 对应 `iproute2-ss`。功能操作的 `YES` 确认不区分大小写，空输入与 EOF 仍取消。不支持的系统仍可进菜单，由各功能自行检查。

主菜单只有一屏；输入编号回车即可：

- `1` 网络服务：Alpine HY2/Xray、TUIC、HY2、Xray
- `2` 安装 BBR，`3` 安装基础依赖，`4` 重装系统（目标选择、预检、准备、状态与取消），`5` 常用工具（Docker、应用、体检以外的系统项）
- `DIAG` 体检（检查只读，缺工具时可确认补装），`99` 重启，`0` 退出

进入子菜单后 `0` 返回上一层；功能管理页返回所属分类，分类页返回主菜单，只有主菜单 `0` 才退出。操作结束后按回车留在当前功能页，单纯返回不再额外暂停。`A4`、`B9` 这类完整编号在任何界面都能直接输入。安装类功能需要 root，执行前会显示影响并要求确认。

真实终端切页会清除当前画面再重绘，不清除历史滚动记录；重定向到日志时不发送清屏控制符。需要保留每次画面时可设置 `TOOLBOX_NO_CLEAR=1`。

网络服务、WebSSH、TCP Brutal、网络优化、Alpine 工具、DNS 与 Relay 通过功能管理页选择动作，不会选中编号就直接安装。网络服务安装会询问已有证书、私钥路径及证书域名。`TLS` 管理页在 Certbot 缺失时可确认补装，再申请证书，续期任务及 VMess 同步分别授权。输入结束或取消不会视为安装成功。

### A5：VMess + WebSocket + TLS（开发预览）

**已包含在 `sh.uw.cx` 当前开发预览。** 运行脚本后输入 `A5`：`1/2/3` 仍是 REALITY，`4` 安装 VMess + WS，`5` 卸载，`6` 查看状态，`7/8/9` 启用、禁用和查看开机自启，`10` 受控换证。两种协议使用独立服务和目录，但默认都用 TCP 443，不能占用同一端口。

- 仅支持 **Debian + systemd、amd64/arm64**；arm64 有固定官方校验值，尚未实际运行验收。需先备好可信的完整 PEM 证书链、无口令 PEM 私钥和证书覆盖的域名；证书路径不接受空白或特殊字符。当前源码候选缺少普通依赖时按 `y` 确认补装；发行版、Python 版本或 init 不满足要求时给出具体原因。
- 新建 `/etc/terry-toolbox-vmess`、`/usr/local/bin/terry-toolbox-vmess`、`terry-toolbox-vmess.service`，固定 Xray 26.10.29；两次输入 `YES` 后才安装。默认 IPv4 `0.0.0.0:443`，可选端口与 WS 路径。不改 REALITY、DNS、防火墙或 ACME，也不设开机自启。
- 随机 UUID 不回显。Xray 客户端配置保存在 `client.json`，导入链接保存在 `vmess.txt`，均为 `0600`；请通过自己的安全渠道取用。客户端本地 SOCKS 为 `127.0.0.1:1080`。
- 状态会核对资源清单、systemd、指定 TCP 端口及实际可执行文件、证书和 WS 握手；安装自检**不是认证数据面或公网可达证明**。测试脚本另外验证正确/错误认证、路径/Host/信任拒绝、进程重启及默认私网阻断。
- 不覆盖既有资源。停止失败、pending job、未知状态或内容/inode 改动时保留文件并报错；不要手工改配置或换证书后期待自动卸载仍接管。使用管理页启用/禁用自启或更新证书；换证保持 UUID、客户端配置与自启策略，失败时只有确认归属和停止状态后才恢复旧证书。不要删除归属清单强行重装。
- **旧客户端兼容功能，不建议新部署优先选用。** 固定版上游已将 VMess（无前向保密）和 WS（特征明显）标为弃用。VMess 依赖准确系统时间；客户端与服务端需正常校时。保留 Xray 默认的私网目的地址阻断，不为测试放开内网。

### B19：Alpine swap（开发预览）

**已包含在 `sh.uw.cx` 当前开发预览。** 运行脚本后输入 `B19`：`1/2/3` 保留 Webtop 与 UDP 端口跳跃，`4` 安装 swap，`5` 卸载，`6` 只读查看状态。

- 仅支持 **Alpine + 已启动的 OpenRC + 可写持久 ext4**。拒绝 overlay、tmpfs、btrfs、NFS 等文件系统；输入 `128..8192` MiB 十进制整数，建议 `1024`，空白取消。完整分配文件，预留额外 16 MiB 可用空间。输入的是文件大小，内核实际可用容量会扣除头部及物理 extent 页对齐损耗。
- 使用 `bash`、`python3`、`cat`、`flock`、`dd`、`mkswap`、`swapon`、`swapoff`、`rc-service`、`openrc-run`；当前源码候选缺少普通命令时按 `y` 确认补装并回读。仍要求本机已经运行 OpenRC，不会安装或切换 init 来绕过平台检查。
- 两次输入 `YES` 后新建 `/var/lib/terry-toolbox-alpine-swap`（`0700`），内含 swapfile（`0600`）、JSON manifest、runtime.py 和运行锁；创建 `/etc/init.d/terry-toolbox-alpine-swap`，真实启用并验证内核记录后添加 `default` 自启链接。**不改 `/etc/fstab`、sysctl、B6 或其他 swap。**
- 只接管本次创建的资源。状态、启动和停止均校验文件/目录归属、脚本内容及 swap 的 UUID/固定头部；不会把可被内核写入的数据页固定为全文件哈希。未知文件、被换 inode、配置被改、同名服务/自启或 `conf.d` 冲突都拒绝。
- 安装失败仅在安全门禁允许时回滚；卸载必须停止成功、OpenRC 明确 `stopped` 且内核不再使用目标文件。停止失败、内存不足、未知/过渡状态或归属变化会**保留现场并报错**，不会强删。退役标记防止卸载期间重新启动；`/run/terry-toolbox-alpine-swap.lock` 故意保留，避免删锁导致并发分裂。
- **历史验证边界：** 首次交付所引用的旧版源码已在独立 Alpine 3.24.2 x86_64 / KVM（kernel 6.18.52）通过菜单安装、32 MiB 实际换页与读回、服务重启、整机重启后自启、未知文件保留和菜单卸载；`fstab`、sysctl、原 swap 表及宿主 swap 保持不变。首部保持不变，数据页实际变化。arm64、其他内核/文件系统、长期负载及真实停止失败后的恢复尚未验收。历史 swap 模拟套件 127 项通过；旧整仓计数不表示本次修改后的全仓结果。
- 不提供在线扩容、接管手工 swap 或自动修复。不要手工改清单后强制卸载。该功能与 VMess 已包含在当前线上开发预览；上述未验边界保持不变。

## 功能列表

状态说明：**已实测**表示在列明环境完成过真实运行验收；**开发中**表示已有实现但整体仍处于开发预览阶段，部分流程可以已有实测证据，具体范围以各行及维护手册为准；**计划**表示还未实现或暂不启用；**预留**表示尚未安排功能。

### 系统工具

| 编号 | 功能 | 状态与说明 |
| --- | --- | --- |
| `DIAG` | 服务器体检 | 只读查看系统、运行时间、内存、磁盘、网络和监听端口；缺工具时可确认补装，拒绝后继续显示已有信息 |
| `M1` | BBR | 开发中：调整当前运行期拥塞控制，重启后可能失效 |
| `M2` | 基础依赖 | 开发中：按缺失命令补包并回读；Alpine 3.24 真实 APK 隔离验证通过，其他系统待当前版本实测 |
| `M3` | 重装系统 | 已实现 preflight/prepare/status/cancel；选择 Debian 13、Ubuntu 24.04 或 Alpine 3.24，提供 SSH 公钥并确认整盘目标；prepare 不自动重启；首次交付版本的三目标均通过 x86_64/KVM/BIOS 实际擦盘重装、公钥登录和持久根分区验收；本次在全新 VM 原生复验依赖补装、Alpine 预检，以及 prepare 确认处 NO/EOF 退出，UEFI/arm64 尚未实测 |
| `M4` | 重启服务器 | 开发中：双确认后重启；M3 失败／中断／未知状态拒绝，prepared 另需目标磁盘确认，取消后的引导状态及确认期间状态变化会再次回读 |
| `B1` | Docker | 开发中：Debian/Ubuntu 使用固定 GPG 主密钥指纹、私有官方索引下载再安装本地包；拒绝全局已有 Docker 包索引及已有安装/冲突包/数据，普通依赖仍用系统源；Alpine 使用系统签名仓库及 docker-openrc，拒绝接管已有安装，启动后回读稳定版 Engine ≥28；失败保留私有日志与现场，不自动卸载，原生包可能启用 Docker 自启；首次交付版本的 IPv6 apply/status/restore 已在 Debian 13.7/KVM 通过双容器 ULA 通信、整机重启与恢复原先无 daemon.json 的状态 |
| `B2` | NodeQuality | 开发中：固定 SHA-256 后执行综合质量测试，真实运行已验证 |
| `B4` | 哪吒面板 | 开发中：容器部署入口，真实运行待验证 |
| `B5` | X-UI | 开发中：3X-UI 容器部署入口，真实运行待验证 |
| `B6` | 虚拟内存 | 开发中：事务式 swapfile + systemd 单元（独占锁、锁内复检、信号回滚、不写 fstab），真实机器待验收 |
| `B7` | 流量告警 | 开发中：vnstat 流量统计与阈值检查，systemd timer 告警；不阻断流量，不等于限速 |
| `B8` | 修改密码 | 开发中：调用系统 `passwd` 修改 root 密码，不使用固定密码 |
| `B10` | 网页 SSH | 开发中：WebSSH（Debian + Python 3.11+，PyPI 固定版本 + nginx Basic 认证，仅回环），支持菜单安装/卸载/状态；首次交付版本已通过 Debian 13/Python 3.13 的真实认证、SSH nonce、服务重启和卸载；首次交付的个人版/Easynode 固定 amd64 镜像已通过 Debian 13.7/KVM 的真实认证、SSH/SFTP、容器重启持久化与卸载保留数据 |
| `B11` | 1Panel | 开发中：官方安装包，固定版本校验，已有安装则拒绝 |
| `B14` | 三网回程 | 开发中：向预设目标执行路由追踪 |
| `B15` | Telegram 流量通知 | 开发中：Token / Chat 隐藏输入，systemd timer 推送 |
| `B16` | 网络优化 | 开发中：独立 sysctl drop-in、保存原值；新增可读参数需先回滚旧方案，回滚记录缺键则保留现场并拒绝 |
| `B19` | Alpine 工具 | 开发中：Webtop、UDP 端口跳跃及移除；历史 OpenRC swap 版本已通过 Alpine 3.24.2 x86_64/KVM 安装、真实换页、服务重启、整机自启及卸载验收，已发布开发预览 |

### 网络服务

| 编号 | 功能 | 状态与说明 |
| --- | --- | --- |
| `A1` | Alpine Hysteria 2 | 开发中：仅 Alpine + OpenRC；固定官方发布二进制并校验 SHA-256，失败回滚 |
| `A2` | Alpine Xray | 开发中：Alpine + OpenRC 的 VLESS + REALITY；缺普通依赖时确认补装，补装失败则停止，按指定端口和真实可执行文件核对归属；隔离安装、正反认证、服务重启和卸载通过，用户机器与公网待验收；回落流量不限 |
| `A3` | TUIC | 开发中：固定官方 v1.0.0 静态二进制，自动验证启动与端口归属；认证需客户端实测 |
| `A4` | Hysteria 2 | 开发中：有 Debian 安装、认证、数据面、重启、卸载的历史实测记录；当前交互与安全修复版本待真机复验 |
| `A5` | Xray | 开发中：VLESS Reality；VMess + WS + TLS 安装/状态/卸载、自启管理和受控换证，首次交付版本已通过 Debian 13/KVM 两次整机重启、认证传输、真实 ACME 换证同步和卸载；上游已弃用 VMess/WS，仅供兼容 |
| `B12` | TCP Brutal | 开发中：DKMS 编译 kernel module、开机载入与默认拥塞控制；仅非容器 Debian |
| `B23` | DNS 切换 | 开发中：仅 systemd-resolved，先查 resolv.conf 归属；验证失败回滚并列出泄漏面 |
| `B31` | Relay 转发 | 开发中：socat 单单元转发（TCP/UDP），不依赖也不会改动 nginx |

### 常用应用

应用部署入口均有实现与模拟测试，部分有历史隔离测试机运行记录；**当前版本不作「全部应用真机验收完成」声明**。后续配置、认证和长期持久化仍需验证。需要稳定版 **Docker Engine ≥ 28**，低版本会因回环端口泄露风险被拒绝，不会绕过该门禁。

默认绑定 `127.0.0.1`；远程访问需 SSH 隧道或另行配置经过审查的反向代理、HTTPS 和认证。WebSSH、NginxWebUI、LibreTV、Stirling PDF 默认可能同用 8080，安装时请为它们指定不同端口；NPM 还需要本机 80/443。

| 编号 | 应用 | 用途 |
| --- | --- | --- |
| `B3` | Alist | 文件列表与网盘管理 |
| `B9` | IT-Tools | 网页开发者工具箱 |
| `B13` | MyIP | IP 信息查询页面 |
| `B17` | Sun-panel | 个人导航页 |
| `B18` | 预留 | 暂未安排 |
| `B20` | Memos | 笔记应用 |
| `B21` | Nginx Proxy Manager | 反向代理管理 |
| `B22` | Halo | 博客与建站 |
| `B24` | NginxWebUI | Nginx 网页管理 |
| `B25` | Nexterm | 网页终端与连接管理 |
| `B26` | LibreTV | 影视搜索与播放 |
| `B27` | Stirling PDF | PDF 工具箱 |
| `B28` | 网页验证 | 开发中：固定镜像、表单登录，数据为未加密 H2 文件 |
| `B29` | DDNS-GO | 动态域名解析 |
| `B30` | Vaultwarden | 密码管理器 |

## 安全提示

- 脚本操作的是**当前登录的服务器**。安装软件、修改网络或重启可能影响现有业务，操作前请备份并保留独立登录方式。
- 体检结果可能包含 IP 地址和监听端口，分享前请检查隐私信息。
- Docker 应用默认使用本机端口，不等于对其他容器或宿主机用户完全隔离；部署密码管理器等应用前，还需要配置 HTTPS、认证和备份。
- 不要盲目运行任何来源不明的远程脚本。正式发布后，建议先下载并查看脚本，再核对发布版本的校验值。

## 开发与测试

菜单编号与「启动检测后进分层菜单」的交互参照 [jht.one](https://jht.one)（jinhuaitao）的公开脚本，脚本实现独立；上游未附版权与许可声明，因此本仓库不代为标注上游许可证。本仓库自身也尚未声明许可证，公开可读不代表已授予开源许可。

源码、欢迎页与 Worker 路由均已公开。默认回归只模拟特权命令，文件写入使用临时路径；设置 `TOOLBOX_NETWORK_REAL_TESTS=1` 后，网络套件另启用本机回环 TLS 和真实 socat 往返，但不安装系统服务。在隔离 Debian/Ubuntu Linux 测试机准备 Bash 4+、Python 3.11+（含 cryptography）、Node.js 20+、OpenSSL、编译工具、APT/dpkg、jq、socat 和测试依赖后运行完整默认套件。默认临时目录为受保护的 `/root/.cache/terry-toolbox-tests`，可用 `TOOLBOX_TEST_TMPDIR` 指定 `/root/` 下无符号链接、私有且父目录不可被其他用户写入的路径（完整套件的 ACME fixture 要求 `/root/`）：

```bash
bash scripts/test.sh --output /root/toolbox-evidence/run-001
```

VMess 的真实协议验证单独运行（需自行准备已核验的 Xray 26.10.29 二进制；测试只创建短命回环进程和私有临时文件，不安装服务）：

```bash
python3 tests/vmess-protocol-test.py /absolute/path/to/xray
```

该测试调用模块生成服务端/客户端配置，再为隔离 nonce 目标临时放行**一个确切回环 TCP 端口**；最后使用未修改的服务端配置验证默认私网阻断。它不等于 systemd、真实 VPS、公网或整机重启验收。

`tests/b2-real.sh` 是单独的真实 NodeQuality 运行，不属于默认回归。**不要在业务机器上把真实安装测试当作回归运行。**

生成 Cloudflare Worker 使用的单文件 Bash 和发布包（`docs/` 同时保留历史 Pages 产物）：

```bash
bash scripts/release.sh
python3 scripts/build-worker.py
```

`release.sh` 成功构建并校验后才原子替换 `docs/index.html`，失败保留旧产物；`build-worker.py` 为 `worker.mjs`、`router.mjs`、`toolbox.txt`、`welcome.txt` 四个模块生成 SHA-256 与字节数 manifest。

部署另需 Python `requests`。通过环境变量 `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_API_TOKEN` 提供凭据（不入库），或通过 `--credentials` 指定仓库外私有 JSON 文件。以下命令直接更新生产 Worker，执行前须已有当前发布授权。程序先验证本地完整发布包，再把原 Worker、配置、域名绑定与公网入口写入仓库外的新私有备份目录，上传后精确回读，并检查 DNS、workers.dev 和 Worker settings。**已知限制：** Cloudflare `/content` 会清除版本描述 annotations，当前程序会在上传后因 settings 不一致而失败，且不会自动恢复。已带描述的 Worker 不要直接重复运行下方命令，先按[实际发布异常记录](docs/release-20261031.md#线上回读与实际发布异常)核对完整上传恢复流程。

```bash
python3 scripts/deploy-cloudflare.py
```

可用 `--backup-dir /absolute/path/to/new-private-backup` 指定全新备份目录，否则默认建在当前用户 home 下；目录为 `0700`，文件为 `0600`。备份须保留在仓库外。首次域名迁移才使用 `--bind`，普通更新无需此参数。

Worker 不向 GitHub 回源：欢迎页与已发布 Bash 原始字节一并打包。发布程序会检查浏览器根路径、CLI 根路径、`/toolbox.sh` 和 `/sha256`，原 URL 与随机参数 URL 均须匹配候选内容。只有生成 `deployment-verified.json` 才表示程序完成全部发布检查，随后同步 README 中的线上 SHA-256。失败时内容可能已经上传，程序不自动回滚 Worker；保留备份并按[维护手册](HANDOFF.md#workers-发布与失败恢复)恢复和回读。

**模拟测试通过不代表真实安装、重启恢复或应用访问已经通过**；真机验收状态以功能表和开发进度为准。
