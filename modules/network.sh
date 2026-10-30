#!/usr/bin/env bash
# Network operations for the toolbox. Sourcing this file only defines functions.
# Network installers refuse unsafe or unsupported environments.

# Print alpine/debian/ubuntu for supported os-release data; never source it as
# shell. An optional path permits isolated tests and offline inspection.
toolbox_network_detect_os() {
    if (( $# > 1 )); then
        printf '用法: toolbox_network_detect_os [os-release 文件]\n' >&2
        return 2
    fi
    local file=${1:-/etc/os-release} line key value id='' id_like='' word
    [[ -r $file && -f $file ]] || {
        printf '无法读取系统信息: %s\n' "$file" >&2
        return 1
    }
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*(ID|ID_LIKE)=(.*)$ ]] || continue
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        if [[ $value == \"*\" || $value == \'*\' ]]; then
            value=${value:1:${#value}-2}
        fi
        # Restrict values to simple identifiers and spaces; no expansions,
        # command substitution, escaped characters, or shell interpretation.
        [[ $value =~ ^[a-zA-Z0-9_.\ -]+$ ]] || continue
        if [[ $key == ID ]]; then id=${value,,}; else id_like=${value,,}; fi
    done < "$file"
    case $id in
        alpine|debian|ubuntu) printf '%s\n' "$id"; return 0 ;;
    esac
    # Avoid word splitting/globbing against the working directory.
    for word in alpine debian ubuntu; do
        if [[ " $id_like " == *" $word "* ]]; then
            printf '%s\n' "$word"
            return 0
        fi
    done
    printf '不支持或无法识别的 Linux 发行版\n' >&2
    return 1
}

# A4 is intentionally disabled: the previous installer could mistake another
# process for its listener, leave an exposed service on failure, and accept a
# certificate without checking its notBefore or requested hostname. Removing
# the installer also prevents direct calls from bypassing the menu refusal.
toolbox_network_hy2() {
    printf 'A4 暂时禁用：监听归属、失败后服务清理及证书有效期/域名尚未安全验证；未修改系统。\n' >&2
    printf '如曾运行旧版安装，请人工检查 toolbox-hy2.service、UDP 监听及 /etc/toolbox-hy2、/usr/local/bin/toolbox-hy2 和 systemd 单元文件；确认归属后再停止或清理。\n' >&2
    return 1
}

# A5 is disabled until fallback relay abuse, installation ownership/rollback,
# concurrent execution, and authenticated end-to-end connectivity are addressed.
# Remove the unsafe install helpers too: sourcing must not leave a bypass.
toolbox_network_xray() {
    printf 'A5 暂时禁用：REALITY 回退流量限制、安装并发及失败清理、目标 TLS 和认证连通性尚未安全验证；未修改系统。\n' >&2
    printf '旧版安装可能仍在运行并暴露回退流量；请人工检查 terry-toolbox-xray.service、TCP 监听、/opt/terry-toolbox-xray 和 systemd 单元文件，确认归属后再停止或清理。\n' >&2
    return 1
}

# resolvectl availability alone cannot establish exclusive control over DNS:
# DHCP, other links, routing domains, fallback resolvers and applications may
# still select other servers. Refuse rather than promise leak-free selection or
# overwrite resolver files managed by an unknown owner.
toolbox_network_dns() {
    if command -v resolvectl >/dev/null 2>&1; then
        printf '检测到 resolvectl，但无法安全确认所有 DNS 路由及管理权。\n' >&2
    else
        printf '未检测到 resolvectl，无法确认 DNS 配置由谁管理。\n' >&2
    fi
    printf 'B23 DNS 选择暂未启用：其他链路、DHCP、回退服务器或应用可能造成 DNS 泄漏；未修改任何配置或重启服务。\n' >&2
    return 1
}

toolbox_network() {
    if (( $# != 1 )); then
        printf '用法: toolbox_network <A1|A2|A3|A4|A5|B12|B23|B31>\n' >&2
        return 2
    fi
    local description
    case $1 in
        A1) description='Alpine HY2' ;;
        A2) description='Alpine Xray' ;;
        A3) description='TUIC' ;;
        A4) toolbox_network_hy2; return $? ;;
        A5) toolbox_network_xray; return $? ;;
        B12) description='TCP Brutal' ;;
        B23) toolbox_network_dns; return $? ;;
        B31) description='Relay 转发' ;;
        *) printf '未知网络操作: %s\n' "$1" >&2; return 2 ;;
    esac
    printf '%s (%s): 未实现，未执行任何安装或系统修改。\n' "$1" "$description" >&2
    printf '缺少可验证且不会覆盖已有服务的安全安装路径；请勿使用来源脚本直接执行。\n' >&2
    return 1
}
