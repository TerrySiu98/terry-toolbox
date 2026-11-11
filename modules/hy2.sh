#!/usr/bin/env bash
# A4 Hysteria 2 服务端安全安装模块。
#
# 只支持「全新的 Debian + systemd + 自签或自带证书」这一条路径；sourcing 本文件只定义
# 函数，不写系统、不探测网络。任何一项前置条件不满足都在写盘前失败；写盘后失败
# 则回滚到安装前的状态。所有判定只认本机事实（OS、systemd、ss 监听、systemd 单元
# 归属），不猜测「看起来像我们的服务」。
#
# 固定上游：HyNetworks/hysteria app/v2.13.0 官方发布二进制 + SHA-256 白名单。
# 不使用官方一键脚本，也不从「latest」解析版本号。

# Remember only the source directory; dependency work remains lazy. Bundles
# already contain the core and must never look beside the downloaded script.
_TOOLBOX_HY2_MODULE_DIR=''
if [[ ${TOOLBOX_BUNDLED:-0} != 1 ]]; then
    case ${BASH_SOURCE[0]} in
        */*) _TOOLBOX_HY2_MODULE_DIR=${BASH_SOURCE[0]%/*};;
        *) _TOOLBOX_HY2_MODULE_DIR=.;;
    esac
    _TOOLBOX_HY2_MODULE_DIR=$(CDPATH= builtin cd -- "$_TOOLBOX_HY2_MODULE_DIR" && builtin pwd -P) || _TOOLBOX_HY2_MODULE_DIR=''
fi

hy2_const() { # name value
    [[ -n ${!1+set} ]] && return 0
    printf -v "$1" '%s' "$2"
    readonly "$1"
}

hy2_const HY2_VERSION '2.13.0'
hy2_const HY2_BIN_NAME 'terry-toolbox-hy2'
hy2_const HY2_UNIT_NAME 'terry-toolbox-hy2.service'
hy2_const HY2_DEFAULT_PORT 443
hy2_const HY2_MIN_VALID_DAYS 7
hy2_const HY2_SELF_VALID_DAYS 365
hy2_const HY2_MASQUERADE_TEXT 'Terry Toolbox Hysteria 2'

# 测试可覆盖的路径与外部事实；默认值即真实主机路径。
hy2_etc()      { printf '%s\n' "${TOOLBOX_HY2_ETC:-/etc/terry-toolbox-hy2}"; }
hy2_unit_dir() { printf '%s\n' "${TOOLBOX_HY2_UNIT_DIR:-/etc/systemd/system}"; }
hy2_bin_dir()  { printf '%s\n' "${TOOLBOX_HY2_BIN_DIR:-/usr/local/bin}"; }
hy2_lock()     { printf '%s\n' "${TOOLBOX_HY2_LOCK:-/run/terry-toolbox-hy2.lock}"; }
hy2_client_dir() { printf '%s\n' "${TOOLBOX_HY2_CLIENT_DIR:-/run/terry-toolbox-hy2-verify}"; }
hy2_bin()      { printf '%s/%s\n' "$(hy2_bin_dir)" "$HY2_BIN_NAME"; }
hy2_unit()     { printf '%s/%s\n' "$(hy2_unit_dir)" "$HY2_UNIT_NAME"; }

hy2_err()  { printf '%s\n' "$*" >&2; }
hy2_die()  { hy2_err "$*"; return 1; }

# ---------------------------------------------------------------- 前置条件

hy2_require_root() {
    [[ ${TOOLBOX_HY2_UID:-${EUID:-$(id -u)}} -eq 0 ]] \
        || hy2_die '需要 root 权限运行（安装会写入 /etc、/usr/local/bin 和 systemd 单元）。'
}

# 只接受 ID=debian。衍生版（如 kali、raspbian）的包和 systemd 行为有差异，不冒险。
hy2_require_debian() {
    local file=${TOOLBOX_HY2_OS_RELEASE:-/etc/os-release} id='' line
    [[ -r $file ]] || { hy2_die "无法读取 $file，不能确认发行版。"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in ID=*) id=${line#ID=}; break;; esac
    done < "$file"
    id=${id%\"}; id=${id#\"}; id=${id%\'}; id=${id#\'}
    [[ ${id,,} == debian ]] || hy2_die "仅支持 Debian（当前 ID=${id:-未知}）；不支持 Alpine/Ubuntu/衍生版。"
}

hy2_require_systemd() {
    local run_dir=${TOOLBOX_HY2_SYSTEMD_RUN:-/run/systemd/system}
    command -v systemctl >/dev/null 2>&1 || { hy2_die '未找到 systemctl，本机不是 systemd 系统。'; return 1; }
    [[ -d $run_dir ]] || hy2_die 'systemd 未作为 init 运行（缺少 /run/systemd/system）。'
}

hy2_require_commands() {
    local missing=() c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} )); then
        declare -F toolbox_require_commands >/dev/null || { [[ -n ${_TOOLBOX_HY2_MODULE_DIR:-} ]] && source "$_TOOLBOX_HY2_MODULE_DIR/dependencies.sh"; } || return 1
        toolbox_require_commands 'Hysteria 2' "${missing[@]}" || return 1
    fi
}

hy2_require_tools() {
    hy2_require_commands openssl sha256sum curl flock ss awk sed mktemp stat install ln timeout \
        uname grep date cut tr readlink cp chmod mkdir rm rmdir dirname cat sleep python3
}

# Check the exact process-control APIs on this kernel before any installation.
# Signal zero through a pidfd to our own process changes no process state.
hy2_require_pidfd() {
    python3 - <<'PY_PIDFD_PREFLIGHT'
import os, signal, sys
try:
    fd = os.pidfd_open(os.getpid())
    try:
        signal.pidfd_send_signal(fd, 0)
    finally:
        os.close(fd)
except (OSError, AttributeError) as exc:
    print('当前 Python/内核不支持必需的 pidfd 安全进程控制；未安装。请使用支持该能力的 Debian 环境。', file=sys.stderr)
    sys.exit(1)
PY_PIDFD_PREFLIGHT
}

hy2_arch() {
    case $(uname -m) in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) hy2_die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
}

# 官方二进制白名单；测试可用 TOOLBOX_HY2_SHA256 覆盖以验证校验逻辑。
hy2_official_sha256() {
    case $1 in
        amd64) printf '%s\n' "${TOOLBOX_HY2_SHA256:-907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691}" ;;
        arm64) printf '%s\n' "${TOOLBOX_HY2_SHA256_ARM64:-a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7}" ;;
        *) return 1 ;;
    esac
}

hy2_valid_port() {
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    (( $1 <= 65535 ))
}

# 证书是用户输入，进 YAML 前先确认是可用的主机名。
hy2_valid_hostname() {
    (( ${#1} <= 253 )) && [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

# The connection endpoint is independent of SNI; never discover it via egress IP.
hy2_valid_endpoint() {
    python3 - "$1" <<'PY_ENDPOINT'
import ipaddress, re, sys
s = sys.argv[1]
try:
    if '%' in s: raise ValueError('scoped address')
    ipaddress.ip_address(s)
except ValueError:
    if len(s) > 253 or not re.fullmatch(r'(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}', s):
        sys.exit(1)
PY_ENDPOINT
}

hy2_pin() { # Leaf-certificate SHA-256, not a public-key/SPKI digest.
    local fingerprint
    fingerprint=$(openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null) || return 1
    fingerprint=${fingerprint#*=}
    [[ $fingerprint =~ ^([[:xdigit:]]{2}:){31}[[:xdigit:]]{2}$ ]] || { hy2_die '证书 SHA-256 指纹格式无效。'; return 1; }
    fingerprint=${fingerprint//:/}
    printf '%s\n' "${fingerprint,,}"
}

hy2_generate_self() { # Called only in the confirmed private staging directory.
    local dir=$1 host=$2
    # Avoid distribution req_extensions/x509_extensions defaults (OpenSSL 1.1).
    printf '[req]\ndistinguished_name=dn\n[dn]\n' > "$dir/self.cnf" || return 1
    openssl req -config "$dir/self.cnf" -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 \
        -days "$HY2_SELF_VALID_DAYS" -subj "/CN=$host" \
        -addext "subjectAltName=DNS:$host" -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature' -addext 'extendedKeyUsage=serverAuth' \
        -keyout "$dir/self.key" -out "$dir/self.crt" </dev/null >"$dir/openssl.log" 2>&1 \
        || { hy2_die '自签证书生成失败；未安装。'; return 1; }
    chmod 0600 -- "$dir/self.key" "$dir/self.crt" || return 1
    hy2_check_cert "$dir/self.crt" "$dir/self.key" "$host"
}

# Write interoperable, explicitly pinned client exports in private staging.
hy2_export_clients() { # dir endpoint sni port password leaf-pin
    local dir=$1 endpoint=$2 host=$3 port=$4 pass=$5 pin=$6 address
    hy2_valid_endpoint "$endpoint" && hy2_valid_hostname "$host" && hy2_valid_port "$port" \
        && [[ $pass =~ ^[A-Za-z0-9]{32}$ && $pin =~ ^[a-f0-9]{64}$ ]] || return 1
    address=$endpoint
    if [[ $endpoint == *:* ]]; then address="[$endpoint]"; fi
    printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1&pinSHA256=%s\n' \
        "$pass" "$address" "$port" "$host" "$pin" > "$dir/hysteria2.txt" || return 1
    cat > "$dir/client.yaml" <<EOF_CLIENT || return 1
server: '$address:$port'
auth: '$pass'
tls:
  sni: '$host'
  insecure: true
  pinSHA256: '$pin'
socks5:
  listen: 127.0.0.1:1080
EOF_CLIENT
    cat > "$dir/mihomo.yaml" <<EOF_MIHOMO || return 1
mixed-port: 7890
allow-lan: false
bind-address: 127.0.0.1
mode: rule
proxies:
  - name: toolbox-hy2
    type: hysteria2
    server: '$endpoint'
    port: $port
    password: '$pass'
    sni: '$host'
    skip-cert-verify: false
    fingerprint: '$pin'
proxy-groups:
  - name: PROXY
    type: select
    proxies: [toolbox-hy2]
rules:
  - MATCH,PROXY
EOF_MIHOMO
    chmod 0600 -- "$dir/hysteria2.txt" "$dir/client.yaml" "$dir/mihomo.yaml"
}

# ---------------------------------------------------------------- 本机事实

# 端口集合来自 ss 的实际监听表，不靠「谁应该监听」推测。
hy2_udp_port_busy() {
    local line local_addr
    while IFS= read -r line; do
        [[ $line =~ ^(UNCONN|ESTAB|State) ]] || continue
        read -r -a _hy2_f <<< "$line"
        local_addr=${_hy2_f[3]:-}
        if [[ ${local_addr##*:} == "$1" ]]; then return 0; fi
    done < <(ss -lunH 2>/dev/null)
    return 1
}

# 单元归属：absent（没有）/ ours（有且指向我们的目标）/ foreign（有但内容不符）。
hy2_unit_state() {
    local unit_file
    unit_file=$(hy2_unit)
    [[ -e $unit_file || -L $unit_file ]] || { printf 'absent\n'; return 0; }
    if [[ -f $unit_file && ! -L $unit_file ]] \
        && grep -qxF 'Description=Terry Toolbox Hysteria 2 server' "$unit_file" \
        && grep -qxF "WorkingDirectory=$(hy2_etc)" "$unit_file" \
        && grep -qxF "ExecStart=$(hy2_bin) server -c $(hy2_etc)/config.yaml --disable-update-check" "$unit_file" \
        && [[ $(grep -c '^ExecStart=' "$unit_file") == 1 ]]; then
        printf 'ours\n'
    else
        printf 'foreign\n'
    fi
}

# 端口是否由「本单元」持有。三层证据，任一成立即可：
#   1) /proc/<pid>/exe 就是我们的二进制（脚本安装时 exe 是解释器，会落到下一层）；
#   2) 该 pid 等于本单元 systemd 的 MainPID（systemd 亲自背书）；
#   3) 进程名匹配（内核 comm 截断到 15 字符，按前缀比）。
hy2_port_owned_by() {
    local port=$1 bin=$2 unit=${3:-$HY2_UNIT_NAME} line pid exe want main=''
    want=$(readlink -f -- "$bin" 2>/dev/null) || want=$bin
    main=$(systemctl show -p MainPID --value "$unit" 2>/dev/null) || main=''
    [[ $main =~ ^[0-9]+$ ]] || main=''
    while IFS= read -r line; do
        read -r -a _hy2_f <<< "$line"
        [[ ${_hy2_f[3]:-} == *":$port" ]] || continue
        while IFS= read -r pid; do
            [[ -n $pid ]] || continue
            if [[ -n $main && $pid == "$main" ]]; then return 0; fi
            exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || exe=''
            if [[ -n $exe && $exe == "$want" ]]; then return 0; fi
        done < <(grep -o 'pid=[0-9]*' <<< "$line" | cut -d= -f2)
        if [[ $line == *"${HY2_BIN_NAME:0:15}"* ]]; then return 0; fi
    done < <(ss -lunpH 2>/dev/null)
    return 1
}

# ---------------------------------------------------------------- 证书

hy2_check_cert() {
    local cert=$1 key=$2 host=$3 now
    [[ -f $cert && -r $cert ]] || { hy2_die "证书不存在或不可读：$cert"; return 1; }
    [[ -f $key && -r $key ]] || { hy2_die "私钥不存在或不可读：$key"; return 1; }
    (( $(stat -c %s -- "$cert") > 0 )) || { hy2_die "证书文件为空：$cert"; return 1; }
    (( $(stat -c %s -- "$key") > 0 )) || { hy2_die "私钥文件为空：$key"; return 1; }

    openssl x509 -in "$cert" -noout 2>/dev/null || { hy2_die "不是有效的 PEM 证书：$cert"; return 1; }
    if grep -q 'ENCRYPTED' "$key"; then hy2_die '私钥有口令加密；仅接受无口令 PEM 私钥，不交互解密。'; return 1; fi
    openssl pkey -in "$key" -passin pass: -noout </dev/null 2>/dev/null || { hy2_die "不是有效的 PEM 私钥：$key"; return 1; }

    # 公私钥配对：比对两者的公开模数/公钥，配对失败的服务启动即 FATAL。
    local cpub kpub
    cpub=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null) || { hy2_die '证书公钥解析失败'; return 1; }
    kpub=$(openssl pkey -in "$key" -passin pass: -pubout </dev/null 2>/dev/null) || { hy2_die '私钥公钥解析失败'; return 1; }
    [[ $cpub == "$kpub" ]] || { hy2_die '证书与私钥不配对。'; return 1; }

    now=$(date +%s)
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 \
        || { hy2_die '证书已过期（notAfter 已过）。'; return 1; }
    # notBefore 在未来时 openssl 只把它算作「尚未生效」，单独判定。
    local start
    start=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null | cut -d= -f2)
    if [[ -n $start ]]; then
        local start_epoch
        start_epoch=$(date -d "$start" +%s 2>/dev/null) || start_epoch=0
        (( start_epoch <= now )) || { hy2_die "证书尚未生效（notBefore=$start）。"; return 1; }
    fi
    if openssl x509 -in "$cert" -noout -checkend $((HY2_MIN_VALID_DAYS * 86400)) >/dev/null 2>&1; then
        :
    else
        hy2_err "注意：证书将在 $HY2_MIN_VALID_DAYS 天内过期，安装后请及时续期。"
    fi

    # 主机名必须出现在证书里，否则客户端校验不过、sniGuard 也会拒绝。
    if openssl x509 -in "$cert" -noout -checkhost "$host" 2>/dev/null | grep -q 'does match'; then
        return 0
    fi
    hy2_die "证书不包含主机名 $host（SAN/CN 不匹配）。"
    return 1
}

# 检查本机/显式 CA 信任；导出始终使用证书指纹，不把未知链降级为裸 insecure。
hy2_tls_trusted() {
    local cert=$1 cafile=${TOOLBOX_HY2_CAFILE-/etc/ssl/certs/ca-certificates.crt}
    local capath=${TOOLBOX_HY2_CAPATH-/etc/ssl/certs}
    [[ ! ${TOOLBOX_HY2_CAFILE+x} || -n $cafile ]] || return 1
    if [[ ! ${TOOLBOX_HY2_CAFILE+x} && ! -r $cafile ]]; then cafile=''; fi
    # 主入口已加载 network 时复用公共实现；本模块独立执行也须有同样判据。
    if declare -F net_tls_verify >/dev/null; then
        net_tls_verify "$cert" "$cafile" "$capath"
        return
    fi
    local verify_help
    local -a trust=()
    if [[ -n $cafile ]]; then
        [[ -f $cafile && -r $cafile && -s $cafile ]] || return 1
        trust=(-CAfile "$cafile" -no-CApath)
    else
        [[ -n $capath && -d $capath ]] || return 1
        trust=(-CApath "$capath" -no-CAfile)
    fi
    # OpenSSL 1.1 has no CAstore; match the shared verifier without retrying
    # failed certificate checks with a weaker trust configuration.
    verify_help=$(openssl verify -help 2>&1) || :
    if [[ $verify_help == *-no-CAstore* ]]; then trust+=(-no-CAstore); fi
    openssl verify "${trust[@]}" -purpose sslserver -untrusted "$cert" "$cert" >/dev/null 2>&1
}

# ---------------------------------------------------------------- 下载

hy2_fetch() {
    local arch=$1 dest=$2 expected url
    expected=$(hy2_official_sha256 "$arch") || { hy2_die "没有 $arch 的固定校验值。"; return 1; }
    url="https://github.com/HyNetworks/hysteria/releases/download/app/v${HY2_VERSION}/hysteria-linux-${arch}"
    url=${TOOLBOX_HY2_URL:-$url}

    if [[ -n ${TOOLBOX_HY2_BIN_SRC:-} ]]; then
        # 测试注入：直接当成本地文件，仍走校验和判断。
        cp -- "$TOOLBOX_HY2_BIN_SRC" "$dest" || { hy2_die '复制本地二进制失败'; return 1; }
    else
        hy2_err "下载官方二进制：$url"
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \
            -o "$dest" "$url" || { hy2_die '下载失败（网络或 GitHub 不可达）。'; return 1; }
    fi

    local actual
    actual=$(sha256sum -- "$dest" | cut -d' ' -f1)
    [[ $actual == "$expected" ]] \
        || { hy2_die "SHA-256 不匹配：期望 $expected，实际 $actual（怀疑下载被篡改或版本漂移）。"; return 1; }
    chmod 0755 -- "$dest" || { hy2_die '无法设置二进制可执行权限。'; return 1; }
}

# ---------------------------------------------------------------- 状态写入与回滚

# 写后哈希与独占落位清单仅属于本次安装，不以同名文件推断所有权。
hy2_created_files=()
hy2_etc_created=0
hy2_client_created=0
hy2_service_touched=0

hy2_place() { # mode src dest
    local mode=$1 src=$2 dest=$3 stage sum
    stage=$(mktemp "${dest}.XXXXXXXX") || return 1
    if ! install -m "$mode" -- "$src" "$stage"; then rm -f -- "$stage"; return 1; fi
    sum=$(sha256sum -- "$stage" | cut -d' ' -f1) || { rm -f -- "$stage"; return 1; }
    # ln 不覆盖现有目标（包括断链）；临时文件与目标位于同一文件系统。
    if ! ln -T -- "$stage" "$dest"; then rm -f -- "$stage"; hy2_die "目标已存在，未覆盖：$dest"; return 1; fi
    hy2_created_files+=("$dest|$sum")
    rm -f -- "$stage"
}

hy2_stop_owned() {
    local rc=0
    [[ $(hy2_unit_state) == ours ]] || { hy2_die '单元归属改变，未停止或删除；请人工确认。'; return 1; }
    if ! systemctl disable --now "$HY2_UNIT_NAME" >/dev/null 2>&1; then
        hy2_die '停止/禁用服务失败，保留单元、二进制和配置供人工处理。'
        return 1
    fi
    systemctl is-active --quiet "$HY2_UNIT_NAME" 2>/dev/null || rc=$?
    if [[ $rc != 3 ]]; then
        hy2_die '服务仍在运行或无法确认已停止，保留全部文件供人工处理。'
        return 1
    fi
}

# Only one smoke/probe child runs at a time. Record its identity before
# handling a pending signal; never signal a process selected by name or PID alone.
hy2_install_signal() {
    if (( ${hy2_child_launching:-0} || ${hy2_child_stopping:-0} )); then
        (( ${hy2_pending_signal:-0} )) || hy2_pending_signal=$1
        return 0
    fi
    trap '' INT TERM HUP
    hy2_pending_signal=0
    hy2_rollback || true
    exit "$1"
}

hy2_child_start() {
    [[ -z ${hy2_child_pid:-} ]] || { hy2_die '上次探针尚未确认停止，拒绝启动。'; return 1; }
    local stat fields
    hy2_child_starttime=''
    hy2_child_launching=1
    "$@" &
    hy2_child_pid=$!
    # Builtins only: do not launch another process before capturing /proc identity.
    if IFS= read -r stat 2>/dev/null <"/proc/$hy2_child_pid/stat"; then
        read -r -a fields <<< "${stat##*) }"
        hy2_child_starttime=${fields[19]:-}
    fi
    hy2_child_launching=0
    if (( ${hy2_pending_signal:-0} )); then hy2_install_signal "$hy2_pending_signal"; fi
}

hy2_child_terminate() {
    python3 - "$1" "$BASHPID" "$2" <<'PY_STOP_CHILD'
import os, pathlib, select, signal, sys
pid, parent, start = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
try:
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        sys.exit(0)
    poll = select.poll()
    poll.register(fd, select.POLLIN)
    if poll.poll(0):
        sys.exit(0)
    fields = pathlib.Path('/proc/%s/stat' % pid).read_text().rsplit(')', 1)[1].split()
    if poll.poll(0):
        sys.exit(0)
    if pid in (os.getpid(), parent) or int(fields[1]) != parent or not start or fields[19] != start:
        raise RuntimeError('child identity changed')
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            signal.pidfd_send_signal(fd, sig)
        except ProcessLookupError:
            sys.exit(0)
        if poll.poll(2000):
            sys.exit(0)
    raise RuntimeError('child did not exit')
except (OSError, ValueError, IndexError, AttributeError, RuntimeError) as exc:
    print('HY2 child stop failed: %s' % exc, file=sys.stderr)
    sys.exit(1)
PY_STOP_CHILD
}

hy2_child_stop() {
    [[ -n ${hy2_child_pid:-} ]] || return 0
    (( ${hy2_child_stop_failed:-0} == 0 )) || return 1
    local rc=0
    hy2_child_stopping=1
    if hy2_child_terminate "$hy2_child_pid" "${hy2_child_starttime:-}"; then
        # pidfd confirmed exit; wait cannot hang and reaps only our recorded job.
        wait "$hy2_child_pid" 2>/dev/null || true
        hy2_child_pid=''
    else
        hy2_child_stop_failed=1
        hy2_err '无法确认本次冒烟/探针子进程已停止，保留二进制、配置及单元；请人工处理。'
        rc=1
    fi
    hy2_child_stopping=0
    if (( ${hy2_pending_signal:-0} )); then hy2_install_signal "$hy2_pending_signal"; fi
    return "$rc"
}

hy2_rollback() {
    local entry path want now unit i rc=0 unit_owned=0 unit_sum=''
    unit=$(hy2_unit) || return 1
    hy2_err '--- 开始回滚 ---'
    hy2_child_stop || return 1
    for entry in "${hy2_created_files[@]}"; do
        if [[ ${entry%%|*} == "$unit" ]]; then unit_owned=1; unit_sum=${entry##*|}; fi
    done
    if (( unit_owned )); then
        now=$(sha256sum -- "$unit" 2>/dev/null | cut -d' ' -f1) || now=''
        if [[ $(hy2_unit_state) != ours || $now != "$unit_sum" ]]; then
            hy2_die '单元内容已改变，保留全部文件；未停止来源不明的服务。'
            return 1
        fi
        if (( hy2_service_touched )); then hy2_stop_owned || return 1; fi
    fi
    for (( i=${#hy2_created_files[@]}-1; i>=0; i-- )); do
        entry=${hy2_created_files[i]}; path=${entry%%|*}; want=${entry##*|}
        [[ -e $path || -L $path ]] || continue
        now=$(sha256sum -- "$path" 2>/dev/null | cut -d' ' -f1) || now=''
        if [[ -L $path || ! -f $path || $now != "$want" ]]; then
            hy2_err "保留 $path：内容或类型已改变，不按本次创建文件删除。"
            rc=1
            continue
        fi
        rm -f -- "$path" || rc=1
    done
    if (( unit_owned )); then
        systemctl daemon-reload >/dev/null 2>&1 || rc=1
        systemctl reset-failed "$HY2_UNIT_NAME" >/dev/null 2>&1 || true
    fi
    if (( hy2_etc_created )) && [[ ! -L $(hy2_etc) ]]; then
        rmdir -- "$(hy2_etc)" 2>/dev/null || rc=1
    fi
    if (( hy2_client_created )) && [[ ! -L $(hy2_client_dir) ]]; then
        rmdir -- "$(hy2_client_dir)" 2>/dev/null || rc=1
    fi
    if (( rc )); then hy2_err '回滚不完整：已保留未确认归属/被改动的文件，请人工处理。'
    else hy2_err '已按本次创建清单回滚。'; fi
    return "$rc"
}

# ---------------------------------------------------------------- 启动与验证

# 写盘后、交给 systemd 之前的离线自检：配置能否被解析、证书能否加载、端口能否绑定。
# 起后台进程看日志，成功就杀掉并等它退出，避免和随后的 systemd 启动抢端口。
hy2_smoke() {
    local bin=$1 conf=$2 port=$3 out pid i
    out=$(mktemp) || return 1
    hy2_child_start "$bin" server -c "$conf" --disable-update-check >"$out" 2>&1 || return 1
    pid=$hy2_child_pid
    for ((i = 0; i < 60; i++)); do
        if grep -q 'server up and running' "$out" 2>/dev/null; then break; fi
        if grep -q 'FATAL' "$out" 2>/dev/null; then break; fi
        kill -0 "$pid" 2>/dev/null || break
        command sleep 0.2
    done
    hy2_child_stop || return 1
    # 进程可能比日志先结束，最终以日志内容为准
    if grep -q 'server up and running' "$out" 2>/dev/null; then
        rm -f -- "$out"
        return 0
    fi
    hy2_err "冒烟启动失败（端口 $port），服务输出："
    sed -n '1,12p' "$out" >&2
    rm -f -- "$out"
    return 1
}

# 用本模块自己的二进制当客户端，经 SOCKS5 走一遍 TLS + 认证。
# 成功判据是客户端日志出现 connected；错误密码/指纹须出现具体拒绝日志。
# 返回 0=连通、2=明确协议拒绝、1=未知/未执行；quiet=1 用于负向探测。
hy2_probe() {
    local bin=$1 host=$2 port=$3 pass=$4 insecure=$5 label=$6 quiet=${7:-0}
    local pin=${8:-} dir sock out out_dc i config
    [[ $label == good || $label == bad || $label == badpin ]] || return 1
    [[ $pin =~ ^[a-f0-9]{64}$ ]] || { hy2_die "探测缺少有效的证书指纹。"; return 1; }
    dir=$(hy2_client_dir); mkdir -p "$dir" || return 1
    sock=$(( 39000 + RANDOM % 2000 ))
    while hy2_udp_port_busy "$sock" || ss -ltnH 2>/dev/null | grep -q ":$sock "; do (( sock++ )); done
    out="$dir/$label.log"
    config=$(mktemp) || return 1

    {
        printf 'server: 127.0.0.1:%s\n' "$port"
        printf 'auth: %s\n' "$pass"
        printf 'tls:\n  sni: %s\n  pinSHA256: %s\n' "$host" "$pin"
        if [[ $insecure == 1 ]]; then
            printf '  insecure: true\n'
        elif [[ -n ${TOOLBOX_HY2_CAFILE:-} ]]; then
            printf "  ca: '%s'\n" "${TOOLBOX_HY2_CAFILE//\'/\'\'}"
        fi
        printf 'socks5:\n  listen: 127.0.0.1:%s\n' "$sock"
    } > "$config" || { rm -f -- "$config"; return 1; }
    hy2_place 0600 "$config" "$dir/$label.yaml" || { rm -f -- "$config"; return 1; }
    rm -f -- "$config"
    # 日志也独占创建；退出后登记最终哈希，回滚不能删固定名字的外来文件。
    ( set -C; : > "$out" ) 2>/dev/null || return 1
    chmod 0600 "$out" || return 1

    # 客户端要一直活着才能做数据面测试，所以放后台，靠日志判断结果。
    hy2_child_start "$bin" client -c "$dir/$label.yaml" --disable-update-check >"$out" 2>&1 || return 1
    local cpid=$hy2_child_pid result=1
    for ((i = 0; i < 75; i++)); do
        if grep -q 'connected to server' "$out" 2>/dev/null; then result=0; break; fi
        if grep -q 'FATAL' "$out" 2>/dev/null; then break; fi
        kill -0 "$cpid" 2>/dev/null || break
        command sleep 0.2
    done
    # 进程可能比日志先结束，最终以日志内容为准
    if (( result == 1 )) && grep -q 'connected to server' "$out" 2>/dev/null; then result=0; fi

    if (( result == 0 )) && (( quiet == 0 )) && command -v curl >/dev/null 2>&1; then
        # 顺带走一次真实数据面；目标不可达时不推翻已证明的认证结果。
        out_dc=''
        for ((i = 0; i < 3; i++)); do
            out_dc=$(timeout 25 curl -fsS --max-time 20 --noproxy '' --socks5-hostname "127.0.0.1:$sock" \
                -o /dev/null -w '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) && break
            out_dc=''
            command sleep 1
        done
        [[ -n $out_dc ]] || hy2_err "提示：$label 隧道已通，但数据面出站未成功（可能主机无外网出口）。"
    elif (( result == 1 )) && (( quiet == 0 )); then
        sed -n '1,8p' "$out" >&2
    fi

    hy2_child_stop || return 1
    local sum
    sum=$(sha256sum -- "$out" | cut -d' ' -f1) || return 1
    hy2_created_files+=("$out|$sum")
    # Only an observed protocol rejection is negative evidence. A missing
    # binary, malformed config, timeout or skipped probe is an install failure.
    if (( result != 0 && quiet == 1 )); then
        case $label in
            badpin) grep -qF 'no certificate matches the pinned hash' "$out" && result=2;;
            bad) grep -qF 'authentication error, HTTP status code:' "$out" && result=2;;
        esac
    fi
    return "$result"
}

# 端口从 enable 到真正 bind 有间隔，轮询等它出现再判定。
hy2_wait_owned() {
    local port=$1 bin=$2 i
    for ((i = 0; i < 20; i++)); do
        if hy2_port_owned_by "$port" "$bin"; then return 0; fi
        sleep 0.5
    done
    return 1
}

hy2_wait_active() {
    local i
    for ((i = 0; i < 20; i++)); do
        if systemctl is-active --quiet "$HY2_UNIT_NAME" 2>/dev/null; then return 0; fi
        sleep 0.5
    done
    return 1
}

# ---------------------------------------------------------------- 安装

_hy2_install() {
    local cert=${1:-} key=${2:-} host=${3:-} port=${4:-} endpoint=${5:-} answer
    local mode=${HY2_INSTALL_MODE:-existing} choice pin wrongpin item probe_rc
    local arch tmp etc bin unit pass trusted=1 interactive=0
    local -a hy2_created_files=()
    local hy2_etc_created=0 hy2_client_created=0 hy2_service_touched=0
    local hy2_child_pid= hy2_child_starttime= hy2_child_launching=0 hy2_child_stopping=0
    local hy2_child_stop_failed=0 hy2_pending_signal=0
    [[ -n $cert && -n $key && -n $host ]] || interactive=1

    hy2_require_root || return 1
    hy2_require_debian || return 1
    hy2_require_systemd || return 1
    hy2_require_tools || return 1
    hy2_require_pidfd || return 1
    arch=$(hy2_arch) || return 1
    etc=$(hy2_etc); bin=$(hy2_bin); unit=$(hy2_unit)

    # No-argument A4 install always chooses certificate preparation first.
    if (( $# == 0 )); then
        printf '证书方式：\n  1 自动生成自签（无需自有域名）\n  2 已有证书\n  0 取消\n选择：'
        IFS= read -r choice || { hy2_err '没有收到选择，已取消。'; return 1; }
        case $choice in
            1) mode=self;;
            2) mode=existing;;
            0) hy2_err '已取消，未修改系统。'; return 1;;
            *) hy2_die '无效选择，已取消。'; return 1;;
        esac
    fi
    if [[ $mode == self ]]; then
        printf '自签证书不是 Apple/Cloudflare 颁发的证书，也不经过它们的代理。\n'
        printf 'SNI 仅是证书名称，不要求解析或拥有该域名；连接入口必须另填本服务器地址。\n'
        printf '有效期固定 %s 天，不自动续期；换证后必须重新导入新指纹。\n' "$HY2_SELF_VALID_DAYS"
        if [[ -z $host ]]; then
            printf '证书 SNI（回车用 www.cloudflare.com）：'
            IFS= read -r host || { hy2_err '没有收到 SNI，已取消。'; return 1; }
            host=${host:-www.cloudflare.com}
        fi
    else
        # Existing positional CLI retains cert/key/host/[port] semantics.
        if [[ -z $cert ]]; then
            printf '证书文件路径（PEM，含完整链）：'
            IFS= read -r cert || { hy2_err '没有收到证书路径，已取消。'; return 1; }
        fi
        if [[ -z $key ]]; then
            printf '私钥文件路径：'
            IFS= read -r key || { hy2_err '没有收到私钥路径，已取消。'; return 1; }
        fi
        if [[ -z $host ]]; then
            printf '证书对应的域名：'
            IFS= read -r host || { hy2_err '没有收到域名，已取消。'; return 1; }
        fi
    fi
    host=${host,,}
    hy2_valid_hostname "$host" || { hy2_die "主机名格式不正确：$host"; return 1; }
    if [[ -z $endpoint ]]; then
        if (( interactive )); then
            printf '本服务器连接入口（IPv4 / IPv6 / 域名，不含端口；不自动查询公网 IP）：'
            IFS= read -r endpoint || { hy2_err '没有收到连接入口，已取消。'; return 1; }
        else
            endpoint=$host
        fi
    fi
    hy2_valid_endpoint "$endpoint" || { hy2_die '连接入口无效：请输入裸 IPv4、IPv6 或域名，不含协议、方括号、端口或路径。'; return 1; }
    if [[ -n $port ]]; then
        hy2_valid_port "$port" || { hy2_die "端口不正确：$port（1-65535，无前导零）"; return 1; }
    else
        if (( interactive )); then
            printf '监听 UDP 端口（回车用 %s）：' "$HY2_DEFAULT_PORT"
            IFS= read -r port || { hy2_err '没有收到端口，已取消。'; return 1; }
        fi
        port=${port:-$HY2_DEFAULT_PORT}
        hy2_valid_port "$port" || { hy2_die "端口不正确：$port（1-65535，无前导零）"; return 1; }
    fi
    if [[ $mode != self ]]; then
        hy2_check_cert "$cert" "$key" "$host" || return 1
        hy2_tls_trusted "$cert" || trusted=0
        if [[ $trusted == 0 && ( ${TOOLBOX_HY2_CAFILE+x} || ${TOOLBOX_HY2_CAPATH+x} ) ]]; then
            hy2_die '显式信任锚校验失败，拒绝降级为 insecure；请检查 CA 文件与完整证书链。'
            return 1
        fi
        pin=$(hy2_pin "$cert") || return 1
    else
        trusted=0
        if [[ ${TOOLBOX_HY2_CAFILE+x} || ${TOOLBOX_HY2_CAPATH+x} ]]; then
            hy2_die '自签模式使用显式证书指纹，不能忽略已指定的 CA 信任锚；请先取消 CA 覆盖。'; return 1
        fi
    fi

    # 冲突判定必须在写盘之前，并区分「我们的残留」和「别人的服务」。
    local state
    state=$(hy2_unit_state)
    case $state in
        foreign)
            hy2_die "$(hy2_unit) 已存在但内容不是本模块生成的，未覆盖；请人工确认归属。"
            return 1
            ;;
        ours)
            if systemctl is-active --quiet "$HY2_UNIT_NAME" 2>/dev/null; then
                hy2_die "$HY2_UNIT_NAME 已在运行（我们的服务）。重装请先执行 toolbox_hy2 uninstall。"
            else
                hy2_die "$HY2_UNIT_NAME 已存在但未运行（我们的残留）。请先执行 toolbox_hy2 uninstall 清理后再安装。"
            fi
            return 1
            ;;
    esac

    # 没有单元文件却已有同名二进制/配置目录：可能是别人的安装，不静默覆盖
    # （否则回滚会把别人的文件一起删掉）。
    if [[ -e $bin || -L $bin || -e $etc || -L $etc ]]; then
        hy2_die "已存在 $bin 或 $etc，却没有 $unit；未覆盖，请人工确认归属。"
        return 1
    fi

    if [[ -e $(hy2_client_dir) || -L $(hy2_client_dir) ]]; then
        hy2_die '探针目录已存在且未确认归属，未覆盖；请人工确认归属。'
        return 1
    fi
    if hy2_udp_port_busy "$port"; then
        hy2_err "UDP 端口 $port 已被占用，监听它的进程："
        ss -lunpH 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" {print "  " $4 " " $0}' | cut -c1-160 >&2
        hy2_die "换成其他端口，或先确认并停止占用方。"
        return 1
    fi

    printf '即将安装 Hysteria 2 服务端：\n'
    printf '  版本    : v%s（官方发布，安装前校验 SHA-256）\n' "$HY2_VERSION"
    printf '  证书名  : %s\n  连接入口: %s\n' "$host" "$endpoint"
    printf '  监听    : :%s/udp（所有地址，IPv4+IPv6）\n' "$port"
    if [[ $mode == self ]]; then
        printf '  证书    : 确认后生成 ECDSA P-256 / SHA-256 / SAN，固定 %s 天\n' "$HY2_SELF_VALID_DAYS"
    else
        printf '  证书    : %s\n' "$cert"
        printf '  私钥    : %s（复制到 %s，权限 600）\n' "$key" "$etc"
    fi
    printf '  单元    : %s\n' "$unit"
    printf '  认证    : 随机密码仅存文件，不打印；客户端必须支持证书 SHA-256 pin\n'
    printf '  导出    : %s/{hysteria2.txt,client.yaml,mihomo.yaml}（0600）\n' "$etc"
    printf '  信任    : 按叶证书指纹信任；不支持 pin 的客户端不得去掉指纹使用\n'
    printf '  防火墙  : 不改动；需自行放行 UDP %s\n' "$port"
    printf '确认安装？输入 YES 继续：'
    IFS= read -r answer || { hy2_err '没有收到完整确认，已取消。'; return 1; }
    [[ ${answer^^} == YES ]] || { hy2_err '已取消，未修改系统。'; return 1; }
    if [[ $mode == self ]]; then
        printf '再次确认安装并信任该证书指纹？输入 YES：'
        IFS= read -r answer || { hy2_err '没有收到完整二次确认，已取消。'; return 1; }
        [[ ${answer^^} == YES ]] || { hy2_err '已取消，未修改系统。'; return 1; }
    fi

    # 互斥：同一时刻只允许一个安装/卸载。
    exec 9>"$(hy2_lock)" || { hy2_die "无法创建锁文件 $(hy2_lock)"; return 1; }
    flock -n 9 || { hy2_die '另一个安装/卸载正在进行，稍后再试。'; return 1; }

    # 加锁后再读目标，关闭预检/确认期间另一安装留下文件的覆盖窗口。
    if [[ $(hy2_unit_state) != absent || -e $bin || -L $bin || -e $etc || -L $etc \
        || -e $(hy2_client_dir) || -L $(hy2_client_dir) ]]; then
        hy2_die '目标在确认期间已出现，未确认归属；未覆盖，请人工确认归属。'
        return 1
    fi
    umask 077
    tmp=$(mktemp -d) || { hy2_die '无法创建临时目录'; return 1; }
    # Signal rollback must stop this transaction's smoke/probe child first.
    # Defer signals across launch/stop bookkeeping; SIGKILL cannot be trapped.
    trap "rm -rf -- $(printf '%q' "$tmp")" EXIT
    trap 'hy2_install_signal 130' INT
    trap 'hy2_install_signal 143' TERM HUP
    if [[ $mode == self ]]; then
        hy2_generate_self "$tmp" "$host" || return 1
        cert=$tmp/self.crt; key=$tmp/self.key
        pin=$(hy2_pin "$cert") || return 1
    fi
    pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)
    [[ ${#pass} -eq 32 ]] || { rm -rf -- "$tmp"; hy2_die '密码生成失败'; return 1; }

    # 从这里开始有任何失败都回滚。
    hy2_err '--- 开始写入 ---'
    hy2_fetch "$arch" "$tmp/hysteria" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }

    mkdir -p -- "$(dirname -- "$etc")" || { rm -rf -- "$tmp"; return 1; }
    mkdir -m 0755 -- "$etc" || { rm -rf -- "$tmp"; hy2_die '配置目录已存在或无法独占创建'; return 1; }
    hy2_etc_created=1
    hy2_place 0755 "$tmp/hysteria" "$bin" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    hy2_place 0600 "$cert" "$etc/cert.pem" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    hy2_place 0600 "$key" "$etc/key.pem" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    if ! hy2_check_cert "$etc/cert.pem" "$etc/key.pem" "$host" || [[ $(hy2_pin "$etc/cert.pem") != "$pin" ]]; then
        hy2_die '证书/私钥在确认或复制期间改变；拒绝安装。'
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi

    cat > "$tmp/config.yaml" <<EOF || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
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
    content: '$HY2_MASQUERADE_TEXT'
    statusCode: 200
EOF
    if [[ ! -s $tmp/config.yaml ]] || ! hy2_place 0600 "$tmp/config.yaml" "$etc/config.yaml"; then
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi

    cat > "$tmp/unit" <<EOF || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
[Unit]
Description=Terry Toolbox Hysteria 2 server
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$etc
ExecStart=$bin server -c $etc/config.yaml --disable-update-check
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
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
    if [[ ! -s $tmp/unit ]] || ! hy2_place 0644 "$tmp/unit" "$unit"; then
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi

    # 写盘后先离线冒烟：证书/配置/端口绑定错误在这里暴露，早于 systemd。
    if ! hy2_smoke "$bin" "$etc/config.yaml" "$port"; then
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi

    if ! systemctl daemon-reload; then
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi
    hy2_service_touched=1
    if ! systemctl enable --now "$HY2_UNIT_NAME" >/dev/null 2>&1; then
        hy2_err 'systemctl enable --now 失败。'
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi
    if ! hy2_wait_active; then
        hy2_err '服务未进入 active 状态。'
        systemctl --no-pager -l status "$HY2_UNIT_NAME" >&2 2>&1 || true
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi

    # 回读：端口确实由本服务持有（而不是别的东西碰巧占着）。
    if ! hy2_wait_owned "$port" "$bin"; then
        hy2_err "单元显示运行中，但 UDP $port 的监听进程不是 $HY2_BIN_NAME。"
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi

    # 信任必须基于实际复制的证书；明确选择 CA 的失败不得降级。
    trusted=1
    hy2_tls_trusted "$etc/cert.pem" || trusted=0
    if [[ $trusted == 0 && ( ${TOOLBOX_HY2_CAFILE+x} || ${TOOLBOX_HY2_CAPATH+x} ) ]]; then
        hy2_die '写入后的证书链不被指定 CA 信任，拒绝降级为 insecure。'
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi
    local insecure=0
    if [[ $trusted == 0 ]]; then insecure=1; fi

    mkdir -m 0700 -- "$(hy2_client_dir)" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    hy2_client_created=1
    if ! hy2_probe "$bin" "$host" "$port" "$pass" "$insecure" good 0 "$pin"; then
        hy2_err '认证探测失败（正确密码未连通）。'
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi
    # 负向探测：错误密码必须被拒，否则等于没验证认证。
    probe_rc=0
    hy2_probe "$bin" "$host" "$port" "wrong-$pass" "$insecure" bad 1 "$pin" || probe_rc=$?
    if (( probe_rc != 2 )); then
        hy2_err '错误密码未得到明确认证拒绝（或探针未完成），安装失败。'
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi
    printf '  负向探测：错误密码被拒绝 ✓\n'
    wrongpin="0${pin:1}"
    if [[ $wrongpin == "$pin" ]]; then wrongpin="1${pin:1}"; fi
    probe_rc=0
    hy2_probe "$bin" "$host" "$port" "$pass" "$insecure" badpin 1 "$wrongpin" || probe_rc=$?
    if (( probe_rc != 2 )); then
        hy2_err '错误证书指纹未得到明确 pin 拒绝（或探针未完成），安装失败。'
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi
    printf '  负向探测：错误证书指纹被拒绝 ✓\n'

    hy2_export_clients "$tmp" "$endpoint" "$host" "$port" "$pass" "$pin" \
        || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    for item in hysteria2.txt client.yaml mihomo.yaml; do
        hy2_place 0600 "$tmp/$item" "$etc/$item" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    done

    printf '%s|%s|%s|%s\n' "$host" "$port" "$insecure" "$HY2_VERSION" > "$tmp/meta" \
        || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    hy2_place 0600 "$tmp/meta" "$etc/meta" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    rm -rf -- "$tmp"

    hy2_report "$host" "$port" "$mode"
}

hy2_report() {
    local port=$2 mode=$3
    printf '\n安装完成，服务 %s 已设为开机自启。\n' "$HY2_UNIT_NAME"
    printf '客户端导入文件（0600，含密码，请通过安全渠道取用）：\n'
    printf '  %s/hysteria2.txt\n  %s/client.yaml\n  %s/mihomo.yaml\n' "$(hy2_etc)" "$(hy2_etc)" "$(hy2_etc)"
    printf '官方 Hysteria 使用 insecure:true + pinSHA256 校验证书指纹，不是裸跳过校验。\n'
    printf 'Mihomo 使用 skip-cert-verify:false + fingerprint；导入后必须核对指纹字段仍在。\n'
    printf '客户端若不支持 pin，请换用支持的客户端；不得删除指纹或仅开启跳过验证。\n'
    if [[ -n ${TOOLBOX_HY2_CAFILE:-} ]]; then
        printf '安装探针使用自定义 CA，其他客户端也需配置同一信任锚，或使用已导出的明确证书指纹。\n'
    fi
    printf '\n验证情况：\n'
    printf '  [已验证] 单元 active、UDP %s 由 %s 监听\n' "$port" "$HY2_BIN_NAME"
    printf '  [已验证] 正确密码和指纹经 TLS 认证连通；错误密码、错误指纹被拒绝\n'
    printf '\n仍需人工处理：\n'
    printf '  - 防火墙/安全组放行 UDP %s（本模块不改 DNS/防火墙）；公网客户端另验\n' "$port"
    if [[ $mode == self ]]; then
        printf '  - 自签有效期固定 %s 天，无自动续期；换证须更新所有客户端指纹\n' "$HY2_SELF_VALID_DAYS"
    else
        printf '  - 证书按副本持久化，不自动续期/同步；换证须更新所有客户端指纹\n'
    fi
    printf '  - 卸载：toolbox_hy2 uninstall\n'
}

# ---------------------------------------------------------------- 卸载

_hy2_uninstall() {
    local unit etc bin state answer
    hy2_require_root || return 1
    hy2_require_systemd || return 1
    unit=$(hy2_unit); etc=$(hy2_etc); bin=$(hy2_bin)
    if [[ ! -e $unit && ! -L $unit && ! -e $bin && ! -L $bin && ! -e $etc && ! -L $etc ]]; then
        hy2_die '没有找到本模块的安装（单元、二进制、配置都不存在）。'
        return 1
    fi
    hy2_require_commands grep flock rm || return 1
    state=$(hy2_unit_state)
    if [[ $state == absent && ! -e $bin && ! -L $bin && ! -e $etc && ! -L $etc ]]; then
        hy2_die '没有找到本模块的安装（单元、二进制、配置都不存在）。'
        return 1
    fi
    if [[ $state == foreign ]]; then
        hy2_die "$unit 不是本模块生成的，未删除；请人工确认。"
        return 1
    fi
    if [[ $state != ours || -L $bin || -L $etc || -L $(hy2_client_dir) ]]; then
        hy2_die '没有自有单元或目标为符号链接，未确认归属；未删除，请人工确认归属。'
        return 1
    fi

    printf '将停止并删除：%s\n  %s\n  %s\n  %s\n' "$unit" "$bin" "$etc" "（证书/私钥副本和 hysteria2.txt、client.yaml、mihomo.yaml；原始证书不动）"
    printf '确认卸载？输入 YES：'
    IFS= read -r answer || { hy2_err '没有收到完整确认，已取消。'; return 1; }
    [[ ${answer^^} == YES ]] || { hy2_err '已取消。'; return 1; }

    exec 9>"$(hy2_lock)" || { hy2_die "无法创建锁文件"; return 1; }
    flock -n 9 || { hy2_die '另一个安装/卸载正在进行。'; return 1; }

    [[ $(hy2_unit_state) == ours && ! -L $bin && ! -L $etc && ! -L $(hy2_client_dir) ]] \
        || { hy2_die '确认期间归属改变，未删除。'; return 1; }
    hy2_stop_owned || return 1
    rm -f -- "$unit" || { hy2_die '删除单元失败，保留其余文件。'; return 1; }
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$HY2_UNIT_NAME" >/dev/null 2>&1 || true
    if ! rm -f -- "$bin" || ! rm -rf -- "$etc" || ! rm -rf -- "$(hy2_client_dir)"; then
        hy2_die '卸载清理失败，请人工处理。'; return 1
    fi
    printf '已卸载。\n'
}

# 安装/卸载整体放进子 shell：锁用 exec 9 持有，子 shell 结束后自动释放，
# 不会把锁句柄留到调用方 shell 里。调用方的 `if` / `||` 会禁用 errexit，
# 因此所有关键写入/服务动作都必须显式检查返回，不能仅依赖这里的 set -e。
hy2_install() {
    local HY2_INSTALL_MODE=existing
    ( set +x +v; set +T; trap - DEBUG RETURN; set -e; _hy2_install "$@" )
}
hy2_install_self() {
    (( $# >= 1 && $# <= 3 )) && [[ -n $1 ]] || { hy2_die '用法: install-self <连接入口IPv4/IPv6/域名> [SNI] [端口]'; return 1; }
    local HY2_INSTALL_MODE=self
    ( set +x +v; set +T; trap - DEBUG RETURN; set -e; _hy2_install '' '' "${2:-www.cloudflare.com}" "${3:-$HY2_DEFAULT_PORT}" "$1" )
}
hy2_uninstall() { ( set -e; _hy2_uninstall ) ; }

hy2_status() {
    local host port _insecure version bin
    bin=$(hy2_bin)
    if [[ ! -e $(hy2_unit) ]]; then
        printf '未安装。\n'
        return 1
    fi
    hy2_require_systemd || return 1
    hy2_require_commands sed ss readlink grep cut || {
        hy2_err '状态读取不完整：缺失工具未补齐，无法确认服务监听归属。'; return 1;
    }
    IFS='|' read -r host port _insecure version < "$(hy2_etc)/meta" 2>/dev/null || true
    printf '单元: %s\n版本: %s\n' "$(hy2_unit)" "${version:-未知}"
    systemctl --no-pager -l status "$HY2_UNIT_NAME" 2>&1 | sed -n '1,6p'
    if [[ -n ${port:-} ]]; then
        printf '端口 %s 监听: ' "$port"
        if hy2_port_owned_by "$port" "$bin"; then printf '由本服务持有\n'; else printf '不是本服务\n'; fi
    fi
}

# ---------------------------------------------------------------- 入口

toolbox_hy2() {
    local action=${1:-install}
    shift || true
    case $action in
        install) (( $# <= 4 )) || { hy2_die 'install 最多接受证书、私钥、主机名、端口四个参数。'; return 1; }; hy2_install "$@" ;;
        install-self) hy2_install_self "$@" ;;
        uninstall) hy2_uninstall ;;
        status) hy2_status ;;
        *) hy2_die "用法: toolbox_hy2 [install [<证书> <私钥> <主机名> [端口]] | install-self <连接入口> [SNI] [端口] | uninstall | status]" ;;
    esac
}

# 直接执行（bash modules/hy2.sh）也能用，但 sourcing 不产生任何副作用。
# 打进单文件包时由构建脚本设置 TOOLBOX_BUNDLED=1，避免误当成独立执行。
if [[ ${BASH_SOURCE[0]:-} == "$0" && ${TOOLBOX_BUNDLED:-0} != 1 ]]; then
    toolbox_hy2 "$@"
fi
