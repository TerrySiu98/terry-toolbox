# Terry Toolbox — Hermes 后续维护手册

更新日期：2026-11-01。本文件记录 Codex 接续后的当前维护入口；原 Hermes 交接已逐字节保存为 [2026-10-31 历史快照](docs/handoff-hermes-20261031.md)。快照中的 Claude Code 称谓、旧测试限制、失败记录及授权说明只描述当时状态，不代表当前分工或新的操作授权。后续工作以 Terry 的当前指示和本文件的证据边界为准。

## 本次 M3 Secure Boot 兼容修复待发布

[PR #4](https://github.com/TerrySiu98/terry-toolbox/pull/4) 候选分支 `codex/m3-secureboot-compat` 处理 UEFI 固件未提供 SecureBoot/SetupMode 变量而 mokutil exit 255 的预检阻塞；仅在固定 efivarfs 及引导变量确实可读、相关变量精确缺失时通过，已开启、权限/I/O 和未知状态仍拒绝。真实宿主生产 Alpine 完整只读预检已通过，未执行 prepare 或重启。候选 SHA-256 为 `02582cdfc6dd42bb14a5710217e8623ea31fc1f93b14db1edf6888b9103d47e6`（705208 字节）。最终冻结源 7 项相关检查及 85 项重装模拟检查全通过；原始 harness 失败与限定范围见[本次修复记录](docs/m3-secureboot-fix-20261101.md)。**当前未合并、未部署；下方 PR #3 仍是线上版本。**

## 本次 M3 旧版 lsblk 修复已发布

[PR #3](https://github.com/TerrySiu98/terry-toolbox/pull/3) 候选分支 `codex/m3-lsblk-compat` 修复 util-linux 2.36.1 不支持 `MOUNTPOINTS` 导致 M3 准备失败的问题，改用 `MOUNTPOINT` 并递归归一，保留挂载与磁盘身份门禁。新候选 SHA-256 为 `042bffafc28c9e47c5fddf485a4c60ac7e0d14cae39ae18f677cbea293f40da4`（702279 字节）。相关 7 项检查和真实旧版只读采集/inventory 已通过；最终调用次数断言补跑的 79 项模拟检查也已通过，完整来源与边界见[本次修复记录](docs/m3-lsblk-fix-20261101.md)。**PR #3 已合并并上线。** 发布源码 `37b0ebb365ebcd8f43873238368b9a7e1cf3cd33`，新候选哈希现为当前线上哈希；Hermes 8 项重点回归和公网/配置精确回读通过，见[当前发布记录](docs/release-pr3-20261101.md)。既有 loop 子分区挂载过滤边界保留，此类布局不要执行 M3 prepare；本轮未重复真实重装。

## 本次依赖补装修复已发布

[PR #2](https://github.com/TerrySiu98/terry-toolbox/pull/2) 的候选分支为 `codex/confirm-missing-dependencies`，产品源码与构建冻结提交为 `f229d25ae66ba0929d3805f0d170ad294ac0ba38`，最终测试提交为 `971d4f3f76eb1a9d36e0fb5a813030a8cc42715f`（仅测试断言修正），基于已发布的 `main` commit `58a5a7171432c6980f860795a13ff60a681504c2`，保留 Hermes 的重装状态及重启保护。线上缺 `virt-what` 就退出的问题已经从发布脚本逐字节确认，并非遗漏上传。

本候选补齐普通依赖的 `y` 确认安装、命令回读及原操作继续执行；M3 目标选择、两次重装确认和磁盘核对仍独立生效。候选 SHA-256 为 `f1a84fed003b0fc344006a6a82ce63a2b42ce552ce9b4301c63ca3e321956777`（701519 字节），测试证据及[固定候选下载命令](docs/dependency-fix-20261031.md#试用固定候选)见依赖补装修复记录。PR #2 已合并为 `36508eafb5234614241b7500f9c89c2fa49a05b5` 并发布到现有 Worker；内容、配置、域名/DNS 及公网已精确回读，见 [2026-11-01 发布记录](docs/release-20261101.md)。普通包安装不会随 M3 cancel 卸载，也不会自动安装或转换 init/引导器。

本次 33 项检查均取得有效通过，0 跳过；按源码哈希汇总四次冻结运行，软件包数据库/日志字节未变、源码无漂移、子进程清理完成。各项来源、原始失败及未验范围见[修复记录](docs/dependency-fix-20261031.md)和[机器可读证据](docs/dependency-fix-20261031.json)。

本次 M3 原生证据为仓库外 `evidence/m3-deps-native-euid-y14fjhon/public-native.json`，对应源码提交 `f229d25ae66ba0929d3805f0d170ad294ac0ba38`：全新 VM 中拒绝补装保持原状态，一次 `y` 真实安装 `virt-what` 后同次 Alpine 预检通过，prepare 确认处 NO/EOF 退出。未执行上游 prepare、擦盘或新系统启动；VM 已关闭。公开摘要及归档校验见本次修复记录。

在新目录取用本次已发布源码（已有目录先检查工作区，不覆盖）：

```bash
git clone --branch main --single-branch https://github.com/TerrySiu98/terry-toolbox.git
cd terry-toolbox
git log -3 --oneline
sha256sum docs/index.html
```

脚本哈希应与本文顶部 PR #3 当前发布版本一致。PR 合并与 Worker 发布各自独立，本次二者均已完成；后续文档提交不改变已验脚本字节。后续更新先看回归及当前发布记录，再按下方 Workers 流程备份、发布和回读。

## 首次交付与上一版生产记录

- 仓库：<https://github.com/TerrySiu98/terry-toolbox>；当前发布分支：`main`；[PR #1](https://github.com/TerrySiu98/terry-toolbox/pull/1) 已合并。Codex 接续开发历史位于 `codex/complete-toolbox`。
- 接续基线：`handoff/hermes`，commit `d884aae024485ff0632011e52a8d37c4a79effb2`。该基线仅用于原始交接，不是依赖修复候选。
- 首次交付的源码与构建 commit：`f880a583adc75a0241fbbea9cc54e6b7d358b4ec`。该提交是 Codex 的验收源码基线。其后文档提交及 Hermes 修复 `dbe845331dd9ab7f54372c85f4e9c4727d2c927e` 一起经 PR #1 合并为 `5a41fee49a852c0e1964114b8f9b60c078185ed1`；当前发布及原验收范围分别见下方。
- Codex 原候选 SHA-256：`eb7fdfa9c6ad729efe3206e67d0b73142f5fb39f280b86e06e910ae1b1c83e9a`。Hermes 重启门禁修复后的上一版 SHA-256：`e6b0641d725550245fe18c154321cd3e59e0ef199d63732ee60f5d3c157f6155`（664523 字节）；2026-10-31 已完成 Worker、配置及公网精确回读，见[发布记录](docs/release-20261031.md)。
- 更早线上 SHA-256 `cdac369c7d03e118a5317071b3db90cf7bae3bb81a343115ef08d5a19355a542` 已保留在历史私有回滚快照。提交源码、构建产物和上传 Worker 仍是三个独立动作；线上以 `/sha256` 回读为准。

接手先运行 `git status --short --branch`、`git rev-parse HEAD` 和 `git diff --stat`，保留已有修改。不要用覆盖式复制、`reset --hard`、`clean -fd` 或强推处理不明工作。

Hermes 在新目录取用已发布分支（包含 PR #3 lsblk 兼容及 PR #2 依赖修复）：

```bash
git clone --branch main --single-branch https://github.com/TerrySiu98/terry-toolbox.git
cd terry-toolbox
git rev-parse HEAD
```

核对 `main` 最新提交、发布记录与线上哈希。已有工作副本先检查状态再 fetch；保留旧 handoff 分支，不用 reset/clean 覆盖不明工作。

## 首次交付的历史验收边界

| 功能 | 已有有效证据 | 仍需完成或不在范围内 |
| --- | --- | --- |
| B1 Docker / IPv6 | Debian 13.7、x86_64、KVM，产品安装 Docker Engine 29.9.2；IPv6 apply、双容器 ULA nonce 传输、整 VM 重启后同一完整容器 ID 再读回、restore 全通过 | 原生 restore 验证的是恢复到原先不存在的 daemon.json；已有 JSON 的字节/权限保留由模拟覆盖。Ubuntu、Alpine、arm64、公网 IPv6、长期运行不在该次原生验收范围 |
| B10 个人版 / Easynode | 固定 linux/amd64 镜像；Debian 13/KVM/Docker 29.9.2 上匿名及错误密码拒绝、原生会话访问受保护 API、真实 SSH nonce、SFTP 文件写读、容器 ID 重启持久化、精确卸载并保留数据全通过；修复信号处理后两分支重验，并在真实 Docker 启动后发送 TERM，确认本次资源清理、数据与非本次资源保持 | 通过回环 HTTP API 验证；未验浏览器 UI、2FA/MFA、RDP、公网 TLS/反代、整 VM 重启或 arm64。原 Python WebSSH 的当前版本复验另计 |
| A5 VMess / TLS | Debian 13/KVM 上原生 Xray 安装、认证拒绝、自启启用/禁用后的两次整机重启、换证与卸载通过；Certbot 4.0.0/Pebble 2.10.1 完成真实 HTTP-01、四张不同证书、真实 timer 恢复已过期 lineage/VMess 证书并同步；测试后时钟恢复 | 公网入站、生产 CA、arm64、长期运行未原生验收。原先单次外网请求失败及诊断重跑保留，最终 candidate03 完整通过 |
| M3 重装 | Debian 13、Ubuntu 24.04、Alpine 3.24 / x86_64 / KVM / BIOS 已通过准备、状态、取消后精确恢复、再次准备、实际擦盘重装及新系统公钥 SSH；确认持久 ext4、旧系统标记消失、原磁盘身份一致、密码登录关闭 | 每个目标各一次全新 overlay 安装；UEFI/arm64 尚未原生验收；不能把 prepare 成功写成重装完成 |
| B19 Alpine swap | 首次交付所引用的旧版模块有历史 Alpine 3.24.2/x86_64/KVM 实际换页、服务重启、整机自启和卸载证据 | 历史范围限 ext4/指定内核；arm64、其他文件系统和长期压力未验；旧整仓通过数不是当前结果 |
| 原 Python WebSSH | Debian 13/Python 3.13 上固定 WebSSH 1.6.3 安装、Basic/WS/Origin 拒绝、真实 SSH nonce、重启后重复验证、卸载及临时 sshd cgroup 消失全通过；系统 nginx/SSH 配置保持 | 无浏览器 UI、MFA、SFTP、公网 TLS 或整机重启声明；依赖版本记录在私有 pip freeze，并非全量依赖锁定 |
| Worker 发布程序 | 已增加原子 release、完整模块 manifest、生产备份与精确回读；Linux 离线发布测试 28 项通过，含真实源码 release/build、DNS 异常恢复及附加字段保留 | Hermes 后续已真实发布并精确回读；原发布程序遇到 annotations 保留差异，恢复细节见发布记录 |

B1 模块内仍保留“尚未真实验收”的旧静态提示；上表及历史证据索引限定首次交付已经证明的范围，不能代替当前依赖补装改动的原生复验。其 restore 恢复 daemon 配置，不承诺恢复 dockerd 自行调整的内核 forwarding 或整机网络状态。B18 保留；其他应用入口存在不表示全部业务功能已验收。

## 构建与回归

主要入口：`toolbox.sh` 为菜单与分发；`modules/` 为按需加载的源模块；`scripts/build.sh` 生成独立 Bash；`web/` 为欢迎页和 Worker 路由；`docs/index.html` 保存发布用 Bash 字节。

在隔离 Debian/Ubuntu Linux 测试机准备 root、Bash 4+、Python 3.11+/cryptography、Node.js 20+、OpenSSL、C 编译器、APT/dpkg、jq、socat 及各测试声明的依赖。macOS 系统 Bash 3 不足以验证全部项目语法。默认回归中的服务/磁盘变更使用模拟；部分测试会启动短命回环进程。

```bash
bash toolbox.sh --help
bash toolbox.sh --list
bash scripts/test.sh --output /root/toolbox-evidence/run-001
```

`--output` 必须是新的仓库外私有目录；每次运行换名称。测试 scratch 默认 `/root/.cache/terry-toolbox-tests`，可用 `TOOLBOX_TEST_TMPDIR` 指定 `/root/` 下受保护的私有目录；完整套件的 ACME fixture 限定该根。B1 fixture 仅要求受保护、root-owned 0700 的 `docker-ipv6-*` 叶目录，不再依赖 Hermes 固定路径。

runner 串行保存源码哈希、每项命令、退出码、超时和日志。B1/TLS 上限各 1800 秒，B19 swap 1200 秒，VMess 管理及两种 WebSSH 套件各 5400 秒，重装 900 秒；其余以 runner 当前配置为准。超时、跳过、未跑完或源码中途变化都不能写成完整通过。定位单项可使用 `--only`，但单项结果不替代最终全套结果。

只构建开发候选、不更新发布文件：

```bash
bash scripts/build.sh /absolute/path/to/new-candidate.sh
```

输出路径必须不存在。真实协议、Docker、systemd 和重装验收分别使用 `tests/vmess-protocol-test.py`、`tests/docker-ipv6-integration.py`、`tests/webssh-containers-real.py`、`tests/vmess-native.sh`、`tests/tls-acme-native.sh`、`tests/webssh-native.py`、`tests/reinstall-native.sh` 及其 readback helper；它们不是默认安装回归。先读脚本的 marker、路径、镜像/二进制和阶段要求，只在明确可丢弃的 VM 运行。整机重启由外部控制者执行，须核对 guest 目标和 boot ID；不能用服务或容器重启代替整机验收。

## Workers 发布与失败恢复

2026-10-31 只读复查：`sh.uw.cx` 的系统信任验证成功，证书 SAN 覆盖该域名，颁发者为 Google Trust Services WE1，当前有效期至 2027-01-28。DNS 返回 Cloudflare 边缘地址。GitHub Pages 仍保留 `main:/docs`、`cname=sh.uw.cx`、`https_enforced=false` 的历史配置；当前资料不足以确定过去证书报错的原因。建议继续由 Workers 分流网页/脚本，GitHub 保存源码与版本。该段为 2026-10-31 的历史预检。本次 2026-11-01 已按 Terry 授权发布依赖修复，托管与 DNS 未迁移，见当前发布记录。

生产平台是 **Cloudflare Workers**：Worker `terry-toolbox`，自定义域名 `sh.uw.cx`。浏览器根路径返回欢迎页；CLI 根路径和 `/toolbox.sh` 返回单文件 Bash；`/sha256` 返回脚本哈希。内容全在 Worker 中，不向 GitHub 或原开发机回源。GitHub Pages 的 `/docs` 配置及 `docs/CNAME` 是历史后备，不是当前域名入口。

以下命令构建和验证本地候选；不调用 Cloudflare API：

```bash
bash scripts/release.sh
python3 scripts/build-worker.py
node tests/worker-test.mjs
sha256sum docs/index.html
```

`release.sh` 在同一文件系统构建并验证新产物，成功才原子替换 `docs/index.html`；构建失败保留旧产物。`build-worker.py` 读取发布文件而不是直接读取当前源码，生成四个模块及其 SHA-256/字节数 manifest。构建包被 `.gitignore` 忽略。

部署环境另需 Python `requests`。凭据用 `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_API_TOKEN`，或通过 `--credentials` 指定仓库外私有 JSON（字段 `account_id`、`api_token`）。不要把值放进源码、命令历史或文档。

**已知发布限制：** 当前 Worker 带有版本描述 `annotations[workers/message]`，普通 `/content` 更新会清除它，现有程序将因配置回读不一致而在上传后报失败。不要直接重复下方命令；Hermes 应先按[上次发布记录](docs/release-20261031.md#线上回读与实际发布异常)核对适用的完整上传与配置保留流程。

```bash
# 此命令直接更新生产 Worker；不是 staging 或预览部署。
python3 scripts/deploy-cloudflare.py
```

可选 `--backup-dir /absolute/path/to/new-private-backup`；父目录须已存在且受保护，叶目录必须全新、在仓库外，不接受 symlink 或 `..`。不指定时在当前用户 home 下新建私有目录。备份目录 0700、文件 0600，含原 Worker multipart、settings、workers.dev 状态、域名绑定、四个公网入口响应和本次候选字节及 manifest。

程序先核验本地四模块哈希及与发布源文件的一致性，再持久化完整备份并复检远端未改变。普通更新使用 Worker `/content` API 保留配置，不改变 DNS 或 workers.dev；上传后逐模块核对名称和完整字节，并验证 settings、域名与四个公网入口。普通 URL 和随机参数 URL 都须匹配，避免缓存遮蔽旧内容。仅完整外部回读完成记录可作为这次发布通过的依据，随后更新 README 的线上哈希与发布记录。注意：`/content` 会丢弃版本描述 `annotations[workers/message]`，且该端点忽略传入 annotations；现有程序会在上传后因 settings 不一致而失败，不会自动恢复。已带描述的 Worker 不要盲目重复普通命令，按发布记录中的完整上传恢复流程核对配置。

`--bind` 只用于明确的首次域名迁移：它会检查原 Pages CNAME、验证 workers.dev 上的生产内容，再更改 DNS/绑定；已有正确绑定时不做迁移。不要把它当普通发布必选项。

失败时保留整个备份目录，先看 `deployment-failed.json` 与相关响应；`upload_attempted=true` 表示新内容可能已经上线。程序**没有自动回滚 Worker 内容，也没有 `--rollback` 命令**，不能用再次执行新候选冒充恢复。需要恢复时，由当前获授权维护者核对线上版本和备份哈希，用 `worker-before.body` 及其响应 Content-Type 还原原模块，通过内容更新 API 恢复，保留既有 settings/DNS，然后重新验证模块和四个公网入口。备份 JSON 中原 settings/绑定用于比较；只有明确授权改变它们时才修改。显式 `--bind` 会在发出删除请求前记录原 DNS，即使响应丢失或证据盘写满，也仅在重新确认没有新域名绑定或 DNS 记录时尝试恢复该原记录，并逐字段读回所有支持的可写字段（含 `tags/settings`）。不重建服务端 ID 和时间戳；未知字段、不支持的值类型或不能可靠重放的设置在任何生产写入前拒绝迁移。恢复不会覆盖未知新记录；读回失败仍报告发布失败。

## 资源归属与维护约束

本次可丢弃 Linux 测试宿主的工作目录为 `/root/terry-toolbox-codex/`，原始回归与原生日志位于其 `evidence/`，重装后的测试磁盘保留用于复核。测试 VM 已关机；私有 Python/Node 运行时不替换系统 Python。宿主曾启用该目录下的 `acceptance.swap`（3 GiB），未写入 fstab；重装测试宿主前先取走需要的私有证据。测试 scratch 为 `/root/.cache/terry-toolbox-tests`。连接信息和密钥留在仓库外，产品运行不依赖测试宿主或本机目录。

- 不接管未知同名文件、服务、容器、网络或证书。完整 ID、inode、内容哈希、父目录、锁和配置清单共同决定归属；手工改动后不能假设卸载仍可安全执行。
- pending job、未知状态、锁被换位、停止失败或认证/TLS 回读失败应报告失败并保留证据。不得为使测试通过而跳过 TLS、放松认证、去掉版本/digest pin 或删除不明资源。
- 自启、ACME 续期和 VMess 同步分别管理；服务重启、自启成功和真实认证传输是不同证据。VMess/WS 为旧客户端兼容，上游已弃用，不作为新部署优先方案。
- M3 准备会影响目标引导，实际重装会毁损所选磁盘。公钥、目标磁盘确认、备份和救援入口按当前用户授权核验；只能在隔离 guest 验证破坏性步骤，不在开发宿主试运行。普通重启对失败／中断／未知 plan 一律拒绝；prepared 需逐字确认目标磁盘，cancelled 需回读恢复后的引导与 EFI，确认后再次核对状态。发布复核补丁与验证边界见 [发布记录](docs/release-20261031.md)。
- 测试账户、私钥、原始日志、数据库、VM 镜像和部署备份留在仓库外。提交前检查已跟踪、未跟踪及暂存文件；`.gitignore` 不能保护已经跟踪的秘密。

## 首次交付的历史证据索引

私有证据根可移至维护者自己的仓库外目录。本次本地根为 `/Users/terrysiu/ChatGPT/toolbox-private/evidence/`；下列为相对该根的路径，仅作定位，不把私有文件复制进 Git 或公开附件。

| 项目 | 私有证据 | 冻结源码 / 校验 |
| --- | --- | --- |
| B1 原生闭环 | `b1-native/guest-evidence.tar.gz`，包含首次安全拒绝、candidate-02 成功闭环及产品记录；`b1-native/qemu-acceleration.json` 确认 KVM enabled | 归档 SHA-256 `cf2ecb999f602af41f30c703d7b5d16ad55b063ece29d9cb66609b3dfdecf8a8` |
| B1 源码 | `b1-native/b1-native/candidate-02/native-record.json`、两个 probe 和 final-readback | module `48636afa070fe222ecb78fd0883a22af12004e03589e68893ff31ba4487e4423`；harness `ebe3eecc3d7949077b29b8931bd5a8ae73ab708c99dbd73cd069f8a4683b77d1` |
| B10 原生与 TERM 重验 | `b10-term-fix-ps9gbcd7/local-verification.json`；原生归档 `webssh-real-v2-termfix-private.tar.gz`，含私钥须保持私有；旧版诊断和修复对照单独保留 | module `be92b787359383f361361d2bf168768cc06407242fbe62cfb7dc3ba720f1217d`；原生归档 SHA-256 `9d84f8db8122e200f189445698eac8dd35c618bca32365e8106a8fe84094a0dc`；14 host、83 diagnostic、130 guest 文件逐个核对 |
| B10 镜像 | `webssh-registry-20261031/summary.json` 及 index/amd64 manifests | 三个固定镜像的 registry 字节哈希与 digest 匹配 |
| 发布程序离线测试 | `final-regression-v8-affected/deploy-cloudflare-test.py.log`；旧版记录保留 | 当前 Linux 28 PASS、0 跳过，含真实源码 release/build；历史 macOS 18 PASS/1 跳过不替代当前结果；没有真实 CF 写操作 |
| M3 三系统原生重装 | `../reinstall-astra/m3-three-targets-20261031.tar.gz`；`../reinstall-astra/reinstall-evidence/m3-native-summary.json`；95 个私有证据文件已逐个核对 | 归档 SHA-256 `2515c2d52c1620552a3a3ae240951d1d4e44c16b0548fe518fa5d0b4ee1db4a6`；各目标使用的 readback 版本哈希分别记录，产品模块相同 |
| 构建候选 | `final-build-v3/index.html`、`final-build-v3/worker/manifest.json`；Worker 四模块逐个核对 | 脚本 SHA-256 `eb7fdfa9c6ad729efe3206e67d0b73142f5fb39f280b86e06e910ae1b1c83e9a`；仅本地构建，未上线 |
| VMess / TLS 首次交付原生 | `root-native-candidate03-run1/completed.tar.gz`、解包后的 `tls-acme-fixture-native03-support/result.json` 与 `clock.restored.json`；host-clock.after 证明宿主时间未跳变 | 归档 SHA-256 `8a31041a6920dfe8b3eb849e7bd30d2410fe0842f7f057b3db0482298061732e`；模块与 harness 哈希见 acceptance JSON |
| 原 Python WebSSH | `webssh-python-native-candidate01/`、`webssh-native-candidate01-review-b92ytn6g/review-summary.json`；真实依赖版本已记录 | 归档 SHA-256 `94706e6dca25b442d0508e1892fc719a4a4c514a026804d5d1fc2a7b0f36392f` |
| VMess 独立真实协议 | `vmess-protocol-final-v2-tt2h5qig/summary.json`、`stdout.log`；8 项全过、19.598 秒，子进程清理完成 | summary SHA-256 `f2a73e35ec68ea0904ec83b4a2041bf3bafdc39c77a82ef27548c39e8e96e223` |
| HY2 / 菜单修复复验 | `hy2-openssl-compat-swr2z893/remote/summary-02.json`、`final-regression-v4-affected/`、`final-regression-v5-menu/` | 独立 HY2 58.799 秒通过，最终候选 HY2 再验 57.92 秒；菜单原始失败与错位 transcript 保留，补目标输入后真实 PTY 22.29 秒通过；没有增加 HY2 原生部署声明 |
| 全仓回归 | `final-regression-consolidated.json`；完整 v3 与最终 v8 原始日志分别保留 | 30 项全部取得有效 PASS：16 项复用 v3 未变传递依赖，14 项在最终 v8 补跑；0 跳过，源码前后不变、进程清理完成。不是同一源码单次 30 项通过；汇总 SHA-256 `77a66da81257993bc2e9baa8ae912403144c22c442b47831ae08b99c4ebd2e58` |

Codex 首次交付的源码修复、限定范围的原生验收、30 项回归与候选构建已完成，结果已关联到源码 commit 和文件哈希。Hermes 后续发布复核、M3 重启门禁补丁与 31 项默认检查的跨冻结运行结果另见发布记录。v1 环境拒绝、v2/v3/v6 超时，以及旧 HY2、菜单、VMess 信任夹具和监督器启动时序失败均保留。首次交付已按 Terry 指示合并并发布，未调整 DNS/托管平台。PR #2 依赖修复已经发布；当前 PR #3 的旧版 lsblk 修复、测试和已发布状态以本文顶部及本次修复记录为准，后续由 Hermes 按本手册维护。
