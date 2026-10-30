#!/usr/bin/env bash
# Network operations for the toolbox. Sourcing this file only defines functions.
# Network installers refuse unsafe or unsupported environments.
#
# A1/A2 只走「Alpine + OpenRC + 固定官方发布产物 + SHA-256 白名单」这一条路径：
# 不执行远程脚本、不改 apk 仓库、不碰防火墙；写盘前拒绝不确定状态，写盘后失败
# 一律回滚。端口归属只认本机事实（pidfile、/proc/<pid>/exe、内核 comm）。
# A5 是同一套 Xray 产物的 Debian + systemd 路径：回落目标必须显式给出并当场验证
# TLS 1.3/h2/证书覆盖，回退流量双向限速，写盘按清单回滚，安装后跑双向认证探针。
# B23 只碰 systemd-resolved，且要求 /etc/resolv.conf 确由它以 stub 接管，
# 其他解析器一律 fail closed；验证失败回滚并列出泄漏面。

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

# A4 的安装逻辑在 modules/hy2.sh（独立模块，菜单直接调用）。这里转发，让
# `toolbox_network A4 …` 与菜单等价；模块没加载时仍 fail closed，不假装可用。
toolbox_network_hy2() {
    if declare -F toolbox_hy2 >/dev/null; then
        toolbox_hy2 "$@"
        return
    fi
    printf 'A4 暂时不可用：modules/hy2.sh 未加载（缺模块）；未修改系统。\n' >&2
    return 1
}

# A5 已启用：回退限速、目标 TLS 1.3/h2 能力校验、flock 串行化、清单化回滚、
# 本机 xray 客户端双向认证探针都在安装路径内。别名让直接调用也可用（分发在
# toolbox_network 里，避免自递归）。
toolbox_network_xray() { toolbox_network A5 "$@" ; }

# ================================================================ 公共设施
#
# B12/A3/B31 共用约定：
#   - sourcing 只定义函数；所有外部命令都在调用时执行。
#   - 只认本机事实（ID=debian、systemd、ss 监听表、MainPID），不猜「看起来像
#     我们的服务」。写盘前拒绝一切不确定状态，写盘后失败一律回滚。
#   - 安装要两次确认（YES + 关键词），卸载一次。
#   - 只删自己写入的绝对路径；同名但内容不符的文件视为他人所有，不覆盖。

net_err() { printf '%s\n' "$*" >&2; }
net_die() { net_err "$*"; return 1; }

# 常量声明成「已定义就不覆盖」：同一 shell 里重复 source 时，函数会被重新定义
# （调用方靠这个刷新实现），而 readonly 变量二次赋值会报错并中止加载。
net_const() { # name value
    [[ -n ${!1+set} ]] && return 0
    printf -v "$1" '%s' "$2"
    readonly "$1"
}

net_require_root() {
    [[ ${TOOLBOX_NET_UID:-${EUID:-$(id -u)}} -eq 0 ]] \
        || net_die '需要 root 权限运行。'
}

# 只接受 ID=debian：衍生版的内核头文件与 DKMS 行为不同，A4 的约定保持一致。
net_require_debian() {
    local file=${TOOLBOX_NET_OS_RELEASE:-/etc/os-release} id=''
    [[ -r $file ]] || net_die "无法读取 $file，不能确认发行版。"
    toolbox_network_detect_os "$file" >/dev/null 2>&1 \
        || net_die "不支持的发行版（$file 无法识别为 debian/ubuntu/alpine）。"
    id=$(sed -n 's/^ID=//p' "$file" 2>/dev/null | head -n1)
    id=${id//\"/}; id=${id//\'/}
    [[ ${id,,} == debian ]] \
        || net_die "仅支持 Debian（当前 ID=${id:-未知}）；不支持 Alpine/Ubuntu/衍生版。"
}

net_require_systemd() {
    local run_dir=${TOOLBOX_NET_SYSTEMD_RUN:-/run/systemd/system}
    command -v systemctl >/dev/null 2>&1 || net_die '未找到 systemctl，本机不是 systemd 系统。'
    [[ -d $run_dir ]] || net_die 'systemd 未作为 init 运行（缺少 /run/systemd/system）。'
}

# 容器内 modprobe/sysctl 写的是宿主内核，且通常没有匹配的内核头文件。
net_require_not_container() {
    local out='' f
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        out=$(systemd-detect-virt --container 2>/dev/null) || out=''
        if [[ -n $out && $out != none ]]; then
            net_die "检测到容器环境（$out）：内核模块需在宿主机安装。"
            return 1
        fi
        return 0
    fi
    for f in /.dockerenv /run/.containerenv; do
        if [[ -e $f ]]; then
            net_die '检测到容器环境：内核模块需在宿主机安装。'
            return 1
        fi
    done
}

net_require_cmds() {
    local missing=() c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    (( ${#missing[@]} == 0 )) || net_die "缺少必需命令：${missing[*]}"
}

net_valid_port() {
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    (( $1 <= 65535 ))
}

net_valid_hostname() {
    [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

# 目标主机：IPv4 或域名。IPv6 需要 socat 的方括号写法，暂不承诺。
net_valid_target_host() {
    local h=$1
    [[ $h =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})$ ]] || return 1
    [[ $h != *..* && $h != .* && $h != *. ]] || return 1
}

net_valid_uuid() {
    [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# 两次确认：先 YES，再输入关键词。任一步不符都在写盘前退出。
net_confirm_twice() {
    local word=$1 first second
    printf '确认执行？输入 YES 继续：'
    IFS= read -r first || return 1
    [[ ${first^^} == YES ]] || { net_err '已取消，未修改系统。'; return 1; }
    printf '再次确认（输入 %s）：' "$word"
    if ! IFS= read -r second; then
        net_err '没有收到二次确认，已取消；未修改系统。'
        return 1
    fi
    [[ ${second^^} == "$word" ]] \
        || { net_err "二次确认不匹配（需要 $word），已取消；未修改系统。"; return 1; }
}

net_confirm_once() {
    local answer
    printf '确认执行？输入 YES：'
    IFS= read -r answer || return 1
    [[ ${answer^^} == YES ]] || { net_err '已取消。'; return 1; }
}

net_lock() {
    local file="${TOOLBOX_NET_LOCK_DIR:-/run}/terry-toolbox-$1.lock"
    exec 9>"$file" || { net_die "无法创建锁文件 $file"; return 1; }
    flock -n 9 || { net_die '另一个安装/卸载正在进行，稍后再试。'; return 1; }
}

# 子菜单：没有参数时（菜单入口）读一个编号。
net_submenu() {
    local title=$1 c
    printf '%s\n 1 安装\n 2 卸载\n 3 状态\n请输入编号：' "$title" >&2
    IFS= read -r c || return 1
    case $c in
        1) printf 'install\n' ;;
        2) printf 'uninstall\n' ;;
        3) printf 'status\n' ;;
        *) net_err '无效选项。'; return 1 ;;
    esac
}

# ---------------------------------------------------------------- 监听事实

# 打印本机在该协议/端口上的监听行（来自 ss，不看「谁应该监听」）。
net_port_lines() {
    local proto=$1 port=$2 line field
    local flags=(-lunH)
    [[ $proto == tcp ]] && flags=(-ltnH)
    while IFS= read -r line; do
        [[ $line =~ ^(LISTEN|UNCONN|ESTAB) ]] || continue
        read -r -a _net_f <<< "$line"
        field=${_net_f[3]:-}
        [[ ${field##*:} == "$port" ]] || continue
        printf '%s\n' "$line"
    done < <(ss "${flags[@]}" 2>/dev/null)
}

net_port_busy() { [[ -n $(net_port_lines "$1" "$2") ]]; }

# 端口是否由指定单元的进程持有：MainPID 相等，或 /proc/<pid>/exe 就是我们的
# 可执行文件。两者都不成立就算「不是我们的」。
net_port_owned_by() {
    local proto=$1 port=$2 bin=$3 unit=${4:-} line pid exe want main=''
    want=$(readlink -f -- "$bin" 2>/dev/null) || want=$bin
    [[ -n $unit ]] && main=$(systemctl show -p MainPID --value "$unit" 2>/dev/null)
    [[ $main =~ ^[0-9]+$ ]] || main=''
    while IFS= read -r line; do
        while IFS= read -r pid; do
            [[ -n $pid ]] || continue
            [[ -n $main && $pid == "$main" ]] && return 0
            exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || exe=''
            [[ -n $exe && $exe == "$want" ]] && return 0
        done < <(grep -o 'pid=[0-9]*' <<< "$line" | cut -d= -f2)
    done < <(ss -lunpH 2>/dev/null; ss -ltnpH 2>/dev/null)
    return 1
}

# 单元归属：absent / ours / foreign。
net_unit_state() {
    local unit=$1 bin=$2
    [[ -e $unit ]] || { printf 'absent\n'; return 0; }
    if grep -qF "ExecStart=$bin" "$unit" 2>/dev/null; then
        printf 'ours\n'
    else
        printf 'foreign\n'
    fi
}

net_wait_active() {
    local unit=$1 i
    for ((i = 0; i < 20; i++)); do
        systemctl is-active --quiet "$unit" 2>/dev/null && return 0
        sleep 0.5
    done
    return 1
}

net_wait_owned() {
    local proto=$1 port=$2 bin=$3 unit=$4 i
    for ((i = 0; i < 20; i++)); do
        net_port_owned_by "$proto" "$port" "$bin" "$unit" && return 0
        sleep 0.5
    done
    return 1
}

# ---------------------------------------------------------------- 证书校验

# 与 A4 同一套判据：可读、非空、PEM 可解析、公私钥配对、未过期未生效、
# 证书包含目标主机名。服务启动时的错误远少于这里的主动检查。
net_check_cert() {
    local cert=$1 key=$2 host=$3 now start start_epoch cpub kpub
    [[ -f $cert && -r $cert ]] || { net_die "证书不存在或不可读：$cert"; return 1; }
    [[ -f $key && -r $key ]] || { net_die "私钥不存在或不可读：$key"; return 1; }
    (( $(stat -c %s -- "$cert") > 0 )) || { net_die "证书文件为空：$cert"; return 1; }
    (( $(stat -c %s -- "$key") > 0 )) || { net_die "私钥文件为空：$key"; return 1; }

    openssl x509 -in "$cert" -noout 2>/dev/null || { net_die "不是有效的 PEM 证书：$cert"; return 1; }
    openssl pkey -in "$key" -noout 2>/dev/null || { net_die "不是有效的 PEM 私钥：$key"; return 1; }

    cpub=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null) || { net_die '证书公钥解析失败'; return 1; }
    kpub=$(openssl pkey -in "$key" -pubout 2>/dev/null) || { net_die '私钥公钥解析失败'; return 1; }
    [[ $cpub == "$kpub" ]] || { net_die '证书与私钥不配对。'; return 1; }

    now=$(date +%s)
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 \
        || { net_die '证书已过期（notAfter 已过）。'; return 1; }
    start=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null | cut -d= -f2)
    if [[ -n $start ]]; then
        start_epoch=$(date -d "$start" +%s 2>/dev/null) || start_epoch=0
        (( start_epoch <= now )) || { net_die "证书尚未生效（notBefore=$start）。"; return 1; }
    fi
    if ! openssl x509 -in "$cert" -noout -checkend $((7 * 86400)) >/dev/null 2>&1; then
        net_err '注意：证书将在 7 天内过期，安装后请及时续期。'
    fi
    openssl x509 -in "$cert" -noout -checkhost "$host" 2>/dev/null | grep -q 'does match' \
        || { net_die "证书不包含主机名 $host（SAN/CN 不匹配）。"; return 1; }
}

# 证书链能否被本机信任库验证，决定自签证书要不要在客户端链接里带 insecure。
# 判定只看本机 CA 文件；读不到信任库时按「不信任」处理（宁多带一个 insecure）。
# TOOLBOX_NET_CAFILE / TOOLBOX_NET_CAPATH 供隔离测试注入。
net_tls_trusted() {
    local cert=$1 cafile=${TOOLBOX_NET_CAFILE:-/etc/ssl/certs/ca-certificates.crt}
    local capath=${TOOLBOX_NET_CAPATH:-/etc/ssl/certs}
    if [[ -n $cafile && -r $cafile ]]; then
        openssl verify -CAfile "$cafile" "$cert" >/dev/null 2>&1
        return
    fi
    [[ -n $capath && -d $capath ]] || return 1
    openssl verify -CApath "$capath" "$cert" >/dev/null 2>&1
}

# ================================================================ B12 TCP Brutal
#
# 固定上游 HyNetworks/tcp-brutal v2.0.1 的官方 DKMS 源码包（SHA-256 白名单），
# 自己 dkms 编译、安装、载入，并写 modules-load.d 与 sysctl.d 持久化。
# 不用官方一键脚本，也不从 latest 解析版本。
#
# v2 起 brutal 仍是内核拥塞控制算法（tcp_congestion_ops.name = "brutal"），
# 全局默认值改成本算法会影响本机所有新 TCP 连接，因此安装必须两次确认。

net_const BRUTAL_VERSION '2.0.1'
net_const BRUTAL_DKMS_NAME 'tcp-brutal'
net_const BRUTAL_MODULE 'brutal'
net_const BRUTAL_SHA256 '64a2778f308f7684cb5a137d578bc071e373960a3b9b79f9de015b84b29a7299'
net_const BRUTAL_MIN_MAJOR 5
net_const BRUTAL_MIN_MINOR 10

net_brutal_etc()    { printf '%s/terry-toolbox-brutal\n' "${TOOLBOX_NET_ETC:-/etc}"; }
net_brutal_modload() { printf '%s/%s.conf\n' "${TOOLBOX_NET_MODLOAD_DIR:-/etc/modules-load.d}" "$BRUTAL_MODULE"; }
net_brutal_sysctl() { printf '%s/terry-toolbox-brutal.conf\n' "${TOOLBOX_NET_SYSCTL_DIR:-/etc/sysctl.d}"; }
net_brutal_bin()    { printf '%s/brutalctl\n' "${TOOLBOX_NET_BIN_DIR:-/usr/local/bin}"; }
net_brutal_dkmsdir() { printf '%s/%s\n' "${TOOLBOX_NET_DKMS_DIR:-/var/lib/dkms}" "$BRUTAL_DKMS_NAME"; }
net_brutal_srcdir() { printf '%s/%s-%s\n' "${TOOLBOX_NET_SRC_DIR:-/usr/src}" "$BRUTAL_DKMS_NAME" "$BRUTAL_VERSION"; }

net_brutal_sysctl_body() {
    printf 'net.ipv4.tcp_congestion_control = %s\n' "$BRUTAL_MODULE"
}

net_kernel_release() { printf '%s\n' "${TOOLBOX_NET_KERNEL_RELEASE:-$(uname -r)}"; }

net_brutal_require_kernel() {
    local rel major minor
    rel=$(net_kernel_release)
    [[ $rel =~ ^([0-9]+)\.([0-9]+) ]] || { net_die "无法解析内核版本：$rel"; return 1; }
    major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
    if (( major < BRUTAL_MIN_MAJOR || (major == BRUTAL_MIN_MAJOR && minor < BRUTAL_MIN_MINOR) )); then
        net_die "内核 $rel 过旧：TCP Brutal v2 需要 5.10 以上。"
        return 1
    fi
    local build="${TOOLBOX_NET_MODDIR:-/lib/modules/$rel/build}"
    [[ -d $build ]] || net_die "缺少内核头文件（$build 不存在），无法编译模块。"
}

net_brutal_require_toolchain() {
    net_require_cmds dkms make cc sha256sum curl flock mktemp modprobe sysctl lsmod tar depmod sed || return 1
    net_require_cmds ip || true
}

net_current_cc() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | tr -d '[:space:]'
}

net_available_cc() {
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null
}

net_cc_supported() {
    local cc=$1 word
    for word in $(net_available_cc); do
        [[ $word == "$cc" ]] && return 0
    done
    return 1
}

net_brutal_module_loaded() {
    lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$BRUTAL_MODULE"
}

# 写盘前的冲突判定。任何一项为真都停下来，宁可让用户先卸载再装。
net_brutal_conflicts() {
    local etc modload sysctl_file dkms_dir bin rc=0 want
    etc=$(net_brutal_etc); modload=$(net_brutal_modload)
    sysctl_file=$(net_brutal_sysctl); dkms_dir=$(net_brutal_dkmsdir); bin=$(net_brutal_bin)
    want=$(net_brutal_sysctl_body)

    if [[ -d $etc ]]; then
        net_err "已存在 $etc：看起来是上次留下的本模块安装，请先卸载（B12 → 2）。"
        rc=1
    fi
    if [[ -e $modload ]]; then
        if [[ "$(tr -d '[:space:]' < "$modload" 2>/dev/null)" == "$BRUTAL_MODULE" ]]; then
            net_err "已存在 $modload（本模块的残留），请先卸载。"
        else
            net_err "已存在 $modload 且内容不同（他人安装），不覆盖；请人工确认。"
        fi
        rc=1
    fi
    if [[ -e $sysctl_file ]]; then
        if [[ "$(cat "$sysctl_file" 2>/dev/null)" == "$want" ]]; then
            net_err "已存在 $sysctl_file（本模块的残留），请先卸载。"
        else
            net_err "已存在 $sysctl_file 且内容不同（他人安装），不覆盖；请人工确认。"
        fi
        rc=1
    fi
    if [[ -d $dkms_dir ]]; then
        net_err "DKMS 中已有 $BRUTAL_DKMS_NAME（$dkms_dir）：请先 dkms remove 或人工确认归属。"
        rc=1
    fi
    if [[ -e $bin ]]; then
        net_err "已存在 $bin：不是本模块安装的，不覆盖。"
        rc=1
    fi
    if (( rc == 0 )) && net_brutal_module_loaded; then
        # 卸载后模块可能因仍有连接而被内核留到重启；文件已清干净时重装无害，
        # modprobe 对已载入模块是空操作，所以这里只提示不阻断。
        net_err "注意：内核里已载入 $BRUTAL_MODULE 模块但没有任何本模块文件（可能是上次卸载的残留）。"
        net_err '将继续安装；若该模块其实是别人装的，请先人工确认。'
    fi
    return $rc
}

net_brutal_fetch() {
    local tmp=$1 tarball="$1/tcp-brutal.dkms.tar.gz" url actual
    url="https://github.com/HyNetworks/tcp-brutal/releases/download/v${BRUTAL_VERSION}/tcp-brutal.dkms.tar.gz"
    url=${TOOLBOX_NET_BRUTAL_URL:-$url}
    if [[ -n ${TOOLBOX_NET_BRUTAL_TGZ:-} ]]; then
        cp -- "$TOOLBOX_NET_BRUTAL_TGZ" "$tarball" || { net_die '复制本地源码包失败'; return 1; }
    else
        net_err "下载官方 DKMS 源码包：$url"
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \
            -o "$tarball" "$url" || { net_die '下载失败（网络或 GitHub 不可达）。'; return 1; }
    fi
    actual=$(sha256sum -- "$tarball" | cut -d' ' -f1)
    [[ $actual == "${TOOLBOX_NET_BRUTAL_SHA256:-$BRUTAL_SHA256}" ]] \
        || { net_die "SHA-256 不匹配：期望 ${TOOLBOX_NET_BRUTAL_SHA256:-$BRUTAL_SHA256}，实际 $actual。"; return 1; }
    tar -C "$tmp" -xzf "$tarball" || { net_die '解压失败。'; return 1; }
    [[ -f $tmp/dkms_source_tree/dkms.conf && -f $tmp/dkms_source_tree/Makefile ]] \
        || { net_die '源码包结构不符（缺 dkms.conf 或 Makefile）。'; return 1; }
    grep -qx "PACKAGE_NAME=\"$BRUTAL_DKMS_NAME\"" "$tmp/dkms_source_tree/dkms.conf" \
        || { net_die 'dkms.conf 的包名与预期不符。'; return 1; }
    grep -qx "PACKAGE_VERSION=\"$BRUTAL_VERSION\"" "$tmp/dkms_source_tree/dkms.conf" \
        || { net_die 'dkms.conf 的版本与预期不符。'; return 1; }
}

net_brutal_rollback() {
    local prev=${1:-} etc modload sysctl_file src dkms_dir bin
    etc=$(net_brutal_etc); modload=$(net_brutal_modload); sysctl_file=$(net_brutal_sysctl)
    src=$(net_brutal_srcdir); dkms_dir=$(net_brutal_dkmsdir); bin=$(net_brutal_bin)
    net_err '--- 开始回滚 ---'
    rmmod "$BRUTAL_MODULE" >/dev/null 2>&1 || true
    dkms remove "$BRUTAL_DKMS_NAME/$BRUTAL_VERSION" --all >/dev/null 2>&1 || true
    rm -rf -- "$src" "$dkms_dir"
    rm -f -- "$bin" "$modload" "$sysctl_file"
    if [[ -f $etc/meta ]]; then rm -rf -- "$etc"; else [[ -d $etc ]] && rm -rf -- "$etc"; fi
    if [[ -n $prev ]] && net_cc_supported "$prev"; then
        sysctl -w "net.ipv4.tcp_congestion_control=$prev" >/dev/null 2>&1 || true
    fi
    depmod -a "$(net_kernel_release)" >/dev/null 2>&1 || true
    net_err '已撤销本次写入（模块、DKMS 记录、drop-in、brutalctl、sysctl 默认值）。'
}

_net_brutal_install() {
    local tmp prev rel bin etc
    net_require_root || return 1
    net_require_debian || return 1
    net_require_systemd || return 1
    net_require_not_container || return 1
    net_brutal_require_kernel || return 1
    net_brutal_require_toolchain || return 1
    net_brutal_conflicts || return 1

    rel=$(net_kernel_release)
    prev=$(net_current_cc)
    [[ -n $prev ]] || prev='cubic'

    printf '即将安装 TCP Brutal 内核模块（全局拥塞控制算法）：\n'
    printf '  版本    : v%s（官方 DKMS 源码包，安装前校验 SHA-256）\n' "$BRUTAL_VERSION"
    printf '  内核    : %s（模块只为当前内核编译）\n' "$rel"
    printf '  默认算法: %s → %s（对本机所有新 TCP 连接生效）\n' "$prev" "$BRUTAL_MODULE"
    printf '  持久化  : %s、%s\n' "$(net_brutal_modload)" "$(net_brutal_sysctl)"
    printf '  工具    : %s（brutalctl，v2 的按目标限速规则）\n' "$(net_brutal_bin)"
    printf '  附带    : 会先确认 dkms/make/cc/内核头文件是否齐备\n'
    printf '  回滚    : 任一步失败即 rmmod、dkms remove 并恢复 %s\n' "$prev"
    printf '注意：升级内核后需要重新 dkms 编译（dkms 会自动尝试）。\n'
    net_confirm_twice BRUTAL || return 1

    net_lock brutal || return 1
    tmp=$(mktemp -d) || { net_die '无法创建临时目录'; return 1; }

    net_err '--- 开始写入 ---'
    net_brutal_fetch "$tmp" || { rm -rf -- "$tmp"; net_brutal_rollback "$prev"; return 1; }

    etc=$(net_brutal_etc); bin=$(net_brutal_bin)

    # 先编译再落盘：编译失败时系统里还没有任何改动。
    make -C "$tmp/dkms_source_tree/tools" >/dev/null 2>&1 \
        || { rm -rf -- "$tmp"; net_brutal_rollback "$prev"; net_die 'brutalctl 编译失败。'; return 1; }
    [[ -x $tmp/dkms_source_tree/tools/brutalctl ]] \
        || { rm -rf -- "$tmp"; net_brutal_rollback "$prev"; net_die 'brutalctl 未生成。'; return 1; }

    install -d -m 0755 "$(net_brutal_srcdir)" \
        && cp -a "$tmp/dkms_source_tree/." "$(net_brutal_srcdir)/" \
        || { rm -rf -- "$tmp"; net_brutal_rollback "$prev"; return 1; }

    dkms add "$(net_brutal_srcdir)" >/dev/null 2>&1 \
        || { rm -rf -- "$tmp"; net_brutal_rollback "$prev"; net_die 'dkms add 失败。'; return 1; }
    dkms build "$BRUTAL_DKMS_NAME/$BRUTAL_VERSION" -k "$rel" >/dev/null 2>&1 \
        || { rm -rf -- "$tmp"; net_brutal_rollback "$prev"; net_die '模块编译失败（检查内核头文件与 dkms 日志）。'; return 1; }
    dkms install "$BRUTAL_DKMS_NAME/$BRUTAL_VERSION" -k "$rel" --force >/dev/null 2>&1 \
        || { rm -rf -- "$tmp"; net_brutal_rollback "$prev"; net_die 'dkms install 失败。'; return 1; }

    install -d -m 0755 "$etc" && install -d -m 0755 "$(dirname -- "$bin")" \
        && install -m 0755 "$tmp/dkms_source_tree/tools/brutalctl" "$bin" \
        || { rm -rf -- "$tmp"; net_brutal_rollback "$prev"; return 1; }

    install -d -m 0755 "$(dirname -- "$(net_brutal_modload)")" \
        && printf '%s\n' "$BRUTAL_MODULE" > "$(net_brutal_modload)" \
        || { rm -rf -- "$tmp"; net_brutal_rollback "$prev"; return 1; }
    install -d -m 0755 "$(dirname -- "$(net_brutal_sysctl)")" \
        && net_brutal_sysctl_body > "$(net_brutal_sysctl)" && chmod 0644 "$(net_brutal_sysctl)" \
        || { rm -rf -- "$tmp"; net_brutal_rollback "$prev"; return 1; }

    if ! modprobe "$BRUTAL_MODULE"; then
        rm -rf -- "$tmp"; net_brutal_rollback "$prev"; net_die 'modprobe 失败。'; return 1
    fi
    if ! net_brutal_module_loaded; then
        rm -rf -- "$tmp"; net_brutal_rollback "$prev"; net_die '模块未出现在内核中。'; return 1
    fi
    if ! net_cc_supported "$BRUTAL_MODULE"; then
        rm -rf -- "$tmp"; net_brutal_rollback "$prev"
        net_die '内核未注册 brutal 拥塞控制算法（tcp_available_congestion_control 无此项）。'
        return 1
    fi
    if ! sysctl -w "net.ipv4.tcp_congestion_control=$BRUTAL_MODULE" >/dev/null 2>&1; then
        rm -rf -- "$tmp"; net_brutal_rollback "$prev"; net_die '写 sysctl 默认拥塞控制失败。'; return 1
    fi
    # 回读：sysctl 真的生效，不是只写了文件。
    if [[ $(net_current_cc) != "$BRUTAL_MODULE" ]]; then
        rm -rf -- "$tmp"; net_brutal_rollback "$prev"
        net_die "回读失败：当前默认算法仍是 $(net_current_cc)。"
        return 1
    fi

    printf '%s|%s|%s\n' "$prev" "$BRUTAL_VERSION" "$rel" > "$etc/meta"
    chmod 0600 "$etc/meta"
    rm -rf -- "$tmp"

    printf '\n安装完成。\n'
    printf '[已验证] 模块已载入，tcp_available_congestion_control 含 %s，默认算法为 %s\n' \
        "$BRUTAL_MODULE" "$(net_current_cc)"
    printf '[已验证] 开机自动载入：%s\n' "$(net_brutal_modload)"
    printf '\n仍需人工处理：\n'
    printf '  - 对具体目标限速（v2 用规则，不改全局）：%s add 203.0.113.5/32 100\n' "$(net_brutal_bin)"
    printf '  - 规则不随重启恢复，需要时自行写进开机脚本；brutalctl list 可查看\n'
    printf '  - 升级内核后确认 dkms 已为新内核编译；卸载：B12 → 2\n'
}

_net_brutal_uninstall() {
    local etc modload sysctl_file src dkms_dir bin prev='' version='' rel=''
    net_require_root || return 1
    net_require_systemd || return 1
    etc=$(net_brutal_etc); modload=$(net_brutal_modload); sysctl_file=$(net_brutal_sysctl)
    src=$(net_brutal_srcdir); dkms_dir=$(net_brutal_dkmsdir); bin=$(net_brutal_bin)

    if [[ ! -d $etc && ! -e $modload && ! -e $bin && ! -d $dkms_dir ]]; then
        net_die '没有找到本模块的安装。'
        return 1
    fi
    if [[ ! -d $etc ]]; then
        net_die "缺少 $etc：不像是本模块的安装，未删除；请人工确认。"
        return 1
    fi
    if [[ -f $etc/meta ]]; then
        IFS='|' read -r prev version rel < "$etc/meta" || true
    fi
    [[ -n $prev ]] || prev='cubic'

    printf '将停止并删除：\n  %s\n  %s\n  %s\n  %s\n  %s\n  %s\n' \
        "$modload" "$sysctl_file" "$bin" "$dkms_dir" "$src" "$etc"
    printf '并把默认拥塞控制恢复为 %s。\n' "$prev"
    printf '注意：会先 brutalctl flush，清掉本工具加的规则和路由（含手工 add 的）。\n'
    net_confirm_once || return 1
    net_lock brutal || return 1

    # 规则和 brutalctl 路由不在文件里，先清掉再卸模块，避免留下孤儿路由。
    if [[ -x $bin ]]; then
        "$bin" flush >/dev/null 2>&1 || net_err '提示：brutalctl flush 未成功，请检查是否有残留路由（ip route show proto 233）。'
    fi
    if net_cc_supported "$prev" && [[ $(net_current_cc) != "$prev" ]]; then
        sysctl -w "net.ipv4.tcp_congestion_control=$prev" >/dev/null 2>&1 \
            || net_err "警告：恢复 $prev 失败，请手工 sysctl。"
    fi
    local i
    for ((i = 0; i < 5; i++)); do
        rmmod "$BRUTAL_MODULE" 2>/dev/null && break
        sleep 1
    done
    if net_brutal_module_loaded; then
        net_err '注意：rmmod 失败（仍有连接在用），模块会保留到重启；开机载入已移除。'
    fi
    rm -f -- "$modload" "$sysctl_file" "$bin"
    dkms remove "$BRUTAL_DKMS_NAME/$BRUTAL_VERSION" --all >/dev/null 2>&1 || true
    [[ -n $version ]] && dkms remove "$BRUTAL_DKMS_NAME/$version" --all >/dev/null 2>&1 || true
    rm -rf -- "$src" "$dkms_dir" "$etc"
    depmod -a "$(net_kernel_release)" >/dev/null 2>&1 || true
    printf '已卸载。\n'
}

net_brutal_status() {
    local etc modload sysctl_file bin prev='' version='' rel=''
    etc=$(net_brutal_etc); modload=$(net_brutal_modload); sysctl_file=$(net_brutal_sysctl)
    bin=$(net_brutal_bin)
    if [[ ! -d $etc && ! -e $modload && ! -e $bin ]]; then
        printf '未安装。\n'
        if net_brutal_module_loaded; then
            printf '注意：brutal 模块仍在内存里（通常是卸载后仍有连接在用），重启后消失；默认算法 %s。\n' "$(net_current_cc)"
        fi
        return 1
    fi
    if [[ -f $etc/meta ]]; then
        IFS='|' read -r prev version rel < "$etc/meta" || true
    fi
    printf '版本    : %s（当初安装的内核 %s，当前内核 %s）\n' \
        "${version:-未知}" "${rel:-未知}" "$(net_kernel_release)"
    printf '模块    : %s\n' "$(net_brutal_module_loaded && printf '已载入' || printf '未载入')"
    printf '默认算法: %s（安装前为 %s）\n' "$(net_current_cc)" "${prev:-未知}"
    printf '可用算法: %s\n' "$(net_available_cc)"
    printf '开机载入: %s\n' "$( [[ -e $modload ]] && printf '已配置 %s' "$modload" || printf '无')"
    printf 'brutalctl: %s\n' "$( [[ -x $bin ]] && printf '%s' "$bin" || printf '缺失')"
}

# ================================================================ A3 TUIC
#
# 固定上游 tuic-protocol/tuic 的 tuic-server 1.0.0 官方静态二进制（musl，
# 自带运行时），SHA-256 取自同版本官方 .sha256sum 并写死。
# 上游自 2023-06 起无新版本，1.0.0 是目前唯一可用的官方服务端。
#
# 认证靠 UUID + 密码，配置里没有主机名字段；主机名只用于证书 SAN 校验和
# 客户端链接。本模块没有 TUIC 客户端可当探针，因此「服务起来、UDP 端口被本
# 服务持有」是全部自动验证，认证是否通过需要客户端实测（报告里写明）。

net_const TUIC_VERSION '1.0.0'
net_const TUIC_BIN_NAME 'terry-toolbox-tuic'
net_const TUIC_UNIT_NAME 'terry-toolbox-tuic.service'
net_const TUIC_DEFAULT_PORT 443

net_tuic_etc()  { printf '%s/terry-toolbox-tuic\n' "${TOOLBOX_NET_ETC:-/etc}"; }
net_tuic_bin()  { printf '%s/%s\n' "${TOOLBOX_NET_BIN_DIR:-/usr/local/bin}" "$TUIC_BIN_NAME"; }
net_tuic_unit() { printf '%s/%s\n' "${TOOLBOX_NET_UNIT_DIR:-/etc/systemd/system}" "$TUIC_UNIT_NAME"; }

net_tuic_arch() {
    case $(uname -m) in
        x86_64|amd64) printf 'x86_64\n' ;;
        aarch64|arm64) printf 'aarch64\n' ;;
        *) net_die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
}

net_tuic_sha256() {
    case $1 in
        x86_64) printf '%s\n' "${TOOLBOX_NET_TUIC_SHA256:-adb808944ca829857bf408d2ee438a156e8171543dbbed3e94964b66b4135393}" ;;
        aarch64) printf '%s\n' "${TOOLBOX_NET_TUIC_SHA256_ARM64:-6ac43186b5197afaf0bc707c1241f2b3931d61356fc8354807884b68861a4892}" ;;
        *) return 1 ;;
    esac
}

net_tuic_fetch() {
    local arch=$1 dest=$2 expected url actual
    expected=$(net_tuic_sha256 "$arch") || { net_die "没有 $arch 的固定校验值。"; return 1; }
    url="https://github.com/tuic-protocol/tuic/releases/download/tuic-server-${TUIC_VERSION}/tuic-server-${TUIC_VERSION}-${arch}-unknown-linux-musl"
    url=${TOOLBOX_NET_TUIC_URL:-$url}
    if [[ -n ${TOOLBOX_NET_TUIC_BIN_SRC:-} ]]; then
        cp -- "$TOOLBOX_NET_TUIC_BIN_SRC" "$dest" || { net_die '复制本地二进制失败'; return 1; }
    else
        net_err "下载官方二进制：$url"
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \
            -o "$dest" "$url" || { net_die '下载失败（网络或 GitHub 不可达）。'; return 1; }
    fi
    actual=$(sha256sum -- "$dest" | cut -d' ' -f1)
    [[ $actual == "$expected" ]] \
        || { net_die "SHA-256 不匹配：期望 $expected，实际 $actual。"; return 1; }
    chmod 0755 -- "$dest" || { net_die '无法设置可执行权限。'; return 1; }
}

# 离线自检：起前台进程，等日志里的监听行，然后杀掉；顺带确认它真占了端口。
net_tuic_smoke() {
    local bin=$1 conf=$2 port=$3 out pid i rc=1
    out=$(mktemp) || return 1
    # 9>&-：冒烟子进程不留住调用方的 flock，否则紧接着的卸载会撞锁。
    "$bin" -c "$conf" >"$out" 2>&1 9>&- &
    pid=$!
    for ((i = 0; i < 60; i++)); do
        grep -q "server started, listening on" "$out" 2>/dev/null && { rc=0; break; }
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    grep -q "server started, listening on" "$out" 2>/dev/null && rc=0
    if (( rc == 0 )); then
        net_port_busy udp "$port" || { net_err "进程报告已监听，但 UDP $port 没有监听项。"; rc=1; }
    fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    if (( rc == 0 )); then rm -f -- "$out"; return 0; fi
    net_err "冒烟启动失败（UDP $port），服务输出："
    sed -n '1,10p' "$out" >&2
    rm -f -- "$out"
    return 1
}

net_tuic_rollback() {
    local unit bin etc
    unit=$(net_tuic_unit); bin=$(net_tuic_bin); etc=$(net_tuic_etc)
    net_err '--- 开始回滚 ---'
    if [[ -e $unit ]]; then
        systemctl disable --now "$TUIC_UNIT_NAME" >/dev/null 2>&1 || true
        rm -f -- "$unit"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed "$TUIC_UNIT_NAME" >/dev/null 2>&1 || true
    fi
    rm -f -- "$bin"
    [[ -d $etc ]] && rm -rf -- "$etc"
    net_err '已恢复到安装前状态。'
}

_net_tuic_install() {
    local cert=${1:-} key=${2:-} host=${3:-} port=${4:-} answer
    local arch tmp etc bin unit pass uuid state
    net_require_root || return 1
    net_require_debian || return 1
    net_require_systemd || return 1
    net_require_cmds openssl sha256sum curl flock ss stat sed mktemp || return 1
    arch=$(net_tuic_arch) || return 1

    [[ -n $cert ]] || { net_die '缺少证书路径。'; return 1; }
    [[ -n $key ]] || { net_die '缺少私钥路径。'; return 1; }
    [[ -n $host ]] || { net_die '缺少主机名（证书对应的域名）。'; return 1; }
    host=${host,,}
    net_valid_hostname "$host" || { net_die "主机名格式不正确：$host"; return 1; }
    if [[ -n $port ]]; then
        net_valid_port "$port" || { net_die "端口不正确：$port（1-65535，无前导零）"; return 1; }
    else
        port=$TUIC_DEFAULT_PORT
    fi
    net_check_cert "$cert" "$key" "$host" || return 1

    etc=$(net_tuic_etc); bin=$(net_tuic_bin); unit=$(net_tuic_unit)
    state=$(net_unit_state "$unit" "$bin")
    case $state in
        foreign)
            net_die "$unit 已存在但内容不是本模块生成的，未覆盖；请人工确认归属。"
            return 1
            ;;
        ours)
            if systemctl is-active --quiet "$TUIC_UNIT_NAME" 2>/dev/null; then
                net_die "$TUIC_UNIT_NAME 已在运行（我们的服务）。重装请先卸载。"
            else
                net_die "$TUIC_UNIT_NAME 已存在但未运行（我们的残留）。请先卸载。"
            fi
            return 1
            ;;
    esac
    if [[ -d $etc || -e $bin ]]; then
        net_die "已存在 $(net_tuic_etc) 或 $bin（不是本模块写入的），未覆盖。"
        return 1
    fi
    if net_port_busy udp "$port"; then
        net_err "UDP 端口 $port 已被占用："
        net_port_lines udp "$port" | cut -c1-160 >&2
        net_die '换端口，或先确认并停止占用方。'
        return 1
    fi

    printf '即将安装 TUIC 服务端：\n'
    printf '  版本    : v%s（官方 musl 静态二进制，安装前校验 SHA-256）\n' "$TUIC_VERSION"
    printf '  主机名  : %s\n' "$host"
    printf '  监听    : [::]:%s/udp（双栈）\n' "$port"
    printf '  证书    : %s\n' "$cert"
    printf '  私钥    : %s（复制到 %s，权限 600）\n' "$key" "$etc"
    printf '  单元    : %s\n' "$unit"
    printf '  认证    : 随机 UUID + 随机密码，只显示一次\n'
    printf '  防火墙  : 不改动；需自行放行 UDP %s\n' "$port"
    net_confirm_twice TUIC || return 1

    net_lock tuic || return 1
    tmp=$(mktemp -d) || { net_die '无法创建临时目录'; return 1; }
    uuid=${TOOLBOX_NET_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null)}
    net_valid_uuid "$uuid" || uuid=$(openssl rand -hex 16 | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')
    net_valid_uuid "$uuid" || { rm -rf -- "$tmp"; net_die 'UUID 生成失败'; return 1; }
    pass=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32)
    [[ ${#pass} -eq 32 ]] || { rm -rf -- "$tmp"; net_die '密码生成失败'; return 1; }

    net_err '--- 开始写入 ---'
    net_tuic_fetch "$arch" "$tmp/tuic-server" || { rm -rf -- "$tmp"; net_tuic_rollback; return 1; }

    install -d -m 0755 "$etc" && install -d -m 0755 "$(dirname -- "$bin")" \
        && install -m 0755 "$tmp/tuic-server" "$bin" \
        || { rm -rf -- "$tmp"; net_tuic_rollback; return 1; }
    install -m 0600 "$cert" "$etc/cert.pem" && install -m 0600 "$key" "$etc/key.pem" \
        || { rm -rf -- "$tmp"; net_tuic_rollback; return 1; }

    cat > "$etc/config.json" <<EOF
{
    "server": "[::]:$port",
    "users": {
        "$uuid": "$pass"
    },
    "certificate": "$etc/cert.pem",
    "private_key": "$etc/key.pem",
    "congestion_control": "bbr",
    "dual_stack": true,
    "log_level": "info"
}
EOF
    chmod 0600 "$etc/config.json" && [[ -s $etc/config.json ]] \
        || { rm -rf -- "$tmp"; net_tuic_rollback; return 1; }

    cat > "$unit" <<EOF
[Unit]
Description=Terry Toolbox TUIC server
Documentation=https://github.com/tuic-protocol/tuic
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$etc
ExecStart=$bin -c $etc/config.json
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$etc
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$unit" && [[ -s $unit ]] || { rm -rf -- "$tmp"; net_tuic_rollback; return 1; }

    if ! net_tuic_smoke "$bin" "$etc/config.json" "$port"; then
        rm -rf -- "$tmp"; net_tuic_rollback; return 1
    fi

    if ! systemctl daemon-reload; then rm -rf -- "$tmp"; net_tuic_rollback; return 1; fi
    if ! systemctl enable --now "$TUIC_UNIT_NAME" >/dev/null 2>&1; then
        net_err 'systemctl enable --now 失败。'
        rm -rf -- "$tmp"; net_tuic_rollback; return 1
    fi
    if ! net_wait_active "$TUIC_UNIT_NAME"; then
        net_err '服务未进入 active 状态。'
        systemctl --no-pager -l status "$TUIC_UNIT_NAME" >&2 2>&1 || true
        rm -rf -- "$tmp"; net_tuic_rollback; return 1
    fi
    if ! net_wait_owned udp "$port" "$bin" "$TUIC_UNIT_NAME"; then
        net_err "单元显示运行中，但 UDP $port 的监听进程不是 $TUIC_BIN_NAME。"
        rm -rf -- "$tmp"; net_tuic_rollback; return 1
    fi

    printf '%s|%s|%s\n' "$uuid" "$pass" "$port" > "$etc/meta"
    chmod 0600 "$etc/meta"
    rm -rf -- "$tmp"

    printf '\n安装完成，服务 %s 已设为开机自启。\n' "$TUIC_UNIT_NAME"
    printf '客户端连接信息（只显示这一次，也写入 %s/meta）：\n' "$etc"
    printf '  tuic://%s:%s@%s:%s?sni=%s&congestion_control=bbr\n' "$uuid" "$pass" "$host" "$port" "$host"
    printf '\n验证情况：\n'
    printf '  [已验证] 单元 active、UDP %s 由 %s 监听、配置可被本二进制解析并绑定\n' "$port" "$TUIC_BIN_NAME"
    printf '  [未验证] 认证与数据面：本机没有 TUIC 客户端可当探针，需用客户端实际连一次\n'
    printf '\n仍需人工处理：\n'
    printf '  - 防火墙/安全组放行 UDP %s（本模块不改防火墙）\n' "$port"
    printf '  - 证书续期：覆盖 %s/cert.pem、key.pem 后重启服务\n' "$etc"
    printf '  - 卸载：A3 → 2\n'
}

_net_tuic_uninstall() {
    local unit etc bin state
    net_require_root || return 1
    net_require_systemd || return 1
    unit=$(net_tuic_unit); etc=$(net_tuic_etc); bin=$(net_tuic_bin)
    state=$(net_unit_state "$unit" "$bin")
    if [[ $state == absent && ! -e $bin && ! -d $etc ]]; then
        net_die '没有找到本模块的安装。'
        return 1
    fi
    if [[ $state == foreign ]]; then
        net_die "$unit 不是本模块生成的，未删除；请人工确认。"
        return 1
    fi
    printf '将停止并删除：\n  %s\n  %s\n  %s\n' "$unit" "$bin" "$etc"
    net_confirm_once || return 1
    net_lock tuic || return 1
    net_tuic_rollback
    printf '已卸载。\n'
}

net_tuic_status() {
    local unit etc uuid pass port
    unit=$(net_tuic_unit); etc=$(net_tuic_etc)
    if [[ ! -e $unit ]]; then
        printf '未安装。\n'
        return 1
    fi
    printf '单元: %s\n' "$unit"
    systemctl --no-pager -l status "$TUIC_UNIT_NAME" 2>&1 | sed -n '1,6p'
    if [[ -f $etc/meta ]]; then
        IFS='|' read -r uuid pass port < "$etc/meta" || true
        printf '端口 %s 监听: ' "${port:-?}"
        if [[ -n ${port:-} ]] && net_port_owned_by udp "$port" "$(net_tuic_bin)" "$TUIC_UNIT_NAME"; then
            printf '由本服务持有\n'
        else
            printf '不是本服务\n'
        fi
        printf '认证: UUID=%s 密码=%s\n' "${uuid:-?}" "${pass:-?}"
    else
        printf '缺少 meta（凭据未知）。\n'
    fi
}

# ================================================================ B31 Relay 转发
#
# 用 socat + 每个转发一个独立 systemd 单元。选它而不是 nginx stream：
#   - 不依赖宿主机是否装有 nginx、也不 reload 别人的共享守护进程；
#   - 不写 nginx conf.d 里的公共目录，冲突面只有一个可以自己命名的单元；
#   - 参数就是一个 ExecStart，回滚 = 停掉并删掉它，没有残留配置。
# 代价是 socat 每连接 fork 一个进程、UDP 语义比 nginx stream 弱，报告里写明。
#
# 单元名带协议和本地端口，因此可以并存多个转发、逐个卸载。

net_const RELAY_PREFIX 'terry-toolbox-relay'

net_relay_unit_dir() { printf '%s\n' "${TOOLBOX_NET_UNIT_DIR:-/etc/systemd/system}"; }
net_relay_unit_name() { printf '%s-%s-%s.service\n' "$RELAY_PREFIX" "$1" "$2"; }
net_relay_unit() { printf '%s/%s\n' "$(net_relay_unit_dir)" "$(net_relay_unit_name "$1" "$2")"; }

net_relay_socat() {
    local p=${TOOLBOX_NET_SOCAT:-}
    if [[ -n $p ]]; then printf '%s\n' "$p"; return 0; fi
    command -v socat 2>/dev/null
}

net_relay_valid_proto() { [[ $1 == tcp || $1 == udp ]]; }

# 单元里用到的两个地址串；UDP 必须 reuseaddr 才不会在重启时撞端口。
net_relay_listen_arg() {
    if [[ $1 == tcp ]]; then
        printf 'TCP-LISTEN:%s,fork,reuseaddr\n' "$2"
    else
        printf 'UDP-LISTEN:%s,reuseaddr,fork\n' "$2"
    fi
}

net_relay_target_arg() {
    if [[ $1 == tcp ]]; then
        printf 'TCP:%s:%s\n' "$2" "$3"
    else
        printf 'UDP:%s:%s\n' "$2" "$3"
    fi
}

net_relay_exec_line() {
    local proto=$1 lport=$2 host=$3 tport=$4 socat
    socat=$(net_relay_socat) || return 1
    [[ -n $socat ]] || return 1
    printf '%s -d -d %s %s\n' "$socat" \
        "$(net_relay_listen_arg "$proto" "$lport")" \
        "$(net_relay_target_arg "$proto" "$host" "$tport")"
}

net_relay_write_unit() {
    local proto=$1 lport=$2 host=$3 tport=$4 unit exec
    unit=$(net_relay_unit "$proto" "$lport")
    exec=$(net_relay_exec_line "$proto" "$lport" "$host" "$tport") || return 1
    cat > "$unit" <<EOF
[Unit]
Description=Terry Toolbox relay $proto $lport -> $host:$tport
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$exec
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$unit" && [[ -s $unit ]]
}

net_relay_rollback() {
    local proto=$1 lport=$2 unit
    unit=$(net_relay_unit "$proto" "$lport")
    net_err '--- 开始回滚 ---'
    systemctl disable --now "$(net_relay_unit_name "$proto" "$lport")" >/dev/null 2>&1 || true
    rm -f -- "$unit"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$(net_relay_unit_name "$proto" "$lport")" >/dev/null 2>&1 || true
    net_err '已删除本次写入的单元。'
}

_net_relay_install() {
    local proto=${1:-} lport=${2:-} host=${3:-} tport=${4:-}
    local unit name socat state
    net_require_root || return 1
    net_require_debian || return 1
    net_require_systemd || return 1
    net_require_cmds flock ss sed mktemp || return 1

    net_relay_valid_proto "$proto" || { net_die "协议只能是 tcp 或 udp：${proto:-空}"; return 1; }
    [[ -n $lport ]] || { net_die '缺少本地端口。'; return 1; }
    net_valid_port "$lport" || { net_die "本地端口不正确：$lport"; return 1; }
    [[ -n $host ]] || { net_die '缺少目标主机。'; return 1; }
    net_valid_target_host "$host" || { net_die "目标主机格式不正确：$host（仅 IPv4/域名）"; return 1; }
    [[ -n $tport ]] || { net_die '缺少目标端口。'; return 1; }
    net_valid_port "$tport" || { net_die "目标端口不正确：$tport"; return 1; }

    socat=$(net_relay_socat) || socat=''
    [[ -n $socat && -x $socat ]] || { net_die '未找到 socat，请先安装（apt-get install socat）。'; return 1; }

    unit=$(net_relay_unit "$proto" "$lport")
    name=$(net_relay_unit_name "$proto" "$lport")
    state=$(net_unit_state "$unit" "$socat")
    case $state in
        foreign)
            net_die "$unit 已存在但内容不是本模块生成的，未覆盖；请人工确认。"
            return 1
            ;;
        ours)
            net_die "$name 已存在（同一端口）。重装请先卸载该转发。"
            return 1
            ;;
    esac
    if net_port_busy "$proto" "$lport"; then
        net_err "$proto 端口 $lport 已被占用："
        net_port_lines "$proto" "$lport" | cut -c1-160 >&2
        net_die '换端口，或先确认并停止占用方。'
        return 1
    fi

    printf '即将创建转发：\n'
    printf '  协议    : %s\n' "$proto"
    printf '  监听    : 0.0.0.0:%s/%s（所有 IPv4 地址）\n' "$lport" "$proto"
    printf '  目标    : %s:%s\n' "$host" "$tport"
    printf '  程序    : %s\n' "$socat"
    printf '  单元    : %s\n' "$unit"
    printf '  防火墙  : 不改动；需自行放行 %s/%s\n' "$lport" "$proto"
    net_confirm_twice RELAY || return 1

    net_lock relay || return 1
    net_relay_write_unit "$proto" "$lport" "$host" "$tport" \
        || { net_relay_rollback "$proto" "$lport"; net_die '单元写入失败。'; return 1; }

    if ! systemctl daemon-reload; then
        net_relay_rollback "$proto" "$lport"; return 1
    fi
    if ! systemctl enable --now "$name" >/dev/null 2>&1; then
        net_err 'systemctl enable --now 失败。'
        net_relay_rollback "$proto" "$lport"; return 1
    fi
    if ! net_wait_active "$name"; then
        net_err '转发未进入 active 状态。'
        systemctl --no-pager -l status "$name" >&2 2>&1 || true
        net_relay_rollback "$proto" "$lport"; return 1
    fi
    if ! net_wait_owned "$proto" "$lport" "$socat" "$name"; then
        net_err "单元显示运行中，但 $proto $lport 的监听进程不是 socat。"
        net_relay_rollback "$proto" "$lport"; return 1
    fi

    printf '\n转发已建立并设为开机自启：%s\n' "$name"
    printf '[已验证] 单元 active、%s/%s 由 socat 监听，目标 %s:%s\n' "$proto" "$lport" "$host" "$tport"
    printf '[未验证] 端到端连通：需要客户端实际经 %s 传输一次\n' "$lport"
    printf '\n仍需人工处理：\n'
    printf '  - 防火墙/安全组放行 %s/%s\n' "$lport" "$proto"
    printf '  - 目标端口若换址，需卸载后重建\n'
    printf '  - 卸载：B31 → 2，或 systemctl disable --now %s\n' "$name"
}

# 列出本模块创建的转发单元（只看自己的前缀）。
net_relay_units() {
    local dir f
    dir=$(net_relay_unit_dir)
    for f in "$dir/$RELAY_PREFIX"-*.service; do
        [[ -e $f ]] || continue
        printf '%s\n' "$f"
    done
}

# 从单元名反解 proto 和端口：terry-toolbox-relay-<proto>-<port>.service
net_relay_parse_unit() {
    local base=${1##*/} rest
    [[ $base == "$RELAY_PREFIX"-*.service ]] || return 1
    rest=${base#"$RELAY_PREFIX"-}
    rest=${rest%.service}
    [[ $rest =~ ^(tcp|udp)-([0-9]+)$ ]] || return 1
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

_net_relay_uninstall() {
    local units=() unit proto lport socat name state
    net_require_root || return 1
    net_require_systemd || return 1
    socat=$(net_relay_socat) || socat=''

    mapfile -t units < <(net_relay_units)
    (( ${#units[@]} > 0 )) || { net_die '没有找到本模块的转发单元。'; return 1; }

    if (( $# == 0 )) || [[ ${1:-} == all ]]; then
        :
    elif (( $# == 2 )); then
        proto=$1; lport=$2
        net_relay_valid_proto "$proto" || { net_die "协议只能是 tcp 或 udp：$proto"; return 1; }
        net_valid_port "$lport" || { net_die "本地端口不正确：$lport"; return 1; }
        unit=$(net_relay_unit "$proto" "$lport")
        [[ -e $unit ]] || { net_die "没有找到 $unit。"; return 1; }
        units=("$unit")
    else
        net_die '用法: uninstall [tcp|udp 本地端口 | all]'
        return 1
    fi

    printf '将停止并删除：\n'
    for unit in "${units[@]}"; do
        state=$(net_unit_state "$unit" "${socat:-socat}")
        printf '  %s%s\n' "$unit" "$( [[ $state == foreign ]] && printf '（他人单元，将保留）')"
    done
    net_confirm_once || return 1
    net_lock relay || return 1

    for unit in "${units[@]}"; do
        if [[ $(net_unit_state "$unit" "${socat:-socat}") == foreign ]]; then
            continue
        fi
        name=${unit##*/}
        systemctl disable --now "$name" >/dev/null 2>&1 || true
        rm -f -- "$unit"
        systemctl reset-failed "$name" >/dev/null 2>&1 || true
        printf '已删除 %s\n' "$name"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
}

net_relay_status() {
    local units=() unit proto lport name
    mapfile -t units < <(net_relay_units)
    if (( ${#units[@]} == 0 )); then
        printf '没有任何本模块的转发。\n'
        return 1
    fi
    for unit in "${units[@]}"; do
        name=${unit##*/}
        read -r proto lport < <(net_relay_parse_unit "$name") || continue
        printf '%s (%s %s)\n' "$name" "$proto" "$lport"
        printf '  ExecStart: %s\n' "$(sed -n 's/^ExecStart=//p' "$unit")"
        printf '  状态    : %s\n' "$(systemctl is-active "$name" 2>/dev/null || true)"
        printf '  监听    : %s\n' "$( [[ -n $(net_port_lines "$proto" "$lport") ]] && printf '有' || printf '无')"
    done
}

# ================================================================ A1/A2 Alpine 公共
#
# A1/A2 只支持「全新 Alpine + OpenRC + 固定官方发布二进制 + SHA-256 白名单」。
# 不执行远程脚本、不改 apk 仓库、不碰防火墙。写盘前拒绝一切不确定状态，
# 写盘后失败一律回滚。端口是否被自己持有只认本机事实（pidfile、/proc/<pid>/exe、
# 内核 comm），不靠「看起来像我们的服务」。

net_const NET_ALPINE_HY2_VERSION '2.13.0'
net_const NET_ALPINE_XRAY_VERSION '26.10.29'
net_const NET_ALPINE_HY2_NAME 'terry-toolbox-hy2'
net_const NET_ALPINE_XRAY_NAME 'terry-toolbox-xray'
net_const NET_ALPINE_DEFAULT_PORT 443
net_const NET_ALPINE_HY2_MASQUERADE 'Terry Toolbox Hysteria 2'

net_initdir() { printf '%s\n' "${TOOLBOX_NET_INITD:-/etc/init.d}"; }
net_rundir()  { printf '%s\n' "${TOOLBOX_NET_RUN:-/run}"; }

net_alpine_require_os() {
    local os
    os=$(toolbox_network_detect_os "${TOOLBOX_NET_OS_RELEASE:-/etc/os-release}" 2>/dev/null) \
        || { net_die '无法确认发行版：A1/A2 只支持 Alpine（Debian/Ubuntu 请用 A4/A5 路径）。'; return 1; }
    [[ $os == alpine ]] || { net_die "A1/A2 只支持 Alpine（检测到 $os）。"; return 1; }
}

# 容器里装 Alpine 很常见，但没有 OpenRC 时装了也起不来，必须提前拒绝。
net_alpine_require_openrc() {
    local run=${TOOLBOX_NET_OPENRC_RUN:-/run/openrc}
    if ! command -v rc-service >/dev/null 2>&1 || ! command -v rc-update >/dev/null 2>&1; then
        net_die '未找到 rc-service/rc-update，本机不是 OpenRC 系统。'
        return 1
    fi
    [[ -d $run ]] || { net_die "OpenRC 未作为 init 运行（缺少 $run）。"; return 1; }
}

net_alpine_arch() {
    case $(uname -m) in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) net_die "不支持的 CPU 架构：$(uname -m)"; return 1 ;;
    esac
}

# HyNetworks/hysteria app/v2.13.0 官方发布二进制的 SHA-256 白名单。
net_alpine_hy2_sha256() {
    case $1 in
        amd64) printf '%s\n' "${TOOLBOX_A1_SHA256:-907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691}" ;;
        arm64) printf '%s\n' "${TOOLBOX_A1_SHA256_ARM64:-a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7}" ;;
        *) return 1 ;;
    esac
}

# XTLS/Xray-core v26.10.29 官方 zip 的 SHA-256 白名单（取自上游 .dgst 并本地复核）。
net_alpine_xray_sha256() {
    case $1 in
        amd64) printf '%s\n' "${TOOLBOX_A2_SHA256:-8a5f3e6a1057e4bd0f8a7c57c9d91204b4be0b74222a6e210d070603101163c2}" ;;
        arm64) printf '%s\n' "${TOOLBOX_A2_SHA256_ARM64:-afe01f19045b05237420328028ee1ee2e1edd2100eb41a8cbbf50e683b0a6e58}" ;;
        *) return 1 ;;
    esac
}

# Xray 官方产物的架构后缀与 uname 名不同：arm64 是 arm64-v8a。
net_xray_asset_arch() {
    case $1 in
        amd64) printf '64\n' ;;
        arm64) printf 'arm64-v8a\n' ;;
        *) return 1 ;;
    esac
}

net_alpine_xray_url() { # arch
    local asset
    asset=$(net_xray_asset_arch "$1") || return 1
    printf 'https://github.com/XTLS/Xray-core/releases/download/v%s/Xray-linux-%s.zip\n' \
        "$NET_ALPINE_XRAY_VERSION" "$asset"
}

net_alpine_port_owned_by() { # proto port bin pidfile
    local proto=$1 port=$2 bin=$3 pidfile=$4 line pid exe want svcpid='' comm
    want=$(readlink -f -- "$bin" 2>/dev/null) || want=$bin
    comm=${bin##*/}; comm=${comm:0:15}
    [[ -r $pidfile ]] && svcpid=$(<"$pidfile")
    [[ $svcpid =~ ^[0-9]+$ ]] || svcpid=''
    while IFS= read -r line; do
        while IFS= read -r pid; do
            [[ -n $pid ]] || continue
            [[ -n $svcpid && $pid == "$svcpid" ]] && return 0
            exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || exe=''
            [[ -n $exe && $exe == "$want" ]] && return 0
        done < <(grep -o 'pid=[0-9]*' <<< "$line" | cut -d= -f2)
        # 内核 comm 被截断到 15 字符，只能按前缀兜底。
        [[ $line == *"$comm"* ]] && return 0
    done < <(if [[ $proto == tcp ]]; then ss -ltnpH 2>/dev/null; else ss -lunpH 2>/dev/null; fi)
    return 1
}

net_alpine_wait_owned() {
    local i
    for ((i = 0; i < 20; i++)); do
        net_alpine_port_owned_by "$1" "$2" "$3" "$4" && return 0
        sleep 0.5
    done
    return 1
}

# absent / ours / foreign：同名 init 脚本不代表是我们的。
net_alpine_svc_state() { # init-script bin
    [[ -e $1 ]] || { printf 'absent\n'; return 0; }
    if grep -qF "command=\"$2\"" "$1" 2>/dev/null; then
        printf 'ours\n'
    else
        printf 'foreign\n'
    fi
}

net_alpine_svc_active() { rc-service "$1" status >/dev/null 2>&1; }

net_alpine_wait_active() {
    local i
    for ((i = 0; i < 20; i++)); do
        net_alpine_svc_active "$1" && return 0
        sleep 0.5
    done
    return 1
}

net_alpine_rollback() { # name init bin etc pidfile clientdir
    local name=$1 init=$2 bin=$3 etc=$4 pid=$5 client=$6
    net_err '--- 开始回滚 ---'
    if [[ -e $init ]]; then
        rc-service "$name" stop >/dev/null 2>&1 || true
        rc-update del "$name" default >/dev/null 2>&1 || true
        rm -f -- "$init"
    fi
    rm -f -- "$bin" "$pid"
    [[ -d $etc ]] && rm -rf -- "$etc"
    [[ -n $client && -d $client ]] && rm -rf -- "$client"
    if net_alpine_svc_active "$name" 2>/dev/null; then
        net_err "警告：回滚后 $name 仍在运行，请人工确认。"
    fi
    net_err '已恢复到安装前状态（新增的 init 脚本、二进制、配置目录已删除）。'
}

# 下载后立刻校验；测试用 *_SRC 注入本地文件，同样会走校验和。
net_alpine_fetch() { # url dest expected [local-src]
    local url=$1 dest=$2 expected=$3 src=${4:-} actual
    if [[ -n $src ]]; then
        cp -- "$src" "$dest" || { net_die "复制本地文件失败：$src"; return 1; }
    else
        net_err "下载官方发布文件：$url"
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \
            -o "$dest" "$url" || { net_die '下载失败（网络或上游不可达）。'; return 1; }
    fi
    actual=$(sha256sum -- "$dest" | cut -d' ' -f1)
    [[ $actual == "$expected" ]] \
        || { net_die "SHA-256 不匹配：期望 $expected，实际 $actual（下载被篡改或版本漂移）。"; return 1; }
}

net_alpine_free_port() {
    local p=$1
    while net_port_busy udp "$p" || net_port_busy tcp "$p"; do ((p++)); done
    printf '%s\n' "$p"
}

net_curl_socks() { # socks-port url
    local out i
    for ((i = 0; i < 3; i++)); do
        out=$(timeout 25 curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:$1" \
            -o /dev/null -w '%{http_code}' "$2" 2>/dev/null) \
            && [[ $out == 2* ]] && return 0
        sleep 1
    done
    return 1
}

# 写盘后、交给 OpenRC 之前的离线自检：配置能解析、证书能加载、端口能绑定。
net_hysteria_smoke() {
    local bin=$1 conf=$2 out pid i
    out=$(mktemp) || return 1
    "$bin" server -c "$conf" --disable-update-check >"$out" 2>&1 &
    pid=$!
    for ((i = 0; i < 60; i++)); do
        grep -q 'server up and running' "$out" 2>/dev/null && break
        grep -q 'FATAL' "$out" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    if grep -q 'server up and running' "$out" 2>/dev/null; then
        rm -f -- "$out"
        return 0
    fi
    net_err '冒烟启动失败，服务输出：'
    sed -n '1,12p' "$out" >&2
    rm -f -- "$out"
    return 1
}

# 认证探测：用同一份二进制当客户端；negative=1 时只在连通时返回 0。
net_hysteria_probe() { # bin host port pass insecure label negative
    local bin=$1 host=$2 port=$3 pass=$4 insecure=$5 label=$6 negative=${7:-0}
    local dir sock out i cpid result=1
    dir=$(net_rundir)/terry-toolbox-hy2-verify
    mkdir -p "$dir" || return 1
    sock=$(net_alpine_free_port $(( 39000 + RANDOM % 2000 )))
    out=$dir/$label.log
    {
        printf 'server: 127.0.0.1:%s\n' "$port"
        printf 'auth: %s\n' "$pass"
        printf 'tls:\n  sni: %s\n' "$host"
        [[ $insecure == 1 ]] && printf '  insecure: true\n'
        printf 'socks5:\n  listen: 127.0.0.1:%s\n' "$sock"
    } > "$dir/$label.yaml" || return 1
    "$bin" client -c "$dir/$label.yaml" --disable-update-check >"$out" 2>&1 &
    cpid=$!
    for ((i = 0; i < 75; i++)); do
        grep -q 'connected to server' "$out" 2>/dev/null && { result=0; break; }
        grep -q 'FATAL' "$out" 2>/dev/null && break
        kill -0 "$cpid" 2>/dev/null || break
        sleep 0.2
    done
    (( result == 1 )) && grep -q 'connected to server' "$out" 2>/dev/null && result=0
    if (( result == 0 && negative == 0 )); then
        net_curl_socks "$sock" 'https://www.cloudflare.com/cdn-cgi/trace' \
            || net_err "提示：$label 隧道已通，但数据面出站未成功（可能主机无外网出口）。"
    fi
    kill "$cpid" 2>/dev/null
    wait "$cpid" 2>/dev/null || true
    return $result
}

# xray 客户端：等它真正开始监听再打数据面；判据是 HTTP 200，不是「进程还活着」。
net_xray_probe() { # bin host port uuid pub shortid label negative
    local bin=$1 host=$2 port=$3 uuid=$4 pub=$5 shortid=$6 label=$7 negative=${8:-0}
    local dir sock out i cpid result=1
    dir=$(net_rundir)/terry-toolbox-xray-verify
    mkdir -p "$dir" || return 1
    sock=$(net_alpine_free_port $(( 41000 + RANDOM % 2000 )))
    out=$dir/$label.log
    cat > "$dir/$label.json" <<EOF || return 1
{
  "log": { "loglevel": "info" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": $sock, "protocol": "socks",
      "settings": { "udp": false } }
  ],
  "outbounds": [
    { "protocol": "vless",
      "settings": { "vnext": [ { "address": "127.0.0.1", "port": $port,
        "users": [ { "id": "$uuid", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "serverName": "$host", "fingerprint": "chrome",
          "publicKey": "$pub", "shortId": "$shortid" } } }
  ]
}
EOF
    "$bin" run -c "$dir/$label.json" >"$out" 2>&1 &
    cpid=$!
    for ((i = 0; i < 75; i++)); do
        grep -q 'started' "$out" 2>/dev/null && { result=0; break; }
        grep -q 'Failed to start' "$out" 2>/dev/null && break
        kill -0 "$cpid" 2>/dev/null || break
        sleep 0.2
    done
    (( result == 1 )) && grep -q 'started' "$out" 2>/dev/null && result=0
    if (( result == 0 && negative == 0 )); then
        net_curl_socks "$sock" 'https://www.cloudflare.com/cdn-cgi/trace' \
            || net_err "提示：$label 隧道已通，但数据面出站未成功（可能主机无外网出口）。"
    fi
    kill "$cpid" 2>/dev/null
    wait "$cpid" 2>/dev/null || true
    return $result
}

# ---------------------------------------------------------------- A1 Alpine HY2

net_a1_etc()  { printf '%s\n' "${TOOLBOX_A1_ETC:-/etc/terry-toolbox-hy2}"; }
net_a1_bin()  { printf '%s/%s\n' "${TOOLBOX_NET_BIN_DIR:-/usr/local/bin}" "$NET_ALPINE_HY2_NAME"; }
net_a1_init() { printf '%s/%s\n' "$(net_initdir)" "$NET_ALPINE_HY2_NAME"; }
net_a1_pid()  { printf '%s/%s.pid\n' "$(net_rundir)" "$NET_ALPINE_HY2_NAME"; }
net_a1_client() { printf '%s/terry-toolbox-hy2-verify\n' "$(net_rundir)"; }

net_a1_rollback() {
    net_alpine_rollback "$NET_ALPINE_HY2_NAME" "$(net_a1_init)" "$(net_a1_bin)" \
        "$(net_a1_etc)" "$(net_a1_pid)" "$(net_a1_client)"
}

net_a1_conflict() { # 写盘前的冲突判定
    local state
    state=$(net_alpine_svc_state "$(net_a1_init)" "$(net_a1_bin)")
    case $state in
        foreign)
            net_die "$(net_a1_init) 已存在但不是本模块生成的，未覆盖；请人工确认归属。"
            return 1
            ;;
        ours)
            if net_alpine_svc_active "$NET_ALPINE_HY2_NAME"; then
                net_die "$NET_ALPINE_HY2_NAME 已在运行（我们的服务）。重装请先执行卸载。"
            else
                net_die "$NET_ALPINE_HY2_NAME 已存在但未运行（我们的残留）。请先执行卸载清理。"
            fi
            return 1
            ;;
        absent)
            # 没有 init 脚本却有同名二进制/配置目录：可能是别人的安装，不静默覆盖。
            if [[ -e $(net_a1_bin) || -d $(net_a1_etc) ]]; then
                net_die "已存在 $(net_a1_bin) 或 $(net_a1_etc)，却没有本模块的 init 脚本；请人工确认后清理。"
                return 1
            fi
            ;;
    esac
}

_net_a1_install() {
    local cert=${1:-} key=${2:-} host=${3:-} port=${4:-} trusted=1 insecure=0
    local arch tmp etc bin init pid pass state
    net_require_root || return 1
    net_alpine_require_os || return 1
    net_alpine_require_openrc || return 1
    net_require_cmds curl sha256sum install mktemp flock ss awk openssl stat timeout
    arch=$(net_alpine_arch) || return 1

    [[ -n $cert ]] || { net_die '缺少证书路径。'; return 1; }
    [[ -n $key ]] || { net_die '缺少私钥路径。'; return 1; }
    [[ -n $host ]] || { net_die '缺少主机名（证书对应的域名）。'; return 1; }
    host=${host,,}
    net_valid_hostname "$host" || { net_die "主机名格式不正确：$host"; return 1; }
    if [[ -n $port ]]; then
        net_valid_port "$port" || { net_die "端口不正确：$port（1-65535，无前导零）"; return 1; }
    else
        port=$NET_ALPINE_DEFAULT_PORT
    fi
    net_check_cert "$cert" "$key" "$host" || return 1
    net_a1_conflict || return 1

    etc=$(net_a1_etc); bin=$(net_a1_bin); init=$(net_a1_init); pid=$(net_a1_pid)
    if net_port_busy udp "$port"; then
        net_err "UDP 端口 $port 已被占用，监听它的进程："
        ss -lunpH 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" {print "  " $4 " " $0}' | cut -c1-160 >&2
        net_die '换成其他端口，或先确认并停止占用方。'
        return 1
    fi

    printf '即将在 Alpine 上安装 Hysteria 2 服务端（OpenRC）：\n'
    printf '  版本    : v%s（官方发布，安装前校验 SHA-256）\n' "$NET_ALPINE_HY2_VERSION"
    printf '  主机名  : %s\n' "$host"
    printf '  监听    : :%s/udp（所有地址，IPv4+IPv6）\n' "$port"
    printf '  证书    : %s\n' "$cert"
    printf '  私钥    : %s（复制到 %s，权限 600）\n' "$key" "$etc"
    printf '  init    : %s（rc-update add default）\n' "$init"
    printf '  认证    : 随机密码，安装完成后只显示一次\n'
    printf '  防火墙  : 不改动；需自行放行 UDP %s\n' "$port"
    net_confirm_once || return 1

    net_lock a1 || return 1
    tmp=$(mktemp -d) || { net_die '无法创建临时目录'; return 1; }
    pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)
    [[ ${#pass} -eq 32 ]] || { rm -rf -- "$tmp"; net_die '密码生成失败'; return 1; }

    net_err '--- 开始写入 ---'
    net_alpine_fetch \
        "https://github.com/HyNetworks/hysteria/releases/download/app/v${NET_ALPINE_HY2_VERSION}/hysteria-linux-${arch}" \
        "$tmp/hysteria" "$(net_alpine_hy2_sha256 "$arch")" "${TOOLBOX_A1_BIN_SRC:-}" \
        || { rm -rf -- "$tmp"; net_a1_rollback; return 1; }

    install -d -m 0755 "$etc" \
        && install -m 0755 "$tmp/hysteria" "$bin" \
        && install -m 0600 "$cert" "$etc/cert.pem" \
        && install -m 0600 "$key" "$etc/key.pem" \
        || { rm -rf -- "$tmp"; net_a1_rollback; return 1; }

    cat > "$etc/config.yaml" <<EOF
listen: :$port
tls:
  cert: $etc/cert.pem
  key: $etc/key.pem
  sniGuard: strict
auth:
  type: password
  password: '$pass'
masquerade:
  type: string
  string:
    content: '$NET_ALPINE_HY2_MASQUERADE'
    statusCode: 200
EOF
    chmod 0600 "$etc/config.yaml" && [[ -s $etc/config.yaml ]] \
        || { rm -rf -- "$tmp"; net_a1_rollback; return 1; }

    cat > "$init" <<EOF
#!/sbin/openrc-run
description="Terry Toolbox Hysteria 2 server"
command="$bin"
command_args="server -c $etc/config.yaml --disable-update-check"
command_background="yes"
pidfile="$pid"
output_log="$etc/service.log"
error_log="$etc/service.log"
depend() {
    need net
    after firewall nftables iptables
}
EOF
    chmod 0755 "$init" && [[ -s $init ]] \
        || { rm -rf -- "$tmp"; net_a1_rollback; return 1; }

    if ! net_hysteria_smoke "$bin" "$etc/config.yaml"; then
        rm -rf -- "$tmp"; net_a1_rollback; return 1
    fi
    if ! rc-update add "$NET_ALPINE_HY2_NAME" default >/dev/null 2>&1; then
        net_err 'rc-update add 失败。'
        rm -rf -- "$tmp"; net_a1_rollback; return 1
    fi
    if ! rc-service "$NET_ALPINE_HY2_NAME" start >/dev/null 2>&1; then
        net_err 'rc-service start 失败。'
        rc-service "$NET_ALPINE_HY2_NAME" status >&2 2>&1 || true
        rm -rf -- "$tmp"; net_a1_rollback; return 1
    fi
    if ! net_alpine_wait_active "$NET_ALPINE_HY2_NAME"; then
        net_err '服务未进入 started 状态。'
        rm -rf -- "$tmp"; net_a1_rollback; return 1
    fi
    if ! net_alpine_wait_owned udp "$port" "$bin" "$pid"; then
        net_err "服务显示已启动，但 UDP $port 的监听进程不是 $NET_ALPINE_HY2_NAME。"
        rm -rf -- "$tmp"; net_a1_rollback; return 1
    fi

    net_tls_trusted "$etc/cert.pem" || trusted=0
    [[ $trusted == 0 ]] && insecure=1

    if ! net_hysteria_probe "$bin" "$host" "$port" "$pass" "$insecure" good; then
        net_err '认证探测失败（正确密码未连通）。'
        rm -rf -- "$tmp"; net_a1_rollback; return 1
    fi
    if net_hysteria_probe "$bin" "$host" "$port" "wrong-$pass" "$insecure" bad 1; then
        net_err '错误密码也被接受，认证未生效。'
        rm -rf -- "$tmp"; net_a1_rollback; return 1
    fi
    printf '  负向探测：错误密码被拒绝 ✓\n'

    printf '%s|%s|%s|%s\n' "$host" "$port" "$insecure" "$NET_ALPINE_HY2_VERSION" > "$etc/meta"
    chmod 0600 "$etc/meta"
    rm -rf -- "$tmp"
    net_a1_report "$host" "$port" "$pass" "$insecure"
}

net_a1_report() {
    local host=$1 port=$2 pass=$3 insecure=$4 qs=''
    [[ $insecure == 1 ]] && qs='&insecure=1'
    printf '\n安装完成，服务 %s 已加入 default 运行级。\n' "$NET_ALPINE_HY2_NAME"
    printf '客户端连接信息（密码只显示这一次，也已写入 %s/config.yaml）：\n' "$(net_a1_etc)"
    printf '  hysteria2://%s@%s:%s/?sni=%s%s\n' "$pass" "$host" "$port" "$host" "$qs"
    if [[ $insecure == 1 ]]; then
        printf '  证书链未被本机信任库验证通过：链接带 insecure=1，客户端需同样开启。\n'
    else
        printf '  证书链验证通过：客户端可保持严格校验（去掉 insecure=1）。\n'
    fi
    printf '\n验证情况：\n'
    printf '  [已验证] 服务 started、UDP %s 由 %s 监听\n' "$port" "$NET_ALPINE_HY2_NAME"
    printf '  [已验证] 正确密码经 TLS 认证连通；错误密码被拒绝\n'
    printf '\n仍需人工处理：\n'
    printf '  - 防火墙/安全组放行 UDP %s（本模块不改防火墙）\n' "$port"
    printf '  - 证书续期后覆盖配置目录里的 cert.pem、key.pem，再 rc-service %s restart\n' "$NET_ALPINE_HY2_NAME"
    printf '  - 卸载：A1 → 2\n'
}

# ---------------------------------------------------------------- A2 Alpine Xray

net_a2_etc()  { printf '%s\n' "${TOOLBOX_A2_ETC:-/etc/terry-toolbox-xray}"; }
net_a2_bin()  { printf '%s/%s\n' "${TOOLBOX_NET_BIN_DIR:-/usr/local/bin}" "$NET_ALPINE_XRAY_NAME"; }
net_a2_init() { printf '%s/%s\n' "$(net_initdir)" "$NET_ALPINE_XRAY_NAME"; }
net_a2_pid()  { printf '%s/%s.pid\n' "$(net_rundir)" "$NET_ALPINE_XRAY_NAME"; }
net_a2_client() { printf '%s/terry-toolbox-xray-verify\n' "$(net_rundir)"; }

net_a2_rollback() {
    net_alpine_rollback "$NET_ALPINE_XRAY_NAME" "$(net_a2_init)" "$(net_a2_bin)" \
        "$(net_a2_etc)" "$(net_a2_pid)" "$(net_a2_client)"
}

net_a2_conflict() {
    local state
    state=$(net_alpine_svc_state "$(net_a2_init)" "$(net_a2_bin)")
    case $state in
        foreign)
            net_die "$(net_a2_init) 已存在但不是本模块生成的，未覆盖；请人工确认归属。"
            return 1
            ;;
        ours)
            if net_alpine_svc_active "$NET_ALPINE_XRAY_NAME"; then
                net_die "$NET_ALPINE_XRAY_NAME 已在运行（我们的服务）。重装请先执行卸载。"
            else
                net_die "$NET_ALPINE_XRAY_NAME 已存在但未运行（我们的残留）。请先执行卸载清理。"
            fi
            return 1
            ;;
        absent)
            if [[ -e $(net_a2_bin) || -d $(net_a2_etc) ]]; then
                net_die "已存在 $(net_a2_bin) 或 $(net_a2_etc)，却没有本模块的 init 脚本；请人工确认后清理。"
                return 1
            fi
            ;;
    esac
}

# 回落目标：主机名，或 主机名:端口。IPv6 目标暂不支持。
net_valid_dest() {
    local dest=${1%:*} dport=''
    [[ $1 == *:* ]] && dport=${1##*:}
    net_valid_hostname "$dest" || return 1
    [[ -z $dport ]] || net_valid_port "$dport"
}

_net_a2_install() {
    local port=${1:-} dest=${2:-} dhost='' dport=''
    local arch tmp etc bin init pid uuid priv pub shortid cfg state
    net_require_root || return 1
    net_alpine_require_os || return 1
    net_alpine_require_openrc || return 1
    net_require_cmds curl sha256sum install mktemp flock ss awk openssl stat timeout unzip
    arch=$(net_alpine_arch) || return 1

    if [[ -n $port ]]; then
        net_valid_port "$port" || { net_die "端口不正确：$port（1-65535，无前导零）"; return 1; }
    else
        port=$NET_ALPINE_DEFAULT_PORT
    fi
    [[ -n $dest ]] || dest='www.cloudflare.com:443'
    net_valid_dest "$dest" || { net_die "回落目标格式不正确：$dest（应为 主机名 或 主机名:端口）"; return 1; }
    dhost=${dest%:*}; dport=${dest##*:}
    [[ $dest == *:* ]] || dport=443
    net_a2_conflict || return 1

    etc=$(net_a2_etc); bin=$(net_a2_bin); init=$(net_a2_init); pid=$(net_a2_pid)
    if net_port_busy tcp "$port"; then
        net_err "TCP 端口 $port 已被占用，监听它的进程："
        ss -ltnpH 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" {print "  " $4 " " $0}' | cut -c1-160 >&2
        net_die '换成其他端口，或先确认并停止占用方。'
        return 1
    fi

    printf '即将在 Alpine 上安装 Xray 服务端（VLESS + TCP + REALITY，OpenRC）：\n'
    printf '  版本    : v%s（官方发布，安装前校验 SHA-256）\n' "$NET_ALPINE_XRAY_VERSION"
    printf '  监听    : :%s/tcp（所有地址，IPv4+IPv6）\n' "$port"
    printf '  回落    : %s（未认证流量原样转发，需要该目标可直连）\n' "$dest"
    printf '  配置    : %s（600；含私钥，凭据只在安装完成后显示一次）\n' "$etc"
    printf '  init    : %s（rc-update add default）\n' "$init"
    printf '  防火墙  : 不改动；需自行放行 TCP %s\n' "$port"
    printf '  局限    : REALITY 不限制回落流量；端口不是 443 时被封锁概率更高\n'
    net_confirm_once || return 1

    net_lock a2 || return 1
    tmp=$(mktemp -d) || { net_die '无法创建临时目录'; return 1; }
    net_err '--- 开始写入 ---'
    net_alpine_fetch \
        "$(net_alpine_xray_url "$arch")" \
        "$tmp/xray.zip" "$(net_alpine_xray_sha256 "$arch")" "${TOOLBOX_A2_ZIP_SRC:-}" \
        || { rm -rf -- "$tmp"; net_a2_rollback; return 1; }

    mkdir -p "$tmp/x" && unzip -oq "$tmp/xray.zip" xray -d "$tmp/x" \
        || { rm -rf -- "$tmp"; net_a2_rollback; return 1; }
    [[ -s $tmp/x/xray ]] || { rm -rf -- "$tmp"; net_die '压缩包内没有 xray 二进制。'; return 1; }

    install -d -m 0755 "$etc" && install -m 0755 "$tmp/x/xray" "$bin" \
        || { rm -rf -- "$tmp"; net_a2_rollback; return 1; }

    # 用刚校验过的二进制自己生成凭据，避免与 xray 的编码差异。
    uuid=$("$bin" uuid 2>/dev/null) || { rm -rf -- "$tmp"; net_die 'uuid 生成失败。'; return 1; }
    # 一次调用同时取公私钥：分两次调用会拿到两对不匹配的密钥。
    local kpair
    kpair=$("$bin" x25519 2>/dev/null) || kpair=''
    priv=$(sed -n 's/^PrivateKey: //p' <<< "$kpair")
    pub=$(sed -n 's/^Password (PublicKey): //p' <<< "$kpair")
    net_valid_uuid "$uuid" || { rm -rf -- "$tmp"; net_die 'uuid 输出异常。'; return 1; }
    [[ -n $priv && -n $pub ]] || { rm -rf -- "$tmp"; net_die 'x25519 密钥生成失败。'; return 1; }
    shortid=$(openssl rand -hex 4)

    cfg=$etc/config.json
    cat > "$cfg" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$dhost:$dport",
          "xver": 0,
          "serverNames": [ "$dhost" ],
          "privateKey": "$priv",
          "shortIds": [ "$shortid" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
    chmod 0600 "$cfg" && [[ -s $cfg ]] \
        || { rm -rf -- "$tmp"; net_a2_rollback; return 1; }

    if ! "$bin" run -test -c "$cfg" >"$tmp/t.log" 2>&1; then
        net_err '配置自检失败，xray 输出：'
        sed -n '1,12p' "$tmp/t.log" >&2
        rm -rf -- "$tmp"; net_a2_rollback; return 1
    fi

    cat > "$init" <<EOF
#!/sbin/openrc-run
description="Terry Toolbox Xray server"
command="$bin"
command_args="run -c $etc/config.json"
command_background="yes"
pidfile="$pid"
output_log="$etc/service.log"
error_log="$etc/service.log"
depend() {
    need net
    after firewall nftables iptables
}
EOF
    chmod 0755 "$init" && [[ -s $init ]] \
        || { rm -rf -- "$tmp"; net_a2_rollback; return 1; }

    if ! rc-update add "$NET_ALPINE_XRAY_NAME" default >/dev/null 2>&1; then
        net_err 'rc-update add 失败。'
        rm -rf -- "$tmp"; net_a2_rollback; return 1
    fi
    if ! rc-service "$NET_ALPINE_XRAY_NAME" start >/dev/null 2>&1; then
        net_err 'rc-service start 失败。'
        rc-service "$NET_ALPINE_XRAY_NAME" status >&2 2>&1 || true
        rm -rf -- "$tmp"; net_a2_rollback; return 1
    fi
    if ! net_alpine_wait_active "$NET_ALPINE_XRAY_NAME"; then
        net_err '服务未进入 started 状态。'
        rm -rf -- "$tmp"; net_a2_rollback; return 1
    fi
    if ! net_alpine_wait_owned tcp "$port" "$bin" "$pid"; then
        net_err "服务显示已启动，但 TCP $port 的监听进程不是 $NET_ALPINE_XRAY_NAME。"
        rm -rf -- "$tmp"; net_a2_rollback; return 1
    fi

    if ! net_xray_probe "$bin" "$dhost" "$port" "$uuid" "$pub" "$shortid" good; then
        net_err '认证探测失败（正确 UUID 未连通）。'
        rm -rf -- "$tmp"; net_a2_rollback; return 1
    fi
    if net_xray_probe "$bin" "$dhost" "$port" '11111111-1111-4111-8111-111111111111' \
        "$pub" "$shortid" bad 1; then
        net_err '错误 UUID 也被接受，认证未生效。'
        rm -rf -- "$tmp"; net_a2_rollback; return 1
    fi
    printf '  负向探测：错误 UUID 被拒绝 ✓\n'

    printf '%s|%s|%s|%s\n' "$dhost" "$port" "$dest" "$NET_ALPINE_XRAY_VERSION" > "$etc/meta"
    chmod 0600 "$etc/meta"
    rm -rf -- "$tmp"
    net_a2_report "$dhost" "$port" "$uuid" "$pub" "$shortid" "$dest"
}

net_a2_report() {
    local host=$1 port=$2 uuid=$3 pub=$4 sid=$5 dest=$6
    printf '\n安装完成，服务 %s 已加入 default 运行级。\n' "$NET_ALPINE_XRAY_NAME"
    printf '客户端连接信息（私钥只在 %s/config.json）：\n' "$(net_a2_etc)"
    printf '  vless://%s@%s:%s?type=tcp&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision#terry\n' \
        "$uuid" "$host" "$port" "${dest%:*}" "$pub" "$sid"
    printf '\n验证情况：\n'
    printf '  [已验证] 服务 started、TCP %s 由 %s 监听\n' "$port" "$NET_ALPINE_XRAY_NAME"
    printf '  [已验证] 正确 UUID 经 REALITY 握手连通；错误 UUID 被拒绝\n'
    printf '\n仍需人工处理：\n'
    printf '  - 防火墙/安全组放行 TCP %s（本模块不改防火墙）\n' "$port"
    printf '  - REALITY 不限制回落流量；未认证流量会转发到 %s\n' "$dest"
    printf '  - 卸载：A2 → 2\n'
}

# ---------------------------------------------------------------- A1/A2 卸载与状态

net_alpine_uninstall() { # name init bin etc pid client label lockkey
    local name=$1 init=$2 bin=$3 etc=$4 pid=$5 client=$6 label=$7 lockkey=$8 state
    net_require_root || return 1
    net_alpine_require_openrc || return 1
    state=$(net_alpine_svc_state "$init" "$bin")
    if [[ $state == absent && ! -e $bin && ! -d $etc ]]; then
        net_die "$label：没有找到本模块的安装（init 脚本、二进制、配置都不存在）。"
        return 1
    fi
    if [[ $state == foreign ]]; then
        net_die "$init 不是本模块生成的，未删除；请人工确认。"
        return 1
    fi
    printf '将停止并删除：%s\n  %s\n  %s\n  %s\n' "$init" "$bin" "$etc" '（服务已从 default 运行级移除）'
    net_confirm_once || return 1
    net_lock "$lockkey" || return 1
    rc-service "$name" stop >/dev/null 2>&1 || true
    rc-update del "$name" default >/dev/null 2>&1 || true
    rm -f -- "$init" "$bin" "$pid"
    [[ -d $etc ]] && rm -rf -- "$etc"
    [[ -n $client && -d $client ]] && rm -rf -- "$client"
    printf '已卸载。\n'
}

net_alpine_status() { # name init bin etc proto
    local name=$1 init=$2 bin=$3 etc=$4 proto=$5 host='' port='' _extra='' version='' pid
    if [[ ! -e $init ]]; then
        printf '%s 未安装。\n' "$name"
        return 1
    fi
    pid=$(net_rundir)/$name.pid
    IFS='|' read -r host port _extra version < "$etc/meta" 2>/dev/null || true
    printf 'init: %s\n' "$init"
    if net_alpine_svc_active "$name"; then printf '状态: started\n'; else printf '状态: 未运行\n'; fi
    rc-service "$name" status 2>&1 | sed -n '1,6p'
    if [[ -n ${port:-} ]]; then
        printf '端口 %s 监听: ' "$port"
        if net_alpine_port_owned_by "$proto" "$port" "$bin" "$pid"; then
            printf '由本服务持有\n'
        else
            printf '不是本服务\n'
        fi
    fi
    return 0
}

# ================================================================ A5 Xray (Debian)
#
# 与 A2 同一套上游产物（XTLS/Xray-core 固定版本 + SHA-256 白名单），但这里是
# Debian + systemd 路径。A2 的四个已知问题在此逐条处理：
#
#   1) REALITY 回退滥用：未认证流量会被原样转给回落目标，扫描到就能白嫖转发。
#      按 XTLS 文档给 realitySettings 加 limitFallbackUpload/limitFallbackDownload
#      令牌桶（afterBytes/bytesPerSec/burstBytesPerSec），双向都限，且参数按文档
#      建议随机化（固定值本身是特征）。已用本版本二进制实测：受限后未认证拉 1 MiB
#      从 0.07 s 变为 28 s，而认证连接不受影响。
#      注：评审提到的 dest 对象形式 maxTime/maxBytes 在 v26.10.29 已不被 REALITY
#      的 target 接受（实测 target 只收字符串），现行机制就是上面两个 limit 对象。
#   2) 部分写盘回滚：所有落盘文件登记到 manifest（路径 + 写后 SHA-256），回退只删
#      「登记过且内容未被改动」的路径；单元只在 ExecStart 指向我们的二进制时才停/
#      删，外来同名单元不动。
#   3) 并发：flock 在冲突检查之前拿到，检查与写盘在同一把锁内完成。
#   4) 目标与认证：回落目标必须显式给出，SNI 必须显式给出；写盘前用 openssl 确认
#      目标支持 TLS 1.3 + ALPN h2 且证书覆盖该 SNI（REALITY 要求，缺一即暴露特征）。
#      安装后先用离线冒烟 + 本机 xray 客户端完成「正确 UUID 连通、错误 UUID 被拒」
#      双向认证验证（服务端日志判据），再交给 systemd，最后在真实服务上再验一次。
#
# 没有证书：REALITY 借用回落目标的证书，本模块不碰证书文件。

net_const NET_A5_VERSION '26.10.29'
net_const NET_A5_BIN_NAME 'terry-toolbox-xray'
net_const NET_A5_UNIT_NAME 'terry-toolbox-xray.service'
net_const NET_A5_DEFAULT_PORT 443
net_const NET_A5_TAG 'vless-in'

net_a5_etc()    { printf '%s/terry-toolbox-xray\n' "${TOOLBOX_NET_ETC:-/etc}"; }
net_a5_bin()    { printf '%s/%s\n' "${TOOLBOX_NET_BIN_DIR:-/usr/local/bin}" "$NET_A5_BIN_NAME"; }
net_a5_unit()   { printf '%s/%s\n' "${TOOLBOX_NET_UNIT_DIR:-/etc/systemd/system}" "$NET_A5_UNIT_NAME"; }
net_a5_client() { printf '%s/terry-toolbox-xray-verify\n' "$(net_rundir)"; }
net_a5_cfg()    { printf '%s/config.json\n' "$(net_a5_etc)"; }
net_a5_meta()   { printf '%s/meta\n' "$(net_a5_etc)"; }

# 校验值只维护一份（A2/A5 同一版本同一产物），测试可用 A5 专用变量覆盖。
net_a5_sha256() {
    local arch=$1
    case $arch in
        amd64) [[ -n ${TOOLBOX_A5_SHA256:-} ]] && { printf '%s\n' "$TOOLBOX_A5_SHA256"; return 0; } ;;
        arm64) [[ -n ${TOOLBOX_A5_SHA256_ARM64:-} ]] && { printf '%s\n' "$TOOLBOX_A5_SHA256_ARM64"; return 0; } ;;
    esac
    net_alpine_xray_sha256 "$arch"
}

net_a5_zip_url() {
    local asset
    asset=$(net_xray_asset_arch "$1") || return 1
    printf 'https://github.com/XTLS/Xray-core/releases/download/v%s/Xray-linux-%s.zip\n' \
        "$NET_A5_VERSION" "$asset"
}

# ---------------------------------------------------------------- 回落目标校验

# REALITY 把未认证流量转给目标，目标本身必须「像正常网站」：TLS 1.3、ALPN h2，
# 且证书覆盖我们声明的 SNI。三者缺一，握手特征就会和目标不一致。
net_a5_check_target() { # host port sni
    local host=$1 port=$2 sni=$3 raw='' cert='' chain='' rc=0 n=0 line infile=0
    raw=$(mktemp) || { net_die '无法创建临时文件。'; return 1; }
    cert=$(mktemp) || { rm -f -- "$raw"; net_die '无法创建临时文件。'; return 1; }
    chain=$(mktemp) || { rm -f -- "$raw" "$cert"; net_die '无法创建临时文件。'; return 1; }
    : > "$cert"; : > "$chain"

    timeout 20 openssl s_client -connect "$host:$port" -servername "$sni" \
        -tls1_3 -alpn h2 -showcerts </dev/null >"$raw" 2>&1 || rc=1

    if (( rc != 0 )) && ! grep -q 'BEGIN CERTIFICATE' "$raw"; then
        net_err "回落目标 $host:$port 握手失败（DNS 解析、网络或端口不通）。"
        sed -n '1,6p' "$raw" >&2
        rm -f -- "$raw" "$cert" "$chain"
        return 1
    fi

    # 第一张是叶子证书，其余按链保存（仅用于本机信任度提示）。
    while IFS= read -r line; do
        case $line in
            *"BEGIN CERTIFICATE"*) n=$(( n + 1 )); infile=1 ;;
        esac
        if (( infile == 1 )); then
            if (( n == 1 )); then printf '%s\n' "$line" >> "$cert"; else printf '%s\n' "$line" >> "$chain"; fi
        fi
        case $line in
            *"END CERTIFICATE"*) infile=0 ;;
        esac
    done < "$raw"

    if [[ ! -s $cert ]]; then
        net_err "回落目标 $host:$port 没有返回证书。"
        rm -f -- "$raw" "$cert" "$chain"
        return 1
    fi

    if ! grep -qE '^[[:space:]]*(New, )?Protocol[[:space:]]*:[[:space:]]*TLSv1\.3' "$raw"; then
        net_err "回落目标 $host:$port 不支持 TLS 1.3（REALITY 必需；中间盒降级也会落到这里）。"
        rm -f -- "$raw" "$cert" "$chain"
        return 1
    fi
    if ! grep -qiE '^ALPN protocol: *h2$' "$raw"; then
        net_err "回落目标 $host:$port 协商不到 ALPN h2（REALITY 要求目标支持 HTTP/2）。"
        rm -f -- "$raw" "$cert" "$chain"
        return 1
    fi
    if ! openssl x509 -in "$cert" -noout -checkhost "$sni" 2>/dev/null | grep -q 'does match'; then
        net_err "回落目标的证书不覆盖 SNI $sni（选目标证书里真实存在的名字）。"
        rm -f -- "$raw" "$cert" "$chain"
        return 1
    fi
    if [[ -r /etc/ssl/certs/ca-certificates.crt ]]; then
        local vrc=0
        if [[ -s $chain ]]; then
            openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted "$chain" "$cert" >/dev/null 2>&1 || vrc=1
        else
            openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$cert" >/dev/null 2>&1 || vrc=1
        fi
        (( vrc == 0 )) || net_err '注意：回落目标的证书链未被本机信任库验证通过（客户端看到的仍是同一张证书）。'
    fi
    rm -f -- "$raw" "$cert" "$chain"
    return 0
}

# 回退限速参数：文档建议随机化（固定值本身是特征）。范围取「人类浏览体感」的
# 量级，认证连接不受影响。测试可整体覆盖。
net_a5_limits() {
    local after base
    if [[ -n ${TOOLBOX_A5_LIMITS:-} ]]; then
        # after:downBps:downBurst:upBps:upBurst（全部为字节/秒，测试用）
        IFS=':' read -r A5_AFTER A5_DOWN_BPS A5_DOWN_BURST A5_UP_BPS A5_UP_BURST <<< "$TOOLBOX_A5_LIMITS"
        local f
        for f in "$A5_AFTER" "$A5_DOWN_BPS" "$A5_DOWN_BURST" "$A5_UP_BPS" "$A5_UP_BURST"; do
            [[ $f =~ ^[1-9][0-9]*$ ]] || { net_die "TOOLBOX_A5_LIMITS 格式不对：$TOOLBOX_A5_LIMITS"; return 1; }
        done
        return 0
    fi
    after=$(( (4 + RANDOM % 13) * 1048576 ))
    base=$(( (512 + RANDOM % 513) * 1024 ))
    A5_AFTER=$after; A5_DOWN_BPS=$base; A5_DOWN_BURST=$(( base * (2 + RANDOM % 3) ))
    base=$(( (256 + RANDOM % 257) * 1024 ))
    A5_UP_BPS=$base; A5_UP_BURST=$(( base * (2 + RANDOM % 3) ))
}

# ---------------------------------------------------------------- 归属与回滚

net_a5_conflict() {
    local state
    state=$(net_unit_state "$(net_a5_unit)" "$(net_a5_bin)")
    case $state in
        foreign)
            net_die "$(net_a5_unit) 已存在但不是本模块生成的，未覆盖；请人工确认归属。"
            return 1
            ;;
        ours)
            if systemctl is-active --quiet "$NET_A5_UNIT_NAME" 2>/dev/null; then
                net_die "$NET_A5_UNIT_NAME 已在运行（我们的服务）。重装请先卸载。"
            else
                net_die "$NET_A5_UNIT_NAME 已存在但未运行（我们的残留）。请先卸载。"
            fi
            return 1
            ;;
        absent)
            if [[ -e $(net_a5_bin) || -d $(net_a5_etc) ]]; then
                net_die "已存在 $(net_a5_bin) 或 $(net_a5_etc)，却没有本模块的单元；请人工确认后清理。"
                return 1
            fi
            ;;
    esac
}

# 写盘清单：路径 | 写后 SHA-256。回滚只认清单，不凭猜测删路径。
net_a5_manifest=()
net_a5_etc_created=0

net_a5_record() {
    local sum
    sum=$(sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1) || sum=''
    net_a5_manifest+=("$1|$sum")
}

# 先写到临时路径、校验通过再 mv 到位（mv 同目录内是原子的，不会留半截文件）；
# 成功后登记清单。
net_a5_place() { # mode src dest
    local mode=$1 src=$2 dest=$3
    [[ -s $src ]] || { net_die "临时文件为空：$src"; return 1; }
    install -m "$mode" -- "$src" "$dest.a5tmp" || { net_die "写入失败：$dest"; return 1; }
    if ! mv -f -- "$dest.a5tmp" "$dest"; then
        rm -f -- "$dest.a5tmp"
        net_die "落位失败：$dest"
        return 1
    fi
    net_a5_record "$dest"
}

net_a5_rollback() {
    local unit entry path want now i
    unit=$(net_a5_unit)
    net_err '--- 开始回滚 ---'
    # 单元只在确属本模块时才停：看 ExecStart 是否指向我们的二进制。
    if [[ -e $unit ]] && grep -qF "ExecStart=$(net_a5_bin)" "$unit" 2>/dev/null; then
        systemctl disable --now "$NET_A5_UNIT_NAME" >/dev/null 2>&1 || true
        rm -f -- "$unit"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed "$NET_A5_UNIT_NAME" >/dev/null 2>&1 || true
    fi
    for (( i = ${#net_a5_manifest[@]} - 1; i >= 0; i-- )); do
        entry=${net_a5_manifest[i]}
        path=${entry%%|*}; want=${entry##*|}
        [[ -e $path ]] || continue
        if [[ -n $want ]]; then
            now=$(sha256sum -- "$path" 2>/dev/null | cut -d' ' -f1) || now=''
            if [[ $now != "$want" ]]; then
                net_err "保留 $path：安装期间内容被改动，不当作我们的文件删除。"
                continue
            fi
        fi
        rm -f -- "$path"
    done
    if (( net_a5_etc_created == 1 )) && [[ -d $(net_a5_etc) ]]; then
        rmdir -- "$(net_a5_etc)" 2>/dev/null || true
    fi
    rm -rf -- "$(net_a5_client)"
    net_a5_manifest=()
    if systemctl is-active --quiet "$NET_A5_UNIT_NAME" 2>/dev/null; then
        net_err "警告：回滚后 $NET_A5_UNIT_NAME 仍在运行，请人工确认。"
    fi
    net_err '已按清单恢复到安装前状态。'
}

# ---------------------------------------------------------------- 探针

# 本机 xray 客户端走一遍 REALITY：判据是数据面真拿到 HTTP 响应，不是「进程还在」。
net_a5_probe() { # bin port uuid pub shortid sni label
    local bin=$1 port=$2 uuid=$3 pub=$4 shortid=$5 sni=$6 label=$7
    local dir sock out i cpid result=1
    dir=$(net_a5_client); mkdir -p "$dir" || return 1
    sock=$(net_alpine_free_port $(( 41000 + RANDOM % 2000 )))
    out=$dir/$label.log
    cat > "$dir/$label.json" <<EOF || return 1
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": $sock, "protocol": "socks",
      "settings": { "udp": false } }
  ],
  "outbounds": [
    { "protocol": "vless",
      "settings": { "vnext": [ { "address": "127.0.0.1", "port": $port,
        "users": [ { "id": "$uuid", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
      "streamSettings": { "network": "tcp", "security": "reality",
        "realitySettings": { "serverName": "$sni", "fingerprint": "chrome",
          "publicKey": "$pub", "shortId": "$shortid" } } }
  ]
}
EOF
    # 9>&-：别把调用方的锁句柄带进客户端进程。
    "$bin" run -c "$dir/$label.json" >"$out" 2>&1 9>&- &
    cpid=$!
    for ((i = 0; i < 75; i++)); do
        grep -q 'started' "$out" 2>/dev/null && { result=0; break; }
        grep -q 'Failed to start' "$out" 2>/dev/null && break
        kill -0 "$cpid" 2>/dev/null || break
        sleep 0.2
    done
    (( result == 1 )) && grep -q 'started' "$out" 2>/dev/null && result=0
    if (( result == 0 )); then
        # -k：目标证书已由 net_a5_check_target 验过，这里只关心隧道是否通。
        local code=''
        for ((i = 0; i < 3; i++)); do
            code=$(timeout 25 curl -sSk --max-time 20 --socks5-hostname "127.0.0.1:$sock" \
                -o /dev/null -w '%{http_code}' "https://$sni/" 2>/dev/null) || code=''
            [[ $code == 2* || $code == 3* ]] && break
            sleep 1
        done
        [[ $code == 2* || $code == 3* ]] || { net_err "探针 $label：隧道无数据面响应（HTTP $code）。"; result=1; }
    else
        sed -n '1,8p' "$out" >&2
    fi
    kill "$cpid" 2>/dev/null
    wait "$cpid" 2>/dev/null || true
    return $result
}

net_a5_wait_listen() { # logfile
    local log=$1 i
    for ((i = 0; i < 60; i++)); do
        grep -q 'listening tcp' "$log" 2>/dev/null && return 0
        sleep 0.2
    done
    return 1
}

# ---------------------------------------------------------------- 安装

_net_a5_install() {
    local target=${1:-} sni=${2:-} port=${3:-} answer
    local thost='' tport='' arch tmp etc bin unit uuid priv pub shortid
    local cfg log smcfg accepted rejected after_accepted after_rejected
    local A5_AFTER='' A5_DOWN_BPS='' A5_DOWN_BURST='' A5_UP_BPS='' A5_UP_BURST=''
    local spid=''

    net_require_root || return 1
    net_require_debian || return 1
    net_require_systemd || return 1
    net_require_cmds openssl sha256sum curl install flock ss cut unzip mktemp timeout sed || return 1
    arch=$(net_alpine_arch) || return 1

    [[ -n $target ]] || { net_die '缺少回落目标（显式给出 主机名[:端口]，默认端口 443）。'; return 1; }
    [[ -n $sni ]] || { net_die '缺少 SNI 主机名（必须是回落目标证书覆盖的名字，需显式给出）。'; return 1; }
    sni=${sni,,}

    thost=${target%%:*}; tport=''
    [[ $target == *:* ]] && tport=${target##*:}
    [[ -n $tport ]] || tport=$NET_A5_DEFAULT_PORT
    net_valid_target_host "$thost" || { net_die "回落目标格式不正确：$target"; return 1; }
    net_valid_port "$tport" || { net_die "回落目标端口不正确：$tport"; return 1; }
    net_valid_hostname "$sni" || { net_die "SNI 格式不正确：$sni"; return 1; }
    if [[ -n $port ]]; then
        net_valid_port "$port" || { net_die "监听端口不正确：$port（1-65535，无前导零）"; return 1; }
    else
        port=$NET_A5_DEFAULT_PORT
    fi

    etc=$(net_a5_etc); bin=$(net_a5_bin); unit=$(net_a5_unit)
    cfg=$(net_a5_cfg)

    # 目标能力：写盘前确认，失败即拒绝（不会留半套东西）。
    net_err "检查回落目标 $thost:$tport（TLS 1.3 + h2 + 证书覆盖 $sni）…"
    net_a5_check_target "$thost" "$tport" "$sni" || return 1

    net_a5_limits || return 1

    # 检查与写盘之间不允许别人插进来。
    net_lock a5 || return 1

    net_a5_conflict || return 1
    if net_port_busy tcp "$port"; then
        net_err "TCP $port 已被占用："
        net_port_lines tcp "$port" | cut -c1-160 >&2
        net_die '换端口，或先确认并停止占用方。'
        return 1
    fi

    printf '即将安装 Xray 服务端（VLESS + TCP + REALITY，systemd）：\n'
    printf '  版本    : v%s（官方发布，安装前校验 SHA-256）\n' "$NET_A5_VERSION"
    printf '  监听    : :%s/tcp（所有地址，IPv4+IPv6）\n' "$port"
    printf '  回落    : %s:%s（已验 TLS 1.3 / h2 / 证书覆盖 %s）\n' "$thost" "$tport" "$sni"
    printf '  回退限速: 未认证流量 %s MiB 后限 %s KiB/s（下行）/ %s KiB/s（上行），认证连接不限\n' \
        "$(( A5_AFTER / 1048576 ))" "$(( A5_DOWN_BPS / 1024 ))" "$(( A5_UP_BPS / 1024 ))"
    printf '  单元    : %s\n' "$unit"
    printf '  凭据    : 随机 UUID，只显示一次；私钥只写 %s\n' "$cfg"
    printf '  防火墙  : 不改动；需自行放行 TCP %s\n' "$port"
    net_confirm_twice XRAY || return 1

    tmp=$(mktemp -d) || { net_die '无法创建临时目录'; return 1; }
    net_err '--- 开始写入 ---'

    if [[ -n ${TOOLBOX_A5_ZIP_SRC:-} ]]; then
        cp -- "$TOOLBOX_A5_ZIP_SRC" "$tmp/xray.zip" || { rm -rf -- "$tmp"; net_die '复制本地压缩包失败'; return 1; }
    else
        net_err "下载官方发布文件：$(net_a5_zip_url "$arch")"
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \
            -o "$tmp/xray.zip" "$(net_a5_zip_url "$arch")" \
            || { rm -rf -- "$tmp"; net_die '下载失败（网络或上游不可达）。'; return 1; }
    fi
    local actual; actual=$(sha256sum -- "$tmp/xray.zip" | cut -d' ' -f1)
    [[ $actual == "$(net_a5_sha256 "$arch")" ]] \
        || { rm -rf -- "$tmp"; net_die "SHA-256 不匹配：期望 $(net_a5_sha256 "$arch")，实际 $actual。"; return 1; }

    mkdir -p "$tmp/x" && unzip -oq "$tmp/xray.zip" xray -d "$tmp/x" \
        || { rm -rf -- "$tmp"; net_die '解压失败'; return 1; }
    [[ -s $tmp/x/xray ]] || { rm -rf -- "$tmp"; net_die '压缩包内没有 xray 二进制。'; return 1; }

    # 凭据用刚校验过的二进制自己生成，避免编码差异。
    uuid=$("$tmp/x/xray" uuid 2>/dev/null) || { rm -rf -- "$tmp"; net_die 'uuid 生成失败'; return 1; }
    net_valid_uuid "$uuid" || { rm -rf -- "$tmp"; net_die 'uuid 输出异常'; return 1; }
    # 一次调用同时取公私钥：分两次调用会拿到两对不匹配的密钥。
    local kpair
    kpair=$("$tmp/x/xray" x25519 2>/dev/null) || kpair=''
    priv=$(sed -n 's/^PrivateKey: //p' <<< "$kpair")
    pub=$(sed -n 's/^Password (PublicKey): //p' <<< "$kpair")
    [[ -n $priv && -n $pub ]] || { rm -rf -- "$tmp"; net_die 'x25519 密钥生成失败'; return 1; }
    shortid=$(openssl rand -hex 8)

    if [[ -d $etc ]]; then net_a5_etc_created=0; else
        install -d -m 0755 -- "$etc" || { rm -rf -- "$tmp"; net_die '无法创建配置目录'; return 1; }
        net_a5_etc_created=1
    fi
    install -d -m 0755 -- "$(dirname -- "$bin")" || { rm -rf -- "$tmp"; net_die '无法创建二进制目录'; return 1; }

    # 配置先落在临时目录，自检通过后才到位：partial 写入不会污染 etc。
    cat > "$tmp/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "$NET_A5_TAG",
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid", "email": "terry", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$thost:$tport",
          "xver": 0,
          "serverNames": [ "$sni" ],
          "privateKey": "$priv",
          "shortIds": [ "$shortid" ],
          "limitFallbackUpload": {
            "afterBytes": $A5_AFTER,
            "bytesPerSec": $A5_UP_BPS,
            "burstBytesPerSec": $A5_UP_BURST
          },
          "limitFallbackDownload": {
            "afterBytes": $A5_AFTER,
            "bytesPerSec": $A5_DOWN_BPS,
            "burstBytesPerSec": $A5_DOWN_BURST
          }
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
    chmod 0600 "$tmp/config.json" && [[ -s $tmp/config.json ]] \
        || { rm -rf -- "$tmp"; net_die '配置写入失败'; return 1; }

    # 二进制先到位（自检要用它），然后登记 → 之后任何失败都可回滚。
    net_a5_place 0755 "$tmp/x/xray" "$bin" || { rm -rf -- "$tmp"; net_a5_rollback; return 1; }

    if ! "$bin" run -test -c "$tmp/config.json" >"$tmp/t.log" 2>&1; then
        net_err '配置自检失败，xray 输出：'
        sed -n '1,12p' "$tmp/t.log" >&2
        rm -rf -- "$tmp"; net_a5_rollback; return 1
    fi

    cat > "$tmp/unit" <<EOF
[Unit]
Description=Terry Toolbox Xray server
Documentation=https://xtls.github.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$etc
ExecStart=$bin run -c $cfg
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$etc
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
    net_a5_place 0600 "$tmp/config.json" "$cfg" || { rm -rf -- "$tmp"; net_a5_rollback; return 1; }
    net_a5_place 0644 "$tmp/unit" "$unit" || { rm -rf -- "$tmp"; net_a5_rollback; return 1; }

    # 冒烟：用真实配置在真实端口上先跑一遍。loglevel 提到 info，认证判据要日志。
    log="$tmp/smoke.log"; smcfg="$tmp/smoke.json"
    sed 's/"loglevel": "warning"/"loglevel": "info"/' "$cfg" > "$smcfg"
    : > "$log"
    "$bin" run -c "$smcfg" >"$log" 2>&1 9>&- &
    spid=$!
    if ! net_a5_wait_listen "$log"; then
        net_err '冒烟启动失败（未监听），服务输出：'
        sed -n '1,12p' "$log" >&2
        kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true
        rm -rf -- "$tmp"; net_a5_rollback; return 1
    fi

    accepted=$(grep -c "accepted tcp:" "$log" 2>/dev/null || true)
    rejected=$(grep -c "invalid request user id" "$log" 2>/dev/null || true)

    if ! net_a5_probe "$bin" "$port" "$uuid" "$pub" "$shortid" "$sni" good; then
        net_err '认证探测失败（正确 UUID 未连通或无数据面）。'
        sed -n '1,12p' "$log" >&2
        kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true
        rm -rf -- "$tmp"; net_a5_rollback; return 1
    fi

    after_accepted=$(grep -c "accepted tcp:" "$log" 2>/dev/null || true)
    if (( after_accepted <= accepted )); then
        net_err '隧道有数据，但服务端日志没有认证通过记录（可能只是回退转发，认证未生效）。'
        sed -n '1,12p' "$log" >&2
        kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true
        rm -rf -- "$tmp"; net_a5_rollback; return 1
    fi

    # 负向：错误 UUID 必须被服务端明确拒绝。
    net_a5_probe "$bin" "$port" '11111111-1111-4111-8111-111111111111' \
        "$pub" "$shortid" "$sni" bad || true
    after_rejected=$(grep -c "invalid request user id" "$log" 2>/dev/null || true)
    if (( after_rejected <= rejected )); then
        net_err '错误 UUID 没有被拒绝，认证未生效。'
        sed -n '1,12p' "$log" >&2
        kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true
        rm -rf -- "$tmp"; net_a5_rollback; return 1
    fi
    printf '  负向探测：错误 UUID 被拒绝 ✓\n'

    kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true

    if ! systemctl daemon-reload; then rm -rf -- "$tmp"; net_a5_rollback; return 1; fi
    if ! systemctl enable --now "$NET_A5_UNIT_NAME" >/dev/null 2>&1; then
        net_err 'systemctl enable --now 失败。'
        rm -rf -- "$tmp"; net_a5_rollback; return 1
    fi
    if ! net_wait_active "$NET_A5_UNIT_NAME"; then
        net_err '服务未进入 active 状态。'
        systemctl --no-pager -l status "$NET_A5_UNIT_NAME" >&2 2>&1 || true
        rm -rf -- "$tmp"; net_a5_rollback; return 1
    fi
    if ! net_wait_owned tcp "$port" "$bin" "$NET_A5_UNIT_NAME"; then
        net_err "单元显示运行中，但 TCP $port 的监听进程不是 $NET_A5_BIN_NAME。"
        rm -rf -- "$tmp"; net_a5_rollback; return 1
    fi
    # 真实服务上再验一次（冒烟进程已退出，这里是 systemd 起的那个）。
    if ! net_a5_probe "$bin" "$port" "$uuid" "$pub" "$shortid" "$sni" live; then
        net_err '对已启用的服务再探测失败。'
        rm -rf -- "$tmp"; net_a5_rollback; return 1
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$thost" "$tport" "$sni" "$port" "$uuid" "$pub" \
        "$shortid" "$NET_A5_VERSION" > "$tmp/meta" || { rm -rf -- "$tmp"; net_die 'meta 写入失败'; return 1; }
    net_a5_place 0600 "$tmp/meta" "$(net_a5_meta)" || { rm -rf -- "$tmp"; net_a5_rollback; return 1; }
    rm -rf -- "$tmp"
    net_a5_report "$thost" "$tport" "$sni" "$port" "$uuid" "$pub" "$shortid" \
        "$A5_AFTER" "$A5_DOWN_BPS" "$A5_UP_BPS"
}

net_a5_report() {
    local thost=$1 tport=$2 sni=$3 port=$4 uuid=$5 pub=$6 sid=$7 after=$8 dbps=$9 ubps=${10}
    printf '\n安装完成，服务 %s 已设为开机自启。\n' "$NET_A5_UNIT_NAME"
    printf '客户端连接信息（只显示这一次，也写入 %s）：\n' "$(net_a5_meta)"
    printf '  vless://%s@%s:%s?type=tcp&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision#terry\n' \
        "$uuid" "$sni" "$port" "$sni" "$pub" "$sid"
    printf '\n验证情况：\n'
    printf '  [已验证] 回落目标 %s:%s 支持 TLS 1.3、ALPN h2，证书覆盖 %s\n' "$thost" "$tport" "$sni"
    printf '  [已验证] 单元 active、TCP %s 由 %s 监听\n' "$port" "$NET_A5_BIN_NAME"
    printf '  [已验证] 正确 UUID 经 REALITY 建立隧道并有数据面响应；错误 UUID 被服务端拒绝\n'
    printf '  [已限制] 未认证回退流量：%s MiB 后限 %s KiB/s 下行、%s KiB/s 上行\n' \
        "$(( after / 1048576 ))" "$(( dbps / 1024 ))" "$(( ubps / 1024 ))"
    printf '\n仍需人工处理：\n'
    printf '  - 防火墙/安全组放行 TCP %s（本模块不改防火墙）\n' "$port"
    printf '  - 目标证书更新无需改动；目标站点关停/换证书后需重装换目标\n'
    printf '  - 卸载：A5 → 2\n'
}

# ---------------------------------------------------------------- 卸载与状态

_net_a5_uninstall() {
    local unit etc bin state answer
    net_require_root || return 1
    net_require_systemd || return 1
    unit=$(net_a5_unit); etc=$(net_a5_etc); bin=$(net_a5_bin)
    state=$(net_unit_state "$unit" "$bin")
    if [[ $state == absent && ! -e $bin && ! -d $etc ]]; then
        net_die '没有找到本模块的安装（单元、二进制、配置都不存在）。'
        return 1
    fi
    if [[ $state == foreign ]]; then
        net_die "$unit 不是本模块生成的，未删除；请人工确认。"
        return 1
    fi
    printf '将停止并删除：\n  %s\n  %s\n  %s\n' "$unit" "$bin" "$etc"
    net_confirm_once || return 1
    net_lock a5 || return 1

    # 只停/删我们的单元（ExecStart 指向我们的二进制）。
    if [[ -e $unit ]] && grep -qF "ExecStart=$bin" "$unit" 2>/dev/null; then
        systemctl disable --now "$NET_A5_UNIT_NAME" >/dev/null 2>&1 || true
        rm -f -- "$unit"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$NET_A5_UNIT_NAME" >/dev/null 2>&1 || true
    rm -f -- "$bin"
    [[ -d $etc ]] && rm -rf -- "$etc"
    rm -rf -- "$(net_a5_client)"
    printf '已卸载。\n'
}

net_a5_status() {
    local unit meta thost tport sni port uuid pub sid version bin
    unit=$(net_a5_unit); meta=$(net_a5_meta); bin=$(net_a5_bin)
    if [[ ! -e $unit ]]; then
        printf '未安装。\n'
        return 1
    fi
    printf '单元: %s（%s）\n' "$unit" "$(net_unit_state "$unit" "$bin")"
    systemctl --no-pager -l status "$NET_A5_UNIT_NAME" 2>&1 | sed -n '1,6p'
    if [[ -f $meta ]]; then
        IFS='|' read -r thost tport sni port uuid pub sid version < "$meta" || true
        printf '回落目标: %s:%s（SNI %s）\n' "${thost:-?}" "${tport:-?}" "${sni:-?}"
        printf '版本: %s\n' "${version:-?}"
        if [[ -n ${port:-} ]]; then
            printf 'TCP %s 监听: ' "$port"
            if net_port_owned_by tcp "$port" "$bin" "$NET_A5_UNIT_NAME"; then
                printf '由本服务持有\n'
            else
                printf '不是本服务\n'
            fi
        fi
    else
        printf '缺少 meta（目标/凭据未知）。\n'
    fi
}

# ================================================================ B23 DNS 切换
#
# 只在 systemd-resolved 真正接管解析时动手：resolvectl 存在、服务 active、
# stub-resolv.conf 存在，且 /etc/resolv.conf 确实指向 stub。其他解析器
# （NetworkManager、openresolv、手写文件）一律 fail closed。
# 持久化用 resolved.conf.d drop-in + 重启 systemd-resolved；同时按默认路由链路
# 写运行期设置，覆盖 DHCP 下发。成功判据是 resolvectl status 与 query 都能过。

net_dns_dropin() { printf '%s/%s\n' "${TOOLBOX_DNS_DROPIN_DIR:-/etc/systemd/resolved.conf.d}" '99-terry-toolbox-dns.conf'; }
net_dns_resolv() { printf '%s\n' "${TOOLBOX_DNS_RESOLV_CONF:-/etc/resolv.conf}"; }
net_dns_run()    { printf '%s\n' "${TOOLBOX_DNS_RESOLVE_RUN:-/run/systemd/resolve}"; }

net_dns_require_resolved() {
    command -v resolvectl >/dev/null 2>&1 || { net_die '未找到 resolvectl，本机没有 systemd-resolved。'; return 1; }
    systemctl is-active --quiet systemd-resolved 2>/dev/null \
        || { net_die 'systemd-resolved 未运行（容器或被禁用）。'; return 1; }
    [[ -e $(net_dns_run)/stub-resolv.conf ]] \
        || { net_die "缺少 $(net_dns_run)/stub-resolv.conf，无法确认由 systemd-resolved 接管。"; return 1; }
}

net_dns_check_resolv() {
    local conf target
    conf=$(net_dns_resolv)
    [[ -e $conf || -L $conf ]] || { net_die "$conf 不存在。"; return 1; }
    [[ -L $conf ]] || { net_die "$conf 是普通文件（不是 systemd-resolved 的 stub 链接），解析权不在 resolved。"; return 1; }
    target=$(readlink -- "$conf")
    case $target in
        *systemd/resolve/stub-resolv.conf|*systemd/resolve/resolv.conf) return 0 ;;
        *) net_die "$conf 指向 $target，不是 systemd-resolved 的 stub，被其他程序接管。" ;;
    esac
}

# 默认路由链路。新版 systemd 直接给 "Default Route: yes" 字段，用它最准确；
# 旧版只能看 Protocols 里的 +DefaultRoute，此时再排除 Current Scopes: none
# （tailscale 之类会挂 +DefaultRoute 但没有 DNS）。多个或没有就返回空。
net_dns_default_link() {
    local out line name='' default='' count=0 scopes_none=0 has_field=0 dns_links
    out=$(resolvectl status 2>/dev/null) || return 0
    # 该字段在 Protocol 之后才出现，先单独收集有 DNS 的链路，避免顺序依赖。
    dns_links=" $(net_dns_links_with_dns | tr '\n' ' ') "
    grep -qE '^[[:space:]]*Default Route:' <<< "$out" && has_field=1
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*Link\ ([0-9]+)\ \((.+)\)$ ]]; then
            name=${BASH_REMATCH[2]}; name=${name%%@*}
            scopes_none=0
            continue
        fi
        [[ -z $name ]] && continue
        # 有默认路由但没有 DNS 的链路（tailscale、docker 网桥）不算可用的出口链路。
        [[ $dns_links == *" $name "* ]] || continue
        if [[ $line == *'Current Scopes:'* && $line == *none* ]]; then
            scopes_none=1
            continue
        fi
        if (( has_field )); then
            if [[ $line =~ ^[[:space:]]*Default\ Route:[[:space:]]*yes ]]; then
                default=$name; ((count += 1))
            fi
        elif [[ $line == *'+DefaultRoute'* && $scopes_none == 0 ]]; then
            default=$name; ((count += 1))
        fi
    done <<< "$out"
    (( count == 1 )) && printf '%s\n' "$default"
    return 0
}

# 某条链路上当前的 DNS 服务器（空格分隔，可能为空）。
net_dns_link_servers() {
    local line name='' out=''
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*Link\ ([0-9]+)\ \((.+)\)$ ]]; then
            name=${BASH_REMATCH[2]}; name=${name%%@*}
            continue
        fi
        if [[ $name == "$1" && $line =~ ^[[:space:]]*DNS\ Servers:[[:space:]]*(.*)$ ]]; then
            out=${BASH_REMATCH[1]}
        fi
    done < <(resolvectl status 2>/dev/null)
    printf '%s' "$out"
}

# 部分 systemd 版本的 `resolvectl revert` 不接受空参数（会报 Interface argument
# required），所以要逐条链路退回，但只碰「DNS 里含我们写入的服务器」的链路。
net_dns_revert_ours() { # servers...
    local our=" $* " link srv s hit
    while IFS= read -r link; do
        [[ -n $link ]] || continue
        srv=$(net_dns_link_servers "$link")
        hit=0
        for s in $srv; do
            [[ $our == *" $s "* ]] && { hit=1; break; }
        done
        (( hit )) && resolvectl revert "$link" >/dev/null 2>&1 || true
    done < <(net_dns_links_with_dns)
}

# 配置了 DNS 服务器的链路名（一行一个），只用于判断「这条链路能不能当出口」。
net_dns_links_with_dns() {
    local line name=''
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*Link\ ([0-9]+)\ \((.+)\)$ ]]; then
            name=${BASH_REMATCH[2]}; name=${name%%@*}
            continue
        fi
        if [[ -n $name && $line =~ ^[[:space:]]*(Current\ DNS\ Server|DNS\ Servers): ]]; then
            printf '%s\n' "$name"
        fi
    done < <(resolvectl status 2>/dev/null)
}

# 其他链路自带的 DNS：Domains=~. 下它们只在本域生效，但仍值得点名。
net_dns_leak_links() { # [跳过本链路]
    local line name='' found='' servers
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*Link\ ([0-9]+)\ \((.+)\)$ ]]; then
            name=${BASH_REMATCH[2]}; name=${name%%@*}
            continue
        fi
        if [[ $line =~ ^[[:space:]]*(Current\ DNS\ Server|DNS\ Servers):[[:space:]]*(.*)$ ]]; then
            servers=${BASH_REMATCH[2]}
            [[ -n $name && -n $servers ]] || continue
            [[ -n ${1:-} && $name == "$1" ]] && continue
            case " $found " in
                *" $name "*) ;;
                *) found+="$name "; printf '%s(%s) ' "$name" "$servers" ;;
            esac
        fi
    done < <(resolvectl status 2>/dev/null)
}

net_dns_preset() {
    case $1 in
        1) printf '1.1.1.1 1.0.0.1' ;;
        2) printf '8.8.8.8 8.8.4.4' ;;
        3) printf '9.9.9.9 149.112.112.112' ;;
        4) printf '223.5.5.5 223.6.6.6' ;;
        5) printf '119.29.29.29 182.254.116.116' ;;
        *) return 1 ;;
    esac
}

net_valid_ip() { net_valid_ipv4 "$1" || net_valid_ipv6 "$1"; }

net_valid_ipv4() {
    local o
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in $1; do (( o <= 255 )) || return 1; done
}

net_valid_ipv6() {
    [[ $1 == *:* && $1 =~ ^[0-9a-fA-F:.]+$ ]] || return 1
    [[ $1 == *::* || $(grep -o ':' <<< "$1" | wc -l) -eq 7 ]]
}

net_dns_write() { # servers...
    local file tmp
    file=$(net_dns_dropin)
    install -d -m 0755 "$(dirname -- "$file")" || { net_die "无法创建 $(dirname -- "$file")"; return 1; }
    # 只保留第一次的原始备份：多次切换后回滚仍回到本工具接管前的状态。
    if [[ -e $file && ! -e $file.pre-toolbox ]]; then
        cp -p -- "$file" "$file.pre-toolbox" || { net_die '备份现有配置失败。'; return 1; }
    fi
    tmp=$file.new.$$
    {
        printf '# 由 Terry Toolbox B23 生成；恢复请走 B23 → 7，或删除本文件后重启 systemd-resolved。\n'
        printf '[Resolve]\nDNS=%s\nDomains=~.\n' "$*"
    } > "$tmp" || { net_die '写入临时配置失败。'; return 1; }
    chmod 0644 "$tmp" && mv -f -- "$tmp" "$file" \
        || { rm -f -- "$tmp"; net_die '替换配置失败。'; return 1; }
}

net_dns_restart_resolved() {
    local i
    systemctl restart systemd-resolved >/dev/null 2>&1 || { net_die '重启 systemd-resolved 失败。'; return 1; }
    for ((i = 0; i < 20; i++)); do
        systemctl is-active --quiet systemd-resolved 2>/dev/null && return 0
        sleep 0.3
    done
    net_die 'systemd-resolved 重启后未回到 active。'
}

net_dns_rollback() {
    local file link=${1:-}
    file=$(net_dns_dropin)
    net_err '--- 开始回滚 DNS ---'
    if [[ -e $file.pre-toolbox ]]; then
        mv -f -- "$file.pre-toolbox" "$file" || net_err "警告：还原 $file 失败，请人工检查。"
    else
        rm -f -- "$file"
    fi
    [[ -n $link ]] && resolvectl revert "$link" >/dev/null 2>&1 || true
    systemctl restart systemd-resolved >/dev/null 2>&1 \
        || net_err '警告：重启 systemd-resolved 失败，请人工确认。'
    net_err '已恢复原有 DNS 配置。'
}

# 成功判据：status 里必须能看到每个服务器，query 也必须真的能解析。
net_dns_verify() {
    local out s i
    out=$(resolvectl status 2>/dev/null) || { net_die '读取 resolvectl status 失败。'; return 1; }
    for s in "$@"; do
        grep -qF -- "$s" <<< "$out" || { net_die "resolvectl status 里看不到 $s，配置未生效。"; return 1; }
    done
    for ((i = 0; i < 3; i++)); do
        resolvectl query www.cloudflare.com >/dev/null 2>&1 && return 0
        sleep 1
    done
    net_die '解析查询仍然失败（服务器不可达或被拦截）。'
}

_net_dns_apply() {
    local servers=("$@") link='' s other had_backup=0
    net_require_root || return 1
    net_dns_require_resolved || return 1
    net_dns_check_resolv || return 1
    (( ${#servers[@]} > 0 )) || { net_die '没有要设置的 DNS 服务器。'; return 1; }
    (( ${#servers[@]} <= 2 )) || { net_die '最多两个 DNS 服务器。'; return 1; }
    for s in "${servers[@]}"; do
        net_valid_ip "$s" || { net_die "不是合法的 IPv4/IPv6 地址：$s"; return 1; }
    done

    link=$(net_dns_default_link)
    printf '即将修改本机 DNS：\n'
    for s in "${servers[@]}"; do printf '  DNS 服务器: %s\n' "$s"; done
    printf '  配置文件  : %s（drop-in，重启后仍生效）\n' "$(net_dns_dropin)"
    if [[ -n $link ]]; then
        printf '  作用链路  : %s（默认路由；全局与链路同时写，覆盖 DHCP 下发）\n' "$link"
    else
        printf '  作用链路  : 未能唯一定位默认路由，只写全局（链路自带 DNS 可能优先）\n'
    fi
    printf '  影响      : 会重启 systemd-resolved，DNS 可能短暂中断；明文 DNS（非 DoT/DoH）\n'
    net_confirm_once || return 1

    net_lock dns || return 1
    [[ -e $(net_dns_dropin).pre-toolbox ]] && had_backup=1
    if ! net_dns_write "${servers[@]}"; then
        # 写失败时只在本次新建了备份的情况下清掉，避免丢掉更早的原始备份。
        (( had_backup )) || rm -f -- "$(net_dns_dropin).pre-toolbox"
        return 1
    fi
    if ! net_dns_restart_resolved; then
        net_dns_rollback "$link"
        return 1
    fi
    if [[ -n $link ]]; then
        resolvectl dns "$link" "${servers[@]}" >/dev/null 2>&1 \
            || { net_err "resolvectl dns $link 失败。"; net_dns_rollback "$link"; return 1; }
        resolvectl domain "$link" '~.' >/dev/null 2>&1 \
            || { net_err "resolvectl domain $link 失败。"; net_dns_rollback "$link"; return 1; }
    fi
    if ! net_dns_verify "${servers[@]}"; then
        net_dns_rollback "$link"
        return 1
    fi

    printf '\nDNS 已切换并验证通过：\n'
    for s in "${servers[@]}"; do printf '  [已验证] %s 出现在 resolvectl status\n' "$s"; done
    printf '  [已验证] resolvectl query 可以正常解析\n'
    printf '\n剩余泄漏面（本模块不处理，需自行评估）：\n'
    other=$(net_dns_leak_links "$link")
    if [[ -n $other ]]; then
        printf '  - 其他链路仍有自己的 DNS，命中其域名的查询可能走它们：%s\n' "$other"
    else
        printf '  - 当前没发现其他链路自带 DNS；以后插网卡/VPN 仍可能新增\n'
    fi
    printf '  - 明文 DNS，可被中间人看到；需要加密请另配 DNS over TLS\n'
    printf '  - 容器、自带解析器的应用（docker、nginx 缓存、部分 VPN 客户端）不受本设置约束\n'
    printf '  - 恢复原状：B23 → 7（删除 %s 并重启 systemd-resolved）\n' "$(net_dns_dropin)"
}

net_dns_status() {
    local file other
    file=$(net_dns_dropin)
    printf 'systemd-resolved: '
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then printf '运行中\n'; else printf '未运行\n'; fi
    printf '%s -> %s\n' "$(net_dns_resolv)" \
        "$(readlink -- "$(net_dns_resolv)" 2>/dev/null || printf '（普通文件）')"
    if [[ -e $file ]]; then
        printf '本工具配置: %s\n' "$file"
        sed -n '1,10p' "$file"
    else
        printf '本工具配置: 无（当前 DNS 不是本工具设置的）\n'
    fi
    printf '\n当前解析状态：\n'
    resolvectl status 2>/dev/null | sed -n '1,25p'
    other=$(net_dns_leak_links)
    [[ -n $other ]] && printf '\n其他链路 DNS（潜在泄漏）：%s\n' "$other"
    return 0
}

_net_dns_restore() {
    local file ours=''
    net_require_root || return 1
    net_dns_require_resolved || return 1
    file=$(net_dns_dropin)
    if [[ ! -e $file && ! -e $file.pre-toolbox ]]; then
        net_die '没有本工具写入的 DNS 配置，无需恢复。'
        return 1
    fi
    # 恢复过备份后文件还在，但已经不含本工具的标记；再恢复一次就会误删别人的配置。
    if [[ -e $file && ! -e $file.pre-toolbox ]] \
        && ! grep -qF '由 Terry Toolbox B23 生成' "$file" 2>/dev/null; then
        net_die "$file 已不是本工具生成的配置，未删除；请人工确认。"
        return 1
    fi
    printf '将删除 %s 并重启 systemd-resolved（DNS 可能短暂中断）。\n' "$file"
    net_confirm_once || return 1
    ours=$(sed -n 's/^DNS=//p' "$file" 2>/dev/null) || ours=''
    if [[ -e $file.pre-toolbox ]]; then
        mv -f -- "$file.pre-toolbox" "$file" || { net_die '还原备份失败。'; return 1; }
    else
        rm -f -- "$file"
    fi
    # shellcheck disable=SC2086
    net_dns_revert_ours $ours
    net_dns_restart_resolved || return 1
    printf '已恢复。当前解析状态：\n'
    resolvectl status 2>/dev/null | sed -n '1,15p'
}

# B23 入口：直接调用时接受 install/restore/status，不带动作时进预置菜单。
toolbox_network_dns() {
    local c='' input s
    local -a servers=()
    if (( $# > 0 )); then
        case $1 in
            install)
                shift
                (( $# > 0 )) || { net_die '用法: toolbox_network B23 install <DNS1> [DNS2]'; return 1; }
                ( set -e; _net_dns_apply "$@" )
                ;;
            restore) ( set -e; _net_dns_restore ) ;;
            status) net_dns_status ;;
            *) net_die '用法: toolbox_network B23 [install <DNS1> [DNS2] | restore | status]' ;;
        esac
        return $?
    fi

    printf 'B23 DNS 切换（仅 systemd-resolved）\n' >&2
    printf ' 1 Cloudflare 1.1.1.1/1.0.0.1\n 2 Google 8.8.8.8/8.8.4.4\n' >&2
    printf ' 3 Quad9 9.9.9.9/149.112.112.112\n 4 阿里 223.5.5.5/223.6.6.6\n' >&2
    printf ' 5 腾讯 119.29.29.29/182.254.116.116\n 6 自定义\n 7 恢复原状\n 8 查看状态\n请输入编号：' >&2
    IFS= read -r c || return 1
    case $c in
        1|2|3|4|5)
            for s in $(net_dns_preset "$c"); do servers+=("$s"); done
            ( set -e; _net_dns_apply "${servers[@]}" )
            ;;
        6)
            printf '输入 1-2 个 IPv4/IPv6 地址（空格或逗号分隔）：'
            IFS= read -r input || return 1
            input=${input//,/ }
            for s in $input; do servers+=("$s"); done
            ( set -e; _net_dns_apply "${servers[@]}" )
            ;;
        7) ( set -e; _net_dns_restore ) ;;
        8) net_dns_status ;;
        *) net_die '无效选项。' ;;
    esac
}

# ================================================================ 入口

toolbox_network() {
    if (( $# < 1 || $# > 6 )); then
        printf '用法: toolbox_network <A1|A2|A3|A4|A5|B12|B23|B31>\n' >&2
        printf '     toolbox_network A1  [install <证书> <私钥> <主机名> [端口] | uninstall | status]\n' >&2
        printf '     toolbox_network A2  [install [端口] [回落目标] | uninstall | status]\n' >&2
        printf '     toolbox_network A3  [install|uninstall|status] [证书] [私钥] [主机名] [端口]\n' >&2
        printf '     toolbox_network A5  [install <回落目标> <SNI主机名> [端口] | uninstall | status]\n' >&2
        printf '     toolbox_network B12 [install|uninstall|status]\n' >&2
        printf '     toolbox_network B23 [install <DNS...> | restore | status]\n' >&2
        printf '     toolbox_network B31 [install|uninstall|status] <tcp|udp> <本地端口> [目标主机] [目标端口]\n' >&2
        return 2
    fi
    local key=$1 action description
    shift || true
    case $key in
        A1)
            action=${1:-}
            if [[ -z $action ]]; then
                action=$(net_submenu 'A1 Alpine Hysteria 2') || return 1
                set --
            fi
            shift || true
            case $action in
                install) ( set -e; _net_a1_install "$@" ) ;;
                uninstall) ( set -e; net_alpine_uninstall "$NET_ALPINE_HY2_NAME" "$(net_a1_init)" \
                    "$(net_a1_bin)" "$(net_a1_etc)" "$(net_a1_pid)" "$(net_a1_client)" 'A1' a1 ) ;;
                status) net_alpine_status "$NET_ALPINE_HY2_NAME" "$(net_a1_init)" \
                    "$(net_a1_bin)" "$(net_a1_etc)" udp ;;
                *) net_die '用法: toolbox_network A1 [install <证书> <私钥> <主机名> [端口] | uninstall | status]' ;;
            esac
            return $?
            ;;
        A2)
            action=${1:-}
            if [[ -z $action ]]; then
                action=$(net_submenu 'A2 Alpine Xray') || return 1
                set --
            fi
            shift || true
            case $action in
                install) ( set -e; _net_a2_install "$@" ) ;;
                uninstall) ( set -e; net_alpine_uninstall "$NET_ALPINE_XRAY_NAME" "$(net_a2_init)" \
                    "$(net_a2_bin)" "$(net_a2_etc)" "$(net_a2_pid)" "$(net_a2_client)" 'A2' a2 ) ;;
                status) net_alpine_status "$NET_ALPINE_XRAY_NAME" "$(net_a2_init)" \
                    "$(net_a2_bin)" "$(net_a2_etc)" tcp ;;
                *) net_die '用法: toolbox_network A2 [install [端口] [回落目标] | uninstall | status]' ;;
            esac
            return $?
            ;;
        A3)
            action=${1:-}
            if [[ -z $action ]]; then
                action=$(net_submenu 'A3 TUIC') || return 1
                set --
            fi
            shift || true
            case $action in
                install) ( set -e; _net_tuic_install "$@" ) ;;
                uninstall) ( set -e; _net_tuic_uninstall ) ;;
                status) net_tuic_status ;;
                *) net_die "用法: toolbox_network A3 [install <证书> <私钥> <主机名> [端口] | uninstall | status]" ;;
            esac
            return $?
            ;;
        A4) toolbox_network_hy2 "$@"; return $? ;;
        A5)
            action=${1:-}
            if [[ -z $action ]]; then
                action=$(net_submenu 'A5 Xray (Debian)') || return 1
                set --
            fi
            shift || true
            case $action in
                install) ( set -e; _net_a5_install "$@" ) ;;
                uninstall) ( set -e; _net_a5_uninstall ) ;;
                status) net_a5_status ;;
                *) net_die '用法: toolbox_network A5 [install <回落目标> <SNI主机名> [端口] | uninstall | status]' ;;
            esac
            return $?
            ;;
        B12)
            action=${1:-}
            if [[ -z $action ]]; then
                action=$(net_submenu 'B12 TCP Brutal') || return 1
                set --
            fi
            shift || true
            case $action in
                install) ( set -e; _net_brutal_install ) ;;
                uninstall) ( set -e; _net_brutal_uninstall ) ;;
                status) net_brutal_status ;;
                *) net_die '用法: toolbox_network B12 [install | uninstall | status]' ;;
            esac
            return $?
            ;;
        B23) toolbox_network_dns "$@"; return $? ;;
        B31)
            action=${1:-}
            if [[ -z $action ]]; then
                action=$(net_submenu 'B31 Relay 转发') || return 1
                set --
            fi
            shift || true
            case $action in
                install) ( set -e; _net_relay_install "$@" ) ;;
                uninstall) ( set -e; _net_relay_uninstall "$@" ) ;;
                status) net_relay_status ;;
                *) net_die '用法: toolbox_network B31 [install <tcp|udp> <本地端口> <目标> <目标端口> | uninstall [tcp|udp 端口 | all] | status]' ;;
            esac
            return $?
            ;;
        *) printf '未知网络操作: %s\n' "$key" >&2; return 2 ;;
    esac
    printf '%s (%s): 未实现，未执行任何安装或系统修改。\n' "$key" "$description" >&2
    printf '缺少可验证且不会覆盖已有服务的安全安装路径；请勿使用来源脚本直接执行。\n' >&2
    return 1
}
