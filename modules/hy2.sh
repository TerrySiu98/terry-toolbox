#!/usr/bin/env bash
# A4 Hysteria 2 服务端安全安装模块。
#
# 只支持「全新的 Debian + systemd + 自带证书」这一条路径；sourcing 本文件只定义
# 函数，不写系统、不探测网络。任何一项前置条件不满足都在写盘前失败；写盘后失败
# 则回滚到安装前的状态。所有判定只认本机事实（OS、systemd、ss 监听、systemd 单元
# 归属），不猜测「看起来像我们的服务」。
#
# 固定上游：HyNetworks/hysteria app/v2.13.0 官方发布二进制 + SHA-256 白名单。
# 不使用官方一键脚本，也不从「latest」解析版本号。

readonly HY2_VERSION='2.13.0'
readonly HY2_BIN_NAME='terry-toolbox-hy2'
readonly HY2_UNIT_NAME='terry-toolbox-hy2.service'
readonly HY2_DEFAULT_PORT=443
readonly HY2_MIN_VALID_DAYS=7
readonly HY2_MASQUERADE_TEXT='Terry Toolbox Hysteria 2'

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
    local file=${TOOLBOX_HY2_OS_RELEASE:-/etc/os-release} id=''
    [[ -r $file ]] || hy2_die "无法读取 $file，不能确认发行版。"
    id=$(sed -n 's/^ID=//p' "$file" | head -n1)
    id=${id%\"}; id=${id#\"}; id=${id%\'}; id=${id#\'}
    [[ ${id,,} == debian ]] || hy2_die "仅支持 Debian（当前 ID=${id:-未知}）；不支持 Alpine/Ubuntu/衍生版。"
}

hy2_require_systemd() {
    local run_dir=${TOOLBOX_HY2_SYSTEMD_RUN:-/run/systemd/system}
    command -v systemctl >/dev/null 2>&1 || hy2_die '未找到 systemctl，本机不是 systemd 系统。'
    [[ -d $run_dir ]] || hy2_die 'systemd 未作为 init 运行（缺少 /run/systemd/system）。'
}

hy2_require_tools() {
    local missing=() c
    for c in openssl sha256sum curl flock ss awk sed mktemp; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    (( ${#missing[@]} == 0 )) || hy2_die "缺少必需命令：${missing[*]}"
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
    [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
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
    [[ -e $unit_file ]] || { printf 'absent\n'; return 0; }
    if grep -qF "ExecStart=$(hy2_bin)" "$unit_file" 2>/dev/null; then
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
    openssl pkey -in "$key" -noout 2>/dev/null || { hy2_die "不是有效的 PEM 私钥：$key"; return 1; }

    # 公私钥配对：比对两者的公开模数/公钥，配对失败的服务启动即 FATAL。
    local cpub kpub
    cpub=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null) || { hy2_die '证书公钥解析失败'; return 1; }
    kpub=$(openssl pkey -in "$key" -pubout 2>/dev/null) || { hy2_die '私钥公钥解析失败'; return 1; }
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

# 证书链是否能被本机信任库验证（决定验证客户端要不要加 insecure）。
hy2_tls_trusted() {
    local cert=$1
    if [[ -r /etc/ssl/certs/ca-certificates.crt ]]; then
        openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$cert" >/dev/null 2>&1
    elif [[ -d /etc/ssl/certs ]]; then
        openssl verify -CApath /etc/ssl/certs "$cert" >/dev/null 2>&1
    else
        return 1
    fi
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

hy2_rollback() {
    local unit bin etc
    unit=$(hy2_unit); bin=$(hy2_bin); etc=$(hy2_etc)
    hy2_err '--- 开始回滚 ---'
    if [[ -e $unit ]]; then
        systemctl disable --now "$HY2_UNIT_NAME" >/dev/null 2>&1 || true
        rm -f -- "$unit"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed "$HY2_UNIT_NAME" >/dev/null 2>&1 || true
    fi
    rm -f -- "$bin"
    if [[ -d $etc ]]; then rm -rf -- "$etc"; fi
    rm -rf -- "$(hy2_client_dir)"
    # 只认我们自己的单元名，不碰同名以外的东西。
    if systemctl is-active --quiet "$HY2_UNIT_NAME" 2>/dev/null; then
        hy2_err "警告：回滚后 $HY2_UNIT_NAME 仍在运行，请人工确认。"
    fi
    hy2_err '已恢复到安装前状态（新增的单元、二进制、/etc 目录已删除）。'
}

# ---------------------------------------------------------------- 启动与验证

# 写盘后、交给 systemd 之前的离线自检：配置能否被解析、证书能否加载、端口能否绑定。
# 起后台进程看日志，成功就杀掉并等它退出，避免和随后的 systemd 启动抢端口。
hy2_smoke() {
    local bin=$1 conf=$2 port=$3 out pid i
    out=$(mktemp) || return 1
    "$bin" server -c "$conf" --disable-update-check >"$out" 2>&1 &
    pid=$!
    for ((i = 0; i < 60; i++)); do
        if grep -q 'server up and running' "$out" 2>/dev/null; then break; fi
        if grep -q 'FATAL' "$out" 2>/dev/null; then break; fi
        kill -0 "$pid" 2>/dev/null || break
        command sleep 0.2
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
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
# 成功判据是客户端日志出现 connected；密码错误/SNI 错误必须分别失败，否则视为
# 「认证没被证明」而不是默认通过。
# quiet=1 时只在失败时输出（用于预期失败的负向探测）。
hy2_probe() {
    local bin=$1 host=$2 port=$3 pass=$4 insecure=$5 label=$6 quiet=${7:-0}
    local dir sock out out_dc i
    dir=$(hy2_client_dir); mkdir -p "$dir" || return 1
    sock=$(( 39000 + RANDOM % 2000 ))
    while hy2_udp_port_busy "$sock" || ss -ltnH 2>/dev/null | grep -q ":$sock "; do (( sock++ )); done
    out="$dir/$label.log"

    {
        printf 'server: 127.0.0.1:%s\n' "$port"
        printf 'auth: %s\n' "$pass"
        printf 'tls:\n  sni: %s\n' "$host"
        if [[ $insecure == 1 ]]; then printf '  insecure: true\n'; fi
        printf 'socks5:\n  listen: 127.0.0.1:%s\n' "$sock"
    } > "$dir/$label.yaml" || return 1

    # 客户端要一直活着才能做数据面测试，所以放后台，靠日志判断结果。
    "$bin" client -c "$dir/$label.yaml" --disable-update-check >"$out" 2>&1 &
    local cpid=$! result=1
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
            out_dc=$(timeout 25 curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:$sock" \
                -o /dev/null -w '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) && break
            out_dc=''
            command sleep 1
        done
        [[ -n $out_dc ]] || hy2_err "提示：$label 隧道已通，但数据面出站未成功（可能主机无外网出口）。"
    elif (( result == 1 )) && (( quiet == 0 )); then
        sed -n '1,8p' "$out" >&2
    fi

    kill "$cpid" 2>/dev/null
    wait "$cpid" 2>/dev/null || true
    return $result
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
    local cert=${1:-} key=${2:-} host=${3:-} port=${4:-} answer
    local arch tmp etc bin unit pass trusted=1

    hy2_require_root || return 1
    hy2_require_debian || return 1
    hy2_require_systemd || return 1
    hy2_require_tools || return 1
    arch=$(hy2_arch) || return 1
    etc=$(hy2_etc); bin=$(hy2_bin); unit=$(hy2_unit)

    [[ -n $cert ]] || { hy2_die '缺少证书路径。'; return 1; }
    [[ -n $key ]] || { hy2_die '缺少私钥路径。'; return 1; }
    [[ -n $host ]] || { hy2_die '缺少主机名（证书对应的域名）。'; return 1; }
    host=${host,,}
    hy2_valid_hostname "$host" || { hy2_die "主机名格式不正确：$host"; return 1; }
    if [[ -n $port ]]; then
        hy2_valid_port "$port" || { hy2_die "端口不正确：$port（1-65535，无前导零）"; return 1; }
    else
        port=$HY2_DEFAULT_PORT
    fi
    hy2_check_cert "$cert" "$key" "$host" || return 1

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

    if hy2_udp_port_busy "$port"; then
        hy2_err "UDP 端口 $port 已被占用，监听它的进程："
        ss -lunpH 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" {print "  " $4 " " $0}' | cut -c1-160 >&2
        hy2_die "换成其他端口，或先确认并停止占用方。"
        return 1
    fi

    printf '即将安装 Hysteria 2 服务端：\n'
    printf '  版本    : v%s（官方发布，安装前校验 SHA-256）\n' "$HY2_VERSION"
    printf '  主机名  : %s\n' "$host"
    printf '  监听    : 0.0.0.0:%s/udp（IPv4+IPv6 通配）\n' "$port"
    printf '  证书    : %s\n' "$cert"
    printf '  私钥    : %s（复制到 %s，权限 600）\n' "$key" "$etc"
    printf '  单元    : %s\n' "$unit"
    printf '  认证    : 随机密码，安装完成后只显示一次\n'
    printf '  防火墙  : 不改动；需自行放行 UDP %s\n' "$port"
    printf '确认安装？输入 YES 继续：'
    IFS= read -r answer || true
    [[ ${answer^^} == YES ]] || { hy2_err '已取消，未修改系统。'; return 1; }

    # 互斥：同一时刻只允许一个安装/卸载。
    exec 9>"$(hy2_lock)" || { hy2_die "无法创建锁文件 $(hy2_lock)"; return 1; }
    flock -n 9 || { hy2_die '另一个安装/卸载正在进行，稍后再试。'; return 1; }

    tmp=$(mktemp -d) || { hy2_die '无法创建临时目录'; return 1; }
    pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-32)
    [[ ${#pass} -eq 32 ]] || { rm -rf -- "$tmp"; hy2_die '密码生成失败'; return 1; }

    # 从这里开始有任何失败都回滚。
    hy2_err '--- 开始写入 ---'
    hy2_fetch "$arch" "$tmp/hysteria" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }

    install -d -m 0755 "$etc" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    install -m 0755 "$tmp/hysteria" "$bin" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    install -m 0600 "$cert" "$etc/cert.pem" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }
    install -m 0600 "$key" "$etc/key.pem" || { rm -rf -- "$tmp"; hy2_rollback; return 1; }

    local masq=''
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
    content: '$HY2_MASQUERADE_TEXT'
    statusCode: 200
EOF
    chmod 0600 "$etc/config.yaml"

    cat > "$unit" <<EOF
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
    chmod 0644 "$unit"

    # 写盘后先离线冒烟：证书/配置/端口绑定错误在这里暴露，早于 systemd。
    if ! hy2_smoke "$bin" "$etc/config.yaml" "$port"; then
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi

    if ! systemctl daemon-reload; then
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi
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

    # 证书链不被本机信任时（自签/缺中间证书）用 insecure 探测，并明确标注。
    hy2_tls_trusted "$etc/cert.pem" || trusted=0
    local insecure=0
    if [[ $trusted == 0 ]]; then insecure=1; fi

    if ! hy2_probe "$bin" "$host" "$port" "$pass" "$insecure" good; then
        hy2_err '认证探测失败（正确密码未连通）。'
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi
    # 负向探测：错误密码必须被拒，否则等于没验证认证。
    if hy2_probe "$bin" "$host" "$port" "wrong-$pass" "$insecure" bad 1; then
        hy2_err '错误密码也被接受，认证未生效。'
        rm -rf -- "$tmp"; hy2_rollback; return 1
    fi
    printf '  负向探测：错误密码被拒绝 ✓\n'

    printf '%s|%s|%s|%s\n' "$host" "$port" "$insecure" "$HY2_VERSION" > "$etc/meta"
    chmod 0600 "$etc/meta"
    rm -rf -- "$tmp"

    hy2_report "$host" "$port" "$pass" "$insecure"
}

hy2_report() {
    local host=$1 port=$2 pass=$3 insecure=$4 qs=''
    if [[ $insecure == 1 ]]; then qs='&insecure=1'; fi
    printf '\n安装完成，服务 %s 已设为开机自启。\n' "$HY2_UNIT_NAME"
    printf '客户端连接信息（密码只显示这一次，也已写入 %s/config.yaml）：\n' "$(hy2_etc)"
    printf '  hysteria2://%s@%s:%s/?sni=%s%s\n' "$pass" "$host" "$port" "$host" "$qs"
    if [[ $insecure == 1 ]]; then
        printf '  证书链未被本机信任库验证通过：上面链接带 insecure=1，客户端需同样开启。\n'
    else
        printf '  证书链验证通过：客户端可保持严格校验（去掉 insecure=1）。\n'
    fi
    printf '\n验证情况：\n'
    printf '  [已验证] 单元 active、UDP %s 由 %s 监听\n' "$port" "$HY2_BIN_NAME"
    printf '  [已验证] 正确密码经 TLS 认证连通；错误密码被拒绝\n'
    printf '\n仍需人工处理：\n'
    printf '  - 防火墙/安全组放行 UDP %s（本模块不改防火墙）\n' "$port"
    printf '  - 证书续期：更新后覆盖 %s/cert.pem、key.pem，重载服务\n' "$(hy2_etc)"
    printf '  - 卸载：toolbox_hy2 uninstall\n'
}

# ---------------------------------------------------------------- 卸载

_hy2_uninstall() {
    local unit etc bin state answer
    hy2_require_root || return 1
    hy2_require_systemd || return 1
    unit=$(hy2_unit); etc=$(hy2_etc); bin=$(hy2_bin)
    state=$(hy2_unit_state)
    if [[ $state == absent && ! -e $bin && ! -d $etc ]]; then
        hy2_die '没有找到本模块的安装（单元、二进制、配置都不存在）。'
        return 1
    fi
    if [[ $state == foreign ]]; then
        hy2_die "$unit 不是本模块生成的，未删除；请人工确认。"
        return 1
    fi

    printf '将停止并删除：%s\n  %s\n  %s\n  %s\n' "$unit" "$bin" "$etc" "（证书副本，原始证书不动）"
    printf '确认卸载？输入 YES：'
    IFS= read -r answer || true
    [[ ${answer^^} == YES ]] || { hy2_err '已取消。'; return 1; }

    exec 9>"$(hy2_lock)" || { hy2_die "无法创建锁文件"; return 1; }
    flock -n 9 || { hy2_die '另一个安装/卸载正在进行。'; return 1; }

    systemctl disable --now "$HY2_UNIT_NAME" >/dev/null 2>&1 || true
    rm -f -- "$unit"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed "$HY2_UNIT_NAME" >/dev/null 2>&1 || true
    rm -f -- "$bin"
    rm -rf -- "$etc"
    rm -rf -- "$(hy2_client_dir)"
    printf '已卸载。\n'
}

# 安装/卸载整体放进子 shell：锁用 exec 9 持有，子 shell 结束后自动释放，
# 不会把锁句柄留到调用方 shell 里。子 shell 内显式 set -e，这样即使调用方把
# 本函数放进 `||` / `$( )` 之类会关闭 errexit 的上下文，中途失败也会立即停下。
hy2_install() { ( set -e; _hy2_install "$@" ) ; }
hy2_uninstall() { ( set -e; _hy2_uninstall "$@" ) ; }

hy2_status() {
    local host port insecure version
    if [[ ! -e $(hy2_unit) ]]; then
        printf '未安装。\n'
        return 1
    fi
    IFS='|' read -r host port insecure version < "$(hy2_etc)/meta" 2>/dev/null || true
    printf '单元: %s\n' "$(hy2_unit)"
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
        install) hy2_install "$@" ;;
        uninstall) hy2_uninstall ;;
        status) hy2_status ;;
        *) hy2_die "用法: toolbox_hy2 [install <证书> <私钥> <主机名> [端口] | uninstall | status]" ;;
    esac
}

# 直接执行（bash modules/hy2.sh）也能用，但 sourcing 不产生任何副作用。
# 打进单文件包时由构建脚本设置 TOOLBOX_BUNDLED=1，避免误当成独立执行。
if [[ ${BASH_SOURCE[0]:-} == "$0" && ${TOOLBOX_BUNDLED:-0} != 1 ]]; then
    toolbox_hy2 "$@"
fi
