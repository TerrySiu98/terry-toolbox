#!/usr/bin/env bash
# Source-only system management module. No work is performed until toolbox_system.

_toolbox_system_error() { printf '%s\n' "$*" >&2; }
_toolbox_system_unimplemented() {
    _toolbox_system_error "$1：尚未实现；未执行任何更改。"
    return 1
}
_toolbox_system_root() {
    if [[ $(id -u) != 0 ]]; then _toolbox_system_error '此操作需要 root。'; return 1; fi
}
_toolbox_system_confirm() {
    local answer
    printf '%s\n' "$1" >&2
    printf '输入 YES 确认: ' >&2
    IFS= read -r answer && [[ $answer == YES ]] || { _toolbox_system_error '已取消。'; return 1; }
    printf '再次输入 YES 确认: ' >&2
    IFS= read -r answer && [[ $answer == YES ]] || { _toolbox_system_error '已取消。'; return 1; }
}
_toolbox_system_os() {
    # Parse OS metadata as data rather than executing shell from /etc/os-release.
    local detected
    detected=$(toolbox_network_detect_os) || return
    case "$detected" in
        alpine) printf 'alpine\n';;
        debian|ubuntu) printf 'debian\n';;
        *) _toolbox_system_error '不支持的系统'; return 1;;
    esac
}
_toolbox_system_deps() {
    local os
    _toolbox_system_root || return
    os=$(_toolbox_system_os) || return
    _toolbox_system_confirm "将通过 $os 系统包管理器安装 curl socat wget sudo nano iptables，可能触发依赖升级。" || return
    case "$os" in
        alpine) apk add --no-cache curl socat wget sudo nano iptables;;
        debian) apt-get install -y curl socat wget sudo nano iptables;;
        *) _toolbox_system_error '不支持的包管理器'; return 1;;
    esac
}
_toolbox_system_bbr() {
    local available current
    _toolbox_system_root || return
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control) || return
    case " $available " in *' bbr '*) ;; *) _toolbox_system_error '内核当前未提供 BBR；未改动。'; return 1;; esac
    current=$(sysctl -n net.ipv4.tcp_congestion_control) || return
    if [[ $current == bbr ]]; then printf 'BBR 已启用。\n'; return 0; fi
    _toolbox_system_confirm "将当前 TCP 拥塞控制从 $current 切换到 bbr（仅当前运行期，不写持久配置）；回滚: sysctl -w net.ipv4.tcp_congestion_control=$current" || return
    sysctl -w net.ipv4.tcp_congestion_control=bbr || return
    current=$(sysctl -n net.ipv4.tcp_congestion_control) || return
    [[ $current == bbr ]] || { _toolbox_system_error '设置后验证失败；请检查系统状态。'; return 1; }
    printf 'BBR 已启用（重启后可能失效）。\n'
}
_toolbox_system_docker() {
    local os
    _toolbox_system_root || return
    if command -v docker >/dev/null 2>&1; then
        _toolbox_system_error 'Docker 已存在；为保护现有服务和数据不进行安装或重配置。'; return 1
    fi
    os=$(_toolbox_system_os) || return
    _toolbox_system_confirm '将使用系统仓库安装 Docker；包安装可能启动服务或改变防火墙。不会删除容器和数据。' || return
    case "$os" in
        debian) apt-get install -y docker.io;;
        alpine) apk add --no-cache docker docker-cli-compose;;
        *) return 1;;
    esac || return
    command -v docker >/dev/null 2>&1 || { _toolbox_system_error '安装命令已完成但 docker 不可用；请检查包状态。'; return 1; }
    printf 'Docker 包已安装；服务状态及网络尚需单独检查。\n'
}
_toolbox_system_password() {
    _toolbox_system_root || return
    _toolbox_system_confirm '将交由 passwd 交互式修改 root 密码。请确保保留独立登录方式。' || return
    passwd root
}
_toolbox_system_reboot() {
    _toolbox_system_root || return
    _toolbox_system_confirm '将立即重启本机，中断所有服务和连接。' || return
    reboot
}
_toolbox_system_nodequality() {
    # Top-level file pinned, but upstream downloads and executes mutable scripts and
    # rootfs content. Pinning only this loader cannot make execution safe.
    _toolbox_system_error 'NodeQuality（不执行未经验证的远程脚本）：自动执行已禁用，未下载、未执行。'
    _toolbox_system_error '上游: https://github.com/LloydAsp/NodeQuality'
    _toolbox_system_error '固定版本: a92fca6c0067df29ddd03fdc2fee6f3000f64545'
    _toolbox_system_error 'NodeQuality.sh SHA-256: 4e1b25894cadf908ef61fb0d9ce874a75524c6dafc2ea26f0477107288e0c018'
    _toolbox_system_error '审阅地址: https://github.com/LloydAsp/NodeQuality/blob/a92fca6c0067df29ddd03fdc2fee6f3000f64545/NodeQuality.sh'
    _toolbox_system_error '固定文件下载地址: https://raw.githubusercontent.com/LloydAsp/NodeQuality/a92fca6c0067df29ddd03fdc2fee6f3000f64545/NodeQuality.sh'
    _toolbox_system_error '可手动下载到私人目录并用 sha256sum 对照上述摘要，再阅读源码；摘要只验证下载文件与该版本一致，并非安全认证。'
    _toolbox_system_error '警告：上游还会下载未固定内容、挂载目录、运行 chroot、测试硬件与网络并上传结果；校验主脚本不足以校验这些内容。'
    return 1
}
_toolbox_system_trace() {
    local destination label failed=0
    command -v traceroute >/dev/null 2>&1 || { _toolbox_system_error '缺少 traceroute；请先手动安装。'; return 1; }
    # Published example targets, not an assurance of current carrier ownership:
    # https://github.com/zhucaidan/mtr_trace (README, Beijing destinations).
    _toolbox_system_confirm '将发送 UDP traceroute 探测到北京电信 219.141.136.12、联通 202.106.50.1、移动 221.179.155.161；目标可能变更或不响应。输出是本机至目标的 IPv4 路由，不自动判断线路。' || return
    while IFS=' ' read -r label destination; do
        printf '\n=== %s (%s) ===\n' "$label" "$destination"
        if ! traceroute -n -m 20 -w 2 -q 1 "$destination"; then
            _toolbox_system_error "$label 探测命令失败。"
            failed=1
        fi
    done <<'TARGETS'
北京电信 219.141.136.12
北京联通 202.106.50.1
北京移动 221.179.155.161
TARGETS
    printf '\n提示：命令成功不代表目标可达；星号可能是丢包或设备不响应。\n'
    (( failed == 0 ))
}
# B6 stays fail-closed: no transaction/recovery implementation exists yet.
# A cooperating-process lock does not serialize external swapon/swapoff, mount
# changes or systemd. Checking a pathname's inode and active swap membership
# before cleanup does not make the check and subsequent action atomic; a race
# could remove or deactivate somebody else's resource. Effective systemd state
# also includes already-loaded units, generated units and drop-ins. A recovery
# journal must survive SIGKILL/power loss and distinguish our partial state
# without trusting replaceable paths; this has not been designed or tested.
_toolbox_system_swap() {
    _toolbox_system_error 'swap 暂时禁用：并发操作、进程中断/崩溃恢复及 systemd 实际配置冲突尚无法安全处理；未执行任何更改。'
    _toolbox_system_error '具体阻碍：私有锁不能阻止外部 swapon/swapoff、挂载或 systemd；清理前检查 inode 和活动 swap 后仍有竞态，不能安全断言资源归属。'
    _toolbox_system_error '尚未验证已加载的 systemd 单元、生成器和 drop-in 冲突；SIGKILL 或断电不会自动恢复，安全恢复日志和处理流程尚未实现。'
    _toolbox_system_error '此功能目前未创建或删除文件、未启用或关闭 swap，也未修改持久配置。'
    return 1
}
# MAIN_* distinguish primary menu actions from B* toolbox actions.
# B<number> and bare <number> both select toolbox-menu entries.
toolbox_system() {
    case "${1-}" in
        MAIN_BBR) _toolbox_system_bbr;;
        MAIN_DEPS) _toolbox_system_deps;;
        MAIN_REINSTALL) _toolbox_system_unimplemented '系统重装（缺少安全可验证的恢复方案）';;
        MAIN_REBOOT) _toolbox_system_reboot;;
        B1|1) _toolbox_system_docker;;
        B2|2) _toolbox_system_nodequality;;
        B4|4) _toolbox_system_unimplemented '哪吒安装';;
        B5|5) _toolbox_system_unimplemented 'XUI 安装';;
        B6|6) _toolbox_system_swap;;
        B7|7) _toolbox_system_unimplemented '流量限制（可能中断网络）';;
        B8|8) _toolbox_system_password;;
        B10|10) _toolbox_system_unimplemented 'WebSSH 安装（缺少安全认证和部署方案）';;
        B11|11) _toolbox_system_unimplemented '1Panel 安装';;
        B14|14) _toolbox_system_trace;;
        B15|15) _toolbox_system_unimplemented 'TG 流量通知';;
        B16|16) _toolbox_system_unimplemented '网络优化（未确定安全参数和回滚方案）';;
        B19|19) _toolbox_system_unimplemented 'Alpine 专用工具';;
        *) _toolbox_system_error "未知系统工具编号: ${1-}"; return 2;;
    esac
}
