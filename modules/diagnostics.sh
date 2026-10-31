#!/usr/bin/env bash
# Diagnostics read system state; missing utilities can be installed after consent.
# Remember only the source directory; dependency work remains lazy. Bundles
# already contain the core and must never look beside the downloaded script.
_TOOLBOX_DIAGNOSTICS_MODULE_DIR=''
if [[ ${TOOLBOX_BUNDLED:-0} != 1 ]]; then
    case ${BASH_SOURCE[0]} in
        */*) _TOOLBOX_DIAGNOSTICS_MODULE_DIR=${BASH_SOURCE[0]%/*};;
        *) _TOOLBOX_DIAGNOSTICS_MODULE_DIR=.;;
    esac
    _TOOLBOX_DIAGNOSTICS_MODULE_DIR=$(CDPATH= builtin cd -- "$_TOOLBOX_DIAGNOSTICS_MODULE_DIR" && builtin pwd -P) || _TOOLBOX_DIAGNOSTICS_MODULE_DIR=''
fi

toolbox_diagnostics() {
    local line dependency
    for dependency in uname uptime free df ip ss; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            if declare -F toolbox_require_commands >/dev/null || { [[ -n ${_TOOLBOX_DIAGNOSTICS_MODULE_DIR:-} ]] && source "$_TOOLBOX_DIAGNOSTICS_MODULE_DIR/dependencies.sh"; }; then
                toolbox_require_commands '服务器体检' uname uptime free df ip ss || printf '依赖未补齐，继续显示可读取的信息。\n' >&2
            fi
            break
        fi
    done
    printf '\n=== 系统 ===\n'
    uname -a || true
    if [[ -r /etc/os-release ]]; then
        while IFS= read -r line; do case "$line" in PRETTY_NAME=*) printf '%s\n' "$line";; esac; done < /etc/os-release
    fi
    printf '\n=== 运行时间 ===\n'
    if command -v uptime >/dev/null 2>&1; then uptime || true; else printf 'uptime 不可用\n'; fi
    printf '\n=== 内存 ===\n'
    if command -v free >/dev/null 2>&1; then free -h || free || true
    elif [[ -r /proc/meminfo ]]; then while IFS= read -r line; do case "$line" in MemTotal:*|MemAvailable:*|SwapTotal:*|SwapFree:*) printf '%s\n' "$line";; esac; done < /proc/meminfo
    else printf '不可用\n'; fi
    printf '\n=== 磁盘 ===\n'
    df -h || true
    printf '\n=== 网络 ===\n'
    if command -v ip >/dev/null 2>&1; then ip -brief address || ip address || true
    else printf 'ip 命令不可用\n'; fi
    printf '\n=== 监听端口 ===\n'
    if command -v ss >/dev/null 2>&1; then ss -lntup || true
    elif command -v netstat >/dev/null 2>&1; then netstat -lntup || true
    else printf 'ss / netstat 不可用\n'; fi
}
