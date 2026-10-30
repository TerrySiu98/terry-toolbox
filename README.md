<div align="center">

# Terry Toolbox

**Linux 服务器工具箱**

系统管理 · 网络服务 · 常用应用

[使用方法](#使用方法) · [功能列表](#功能列表) · [安全提示](#安全提示) · [开发与测试](#开发与测试)

</div>

---

> **开发预览，尚非稳定版。** 源码与单文件脚本已公开。下方功能表同时列出已实测、待真机验收及计划项目，不能视为全部完成；首次使用请选测试机。

## 简介

Terry Toolbox 是一个面向 Linux 服务器的中文菜单工具箱。登录服务器后运行脚本，输入编号就能进入相应功能。

启动时只做系统检测，缺依赖才询问是否安装。涉及安装、修改系统或重启的操作，会先显示内容并二次确认。B18 暂时保留，以后再补。

## 开发进度

- **自动化回归**：默认 shell 套件、真实 PTY 菜单、单文件构建及 Worker 路由；包含 swap 启动任务/SIGTERM、sysctl 缺键回滚与真实离线 APT 包源回归。默认套件中的特权操作为模拟，不能当作真实安装验收。
- **Alpine 3.24 隔离验证**：真实 APK 完成 M2 缺依赖补装并回读 `ss`；A2 使用真实 Xray/OpenRC，完成安装、正确认证 HTTP 200、错误 UUID 拒绝、服务重启后再次 HTTP 200、卸载清理。测试位于私有命名空间，使用本地 HTTP/TLS 源与明确标注的 OpenRC 启动状态；不等于用户机器、VM 启动、公网链路或崩溃恢复验收。
- **Alpine Docker 隔离验证**：已修复只安装包不启动服务、日志文件名不兼容 BusyBox 的问题。全新 Alpine 3.24 用户态通过完整 B1 双确认菜单、真实签名 APK 安装、OpenRC 启动、Engine 29.9.2 / docker info 回读及服务归属核对，停止后确认不可连接，未配置自启。首次验证因 fixture 缺失 cgroup2 失败；仅补只读 cgroup2 挂载后通过。OpenRC 启动状态仍是 fixture，cgroup controller 有只读/支持警告；没有运行容器、验证应用或整机重启。
- **历史实测记录**：部分 Docker 应用、Hysteria 2 全流程、WebSSH 认证拦截与卸载；不能据此声称当前全部功能已通过真实验收。
- **已开发、待当前版本真机验收**：BBR、依赖、Docker、改密码、重启、路由追踪、Debian/Ubuntu swap、Xray、DNS、TCP Brutal、Relay、Alpine HY2/Xray、1Panel、流量告警、Telegram 通知、网络优化、WebSSH 和各 Docker 应用。
- **计划或未启用**：系统重装（M3）、Docker IPv6、WebSSH 个人版/Easynode、Xray VMess + WS、Alpine swap。
- **预留**：B18。

## 使用方法

### 一键入口

```bash
bash <(curl -fsSL sh.uw.cx)
```

非 root 用户会自动 `sudo` 提权；用 root 跑也行。没有 curl 时：

```bash
bash <(wget -qO- sh.uw.cx)
```

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

与仓库 `docs/index.html` 的哈希对比，一致再执行。**当前发布版本的 SHA-256**：`cdac369c7d03e118a5317071b3db90cf7bae3bb81a343115ef08d5a19355a542`（每次发布后更新）。

服务端下载的是单文件版本，全部模块已经打包进去，不需要准备其他文件。Debian / Ubuntu 为当前主要支持环境，Alpine 仅部分功能。

网站与脚本由 **Cloudflare Workers** 托管，HTTPS 证书由 Cloudflare 提供；GitHub 用于保存源码。
- 浏览器访问 [https://sh.uw.cx](https://sh.uw.cx)：欢迎页、复制命令、下载入口。
- curl / wget 访问相同地址：返回脚本，保留短命令。HTTP 会重定向到 HTTPS；希望首个请求也加密，可写 `bash <(curl -fsSL https://sh.uw.cx)`。
- 明确下载脚本：[https://sh.uw.cx/toolbox.sh](https://sh.uw.cx/toolbox.sh)，不依赖请求头；校验值：[https://sh.uw.cx/sha256](https://sh.uw.cx/sha256)。

### 启动与菜单

启动时先识别系统与架构，只缺依赖时才提示安装（`Y`/`y` 确认，其他键跳过；只补齐缺失项，安装后重新检查命令，不升级系统）。Alpine 的 `ss` 对应 `iproute2-ss`。功能操作的 `YES` 确认不区分大小写，空输入与 EOF 仍取消。不支持的系统仍可进菜单，由各功能自行检查。

主菜单只有一屏；输入编号回车即可：

- `1` 网络服务：Alpine HY2/Xray、TUIC、HY2、Xray
- `2` 安装 BBR，`3` 安装基础依赖，`4` 重装系统（未实现），`5` 常用工具（Docker、应用、体检以外的系统项）
- `DIAG` 只读体检，`99` 重启，`0` 退出

进入子菜单后 `0` 返回上一层；功能管理页返回所属分类，分类页返回主菜单，只有主菜单 `0` 才退出。操作结束后按回车留在当前功能页，单纯返回不再额外暂停。`A4`、`B9` 这类完整编号在任何界面都能直接输入。安装类功能需要 root，执行前会显示影响并要求确认。

真实终端切页会清除当前画面再重绘，不清除历史滚动记录；重定向到日志时不发送清屏控制符。需要保留每次画面时可设置 `TOOLBOX_NO_CLEAR=1`。

网络服务、WebSSH、TCP Brutal、网络优化、Alpine 工具、DNS 与 Relay 通过功能管理页选择动作，不会选中编号就直接安装。TLS 服务安装会询问已有证书、私钥路径及证书域名；当前不自动申请或生成证书。输入结束或取消不会视为安装成功。

## 功能列表

状态说明：**已实测**表示在隔离测试机完成过真实运行验收；**开发中**表示已有实现但未完成真实验收；**计划**表示还未实现或暂不启用；**预留**表示尚未安排功能。

### 系统工具

| 编号 | 功能 | 状态与说明 |
| --- | --- | --- |
| `DIAG` | 服务器体检 | 开发中：只读查看系统、运行时间、内存、磁盘、网络和监听端口 |
| `M1` | BBR | 开发中：调整当前运行期拥塞控制，重启后可能失效 |
| `M2` | 基础依赖 | 开发中：按缺失命令补包并回读；Alpine 3.24 真实 APK 隔离验证通过，其他系统待当前版本实测 |
| `M3` | 重装系统 | 计划、禁用：尚无经过验证的恢复与重装方案，选择此项不会执行重装 |
| `M4` | 重启服务器 | 开发中：确认后重启本机 |
| `B1` | Docker | 开发中：Debian/Ubuntu 使用固定 GPG 主密钥指纹、私有官方索引下载再安装本地包；拒绝全局已有 Docker 包索引及已有安装/冲突包/数据，普通依赖仍用系统源；Alpine 使用系统签名仓库及 docker-openrc，拒绝接管已有安装，启动后回读稳定版 Engine ≥28；失败保留私有日志与现场，不自动卸载，不默认自启；Docker IPv6 未实现 |
| `B2` | NodeQuality | 开发中：固定 SHA-256 后执行综合质量测试，真实运行已验证 |
| `B4` | 哪吒面板 | 开发中：容器部署入口，真实运行待验证 |
| `B5` | X-UI | 开发中：3X-UI 容器部署入口，真实运行待验证 |
| `B6` | 虚拟内存 | 开发中：事务式 swapfile + systemd 单元（独占锁、锁内复检、信号回滚、不写 fstab），真实机器待验收 |
| `B7` | 流量告警 | 开发中：vnstat 流量统计与阈值检查，systemd timer 告警；不阻断流量，不等于限速 |
| `B8` | 修改密码 | 开发中：调用系统 `passwd` 修改 root 密码，不使用固定密码 |
| `B10` | 网页 SSH | 开发中：WebSSH（PyPI 固定版本 + nginx Basic 认证，仅回环），支持菜单安装/卸载/状态；有历史实测记录，当前修复版本待真机复验；个人版/Easynode 未做 |
| `B11` | 1Panel | 开发中：官方安装包，固定版本校验，已有安装则拒绝 |
| `B14` | 三网回程 | 开发中：向预设目标执行路由追踪 |
| `B15` | Telegram 流量通知 | 开发中：Token / Chat 隐藏输入，systemd timer 推送 |
| `B16` | 网络优化 | 开发中：独立 sysctl drop-in、保存原值；新增可读参数需先回滚旧方案，回滚记录缺键则保留现场并拒绝 |
| `B19` | Alpine 工具 | 开发中：Webtop、UDP 端口跳跃及移除；Alpine swap 暂未启用 |

### 网络服务

| 编号 | 功能 | 状态与说明 |
| --- | --- | --- |
| `A1` | Alpine Hysteria 2 | 开发中：仅 Alpine + OpenRC；固定官方发布二进制并校验 SHA-256，失败回滚 |
| `A2` | Alpine Xray | 开发中：Alpine + OpenRC 的 VLESS + REALITY；依赖检查失败立即退出，按指定端口和真实可执行文件核对归属；隔离安装、正反认证、服务重启和卸载通过，用户机器与公网待验收；回落流量不限 |
| `A3` | TUIC | 开发中：固定官方 v1.0.0 静态二进制，自动验证启动与端口归属；认证需客户端实测 |
| `A4` | Hysteria 2 | 开发中：有 Debian 安装、认证、数据面、重启、卸载的历史实测记录；当前交互与安全修复版本待真机复验 |
| `A5` | Xray | 开发中：VLESS Reality，回落限流、并发锁、回滚和认证自检 |
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

源码、欢迎页与 Worker 路由均已公开。默认回归只模拟特权命令，文件写入使用临时路径；网络套件还会使用本机回环 TLS / socat 测试，但不安装系统服务。运行完整默认套件：

```bash
for t in tests/*-test.sh; do bash "$t" || exit; done
python3 tests/menu-test.py
python3 tests/entry-feedback-test.py # 启动 ss 检查、包映射与装后回读
python3 tests/docker-origin-test.py # 真实离线 APT，索引与空包为明确标注的合成 fixture
node tests/worker-test.mjs
```

`tests/b2-real.sh` 是单独的真实 NodeQuality 运行，不属于默认回归。**不要在业务机器上把真实安装测试当作回归运行。**

生成 GitHub Pages 保留产物与 Cloudflare Worker 包：

```bash
bash scripts/release.sh
python3 scripts/build-worker.py
```

部署时通过环境变量 `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_API_TOKEN` 提供凭据（不入库），或给 `scripts/deploy-cloudflare.py` 传入私有凭据文件；已有域名绑定后仅上传 Worker，不需要重新切 DNS。

```bash
python3 scripts/deploy-cloudflare.py
```

Worker 不向 GitHub 回源：欢迎页与已发布 Bash 原始字节一并打包。发布后需回读浏览器页、curl 脚本和 `/sha256`；脚本变更后同步 README 中的 SHA-256。**模拟测试通过不代表真实安装、重启恢复或应用访问已经通过**；真机验收状态以功能表和开发进度为准。
