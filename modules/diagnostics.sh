#!/usr/bin/env bash
# Read-only diagnostics; missing utilities are reported rather than installed.
toolbox_diagnostics() {
    local line
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
