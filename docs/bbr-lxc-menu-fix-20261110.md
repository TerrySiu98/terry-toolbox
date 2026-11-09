# LXC BBR 与菜单对齐补丁

日期：2026-11-10。分支 `codex/bbr-lxc-menu-alignment`，基于已发布 PR #8 后的 `main`（`2a80b39`）。本候选尚未合并或部署；保留 Hermes 的 PR #8 生产发布记录与全部既有功能。

## 修复行为

宿主默认使用 cubic，不妨碍已获得 BBR 支持的 LXC 单独切换。上一版把容器中的未注册算法一律转为宿主处理，遗漏部分特权容器可通过 sysctl 请求宿主自动加载的路径。现容器或识别未知环境在独立两次 YES 后尝试一次 `sysctl -w net.ipv4.tcp_congestion_control=bbr`；明确说明可能请求宿主加载共享模块，失败也可能留下模块，不主动卸载。确认前后回读内核、环境、当前算法及注册列表，变化时取消。原始写入错误保留，随后同时回读默认算法和注册列表；写入失败、回读失败或结果不一致均不称成功，不自动重试。

已启用状态、已注册切换、普通服务器的当前内核真实模块核验与独立加载确认均保留。状态只读、不补装依赖；不换内核、不写持久配置、不执行 depmod 或重启、不改变 B16。缺少容器本地模块目录不能用于断言宿主永远无法提供 BBR。用户机器仅有 `reno cubic` 表明当前尚未注册，实际尝试仍取决于宿主内核和权限，未在该机器执行本候选。

## 菜单框架

截图中的主菜单和 M3 按行错位来自 emoji 在终端中的一格/两格差异，以及 VS16 宽度处理。主菜单、分类页、全部 15 个管理页、启动页和告别页共用集中绘制函数。TTY 非 dumb 时使用 CHA 固定右边框及双列起点，避免由图标占位决定边框位置；重定向或 dumb 输出保留纯文本 padding，不发送定位控制符。

每页重绘读取真实 TTY 窗口宽度，优先终端 fd 的 stty，再 tput/COLUMNS。长标题和正文按完整 UTF-8 字符折行，VS16 与前一字符保持同一行，保留全部编号与文字。双列不够时改单列，小于 20 列使用无框单列。NO_COLOR 只禁颜色；TOOLBOX_NO_CLEAR 只禁清屏，TTY 仍可用定位对齐。

范围限定为带框菜单和静态页。框外安装日志、依赖确认和 M3 目标选择仍由终端自然换行。未覆盖把模糊宽度框线设为双宽的特殊终端模式；一列终端无法容纳完整中文字符。没有新增 Python 或终端库依赖。

## LXC 官方实现依据

本节于 2026-11-10 按 Linux 主线源码与 LXC 官方实现核验。Linux 链接固定为 `v6.18`（版本边界另列），LXC 链接固定为 `3569f01ac6d0f326ffb8d1d457117bb8fdec527a`；发行版补丁、服务商限制及容器配置仍需以实际系统为准。本节是源码依据，不是本轮真实模块加载或容器验收记录。

**宿主默认使用 `cubic`，不等于宿主没有提供 BBR。** `tcp_congestion_control` 表示默认选择，`tcp_available_congestion_control` 列出已注册算法，两者不能混为一谈。后者省略尚未加载的模块，因此没有 `bbr` 也只能说明当前尚未注册。依据：[Linux sysctl 文档：已注册列表](https://github.com/torvalds/linux/blob/v6.18/Documentation/networking/ip-sysctl.rst#L387-L390)、[默认算法与新连接](https://github.com/torvalds/linux/blob/v6.18/Documentation/networking/ip-sysctl.rst#L412-L420)、[全局注册列表实现](https://github.com/torvalds/linux/blob/v6.18/net/ipv4/tcp_cong.c#L317-L333)。

**已有 BBR 时，LXC 可以选择它；隔离范围取决于内核与网络命名空间。** Linux 主线从 4.15 起把默认 TCP 拥塞控制改为每网络命名空间保存，见[引入提交 `6670e152`](https://github.com/torvalds/linux/commit/6670e152447732ba90626f36dfc015a13fbf150e)、[v4.14 的全局实现](https://github.com/torvalds/linux/blob/v4.14/net/ipv4/tcp_cong.c#L217-L241)与[v4.15 的命名空间实现](https://github.com/torvalds/linux/blob/v4.15/net/ipv4/tcp_cong.c#L214-L236)。当前主线的[默认算法设置函数](https://github.com/torvalds/linux/blob/v6.18/net/ipv4/tcp_cong.c#L280-L306)允许非初始网络命名空间选择非受限算法，而 [BBR 自身标记为 `TCP_CONG_NON_RESTRICTED`](https://github.com/torvalds/linux/blob/v6.18/net/ipv4/tcp_bbr.c#L1143-L1145)。写入仍受 [sysctl 文件模式](https://github.com/torvalds/linux/blob/v6.18/net/ipv4/sysctl_net_ipv4.c#L963-L975)、[网络命名空间权限与所有者](https://github.com/torvalds/linux/blob/v6.18/net/sysctl_net.c#L41-L70)、只读挂载及安全策略限制。LXC 的 [`lxc.net.0.type = none`](https://linuxcontainers.org/lxc/manpages/man5/lxc.container.conf.5.html)会共用宿主网络命名空间，因此不能无条件承诺只影响容器；更旧内核也不能套用 4.15+ 的隔离保证。发行版回移补丁另行核实。

**未注册时，`sysctl` 可能触发宿主自动加载，不是所有 LXC 都必须由宿主手动加载。** [sysctl 写处理函数](https://github.com/torvalds/linux/blob/v6.18/net/ipv4/sysctl_net_ipv4.c#L216-L233)调用默认算法设置函数，后者进入 [`tcp_ca_find_autoload`](https://github.com/torvalds/linux/blob/v6.18/net/ipv4/tcp_cong.c#L49-L61)。算法未注册且调用者通过 `capable(CAP_NET_ADMIN)` 时，内核会请求 `tcp_bbr`。这里的 [`capable()` 明确检查初始用户命名空间](https://github.com/torvalds/linux/blob/v6.18/kernel/capability.c#L414-L417)，并非只检查容器网络命名空间的能力。由此可知，只有子用户命名空间能力的普通非特权 LXC 不能经此路径触发加载；共享初始用户命名空间并保留有效 `CAP_NET_ADMIN` 的特权 LXC 则可能触发。[LXC 官方用户映射说明](https://github.com/lxc/lxc/blob/3569f01ac6d0f326ffb8d1d457117bb8fdec527a/doc/lxc.container.conf.sgml.in#L49-L68)说明了非特权容器内 root 与宿主权限的区别。

**丢弃容器的 `CAP_SYS_MODULE`，不能单独证明上述自动加载一定失败。** [LXC 默认配置](https://github.com/lxc/lxc/blob/3569f01ac6d0f326ffb8d1d457117bb8fdec527a/config/templates/common.conf.in#L12-L13)丢弃 `sys_module`，该列表没有丢弃 `net_admin`；[默认 seccomp 配置](https://github.com/lxc/lxc/blob/3569f01ac6d0f326ffb8d1d457117bb8fdec527a/config/templates/common.seccomp#L5-L9)禁止容器进程直接调用模块加载/卸载系统调用。内核自动加载采用另一条路径：[`request_module`](https://github.com/torvalds/linux/blob/v6.18/kernel/module/kmod.c#L131-L177)先经过模块请求安全钩子，再通过[用户态帮助进程调用 modprobe](https://github.com/torvalds/linux/blob/v6.18/kernel/module/kmod.c#L71-L104)；[帮助进程使用初始根目录与内核凭据](https://github.com/torvalds/linux/blob/v6.18/kernel/umh.c#L63-L111)，由[内核工作队列提供执行权限](https://github.com/torvalds/linux/blob/v6.18/kernel/umh.c#L143-L172)。依据这些调用关系，容器自身的模块系统调用禁令不等于宿主帮助进程也被禁止。是否最终成功，仍取决于宿主模块、加载策略和 LSM；例如 [SELinux 的模块请求权限检查](https://github.com/torvalds/linux/blob/v6.18/security/selinux/hooks.c#L4240-L4249)可以拒绝请求。

**容器内缺少 `/lib/modules/$(uname -r)`，不足以判断宿主绝无自动加载能力。** 上述帮助进程从宿主侧执行，容器可见的文件树不能代表宿主模块文件树。这是从内核调用路径得出的结论，不是对任意服务商环境的成功保证。因此本轮实现对容器或识别为 `unknown` 的环境，明确告知“可能请求宿主加载共享模块并尝试切换”，经独立双 YES 后只写入一次并回读；`unknown` 只表示识别不确定，不代表已拥有相关能力。共享模块可能在切换失败后仍已加载，不能把失败笼统报告为完全未改动。普通服务器的直接 `modprobe` 路径仍要求核验当前运行内核的模块文件；缺少本地模块树时，文案只说明本工具无法核验该直接加载路径。


## 验证与候选

最终冻结 **12/12 相关检查通过、0 跳过、源码无漂移、子孙进程清理完成**：语法、BBR、系统、系统复核、普通依赖、依赖入口、菜单入口、单文件构建、菜单、PTY 启动、离线部署及 Worker。BBR **127 个模拟场景**通过，覆盖拒绝/EOF、单次写入与 stdin 隔离、写入失败后状态、部分错误 stdout、回读不一致以及确认期间状态变化。

全部 19 个静态页在 19、32、40、67、80 列、C/C.UTF-8、普通输出/TTY 和现代/旧版 emoji 占位下进行独立 cell model 检查，共 **35 组矩阵**；另核对主菜单及工具页双列固定起点。窗口缩放真实 PTY 路径使用故意过时的 COLUMNS 验证尺寸优先级。独立审查 121 个静态框内字符串与所有共享绘制函数未发现阻塞。它是输出模型和 PTY 检查，不代表所有真实终端验收。

实际单文件再次通过同一 127 场景和最终菜单矩阵；15 个内嵌模块与源码逐字节一致、四个 Worker 模块与 manifest 完整一致。候选 `docs/index.html` 为 **747887 字节**，SHA-256 `ac70ac697df7543f2935b625a1f0b6f7de4fd524dad9bd03d42f26a2042e7bab`。机器可读来源见 [JSON](bbr-lxc-menu-fix-20261110.json)。

保留的首轮失败为新增 BBR scope 静态行超长，已拆行；缩放 fixture 原先把 redraw 重定向而绕过 TTY，已修正真实调用和 stale COLUMNS，最终 runner 与单文件重验通过。Python requests 未安装、urllib 根路径请求返回 403，均未算成功证据；后续 curl 系统 HTTPS 信任读取 `/toolbox.sh` 与 `/sha256` 一致，线上仍为 PR #8 的 740059 字节、SHA-256 `5a4630c91450d279889ddf83534af6b5cf34b091af13aefbf419655b50bee5cf`。

所有 BBR 模块、网络、包管理写入均由模拟与实体拒绝 guard 隔离，没有真实 modprobe/sysctl、内核修改或用户 LXC 验收。测试 scratch 已按本轮归属清理；回归日志及回退证据保留在仓库外。现有 Cloudflare Workers 托管保持；Hermes 后续依当前授权和 HANDOFF 流程复核、合并、备份、发布并精确回读。GitHub 合并不代表 Worker 上线。
