# Terry Toolbox — Claude Code 交接

> 交接日期：2026-10-31（北京时间） · 交接人：Terry's Hermes
>
> **这是未完成开发工作的接续分支，不是稳定版，也不是已上线版本。** Terry 已授权把未上传工作提交到独立分支，交给 Claude Code 继续完善；本次不合并 `main`、不更新线上 Worker、不修改 DNS。后续小功能在 Terry 通知后再由 Hermes 接手。

## 1. 从哪里接手

- 仓库：<https://github.com/TerrySiu98/terry-toolbox>
- 交接分支：`handoff/hermes`
- 交接前 `main` / `origin/main`：`51c1f37c9f4113a648c49be21b6f7724cae49ae4`
- 原开发目录：`/root/projects/terry-toolbox`。**源码在此分支中完整提交，不要求继续使用原开发机。**
- 最后提交号用 `git rev-parse HEAD` 核对；Terry 会收到推送完成后的完整 hash。文档不填自己的 commit hash，避免自引用。

新目录接手：

```bash
git clone --branch handoff/hermes --single-branch https://github.com/TerrySiu98/terry-toolbox.git
cd terry-toolbox
git status --short --branch
git rev-parse HEAD
```

已有克隆：先保存自己的改动，再 `git fetch origin`，然后跟踪 `origin/handoff/hermes`。不要用 `reset --hard`、`clean -fd`、覆盖式复制或强推处理已有工作。无需 cherry-pick 零散模块。

### 交接前 Git 清点

已运行 `git status --porcelain=v1 -uall`、`git fetch origin`、`git branch -avv`、`git log --branches --not --remotes`、`git stash list`、`git worktree list` 并核对远端 heads：

- 原本只有本地 `main` 和远端 `origin/main`，ahead/behind 均为 0。
- **没有未推送的本地提交、其他本地分支或 stash**；仅一个工作树。
- 原工作区有 **10 个已跟踪文件修改 + 20 个未跟踪文件**，完整列表见附录 A。
- 交接另增加本文件，并扩展 `.gitignore`；README 增加交接提示。功能代码不因本次上传而重写。
- 不携带 `.git`、本机凭据、原始测试日志、VM 磁盘和测试数据库。

## 2. 项目结构与本地运行

```text
toolbox.sh                  中文菜单、按需加载、管理动作分发
modules/                    source-only 功能模块
  entry.sh                  系统识别、依赖提示、终端 UI
  apps.sh                   Docker 应用
  network.sh                网络服务及 VMess 转发适配
  system.sh                 系统操作与新模块适配
  vmess.sh                  VMess + WS + TLS 生命周期、自启、换证
  alpine-swap.sh            Alpine/OpenRC swap
  docker-ipv6.sh            默认 Docker bridge IPv6
  webssh-containers.sh      WebSSH 个人版 / Easynode
  tls-acme.sh               Certbot ACME、续期定时任务、VMess 部署
  reinstall-provenance.sh   固定重装上游及校验/派生规则
  reinstall.sh              bin456789/reinstall 受控适配
scripts/build.sh             源码 -> 单文件 Bash（拒绝覆盖已有输出）
scripts/release.sh           覆盖 docs/index.html 为待发布脚本
scripts/build-worker.py      发布脚本 + 欢迎页 -> dist/worker
scripts/deploy-cloudflare.py 通过 CF API 上传固定名称的 Worker
web/index.html              浏览器欢迎页
web/router.mjs              浏览器/CLI 响应路由
docs/index.html             上次发布的单文件 Bash，不是网页
 tests/                     模拟边界、PTY、真实协议与集成辅助脚本
```

本地查看，无需 Cloudflare/GitHub 密钥：

```bash
bash toolbox.sh --help
bash toolbox.sh --list
bash toolbox.sh
```

**最后一条在真实 TTY 中可能询问补装缺失依赖；只浏览时拒绝补装。菜单里的安装、网络修改、重启、重装会作用于运行它的机器，不要在开发宿主上随手确认。**

- 常规本地构建用 Bash / Python 3；菜单/路由测试用 Python 3、Node.js。
- 部分测试需要 root、OpenSSL、编译器、socat、timeout、系统原生工具等；不要通过宿主安装服务“补齐测试”。
- 源码自带模块，发布脚本已内嵌模块，不会从 Hermes 服务器动态下载模块。
- 菜单保持原编号；B18 保留。不要为了赶进度把拒绝分支算作功能完成。

## 3. Cloudflare 托管与发布

### 当前线上架构

**实际托管是 Cloudflare Workers，Worker 名称 `terry-toolbox`，自定义域名 `sh.uw.cx`。不是 Cloudflare Pages。**

已回读 CF API 的域名绑定及 Worker settings：域名绑定到该 Worker 的 production 环境，bindings 为空，无数据库/KV/R2/远端服务绑定。Worker 自带 Bash 和 HTML 字节，运行时不访问原开发机或 GitHub 回源。

- 浏览器：<https://sh.uw.cx/> → 欢迎页。
- curl/wget 根路径或 <https://sh.uw.cx/toolbox.sh> → 单文件 Bash。
- <https://sh.uw.cx/sha256> → 已发布脚本哈希。
- GitHub Pages **历史后备配置**仍存在：`main` 分支 `/docs`，`docs/CNAME` 仍为原域名。它不是当前自定义域名流量入口，别因看到 `docs/` 就重新迁移 DNS。
- 仓库只有 GitHub 自动生成的 Pages workflow；没有把本交接分支自动部署到 Cloudflare 的 workflow。推送本分支不等于部署。
- 本次核对的线上脚本 SHA-256：`cdac369c7d03e118a5317071b3db90cf7bae3bb81a343115ef08d5a19355a542`，与分支保留的 `docs/index.html` 相同。**新增模块只在源码，尚未进入此线上产物。**

### 将来正式发布的流程（需要 Terry 另行授权）

先审查并验收冻结源码，保存线上 Worker/主页/脚本快照，再按顺序：

```bash
# 以下会改本地发布产物；不是仅上传源码所必需的步骤。
bash scripts/release.sh
python3 scripts/build-worker.py
node tests/worker-test.mjs
sha256sum docs/index.html

# 仅在获准上线、部署环境变量已私下配置后执行：
python3 scripts/deploy-cloudflare.py
```

注意：

1. `build-worker.py` 读取的是 **`docs/index.html`**，不是直接打包当前 `toolbox.sh`。遗漏 release 会部署旧脚本。
2. `release.sh` 会删除/重建本地 `docs/index.html`；本次交接刻意不运行它、不更新发布 hash。
3. **`deploy-cloudflare.py` 即使不加 `--bind`，也会直接覆盖线上同名 Worker。脚本打印的 Preview 不是隔离 staging。** 不能拿它试验未完成代码。
4. 已有域名绑定，普通更新不要加 `--bind`，不要操作 DNS。该选项属于历史首次迁移路径。
5. 上传成功后必须回读 CF 部署模块，以及线上 `/toolbox.sh`、CLI 根路径、浏览器根路径、`/sha256` 的字节与 hash；再更新 README 发布记录。
6. 部署脚本依赖 Python `requests`。可在独立虚拟环境安装，不必安装 Wrangler。

### 所需环境变量（只列名称，不提供值）

**部署时必需，二选一配置方式：**

- 环境变量：`CLOUDFLARE_ACCOUNT_ID`、`CLOUDFLARE_API_TOKEN`。
- 或 `--credentials` 指向仓库外的私有 JSON，字段名 `account_id`、`api_token`。

脚本不会自动读取 `.env` 或 `.dev.vars`。GitHub 推送可用自己的 `gh auth login` 或 SSH；非交互可配置 `GH_TOKEN` / `GITHUB_TOKEN`，但它们不是 toolbox 运行依赖。不要复制原机整套 gh 登录文件。

**普通用户运行：没有必需的业务环境变量或集中式 API Key。** 凭据、域名、证书、端口通过对应功能交互提供，本地生成的凭据保存在目标机私有文件。

可选用户/测试项（不是生产必填，也不要为绕过门禁乱设）：

- UI/临时目录：`NO_COLOR`、`TERM`、`TOOLBOX_NO_CLEAR`、`TMPDIR`、`HOME`。
- 重装公钥输入：`TOOLBOX_REINSTALL_SSH_KEY_FILE`（公钥路径，不是私钥）；测试用 `TOOLBOX_REINSTALL_ROOT`、`TOOLBOX_REINSTALL_STATE`。
- VMess fixture：`TOOLBOX_VM_WS_ETC`、`TOOLBOX_VM_WS_BIN_DIR`、`TOOLBOX_VM_WS_UNIT_DIR`、`TOOLBOX_VM_WS_LOCK`、`TOOLBOX_VM_WS_LISTEN`、`TOOLBOX_VM_WS_OS_RELEASE`、`TOOLBOX_VM_WS_SYSTEMD_RUN`、`TOOLBOX_VM_WS_ZIP_SRC`。
- 测试信任库：`TOOLBOX_NET_CAFILE`、`TOOLBOX_NET_CAPATH`；不能把“不校验证书”作为兼容方案。
- ACME fixture：`TOOLBOX_TLS_ACME_ROOT`、`TOOLBOX_TLS_ACME_UNIT_DIR`、`TOOLBOX_TLS_ACME_OS_RELEASE`、`TOOLBOX_TLS_ACME_SYSTEMD_RUN`、`TOOLBOX_TLS_ACME_TEST_FIXTURE`、`TOOLBOX_TLS_ACME_TEST_FORCE_RENEWAL`。
- Docker IPv6 fixture：`TOOLBOX_DOCKER_IPV6_TEST_ROOT`。当前实现把该测试根限制为 `/root/.hermes/cache/scratch/docker-ipv6-*`，这是**测试路径耦合**，不是 Hermes 服务依赖；换机器要按测试约束准备目录或先审查后改善可移植性。
- Alpine swap fixture：`TOOLBOX_ALPINE_SWAP_ROOT`、`TOOLBOX_ALPINE_SWAP_INITD`、`TOOLBOX_ALPINE_SWAP_CONFD`、`TOOLBOX_ALPINE_SWAP_RUNLEVELS`、`TOOLBOX_ALPINE_SWAP_SWAPS`、`TOOLBOX_ALPINE_SWAP_MOUNTINFO`、`TOOLBOX_ALPINE_SWAP_OPENRC_RUN`、`TOOLBOX_ALPINE_SWAP_OS_RELEASE`、`TOOLBOX_ALPINE_SWAP_LOCK`、`TOOLBOX_ALPINE_SWAP_ENGINE`。
- Docker 上下文会被核查：`DOCKER_HOST`、`DOCKER_CONTEXT`、`DOCKER_TLS_VERIFY`、`DOCKER_CERT_PATH`。远端/rootless/不明 daemon 不能靠环境覆盖绕过。

其他历史模块的测试覆盖变量见相应 `tests/*`；不要整份复制原控制机 `.env`。

## 4. 已有功能与当前进度

### A5 VMess + WebSocket + TLS

源码已有：独立安装/状态/卸载、显式启用/禁用自启、自启只读状态、受控证书更新。REALITY 保留 1/2/3；VMess 保留 4/5/6，新增 7/8/9 自启管理、10 换证。固定上游 Xray 26.10.29，默认不自启；不改 REALITY、DNS、防火墙。

已有历史实证：

- 真实回环协议 8 场景：正确认证数据、错误 UUID/WS 路径/Host/信任拒绝、拒绝后正对照、进程重启、默认私网目的阻断。
- 独立 Debian 13/systemd guest 安装、精确服务与端口归属、可信 TLS/WS。
- 两次真实 VM 启动分别核实 enable 后自启、disable 后不自启；不是只运行 `systemctl restart`。
- 真实 Certbot/Pebble 签发后部署 VMess、强制续期后证书同步。

**最近补丁须重点复核**（`modules/vmess.sh` + `tests/vmess-management-test.sh`）：

1. `/run` 锁父目录是 boot-local inode，不再成为持久安装清单门禁；兼容含旧锁父目录字段的清单，同时保留持久目录完整性核验。
2. 扫描 `.wants` / `.requires` / `.upholds`，包括其他名称但指向本 unit 的符号链接；外来依赖拒绝接管。
3. `systemctl disable` 会移除指向 unit 的链接，动作前核验只有精确 owned 链接，动作后验证无残留；不能静默删除别人资源。
4. 安装发布、自启提交、卸载停止、换证交换之前核验锁 inode，换位则拒绝。

历史真机证据不自动覆盖最新补丁。需冻结当前源码后重跑完整 systemd 安装、认证、换证、整机重启、禁用、卸载闭环。公网、arm64、长期运行仍未完成验收。VMess/WS 已被固定上游标为弃用，保留是兼容需求，不应宣传为新部署首选。

### B19 Alpine swap

独立模块已接入 4/5/6。已有独立 Alpine 3.24.2 x86_64/KVM 实际安装、32 MiB 换页读回、OpenRC 服务重启、整机自启、未知文件保留、卸载证据；原 fstab/sysctl/swap 及宿主 swap 不变。

- 该模块当前 SHA-256：`c84b599967dfe5f8eb827ce221093e4839ed0515542e6aad0158bf636971aa26`，与已验证候选相同。
- 历史模拟套件 127 案例；当时整仓 56 项命令检查通过。**不是当前扩展后全仓已经全绿的声明。**
- arm64、其他文件系统/内核、长期压力、真实停用失败恢复仍待验收。

### TLS / ACME

`modules/tls-acme.sh` 已有 Certbot HTTP-01 签发、状态、续期、启用/禁用 owned systemd 续期任务、部署 VMess；已接 `TLS` 管理页。

独立 Debian 13 guest 使用真实 Certbot + 固定 Pebble，完成真实 HTTP-01、证书 serial 变化、timer/service、VMess 换证与续期后同步。没有跳过 challenge 或关闭证书验证。

当前模块 SHA-256 与上述产品级测试记录一致：`fffacc06108e63dad88ff002ba619c02c91c552f30a7202976149b12ece47f7d`。生产 Let's Encrypt、公网域名/DNS、完整 bundle 路径、A1/A3/A4 自动部署仍未验收。仅实现明确的 Debian/Ubuntu systemd 路径；不要声称 Alpine 自动续期已支持。

### B1 Docker IPv6

源码已有 apply/status/restore，保留无关 daemon JSON、验证来源/归属和服务状态；已有模拟用例及菜单接入。

**真实验收未完成。** 最近 guest apply 返回 `docker.socket pending/状态/drop-in 冲突`（exit 1），之后有只读 socket 回查，不能把回查成功当成 apply 成功。先确认原生 systemd socket 兼容门禁与测试 fixture，再测试 IPv6 容器通信、重启、精确 restore；不要直接放松安全拒绝。

### B10 WebSSH 个人版 / Easynode

原 Python WebSSH 保留 1/2/3；个人版 4/5/6，Easynode 7/8/9。复用上游容器产品，固定 linux/amd64 digest、回环端口、私有目录；guacd 不暴露宿主端口。账户初始化及秘密存储已有实现。

**真实验收未完成。** 最近记录既有认证断言失败，也有测试 harness 问题：重复 fixture 目录/同名旧容器触发拒绝、`http` 名称覆盖导致 `AttributeError`。不能把 HTTP 200 当登录成功，也不能为了重跑强删不明容器。需在干净且明确 owned 的隔离 guest 验证正反认证、实际 SSH/SFTP（适用）、数据持久化、重启、卸载保留数据。注意上游 data.json 采用 tmp+rename，单文件 bind 会 EBUSY；当前采用目录挂载。

### M3 系统重装

已实现 `preflight / prepare / status / cancel` 适配，固定 `bin456789/reinstall` commit；不是自写重装引擎。`reinstall-provenance.sh` 必须先于 `reinstall.sh` 加载。当前选择为 Debian 13 / Ubuntu 24.04 / Alpine 3.24。

**真实 prepare/reset、擦盘重装及重新 SSH 验收均未完成，不能视为已可用。** 适配层不调用 reboot，但上游 initrd 在安装完成后可能自行重启；发行版镜像和包仓库仍不是完整内容 pin。需要完整说明磁盘毁损范围、救援入口、备份、公钥，双确认及精确磁盘确认；测试只允许新建可丢弃 VM overlay，绝不使用宿主/业务机磁盘。

### 原有功能与应用

README 列出了全部编号。部分应用已在独立 Debian guest 证明 API 正反认证、自有 nonce 记录写读、完整容器 ID 重启后重登读回：B3 Alist、B4 Nezha、B17 Sun-Panel、B20 Memos、B30 Vaultwarden。

其他一批应用有端点与容器重启记录，但不代表业务功能、浏览器、SSO/2FA、邮件、公网和整机重启验收完成。`acceptance-matrix.json` 仍有 pending 项；它也是历史记录，部分后续单项证据已更新，不能只看一个状态字段判断。

## 5. 本次交接验证与已知问题

本次没有变更功能代码；对现有工作进行了聚焦复测：

- `bash tests/vmess-test.sh`：exit 0，28 个 PASS。
- `bash tests/vmess-dispatch-test.sh`：exit 0。
- `bash tests/remaining-dispatch-test.sh`：exit 0。
- `bash tests/vmess-management-test.sh`：首次 180 秒超时（22 PASS，未完成）；360 秒复测 exit 0，236.62 秒，23 PASS。
- `bash tests/build-test.sh`：exit 0（含单文件构建与启动 smoke）。
- `python3 tests/menu-test.py`：exit 0（层级、管理页、PTY、40 列布局）。
- `node tests/worker-test.mjs`：exit 0，13 个路由场景；这里针对**保留的旧发布产物**。
- `git diff --check`：exit 0。
- VMess 管理套件首次 180 秒超时，已有 22 个 PASS，无最后完整通过标记；**这次首次结果不是通过**。原日志保留，随后用 360 秒上限单独复测：**exit 0，236.62 秒，23 个 PASS，正常输出完成标记**。复测核对 `modules/vmess.sh`、两个相关测试文件 hash 一致。该套件正常耗时超过 180 秒，后续直接给足 420 秒上限，不要用 180 秒判断回归。
- 本次没有重跑完整全仓、真实安装或生产 CA；没有重启 VM 或宿主服务。

待交接收口：

1. README 存在陈旧描述：VMess 仍写没有自启/换证、systemd 未验收；B19 摘要写进行中而正文已有真实验收；IPv6/B10/M3 仍写未实现。这些应按本文件证据边界统一，不可只改成“全完成”。
2. 最新 VMess 安全补丁需要冻结后的独立复核及真实生命周期回归。
3. IPv6、B10、M3 的具体阻塞如上；先修测试前置/真实不兼容，再判断产品代码。
4. 串行重测试，完整保留失败/timeout；每条命令独立记录退出码、时限、日志与 source hash。模拟测试不等于真实 systemd/Docker/重装验收。
5. 本次最初测试 runner 超时只结束顶层 shell，留下精确 fixture 中的测试进程；已按 `/proc/<pid>/exe` 归属终止并回查，未动服务。后续 runner 超时应管理整个进程组，保留日志，不依赖单一父进程退出。
6. 测试曾用新 OpenSSL 的证书起止日期参数；换开发环境后先核对工具版本，别把 harness 缺功能当产品失败。
7. 交接代码不是最终安全审查通过版本。独立审查应重点覆盖 ownership、锁竞态、停服读回、回滚边界与重装磁盘操作。

## 6. 测试与继续开发顺序

推荐先读 `HANDOFF.md`，再读具体模块与测试，不要重写整个项目。

1. 克隆本分支，记录 HEAD 与工作树；核对没有遗漏新增模块。
2. 优先统一状态与定位 B1/B10 未完成验收；审查最近 VMess 四项门禁。
3. 新建独立、可丢弃 Linux VM 做真实服务/重装测试；不要把 macOS/宿主测试失败简单等同产品缺陷。
4. 逐项复测，不降低认证、TLS、pin、资源归属与失败保留门禁。
5. 所有写入结束后冻结源码，跑全套并构建新候选；旧 51/56 项结果只作历史证据。
6. README/菜单/模块加载/单文件构建一致，输出明确已测/未测边界；按 Terry 后续授权决定 PR、合并和部署，本次授权仅交接分支。

快速检查示例（在适合的隔离测试环境；每条命令单独保存退出码）：

```bash
for f in toolbox.sh modules/*.sh tests/*.sh scripts/*.sh; do bash -n "$f" || exit; done
for t in tests/*-test.sh; do bash "$t" || exit; done
python3 tests/menu-test.py
python3 tests/entry-feedback-test.py
python3 tests/docker-origin-test.py
node tests/worker-test.mjs
```

`tests/b2-real.sh`、`tests/tls-acme-integration.sh` 不在默认模拟套件中，前者会运行真实质量测试，后者仅准备隔离 ACME fixture，不要无审查直接执行。

真实 VMess 协议验证需另备经过来源/版本/hash 核验的 Xray：

```bash
python3 tests/vmess-protocol-test.py /absolute/path/to/xray
```

不传路径会报用法错误，不代表协议实现失败。当前要求固定 Xray 26.10.29；正确用例必须通过 VMess 返回 nonce，负例应证明目标未收到请求，最后保留正对照。

仅构建开发候选，不改发布产物：

```bash
# 选择一个不存在的输出文件；build.sh 拒绝覆盖。
bash scripts/build.sh dist/handoff-candidate.sh
bash -n dist/handoff-candidate.sh
bash dist/handoff-candidate.sh --list
```

## 7. 不入 Git 的资产、位置与获取方式

下列路径属于原开发机，不是克隆后的必需目录。不要把整个 `.hermes`、scratch 或 state 打包上传到公开仓库。**获取方式：需要时让 Terry 授权 Hermes 做定向脱敏导出，或自行重建 fixture。未经确认不删除原证据/overlay。**

### 凭据

- Cloudflare 部署凭据：原机 `/root/.hermes/secrets/cloudflare-tunnel.json`，权限 0600。只供获授权部署；优先由 Terry 给 Claude Code 新建专用限权 token，私下配置部署变量，不复制完整凭据文件进 Git。
- 原机 GitHub 登录：`/root/.config/gh/hosts.yml`，权限 0600。不交付、不复用原 OAuth token；Claude Code 使用自己的授权。
- 原机 Hermes `.env` 与 toolbox 无运行关系，不交付。任何 API key、DNS token、私钥不得出现在文档、日志附件或提交中。

### 真实验收与历史记录

持久证据根：`/root/.hermes/state/terry-toolbox-cf/`。

- `claude-handoff-20261031-094415/`：本次 Git/源码 hash、测试退出码和日志、敏感扫描、CF 只读状态。
- `remaining-all-20261031-055112/`：原始源码基线压缩包、`baseline.json`、`acceptance-matrix.json`、独立 Debian guest 测试记录与失败 harness。
  - VMess：`vmess-native-install-systemd-v1-072256.*`、`vmess-native-enable-boot-v1-072839.*`、`vmess-native-reboot-readback-v1-072930.*`、`vmess-native-disable-boot-v1-073632.*`、`vmess-native-disabled-reboot-readback-073707.*`。
  - TLS：`TLS-product-native-v8-081056.*`、`TLS-vmess-integration-v2-082033.*`。
  - IPv6：`B1-ipv6-native-apply-v1-071500.*`、`B1-ipv6-native-socket-readback-071524.*`。
  - B10：`B10-native-acceptance-v1-082922.*`、`B10-native-v5-083133.*`、`B10-native-v6-083204.*` 等失败记录。
- `alpine-real-evidence-3lx5176i/real-acceptance-v3-summary.json`：独立内核 Alpine swap 实证。
- `alpine-local-candidate-3lx5176i/final-regression-summary.json`：历史 56 项检查；同目录候选不是当前扩展后源码。
- `vmess-parent-regression-3zy8afl5/summary.json`：历史 51 项检查；需对照其 source hashes。
- `vmess-development-protocol-evidence.json`、`vmess-protocol-development.log`：历史 8 场景协议证据。

这些日志/JSON可能含测试账号、地址、路径、镜像信息或 fixture 细节，尚未逐文件公开脱敏，因此不直接入 Git。需要某项时按上述文件名定向导出；不要把历史计数替代当前版本验证。

### 大文件、VM 与数据库

- Debian VM 工作区：`/root/.hermes/cache/scratch/toolbox-remaining-vm-20261031/`。
- Alpine swap VM：`/root/.hermes/cache/scratch/toolbox-alpine-swap-vm-7s7agpsx/`。
- 历史 Xray/Alpine fixture：`/root/.hermes/cache/scratch/toolbox-alpine-real.o0j7kh64/`。
- 包括 qcow2/overlay、镜像、seed、fixture SSH 私钥、测试账户和应用数据库。它们不是交付软件的业务数据，不需要迁移到 Claude Code；优先在新机重建。
- 本次核对无运行中的 QEMU VM；磁盘与旧测试数据仍保留。原 runbook 提醒旧 Alpine/Xray fixture 可能有 controller 可见挂载残留；本次未做挂载清理，不要泛化执行 umount/rm。
- scratch 会被清理，不能把它当永久附件地址；如确需保留/传输磁盘，先请求 Terry 授权并核查私钥、测试 DB、大小与挂载状态。
- `dist/worker/` 是可再生打包产物，被忽略；`docs/index.html` 则保留在 Git，代表旧发布版本。
- 原内部详细实施计划：`/root/.hermes/plans/terry-toolbox-remaining-all-20261031.md`；运行手册：`/root/.hermes/runbooks/terry-toolbox-script.md`。关键内容已整理到本文件，继续开发无需读取 Hermes 内部配置。

## 8. 是否依赖原服务器

**产品运行不依赖原 Hermes 控制机的服务、数据库、定时任务、环境变量或常驻 agent。**

- 网站与下载：Cloudflare 自包含 Worker，无原机回源。
- 软件执行：在最终用户选择的 Linux 机器本地；第三方下载仍依赖 GitHub、系统包源、容器镜像仓库等外部上游。
- 数据/服务：安装后位于那台目标机，不是原开发机的集中数据库。例如 `$HOME/.local/share/terry-toolbox/apps/`、`$HOME/.local/share/terry-toolbox/webssh-containers/`、`/etc/terry-toolbox-vmess/`、`/var/lib/terry-toolbox-acme/`、`/var/lib/terry-toolbox-alpine-swap/`、`/var/lib/terry-toolbox/reinstall/`。
- timer/OpenRC/systemd：只有用户确认相应功能后才在目标机创建（如 ACME 续期、流量通知、swap、自启）。无需复制原机 crontab 或 Hermes cron。
- 原机仅保存开发工作区、可选部署凭据、历史日志和测试 VM。少数测试有 `/root/.hermes/cache/scratch` 硬编码约束，需要处理测试可移植性，但无需部署 Hermes。

## 9. 安全与验收约定

- 进入菜单不等于同意安装；缺依赖提示与具体变更确认分开。
- 变更前显示文件/端口/服务/影响，保留规定的双 YES；空输入、EOF、无结尾换行的 YES 都应取消。
- 不接管已有数据、外来 unit/drop-in/symlink、陌生容器/网络；内容、inode、锁、服务或端口归属不明时拒绝。
- stop/readback 失败保留证据，不强删、不开宽松模式、不删除清单“修好”安装。
- 不打印密码/UUID/token；随机生成并保存私有文件；root 密码用 `passwd` 交互，不恢复上游公共密码。
- 不降低 TLS/认证/私网阻断/固定来源校验来让测试通过。
- 本次 Gitleaks 8.30.1 扫描发现 8 条候选，逐项核实为历史模拟密码/密钥 fixture、RFC WebSocket 示例 nonce、空的事务 token 变量误识别（含发布产物重复）。未发现真实部署凭据；另做 CF/GitHub 已知凭据字节匹配及私钥块/provider-token 检查，无命中。**不把扫描表述为绝对安全保证。**
- `.gitignore` 已覆盖 `.env*`、`.dev.vars*`、本地 token/credentials、私钥、数据库、VM 镜像及构建目录。忽略规则不清除已跟踪文件；提交前需核对 staged 清单。
- 公开仓库不等于上游许可授权。保持已有来源说明；本项目许可尚未定，不擅自给上游代码补许可证。

## 附录 A：本次接手前的完整未上传文件

已跟踪修改（10）：

```text
README.md
modules/apps.sh
modules/entry.sh
modules/network.sh
modules/system.sh
scripts/build.sh
tests/build-test.sh
tests/menu-test.py
tests/system-test.sh
toolbox.sh
```

未跟踪（20，全部为源码或测试，纳入交接）：

```text
modules/alpine-swap.sh
modules/docker-ipv6.sh
modules/reinstall-provenance.sh
modules/reinstall.sh
modules/tls-acme.sh
modules/vmess.sh
modules/webssh-containers.sh
tests/alpine-swap-dispatch-test.sh
tests/alpine-swap-test.sh
tests/docker-ipv6-test.sh
tests/reinstall-test.sh
tests/remaining-dispatch-test.sh
tests/tls-acme-integration.sh
tests/tls-acme-test.sh
tests/vmess-dispatch-test.sh
tests/vmess-management-test.sh
tests/vmess-protocol-test.py
tests/vmess-test.sh
tests/webssh-containers-mock.py
tests/webssh-containers-test.sh
```

交接另修改 `.gitignore`、新增 `HANDOFF.md`。不删除/覆盖原有功能，不合并 `main`，不发布新单文件或 Worker。
