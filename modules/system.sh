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
# Package-manager and service-manager boundaries are indirected so tests can
# replace them without touching the host.
_toolbox_system_has() { command -v "$1" >/dev/null 2>&1; }
_toolbox_system_need_tools() {
    local c missing=()
    for c in "$@"; do _toolbox_system_has "$c" || missing+=("$c"); done
    (( ${#missing[@]} == 0 )) || { _toolbox_system_error "缺少必需命令：${missing[*]}"; return 1; }
}
_toolbox_system_systemd() {
    _toolbox_system_has systemctl || { _toolbox_system_error '未找到 systemctl，本机不是 systemd 系统。'; return 1; }
    [[ -d ${TOOLBOX_SYSTEMD_RUN:-/run/systemd/system} ]] \
        || { _toolbox_system_error 'systemd 未作为 init 运行（缺少 /run/systemd/system）。'; return 1; }
}
# Paths are overridable so isolated tests never write outside a temp root.
_toolbox_system_etc()       { printf '%s\n' "${TOOLBOX_SYSTEM_ETC:-/etc/terry-toolbox}"; }
_toolbox_system_state()     { printf '%s\n' "${TOOLBOX_SYSTEM_STATE:-/var/lib/terry-toolbox}"; }
_toolbox_system_unit_dir()  { printf '%s\n' "${TOOLBOX_SYSTEM_UNIT_DIR:-/etc/systemd/system}"; }
_toolbox_system_bin_dir()   { printf '%s\n' "${TOOLBOX_SYSTEM_BIN_DIR:-/usr/local/bin}"; }
_toolbox_system_sysctl_dir(){ printf '%s\n' "${TOOLBOX_SYSTEM_SYSCTL_DIR:-/etc/sysctl.d}"; }
# Ownership markers: a file without the marker is treated as foreign and is
# never overwritten, only reported.
readonly _TOOLBOX_SYS_MARK_B7='# terry-toolbox B7 traffic config'
readonly _TOOLBOX_SYS_MARK_B15='# terry-toolbox B15 telegram config'
readonly _TOOLBOX_SYS_MARK_B16='# Managed by terry-toolbox (B16)'
readonly _TOOLBOX_SYS_MARK_B19='# terry-toolbox B19 port-hop'

_toolbox_system_ours() {
    local file=$1 marker=$2
    [[ -f $file ]] && grep -qxF -- "$marker" "$file" 2>/dev/null
}
# Print a file atomically next to its target (same filesystem), mode 0600/0644.
_toolbox_system_put() {
    local target=$1 mode=$2 tmp
    tmp="${target}.tmp.$$"
    cat > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod "$mode" -- "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$target"
}
# Hidden input: value never appears in the terminal echo or in logs.
_toolbox_system_read_secret() {
    local __value
    printf '%s: ' "$2" >&2
    IFS= read -rs __value || { printf '\n' >&2; _toolbox_system_error "$2 未输入。"; return 1; }
    printf '\n' >&2
    [[ -n $__value ]] || { _toolbox_system_error "$2 不能为空。"; return 1; }
    printf -v "$1" '%s' "$__value"
}
_toolbox_system_read_line() {
    local __value
    printf '%s: ' "$2" >&2
    IFS= read -r __value || { _toolbox_system_error "$2 未输入。"; return 1; }
    [[ -n $__value ]] || { _toolbox_system_error "$2 不能为空。"; return 1; }
    printf -v "$1" '%s' "$__value"
}
_toolbox_system_positive_int() { [[ $1 =~ ^[1-9][0-9]{0,6}$ ]]; }

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
    if _toolbox_system_has docker; then
        _toolbox_system_error 'Docker 已存在；为保护现有服务和数据不进行安装或重配置。'; return 1
    fi
    os=$(_toolbox_system_os) || return
    _toolbox_system_confirm '将使用系统仓库安装 Docker；包安装可能启动服务或改变防火墙。不会删除容器和数据。' || return
    case "$os" in
        debian) apt-get install -y docker.io;;
        alpine) apk add --no-cache docker docker-cli-compose;;
        *) return 1;;
    esac || return
    _toolbox_system_has docker || { _toolbox_system_error '安装命令已完成但 docker 不可用；请检查包状态。'; return 1; }
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
# ---------------------------------------------------------------- B2 NodeQuality
# 上游没有版本号，只按 main 分支发布；脚本本体因此固定到提交号，摘要写死在代码里。
# raw.githubusercontent 对完整提交号是不可变地址：上游更新后摘要不变，但需要人改这里
# 的两行常量才会跟随（不自动更新）。摘要只证明下载内容与该提交一致，不是安全审计。
readonly _TOOLBOX_NODEQUALITY_COMMIT='a92fca6c0067df29ddd03fdc2fee6f3000f64545'
readonly _TOOLBOX_NODEQUALITY_URL=\
"https://raw.githubusercontent.com/LloydAsp/NodeQuality/$_TOOLBOX_NODEQUALITY_COMMIT/NodeQuality.sh"
readonly _TOOLBOX_NODEQUALITY_SHA256='4e1b25894cadf908ef61fb0d9ce874a75524c6dafc2ea26f0477107288e0c018'

# 地址与摘要均可被环境变量覆盖：离线测试用，也可在上游更新后临时对照实际摘要。
_toolbox_system_nodequality_url() { printf '%s\n' "${TOOLBOX_NODEQUALITY_URL:-$_TOOLBOX_NODEQUALITY_URL}"; }
_toolbox_system_nodequality_sha() { printf '%s\n' "${TOOLBOX_NODEQUALITY_SHA256:-$_TOOLBOX_NODEQUALITY_SHA256}"; }

# 上游 post_cleanup 固定以 exit 1 结束，成功与否要看输出是否走到上传完成。
_toolbox_system_nodequality() {
    local tmp script actual expected rc=0 left failed=0
    _toolbox_system_root || return
    _toolbox_system_need_tools bash curl sha256sum tar mount chroot || return

    printf 'NodeQuality：官方综合测试（不安装软件，只在临时系统内跑一遍）\n'
    printf '  脚本地址 : %s\n' "$(_toolbox_system_nodequality_url)"
    printf '  固定提交 : %s\n' "$_TOOLBOX_NODEQUALITY_COMMIT"
    printf '  校验     : 下载后比对固定 SHA-256 %s…（不匹配即中止，不执行）\n' \
        "$(_toolbox_system_nodequality_sha | cut -c1-12)"
    printf '  依据     : 摘要只证明文件与该提交一致，不等于安全审计；上游更新需改代码里的常量\n'
    printf '  运行方式 : 在临时目录放脚本，chroot 挂载 BenchOs，测完自动卸载并删除该目录\n'
    printf '  仍在变动 : BenchOS（release v0.0.2）与 main 分支的 part/*.sh、各检查脚本每次运行现下载\n'
    printf '  上传     : 结果 zip 会上传到 api.nodequality.com（第三方接口，可能失败）\n'
    printf '  退出码   : 上游结尾固定 exit 1，返回 1 属正常；以输出是否走到上传完成为准\n'
    printf '  影响面   : 需要 root；运行期短暂挂载 proc/sys/dev，结束后卸载；不改系统配置\n'
    _toolbox_system_confirm '确认下载固定版本脚本，校验通过后在临时目录执行？' || return

    tmp=$(mktemp -d) || return 1
    script="$tmp/NodeQuality.sh"
    if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 \
        -o "$script" "$(_toolbox_system_nodequality_url)"; then
        _toolbox_system_error '下载脚本失败；未执行。'
        rm -rf -- "$tmp"; return 1
    fi
    actual=$(sha256sum -- "$script" | cut -d' ' -f1)
    expected=$(_toolbox_system_nodequality_sha)
    if [[ $actual != "$expected" ]]; then
        _toolbox_system_error "脚本 SHA-256 不匹配：期望 $expected，实际 $actual。未执行。"
        _toolbox_system_error "上游可能已更新；核对无误后可临时用 TOOLBOX_NODEQUALITY_SHA256=$actual 复跑。"
        _toolbox_system_error "已保留下载文件供人工审阅：$script"
        return 1
    fi
    printf '校验通过（%s…）。开始执行，以下输出直接来自上游脚本，中途会提问。\n\n' "${actual:0:12}"

    # 上游以当前目录为基准建 .nodequality<时间戳> 工作目录，故必须先进临时目录。
    ( cd "$tmp" && bash ./NodeQuality.sh ) || rc=$?
    if (( rc != 0 && rc != 1 )); then
        _toolbox_system_error "上游脚本异常退出（$rc）；可能只跑了一部分。"
        failed=1
    fi
    # 正常收尾会删掉工作目录；残留说明卸载或清理没成功，保留临时目录供检查。
    left=$(find "$tmp" -maxdepth 1 -name '.nodequality*' -print -quit 2>/dev/null)
    if [[ -n $left ]]; then
        _toolbox_system_error "检测到未清理的工作目录 $left：可能挂载残留，重启后确认再删除。"
        _toolbox_system_error "临时目录保留在 $tmp（含 error.log，若有）。"
        return 1
    fi
    rm -rf -- "$tmp"
    if (( failed )); then return 1; fi
    printf '\nNodeQuality 已结束：结果已尝试上传，临时目录已删除，本机配置未改动。\n'
    printf '若上传失败，输出里会显示上传接口报错，需重跑；屏幕上的报告不会自动保存。\n'
}
_toolbox_system_trace() {
    local destination label failed=0
    _toolbox_system_has traceroute || { _toolbox_system_error '缺少 traceroute；请先手动安装。'; return 1; }
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

# ---------------------------------------------------------------- B7 流量统计
# vnstat 只读取内核计数，不进入转发路径，也不修改防火墙；因此这里只做统计和
# 阈值告警，不在超额时阻断网络。阈值告警由 systemd timer 每小时调用一次，
# 同一自然日最多告警一次，避免刷屏。
_TOOLBOX_TRAFFIC_CHECK='terry-toolbox-traffic-check'
_TOOLBOX_TRAFFIC_SERVICE='terry-toolbox-traffic.service'
_TOOLBOX_TRAFFIC_TIMER='terry-toolbox-traffic.timer'

_toolbox_system_vnstat_json_ok() {
    local out
    out=$(vnstat --json 2>/dev/null) || return 1
    # vnstat exits 0 before the database exists but emits no JSON object.
    [[ $out == *'"interfaces"'* ]]
}

# 可选参数是旧配置的备份：失败时恢复旧配置，而不是让重设变成“没有配置”。
_toolbox_system_traffic_cleanup() {
    local unit_dir bin etc
    unit_dir=$(_toolbox_system_unit_dir); bin=$(_toolbox_system_bin_dir); etc=$(_toolbox_system_etc)
    systemctl disable --now "$_TOOLBOX_TRAFFIC_TIMER" >/dev/null 2>&1 || true
    rm -f -- "$unit_dir/$_TOOLBOX_TRAFFIC_TIMER" "$unit_dir/$_TOOLBOX_TRAFFIC_SERVICE"
    rm -f -- "$bin/$_TOOLBOX_TRAFFIC_CHECK"
    if [[ -n ${1-} && -f $1 ]]; then
        mv -f -- "$1" "$etc/traffic.conf" \
            && printf '已恢复此前的阈值配置，但定时器已停用；请重跑 B7 重新启用。\n' >&2
    else
        rm -f -- "$etc/traffic.conf"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
}

_toolbox_system_write_traffic_check() {
    local target=$1 etc state
    etc=$(_toolbox_system_etc); state=$(_toolbox_system_state)
    cat > "$target" <<EOF
#!/usr/bin/env bash
# terry-toolbox B7 流量阈值检查（由 systemd timer 调用）。只告警，不阻断流量。
set -u
CONF=\${TOOLBOX_TRAFFIC_CONF:-$etc/traffic.conf}
STATE=\${TOOLBOX_TRAFFIC_STATE:-$state}
TG_CONF=\${TOOLBOX_TG_CONF:-$etc/telegram.conf}
log() { logger -t terry-toolbox-traffic "\$*" 2>/dev/null || printf '%s\n' "\$*" >&2; }
[[ -r \$CONF ]] || exit 0
limit=''
while IFS='=' read -r key value; do
    [[ \$key == LIMIT_GIB ]] && limit=\$value
done < "\$CONF"
case \${limit:-} in ''|*[!0-9]*) exit 0;; esac
(( limit > 0 )) || exit 0
command -v vnstat >/dev/null 2>&1 || { log 'vnstat 不存在，跳过检查'; exit 0; }
command -v jq >/dev/null 2>&1 || { log '缺少 jq，跳过检查'; exit 0; }
json=\$(vnstat --json 2>/dev/null) || { log 'vnstat 读取失败'; exit 0; }
bytes=\$(printf '%s' "\$json" | jq -r --arg y "\$(date +%Y)" --argjson m "\$((10#\$(date +%m)))" \\
    '[ .interfaces[]? | select(.name != "lo") | .traffic.month[]?
       | select((.date.year|tostring) == \$y and .date.month == \$m)
       | ((.rx // 0) + (.tx // 0)) ] | add // 0' 2>/dev/null) || exit 0
case \${bytes:-} in ''|*[!0-9]*) exit 0;; esac
used=\$(awk -v b="\$bytes" 'BEGIN { printf "%.2f", b / 1073741824 }')
over=\$(awk -v u="\$used" -v l="\$limit" 'BEGIN { print (u >= l) ? 1 : 0 }')
(( over == 1 )) || exit 0
mkdir -p "\$STATE" 2>/dev/null || exit 0
marker="\$STATE/traffic-\$(date +%Y%m).state"
today=\$(date +%F)
if [[ -r \$marker && \$(<"\$marker") == "\$today" ]]; then exit 0; fi
printf '%s\n' "\$today" > "\$marker" || exit 0
msg="\$(hostname) 本月流量已用 \${used} GiB，达到阈值 \${limit} GiB（仅告警，未阻断）。"
log "\$msg"
[[ -r \$TG_CONF ]] || exit 0
token=''; chat=''
while IFS='=' read -r key value; do
    case \$key in TOKEN) token=\$value;; CHAT_ID) chat=\$value;; esac
done < "\$TG_CONF"
[[ -n \$token && -n \$chat ]] || exit 0
curl -fsS --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 20 \\
    --data-urlencode "chat_id=\$chat" --data-urlencode "text=\$msg" \\
    -o /dev/null "https://api.telegram.org/bot\$token/sendMessage" \\
    || log 'Telegram 发送失败'
exit 0
EOF
    chmod 0755 -- "$target"
}

_toolbox_system_traffic() {
    local os etc state bin unit_dir conf limit installed=0 ready=0 i backup=''
    _toolbox_system_root || return
    os=$(_toolbox_system_os) || return
    [[ $os == debian ]] || { _toolbox_system_error '流量统计目前只支持 Debian/Ubuntu 的 vnstat 包；Alpine 未验证。'; return 1; }
    _toolbox_system_systemd || return
    _toolbox_system_need_tools curl || return
    etc=$(_toolbox_system_etc); state=$(_toolbox_system_state)
    bin=$(_toolbox_system_bin_dir); unit_dir=$(_toolbox_system_unit_dir)
    conf="$etc/traffic.conf"

    if [[ -e $conf ]] && ! _toolbox_system_ours "$conf" "$_TOOLBOX_SYS_MARK_B7"; then
        _toolbox_system_error "$conf 已存在但不是本工具生成的，未覆盖；请人工确认归属。"
        return 1
    fi
    _toolbox_system_has vnstat && installed=1

    _toolbox_system_read_line limit '每月告警阈值（GiB，整数；0 表示只统计不告警）' || return
    case $limit in
        0) ;;
        *) _toolbox_system_positive_int "$limit" || { _toolbox_system_error "阈值不正确：$limit"; return 1; };;
    esac

    if (( installed == 1 )); then
        printf 'vnstat 已安装：只更新阈值和定时器，不重装包。\n'
    else
        printf 'vnstat 未安装：将从系统仓库安装 vnstat 和 jq（jq 用于解析统计 JSON）。\n'
    fi
    printf '  阈值    : %s\n' "$( (( limit == 0 )) && printf '只统计' || printf '%s GiB/月' "$limit" )"
    printf '  单位    : GiB（1 GiB = 1024^3 字节）\n'
    printf '  检查    : 每小时一次，超额时同日最多告警一次\n'
    printf '  通知    : 写入系统日志；若已配置 B15 则同时发 Telegram\n'
    printf '  阻断    : 不阻断流量，超额后网络照常\n'
    _toolbox_system_confirm 'vnstat 会持续写入本机统计库；统计值来自内核计数，只统计不改变网络配置。确认继续？' || return

    # 目录和旧配置备份要在安装/就绪检查之前建好：任何后续失败都能原样恢复。
    install -d -m 0755 "$etc" "$state" || return 1
    if [[ -f $conf ]]; then backup="$conf.bak.$$"; cp -p -- "$conf" "$backup" || backup=''; fi

    if (( installed == 0 )); then
        apt-get install -y vnstat jq || {
            _toolbox_system_error 'vnstat/jq 安装失败；未写入配置。'; rm -f -- "$backup"; return 1
        }
        _toolbox_system_has jq || {
            _toolbox_system_error 'jq 仍不可用；未写入配置。'; rm -f -- "$backup"; return 1
        }
        systemctl enable --now vnstat >/dev/null 2>&1 || {
            _toolbox_system_error 'vnstat 服务启用失败；未写入配置。'; rm -f -- "$backup"; return 1
        }
    else
        _toolbox_system_has jq \
            || { _toolbox_system_error '已装 vnstat 但缺少 jq（检查脚本用它解析 JSON）。'; rm -f -- "$backup"; return 1; }
        systemctl enable --now vnstat >/dev/null 2>&1 || _toolbox_system_error '提示：vnstat 服务启用失败，统计可能不更新。'
    fi
    for ((i = 0; i < 30; i++)); do
        if _toolbox_system_vnstat_json_ok; then ready=1; break; fi
        sleep 1
    done
    if (( ready == 0 )); then
        _toolbox_system_error 'vnstat 在 30 秒内未产生可用统计（数据库未就绪）；包已安装，配置未写入。'
        _toolbox_system_traffic_cleanup "$backup"
        return 1
    fi

    {
        printf '%s\n' "$_TOOLBOX_SYS_MARK_B7"
        printf '# 由 Terry Toolbox B7 管理；值来自本工具询问。\n'
        printf 'LIMIT_GIB=%s\n' "$limit"
    } | _toolbox_system_put "$conf" 0600 || { _toolbox_system_error '写入阈值配置失败。'; [[ -n $backup ]] && mv -f -- "$backup" "$conf"; return 1; }
    if ! _toolbox_system_write_traffic_check "$bin/$_TOOLBOX_TRAFFIC_CHECK"; then
        _toolbox_system_error '写入检查脚本失败。'
        _toolbox_system_traffic_cleanup "$backup"
        return 1
    fi
    cat > "$unit_dir/$_TOOLBOX_TRAFFIC_SERVICE" <<EOF || { _toolbox_system_traffic_cleanup "$backup"; return 1; }
[Unit]
Description=Terry Toolbox traffic threshold check
Documentation=https://humdi.net/vnstat/
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$bin/$_TOOLBOX_TRAFFIC_CHECK
EOF
    cat > "$unit_dir/$_TOOLBOX_TRAFFIC_TIMER" <<EOF || { _toolbox_system_traffic_cleanup "$backup"; return 1; }
[Unit]
Description=Terry Toolbox hourly traffic threshold check

[Timer]
OnCalendar=hourly
RandomizedDelaySec=120
Persistent=true
Unit=$_TOOLBOX_TRAFFIC_SERVICE

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$unit_dir/$_TOOLBOX_TRAFFIC_SERVICE" "$unit_dir/$_TOOLBOX_TRAFFIC_TIMER"
    if ! systemctl daemon-reload || ! systemctl enable --now "$_TOOLBOX_TRAFFIC_TIMER" >/dev/null 2>&1; then
        _toolbox_system_error '定时器启用失败，已撤销本次写入。'
        _toolbox_system_traffic_cleanup "$backup"
        return 1
    fi
    if ! systemctl is-active --quiet "$_TOOLBOX_TRAFFIC_TIMER"; then
        _toolbox_system_error '定时器未进入 active 状态，已撤销本次写入。'
        _toolbox_system_traffic_cleanup "$backup"
        return 1
    fi
    rm -f -- "$backup"
    if (( limit == 0 )); then
        printf '\n流量统计已就绪：只记录，不告警（阈值为 0）。\n'
    else
        printf '\n流量统计已就绪：vnstat 记录读写字节，每月阈值 %s GiB，超额告警。\n' "$limit"
    fi
    printf '查看：vnstat -m；手动检查：%s；日志：journalctl -t terry-toolbox-traffic\n' "$bin/$_TOOLBOX_TRAFFIC_CHECK"
    printf '注意：统计数据来自内核计数，重装系统或清空 vnstat 数据库会丢失历史；只告警不阻断。\n'
    printf '重设阈值：再次执行 B7。告警渠道：执行 B15 配置 Telegram。\n'
}

# ---------------------------------------------------------------- B15 TG 通知
_TOOLBOX_TG_REPORT='terry-toolbox-tg-report'
_TOOLBOX_TG_SERVICE='terry-toolbox-tg.service'
_TOOLBOX_TG_TIMER='terry-toolbox-tg.timer'

_toolbox_system_tg_valid_token() { [[ $1 =~ ^[0-9]{5,}:[A-Za-z0-9_-]{30,}$ ]]; }
_toolbox_system_tg_valid_chat() { [[ $1 =~ ^(-?[0-9]{4,}|@[A-Za-z0-9_]{4,32})$ ]]; }

_toolbox_system_write_tg_report() {
    local target=$1 etc
    etc=$(_toolbox_system_etc)
    cat > "$target" <<EOF
#!/usr/bin/env bash
# terry-toolbox B15 流量日报。发送失败返回非 0，便于 systemctl 查看，不影响下次调度。
set -u
CONF=\${TOOLBOX_TG_CONF:-$etc/telegram.conf}
log() { logger -t terry-toolbox-tg "\$*" 2>/dev/null || printf '%s\n' "\$*" >&2; }
[[ -r \$CONF ]] || { log "缺少 \$CONF"; exit 1; }
token=''; chat=''
while IFS='=' read -r key value; do
    case \$key in TOKEN) token=\$value;; CHAT_ID) chat=\$value;; esac
done < "\$CONF"
[[ -n \$token && -n \$chat ]] || { log '配置缺少 TOKEN 或 CHAT_ID'; exit 1; }
if [[ \${1-} == --test ]]; then
    text="\$(hostname) 的 Telegram 流量通知已配置成功（B15）。日报将在每天 09:17 左右发送。"
else
    command -v vnstat >/dev/null 2>&1 || { log 'vnstat 不存在'; exit 1; }
    command -v jq >/dev/null 2>&1 || { log '缺少 jq'; exit 1; }
    json=\$(vnstat --json 2>/dev/null) || { log 'vnstat 读取失败'; exit 1; }
    day=\$(printf '%s' "\$json" | jq -r --arg y "\$(date +%Y)" --argjson m "\$((10#\$(date +%m)))" --argjson d "\$((10#\$(date +%d)))" \\
        '[ .interfaces[]? | select(.name != "lo") | .traffic.day[]?
           | select((.date.year|tostring) == \$y and .date.month == \$m and .date.day == \$d)
           | ((.rx // 0) + (.tx // 0)) ] | add // 0' 2>/dev/null) || { log '统计解析失败'; exit 1; }
    month=\$(printf '%s' "\$json" | jq -r --arg y "\$(date +%Y)" --argjson m "\$((10#\$(date +%m)))" \\
        '[ .interfaces[]? | select(.name != "lo") | .traffic.month[]?
           | select((.date.year|tostring) == \$y and .date.month == \$m)
           | ((.rx // 0) + (.tx // 0)) ] | add // 0' 2>/dev/null) || { log '统计解析失败'; exit 1; }
    gi() { awk -v b="\$1" 'BEGIN { printf "%.2f", b / 1073741824 }'; }
    text="\$(hostname) 流量日报 \$(date +%F)：今日下行+上行 \$(gi "\${day:-0}") GiB，本月累计 \$(gi "\${month:-0}") GiB。vnstat 口径，仅供估算。"
fi
curl -fsS --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 20 \\
    --data-urlencode "chat_id=\$chat" --data-urlencode "text=\$text" \\
    -o /dev/null "https://api.telegram.org/bot\$token/sendMessage"
EOF
    chmod 0755 -- "$target"
}

# 可选参数是旧凭据备份：失败时恢复旧配置。
_toolbox_system_tg_cleanup() {
    local unit_dir bin etc
    unit_dir=$(_toolbox_system_unit_dir); bin=$(_toolbox_system_bin_dir); etc=$(_toolbox_system_etc)
    systemctl disable --now "$_TOOLBOX_TG_TIMER" >/dev/null 2>&1 || true
    rm -f -- "$unit_dir/$_TOOLBOX_TG_TIMER" "$unit_dir/$_TOOLBOX_TG_SERVICE"
    rm -f -- "$bin/$_TOOLBOX_TG_REPORT"
    if [[ -n ${1-} && -f $1 ]]; then
        mv -f -- "$1" "$etc/telegram.conf" \
            && printf '已恢复此前的凭据配置，但定时器已停用；请重跑 B15 重新启用。\n' >&2
    else
        rm -f -- "$etc/telegram.conf"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
}

_toolbox_system_tg() {
    local etc bin unit_dir conf token chat out backup=''
    _toolbox_system_root || return
    _toolbox_system_os >/dev/null || return
    _toolbox_system_systemd || return
    _toolbox_system_need_tools curl || return
    _toolbox_system_has vnstat || { _toolbox_system_error '未找到 vnstat；请先执行 B7 流量统计。'; return 1; }
    _toolbox_system_has jq || { _toolbox_system_error '缺少 jq；请先执行 B7（会一并安装）。'; return 1; }
    etc=$(_toolbox_system_etc); bin=$(_toolbox_system_bin_dir); unit_dir=$(_toolbox_system_unit_dir)
    conf="$etc/telegram.conf"
    if [[ -e $conf ]] && ! _toolbox_system_ours "$conf" "$_TOOLBOX_SYS_MARK_B15"; then
        _toolbox_system_error "$conf 已存在但不是本工具生成的，未覆盖；请人工确认归属。"
        return 1
    fi

    printf 'Token 和 Chat ID 从 @BotFather / 与机器人的会话获取；输入时不回显。\n' >&2
    _toolbox_system_read_secret token 'Bot Token（形如 123456789:AA...）' || return
    _toolbox_system_tg_valid_token "$token" || { _toolbox_system_error 'Token 格式不正确（应为 <数字>:<35+ 位字母数字_-）。'; return 1; }
    _toolbox_system_read_line chat 'Chat ID（数字，或 @channelusername）' || return
    _toolbox_system_tg_valid_chat "$chat" || { _toolbox_system_error "Chat ID 格式不正确：$chat"; return 1; }

    printf '将写入 %s（权限 600），并创建每天 09:17 的 systemd 定时器。\n' "$conf"
    printf '安装结束前会真实发送一条测试消息；标签为 %s，发送失败则回滚本次写入。\n' "$(hostname)"
    printf 'Token 会出现在 systemd 以外的 curl 命令行参数中；不写入日志。\n'
    _toolbox_system_confirm '确认保存凭据并启用定时器？' || return

    install -d -m 0755 "$etc" || return 1
    if [[ -f $conf ]]; then backup="$conf.bak.$$"; cp -p -- "$conf" "$backup" || backup=''; fi
    {
        printf '%s\n' "$_TOOLBOX_SYS_MARK_B15"
        printf 'TOKEN=%s\n' "$token"
        printf 'CHAT_ID=%s\n' "$chat"
    } | _toolbox_system_put "$conf" 0600 || { _toolbox_system_error '写入凭据失败。'; [[ -n $backup ]] && mv -f -- "$backup" "$conf"; return 1; }

    _toolbox_system_write_tg_report "$bin/$_TOOLBOX_TG_REPORT" \
        || { _toolbox_system_error '写入发送脚本失败。'; _toolbox_system_tg_cleanup "$backup"; return 1; }
    cat > "$unit_dir/$_TOOLBOX_TG_SERVICE" <<EOF || { _toolbox_system_tg_cleanup "$backup"; return 1; }
[Unit]
Description=Terry Toolbox daily traffic report to Telegram
Documentation=https://core.telegram.org/bots/api
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$bin/$_TOOLBOX_TG_REPORT
EOF
    cat > "$unit_dir/$_TOOLBOX_TG_TIMER" <<EOF || { _toolbox_system_tg_cleanup "$backup"; return 1; }
[Unit]
Description=Terry Toolbox daily traffic report

[Timer]
OnCalendar=*-*-* 09:17:00
RandomizedDelaySec=300
Persistent=true
Unit=$_TOOLBOX_TG_SERVICE

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$unit_dir/$_TOOLBOX_TG_SERVICE" "$unit_dir/$_TOOLBOX_TG_TIMER"

    # 真实发送测试消息：无法送达的凭据不应悄悄留着定时器。
    if ! out=$(TOOLBOX_TG_CONF="$conf" "$bin/$_TOOLBOX_TG_REPORT" --test 2>&1); then
        _toolbox_system_error "测试消息发送失败，响应：${out:0:300}"
        _toolbox_system_error '已回滚本次写入（凭据、脚本、定时器）。请核对 token、chat_id 及到 api.telegram.org 的连通性。'
        _toolbox_system_tg_cleanup "$backup"
        return 1
    fi

    if ! systemctl daemon-reload || ! systemctl enable --now "$_TOOLBOX_TG_TIMER" >/dev/null 2>&1; then
        _toolbox_system_error '定时器启用失败，已回滚本次写入。'
        _toolbox_system_tg_cleanup "$backup"
        return 1
    fi
    rm -f -- "$backup"
    printf '\nTelegram 流量通知已启用：每天 09:17 左右发送前一自然日数量与本自然月累计。\n'
    printf '立即测试：%s（不带参数即发日报）；停用见帮助文档。\n' "$bin/$_TOOLBOX_TG_REPORT"
    printf '凭据以明文存放在 %s（600）：可被 root 读取，注意备份与轮换。\n' "$conf"
}

# ---------------------------------------------------------------- B16 网络优化
# 只写一个独立的 sysctl drop-in，并在写入前逐个确认内核确实接受这些键；
# 已有同名文件但不是本工具写的则拒绝覆盖。回滚按保存的旧值恢复。
_TOOLBOX_NETOPT_KEYS=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control
    net.core.somaxconn
    net.ipv4.tcp_max_syn_backlog
    net.ipv4.tcp_fastopen
    net.ipv4.tcp_slow_start_after_idle
    net.ipv4.tcp_mtu_probing
    net.ipv4.ip_local_port_range
    net.core.rmem_max
    net.core.wmem_max
)
_TOOLBOX_NETOPT_VALUES=(
    fq
    bbr
    4096
    8192
    3
    0
    1
    '10240 65000'
    16777216
    16777216
)

_toolbox_system_netopt_file() { printf '%s/99-terry-toolbox.conf\n' "$(_toolbox_system_sysctl_dir)"; }
_toolbox_system_netopt_state() { printf '%s/net-opt.previous\n' "$(_toolbox_system_state)"; }

_toolbox_system_netopt_apply() {
    local file state applied=0 i key
    local keys=() values=() previous=()
    file=$(_toolbox_system_netopt_file); state=$(_toolbox_system_netopt_state)
    _toolbox_system_root || return
    [[ $(_toolbox_system_os) == debian ]] || { _toolbox_system_error 'B16 只面向 Debian/Ubuntu 的 sysctl.d。'; return 1; }

    local available
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control) || return
    case " $available " in
        *' bbr '*) ;;
        *) _toolbox_system_error '内核未提供 BBR，本轮不改动；先确认内核版本与模块。'; return 1;;
    esac
    if [[ -e $file ]] && ! _toolbox_system_ours "$file" "$_TOOLBOX_SYS_MARK_B16"; then
        _toolbox_system_error "$file 已存在但不是本工具生成的，未覆盖；请人工合并或改名。"
        return 1
    fi

    # 只保留内核接受的键；读不到的值不能用来回滚，直接跳过。
    for ((i = 0; i < ${#_TOOLBOX_NETOPT_KEYS[@]}; i++)); do
        key=${_TOOLBOX_NETOPT_KEYS[i]}
        local old
        old=$(sysctl -n "$key" 2>/dev/null) || { printf '跳过（内核不支持）：%s\n' "$key"; continue; }
        keys+=("$key"); values+=("${_TOOLBOX_NETOPT_VALUES[i]}"); previous+=("$old")
    done
    (( ${#keys[@]} > 0 )) || { _toolbox_system_error '没有任何键被内核接受；未改动。'; return 1; }

    local want existing=''
    want=$(printf '%s\n' "$_TOOLBOX_SYS_MARK_B16" \
        '# 由 Terry Toolbox B16 管理；回滚请用菜单。不要手工混入其他键。'
        for ((i = 0; i < ${#keys[@]}; i++)); do printf '%s = %s\n' "${keys[i]}" "${values[i]}"; done)
    if [[ -r $file ]]; then
        existing=$(<"$file")
        if [[ $existing == "$want" ]]; then
            printf '优化项已全部应用且内容一致；未修改任何配置。\n'
            return 0
        fi
        printf '同名文件已存在（本工具生成）但内容不同：将覆盖为当前内核可接受的键。\n'
    fi
    printf '将写入 %s：\n' "$file"
    for ((i = 0; i < ${#keys[@]}; i++)); do
        printf '  %-40s %s -> %s\n' "${keys[i]}" "${previous[i]}" "${values[i]}"
    done
    printf '  队列与拥塞控制 : fq + bbr（BBR 需要内核支持，已确认）\n'
    printf '  不改动        : 其他 sysctl 文件、防火墙、网卡参数\n'
    printf '  回滚          : 菜单 B16 → 2，按保存的旧值恢复\n'
    _toolbox_system_confirm '这些参数会立即生效并写入持久配置（重启后仍生效）。确认应用？' || return

    install -d -m 0755 "$(_toolbox_system_sysctl_dir)" "$(_toolbox_system_state)" || return 1
    {
        printf '%s\n' "$_TOOLBOX_SYS_MARK_B16"
        for ((i = 0; i < ${#keys[@]}; i++)); do printf '%s=%s\n' "${keys[i]}" "${previous[i]}"; done
    } | _toolbox_system_put "$state" 0600 || { _toolbox_system_error '保存回滚值失败；未改动。'; return 1; }

    printf '%s\n' "$want" | _toolbox_system_put "$file" 0644 \
        || { _toolbox_system_error '写入 drop-in 失败；未改动运行期参数。'; rm -f -- "$state"; return 1; }

    if ! applied=$(sysctl -p "$file" 2>&1); then
        _toolbox_system_error 'sysctl 应用失败，正在恢复运行期旧值并删除 drop-in。原因：'
        printf '%s\n' "$applied" | head -n 3 >&2
        local restore_failed=0
        rm -f -- "$file"
        for ((i = 0; i < ${#keys[@]}; i++)); do
            sysctl -w "${keys[i]}=${previous[i]}" >/dev/null 2>&1 \
                || { _toolbox_system_error "  恢复失败：${keys[i]}=${previous[i]}"; restore_failed=1; }
        done
        if (( restore_failed == 1 )); then
            _toolbox_system_error "部分运行期值未能恢复，回滚记录保留在 $state。"
        else
            rm -f -- "$state"
        fi
        return 1
    fi
    # 回读：写进去不等于生效（例如被后加载的文件覆盖）。
    for ((i = 0; i < ${#keys[@]}; i++)); do
        local now
        now=$(sysctl -n "${keys[i]}" 2>/dev/null) || now=''
        if [[ $now != "${values[i]}" ]]; then
            _toolbox_system_error "回读不一致：${keys[i]} = '$now'（期望 '${values[i]}'）。可能有其他 sysctl 文件后加载并覆盖。"
            applied=1
        fi
    done
    if (( applied == 1 )); then
        _toolbox_system_error 'drop-in 已写入但未全部生效；可先用 B16 → 2 回滚，再检查冲突的 sysctl 文件。'
        return 1
    fi
    printf '\n网络参数已应用并写入 %s；重启后保持。\n' "$file"
    printf '查看：sysctl -a | grep -E "congestion|qdisc|somaxconn"\n'
}

_toolbox_system_netopt_rollback() {
    local file state key value
    file=$(_toolbox_system_netopt_file); state=$(_toolbox_system_netopt_state)
    _toolbox_system_root || return
    if [[ ! -r $state ]]; then
        _toolbox_system_error "没有回滚记录（$state）；可能从未应用，或记录已被删除。"
        return 1
    fi
    if [[ -e $file ]] && ! _toolbox_system_ours "$file" "$_TOOLBOX_SYS_MARK_B16"; then
        _toolbox_system_error "$file 已不是本工具生成的，未删除；请人工处理后再回滚。"
        return 1
    fi
    _toolbox_system_confirm "将删除 $file 并按保存值恢复运行期参数，然后删除回滚记录。确认？" || return
    rm -f -- "$file" || return 1
    local failed=0
    while IFS='=' read -r key value; do
        [[ $key == '#'* || -z $key ]] && continue
        sysctl -w "$key=$value" >/dev/null 2>&1 || { _toolbox_system_error "恢复失败：$key=$value"; failed=1; }
    done < "$state"
    if (( failed == 1 )); then
        _toolbox_system_error "部分值恢复失败，回滚记录保留在 $state；可修正后重试或按记录手工 sysctl -w。"
        return 1
    fi
    rm -f -- "$state"
    printf '已删除 drop-in 并恢复保存的旧值；重启后回到这些值。\n'
    printf '提示：运行期值已恢复，但仍请确认其他 sysctl 文件没有同时改动同一键。\n'
}

_toolbox_system_netopt() {
    local choice
    printf 'B16 网络优化\n 1 应用优化参数\n 2 回滚到应用前\n 0 返回\n请输入编号: ' >&2
    IFS= read -r choice || return 1
    case $choice in
        1) _toolbox_system_netopt_apply;;
        2) _toolbox_system_netopt_rollback;;
        0) printf '未修改。\n';;
        *) _toolbox_system_error "无效选项：$choice"; return 2;;
    esac
}

# ---------------------------------------------------------------- B11 1Panel
# 上游 quick_start.sh 只负责引导，真正的版本号和安装包在运行时才解析；因此这里
# 只固定引导脚本本体，并明确告知版本不固定、包摘要来自同一台官方服务器。
readonly _TOOLBOX_1PANEL_URL='https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh'
readonly _TOOLBOX_1PANEL_SHA256='619716796c54a4e3f82c21dff4d7d3e9eb44b7dd1f3fceb90e8e1f584f674d9c'
readonly _TOOLBOX_1PANEL_BASE='/opt/1panel'

# 固定的摘要/地址可被环境变量替换，便于离线测试和上游更新后的对照。
_toolbox_system_1panel_sha() { printf '%s\n' "${TOOLBOX_1PANEL_SHA256:-$_TOOLBOX_1PANEL_SHA256}"; }

_toolbox_system_1panel_present() {
    _toolbox_system_has 1pctl || _toolbox_system_has 1panel || [[ -d $_TOOLBOX_1PANEL_BASE ]]
}

_toolbox_system_panel() {
    local os tmp script actual
    _toolbox_system_root || return
    os=$(_toolbox_system_os) || return
    [[ $os == debian ]] || { _toolbox_system_error '1Panel 官方脚本面向 Debian/Ubuntu；Alpine 未验证。'; return 1; }
    _toolbox_system_need_tools curl sha256sum tar bash || return
    if _toolbox_system_1panel_present; then
        _toolbox_system_error '检测到 1Panel（1pctl / 1panel / /opt/1panel）；为保护面板数据不做重复安装。'
        _toolbox_system_error '升级请用面板自带的 1pctl update；卸载请用官方脚本后人工确认数据目录。'
        return 1
    fi

    printf '即将安装 1Panel 面板：\n'
    printf '  引导脚本 : %s\n' "${TOOLBOX_1PANEL_URL:-$_TOOLBOX_1PANEL_URL}"
    printf '  校验     : 下载后比对固定 SHA-256 %s…（不匹配即中止）\n' "$(_toolbox_system_1panel_sha | cut -c1-12)"
    printf '  版本     : 不固定，由官方服务器在安装时返回 stable 的最新版本\n'
    printf '  包校验   : 官方脚本用同一服务器上的 checksums.txt 校验安装包\n'
    printf '  注意     : 官方脚本用 curl -k 下载安装包（不校验证书链），并管道执行安装统计脚本\n'
    printf '  数据目录 : %s（脚本默认，未改动）\n' "$_TOOLBOX_1PANEL_BASE"
    printf '  端口     : 脚本默认 9999；安装完成会回显访问地址与初始账号\n'
    printf '  防火墙   : 不改动\n'
    _toolbox_system_confirm '确认下载并执行固定版本的官方引导脚本？' || return

    tmp=$(mktemp -d) || return 1
    script="$tmp/quick_start.sh"
    if ! curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 \
        -o "$script" "${TOOLBOX_1PANEL_URL:-$_TOOLBOX_1PANEL_URL}"; then
        _toolbox_system_error '下载引导脚本失败；未执行。'
        rm -rf -- "$tmp"; return 1
    fi
    actual=$(sha256sum -- "$script" | cut -d' ' -f1)
    local expected
    expected=$(_toolbox_system_1panel_sha)
    if [[ $actual != "$expected" ]]; then
        _toolbox_system_error "引导脚本 SHA-256 不匹配：期望 $expected，实际 $actual。"
        _toolbox_system_error "上游可能已更新；确认无误后可临时用 TOOLBOX_1PANEL_SHA256=$actual 重跑对照。已保留 $script 供人工审阅。"
        return 1
    fi
    printf '引导脚本校验通过（%s）。开始执行，输出直接来自上游脚本。\n\n' "${actual:0:12}…"

    local rc=0
    ( cd "$tmp" && INSTALL_MODE=stable PANEL_BASE_DIR=$_TOOLBOX_1PANEL_BASE bash ./quick_start.sh ) || rc=$?
    if (( rc != 0 )); then
        _toolbox_system_error "上游脚本返回 $rc；可能只完成一部分。"
        _toolbox_system_error "请先检查 1pctl、/opt/1panel 和容器状态再决定是否重试，避免半装状态下重复安装。临时目录：$tmp"
        return 1
    fi
    if ! _toolbox_system_1panel_present; then
        _toolbox_system_error '脚本返回 0 但未发现 1pctl 或 /opt/1panel；请人工检查面板是否真正装上。'
        return 1
    fi
    rm -rf -- "$tmp"
    printf '\n1Panel 已安装。\n'
    printf '下一步：用输出里的地址和初始账号登录，并立刻改密码；开放端口前先确认防火墙。\n'
    printf '当前面板自带 Docker 依赖：如脚本顺带安装了 Docker，请勿再用 B1 重复安装。\n'
    printf '升级：1pctl update；备份：/opt/1panel 与面板内备份功能，二者都要做。\n'
}

# ---------------------------------------------------------------- B19 Alpine
_TOOLBOX_WEBTOP_NAME='terry-toolbox-webtop'
_TOOLBOX_WEBTOP_IMAGE='lscr.io/linuxserver/webtop:latest'
_TOOLBOX_HOP_CONF_NAME='port-hop.conf'

_toolbox_system_alpine_require() {
    local os
    _toolbox_system_root || return
    os=$(_toolbox_system_os) || return
    [[ $os == alpine ]] || { _toolbox_system_error 'B19 只面向 Alpine；Debian 用对应功能即可。'; return 1; }
}

_toolbox_system_alpine_webtop() {
    local dir
    _toolbox_system_alpine_require || return
    if ! _toolbox_system_has docker; then
        _toolbox_system_error '未找到 docker；B19 不负责装 Docker（先走 B1）。'; return 1
    fi
    docker info >/dev/null 2>&1 || { _toolbox_system_error 'Docker 守护进程不可用；先启动并确认权限。'; return 1; }
    if [[ -n $(docker ps -a --filter "name=^/${_TOOLBOX_WEBTOP_NAME}\$" --format '{{.Names}}') ]]; then
        _toolbox_system_error "容器 $_TOOLBOX_WEBTOP_NAME 已存在；不删除、不重建。查看：docker logs $_TOOLBOX_WEBTOP_NAME"
        return 1
    fi
    dir=/opt/terry-toolbox-webtop
    printf '将运行 Webtop 桌面容器：\n'
    printf '  镜像   : %s（latest，不固定摘要）\n' "$_TOOLBOX_WEBTOP_IMAGE"
    printf '  端口   : 127.0.0.1:3000 -> 容器 3000（仅本机；对外需反代或改绑定）\n'
    printf '  数据   : %s（挂载到 /config，重建容器不丢）\n' "$dir"
    printf '  shm    : 1g；重启策略 unless-stopped\n'
    _toolbox_system_confirm '将拉取镜像并启动容器，可能占用数百 MB 磁盘。确认？' || return

    install -d -m 0755 "$dir" || return 1
    if ! docker pull "$_TOOLBOX_WEBTOP_IMAGE"; then
        _toolbox_system_error '镜像拉取失败；未创建容器。'
        return 1
    fi
    if ! docker run -d --name "$_TOOLBOX_WEBTOP_NAME" --restart unless-stopped \
        -e PUID=0 -e PGID=0 -e TZ=Asia/Shanghai \
        -p 127.0.0.1:3000:3000 -v "$dir:/config" --shm-size=1g "$_TOOLBOX_WEBTOP_IMAGE"; then
        _toolbox_system_error '容器启动命令失败；若已创建同名容器，请先 docker rm -f 后重试。'
        return 1
    fi
    if [[ $(docker inspect -f '{{.State.Running}}' "$_TOOLBOX_WEBTOP_NAME" 2>/dev/null) != true ]]; then
        _toolbox_system_error "容器未运行；日志：docker logs $_TOOLBOX_WEBTOP_NAME"
        _toolbox_system_error "已保留容器便于排查；确认后可 docker rm -f $_TOOLBOX_WEBTOP_NAME"
        return 1
    fi
    printf '\n容器已运行。首次启动约 1-2 分钟。\n'
    printf '本机访问：http://127.0.0.1:3000（远程用 SSH 隧道：ssh -L 3000:127.0.0.1:3000 用户@主机）\n'
    printf '数据目录：%s；日志：docker logs -f %s\n' "$dir" "$_TOOLBOX_WEBTOP_NAME"
    printf '注意：容器内 root 映射到主机 root 的 /config；无内置认证，公网暴露前请加反代和密码。\n'
}

_toolbox_system_alpine_hop_apply() {
    local etc conf start end target port
    local -a spec=()
    _toolbox_system_alpine_require || return
    _toolbox_system_need_tools iptables ss || { _toolbox_system_error '缺少 iptables 或 ss（iproute2）；Alpine 可 apk add iptables iproute2。'; return 1; }
    etc=$(_toolbox_system_etc); conf="$etc/$_TOOLBOX_HOP_CONF_NAME"
    if [[ -e $conf ]] && ! _toolbox_system_ours "$conf" "$_TOOLBOX_SYS_MARK_B19"; then
        _toolbox_system_error "$conf 已存在但不是本工具生成的，未覆盖。"
        return 1
    fi
    if [[ -e $conf ]]; then
        # 配置已存在：沿用其中的端口，不重新询问；只补回缺失的规则。
        local key value
        while IFS='=' read -r key value; do
            case $key in START) start=$value;; END) end=$value;; TARGET) target=$value;; esac
        done < "$conf"
        for port in "$start" "$end" "$target"; do
            _toolbox_system_positive_int "$port" && (( port <= 65535 )) \
                || { _toolbox_system_error "配置里的端口不正确：$port；先移除再重设。"; return 1; }
        done
        spec=(-p udp --dport "$start:$end" -j REDIRECT --to-ports "$target")
        if iptables -t nat -C PREROUTING "${spec[@]}" 2>/dev/null; then
            printf '端口跳跃已应用（%s-%s -> %s），规则在位；未修改。\n' "$start" "$end" "$target"
            printf '要改端口请先执行「移除端口跳跃」。\n'
            return 0
        fi
        printf '配置已存在（%s-%s -> %s）但规则不在位，将补回。\n' "$start" "$end" "$target"
    else
        _toolbox_system_read_line start '跳跃起始端口' || return
        _toolbox_system_read_line end '跳跃结束端口' || return
        _toolbox_system_read_line target '实际监听端口（Hysteria2 的 UDP 端口，如 443）' || return
        for port in "$start" "$end" "$target"; do
            _toolbox_system_positive_int "$port" && (( port <= 65535 )) \
                || { _toolbox_system_error "端口不正确：$port"; return 1; }
        done
        (( start <= end )) || { _toolbox_system_error "起始端口 $start 大于结束端口 $end。"; return 1; }
        (( end - start + 1 <= 1000 )) || { _toolbox_system_error '范围超过 1000 个端口，配合 qdisc 可能过重；请缩短。'; return 1; }
        spec=(-p udp --dport "$start:$end" -j REDIRECT --to-ports "$target")
    fi
    if (( target >= start && target <= end )); then
        printf '提示：监听端口 %s 落在跳跃范围内，DNAT 会再指向自己，通常仍可用但建议把监听端口放在范围外。\n' "$target"
    fi
    if iptables -t nat -C PREROUTING "${spec[@]}" 2>/dev/null; then
        printf '规则已存在，未重复添加。\n'
    else
        if ! ss -lunH 2>/dev/null | awk '{print $4}' | grep -q ":$target\$"; then
            printf '提示：本机当前没有 UDP %s 监听；先装好服务再验证，否则流量会落到空端口。\n' "$target"
        fi
        printf '将添加：iptables -t nat -A PREROUTING %s\n' "${spec[*]}"
        printf '作用   : 客户端可在 %s-%s 间切换端口，全部转到 %s/udp\n' "$start" "$end" "$target"
        printf '不改动 : 已有 iptables 规则；持久化依赖本机 iptables 服务，若保存失败会明确提示\n'
        _toolbox_system_confirm '确认添加 DNAT 规则？' || return
        if ! iptables -t nat -A PREROUTING "${spec[@]}"; then
            _toolbox_system_error '添加规则失败；未写入配置。'
            return 1
        fi
        if ! iptables -t nat -C PREROUTING "${spec[@]}" 2>/dev/null; then
            _toolbox_system_error '添加后回读规则不存在，尝试撤销。'
            iptables -t nat -D PREROUTING "${spec[@]}" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    install -d -m 0755 "$etc" || return 1
    {
        printf '%s\n' "$_TOOLBOX_SYS_MARK_B19"
        printf 'START=%s\nEND=%s\nTARGET=%s\n' "$start" "$end" "$target"
    } | _toolbox_system_put "$conf" 0644 || { _toolbox_system_error '写入配置失败；规则已生效但无法回滚。'; return 1; }

    if _toolbox_system_has rc-service && rc-service iptables save >/dev/null 2>&1; then
        printf '规则已保存到本机 iptables 服务配置（重启后保留）。\n'
    else
        printf '提示：未能保存持久化（无 rc-service 或 iptables 服务未启用）。规则当前生效，重启后会丢失。\n'
    fi
    printf '验证：iptables -t nat -L PREROUTING -n --line-numbers\n'
    printf '客户端在 %s-%s 间轮换即可；防火墙需放行整个范围（本工具不改防火墙）。\n' "$start" "$end"
}

_toolbox_system_alpine_hop_remove() {
    local etc conf start end target
    _toolbox_system_alpine_require || return
    _toolbox_system_need_tools iptables || return
    etc=$(_toolbox_system_etc); conf="$etc/$_TOOLBOX_HOP_CONF_NAME"
    if [[ ! -r $conf ]]; then
        _toolbox_system_error "没有端口跳跃配置（$conf）；未改动规则。"
        return 1
    fi
    _toolbox_system_ours "$conf" "$_TOOLBOX_SYS_MARK_B19" \
        || { _toolbox_system_error "$conf 不是本工具生成的，未处理。"; return 1; }
    start=''; end=''; target=''
    while IFS='=' read -r key value; do
        case $key in START) start=$value;; END) end=$value;; TARGET) target=$value;; esac
    done < "$conf"
    [[ -n $start && -n $end && -n $target ]] || { _toolbox_system_error '配置不完整，未改动。'; return 1; }
    _toolbox_system_confirm "将删除 UDP $start:$end -> $target 的 DNAT 规则并删除配置；其他规则不动。确认？" || return
    if iptables -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$target"; then
        :
    else
        _toolbox_system_error '删除规则失败（可能已被手工删除）；配置保留以便重试。'
        return 1
    fi
    rm -f -- "$conf"
    printf '已删除规则与配置。'
    if _toolbox_system_has rc-service; then
        rc-service iptables save >/dev/null 2>&1 && printf '已同步保存。\n' || printf '提示：持久化保存失败，重启后规则本来也会消失。\n'
    else
        printf '\n'
    fi
}

_toolbox_system_alpine_swap() {
    _toolbox_system_error 'Alpine swap 暂未启用：OpenRC 下没有等价的事务与回滚方案，尚未验证；未改动。'
    _toolbox_system_error 'Alpine 可先用 apk add zram-init 或 setup-swap 手工处理；Debian/Ubuntu 请用 B6。'
    return 1
}

_toolbox_system_alpine() {
    local choice
    printf 'B19 Alpine 专用工具\n 1 Webtop 桌面容器\n 2 端口跳跃（HY2 等 UDP 服务）\n 3 移除端口跳跃\n 4 swap（暂未启用）\n 0 返回\n请输入编号: ' >&2
    IFS= read -r choice || return 1
    case $choice in
        1) _toolbox_system_alpine_webtop;;
        2) _toolbox_system_alpine_hop_apply;;
        3) _toolbox_system_alpine_hop_remove;;
        4) _toolbox_system_alpine_swap;;
        0) printf '未修改。\n';;
        *) _toolbox_system_error "无效选项：$choice"; return 2;;
    esac
}

# ---------------------------------------------------------------- B6 swap
# 事务式 swap。写入顺序固定为：独占锁 → 只读预检 → 确认 → 锁内重新校验 →
# 落盘（日志 → 文件 → mkswap → 单元 → daemon-reload → 启用）→ 双重验证。
# 持久化只靠 systemd 单元，不写 fstab，避免两套机制互相覆盖。
#
# 无法判断的现状一律在写入前失败：随机别人的文件、别人的单元、drop-in、
# 已加载但不在本工具路径的单元、乃至 swapon 读不出来，都不猜。
# 只有本工具自己写下的东西才会被撤销，用记录在事务日志里的 dev:inode 认回，
# 单元要等 swapoff 确认后才删除。
_TOOLBOX_SWAP_FILE='swapfile_toolbox'
_TOOLBOX_SWAP_UNIT='swapfile_toolbox.swap'
readonly _TOOLBOX_SYS_MARK_B6='# terry-toolbox B6 swap unit'
_TOOLBOX_SWAP_TXN_FILE=''
_TOOLBOX_SWAP_TXN_UNIT=''
_TOOLBOX_SWAP_TXN_INODE=''
_TOOLBOX_SWAP_MODE=''
_TOOLBOX_SWAP_INODE=''

_toolbox_system_swap_root() { printf '%s\n' "${TOOLBOX_SWAP_ROOT:-/}"; }
_toolbox_system_swap_file() {
    local root
    root=$(_toolbox_system_swap_root)
    printf '%s/%s\n' "${root%/}" "$_TOOLBOX_SWAP_FILE"
}
_toolbox_system_swap_unit() { printf '%s/%s\n' "$(_toolbox_system_unit_dir)" "$_TOOLBOX_SWAP_UNIT"; }
_toolbox_system_swap_lock() { printf '%s/swap.lock\n' "$(_toolbox_system_state)"; }
_toolbox_system_swap_journal() { printf '%s/swap.txn\n' "$(_toolbox_system_state)"; }

_toolbox_system_swap_supported() {
    _toolbox_system_root || return
    [[ $(_toolbox_system_os) == debian ]] || { _toolbox_system_error 'swap 事务只在 Debian/Ubuntu 上验证过；未改动。'; return 1; }
    _toolbox_system_systemd || return
    _toolbox_system_need_tools flock dd mkswap swapon swapoff findmnt df stat || return
}

# 活动 swap 精确匹配：逐个路径串比较，不做前缀/设备号推断。
_toolbox_system_swap_snapshot() {
    local out line
    out=$(swapon --show=NAME --noheadings 2>/dev/null) || return 1
    while IFS= read -r line; do
        [[ -n ${line//[[:space:]]/} ]] && printf '%s\n' "$line"
    done <<< "$out"
    return 0
}
_toolbox_system_swap_listed() {
    local list=$1 want=$2 line
    while IFS= read -r line; do [[ $line == "$want" ]] && return 0; done <<< "$list"
    return 1
}
_toolbox_system_swap_member() {
    local list
    list=$(_toolbox_system_swap_snapshot) || return 1
    _toolbox_system_swap_listed "$list" "$1"
}

_toolbox_system_swap_lock_acquire() {
    local lock
    lock=$(_toolbox_system_swap_lock)
    install -d -m 0755 -- "$(_toolbox_system_state)" || { _toolbox_system_error "无法创建状态目录 $(_toolbox_system_state)；未改动。"; return 1; }
    # 不等待、不自动抢占：并发时报错，由人决定，避免两个进程各自继续。
    exec 9> "$lock" || { _toolbox_system_error "无法打开锁文件 $lock；未改动。"; return 1; }
    if ! flock -n 9; then
        exec 9>&-
        _toolbox_system_error "另一个进程正在操作 swap（锁被占用：$lock）；未改动。"
        return 1
    fi
}
_toolbox_system_swap_lock_release() { flock -u 9 2>/dev/null || true; exec 9>&- 2>/dev/null || true; }

# 事务日志：SIGKILL/断电后，下一次运行据此认回自己的残留，别人的不动。
_toolbox_system_swap_journal_write() {
    printf 'PHASE=%s\nPATH=%s\nUNIT=%s\nINODE=%s\n' "$1" "$2" "$3" "${4-}" \
        | _toolbox_system_put "$(_toolbox_system_swap_journal)" 0600
}

_toolbox_system_swap_check_space() {
    local size=$1 root avail_kb want_kb
    root=$(_toolbox_system_swap_root)
    avail_kb=$(df -Pk -- "$root" 2>/dev/null | while read -r _ _ _ a _; do printf '%s\n' "$a"; done | tail -n 1)
    case ${avail_kb:-} in ''|*[!0-9]*) _toolbox_system_error "无法读取 $root 的可用空间（df）；未改动。"; return 1;; esac
    want_kb=$(( size * 1024 + 65536 ))
    if (( avail_kb < want_kb )); then
        _toolbox_system_error "可用空间不足：需要约 $(( want_kb / 1024 )) MiB（含 64 MiB 余量），实际 $(( avail_kb / 1024 )) MiB。"
        return 1
    fi
}

# 只读预检。成功时只在全局变量里留下判定：create / resume / idempotent。
_toolbox_system_swap_preflight() {
    local file unit dir fstype drops list frag existing
    file=$(_toolbox_system_swap_file); unit=$(_toolbox_system_swap_unit); dir=$(printf '%s.d' "$unit")
    _TOOLBOX_SWAP_MODE=''; _TOOLBOX_SWAP_INODE=''

    _toolbox_system_swap_supported || return 1
    _toolbox_system_swap_check_space 1 || return 1

    fstype=$(findmnt -n -o FSTYPE --target "$(_toolbox_system_swap_root)" 2>/dev/null) || {
        _toolbox_system_error '无法确定根文件系统类型（findmnt）；未改动。'; return 1; }
    case $fstype in
        ext2|ext3|ext4|xfs|btrfs) ;;
        *) _toolbox_system_error "根文件系统是 $fstype，swapfile 的用法未验证；未改动。"; return 1;;
    esac

    # systemd 实际生效的单元可能来自 /usr/lib、/run 或生成器，不止单元目录。
    frag=$(systemctl show -p FragmentPath --value "$_TOOLBOX_SWAP_UNIT" 2>/dev/null) || frag=''
    if [[ -n $frag && $frag != "$unit" ]]; then
        _toolbox_system_error "systemd 中已有同名单元来自 $frag（不是 $unit）；未改动。"
        return 1
    fi
    drops=$(systemctl show -p DropInPaths --value "$_TOOLBOX_SWAP_UNIT" 2>/dev/null) || drops=''
    if [[ -n ${drops// /} ]]; then
        _toolbox_system_error "同名单元已带 drop-in（$drops），可能覆盖 What=；未改动。"
        return 1
    fi
    if [[ -e $unit ]] && ! _toolbox_system_ours "$unit" "$_TOOLBOX_SYS_MARK_B6"; then
        _toolbox_system_error "$unit 已存在但不是本工具生成的；未改动。"
        return 1
    fi
    if compgen -G "$dir/*.conf" >/dev/null; then
        _toolbox_system_error "$dir 里已有 drop-in，可能覆盖 What=；未改动。"
        return 1
    fi

    list=$(_toolbox_system_swap_snapshot) || {
        _toolbox_system_error 'swapon 读取失败，无法确认活动 swap；未改动。'; return 1; }
    if [[ -L $file ]]; then
        _toolbox_system_error "$file 是符号链接，归属不明确；未改动。"; return 1
    fi
    if [[ -e $unit ]]; then
        [[ -f $file ]] || { _toolbox_system_error "单元存在但文件缺失（$file）；未改动。"; return 1; }
        grep -qxF -- "What=$file" "$unit" 2>/dev/null || {
            _toolbox_system_error "单元里的 What= 不是 $file；未改动。"; return 1; }
        if _toolbox_system_swap_listed "$list" "$file"; then
            _TOOLBOX_SWAP_MODE='idempotent'; return 0
        fi
        existing=$(stat -c '%d:%i' -- "$file" 2>/dev/null) || {
            _toolbox_system_error "无法读取 $file 的 inode；未改动。"; return 1; }
        _TOOLBOX_SWAP_MODE='resume'; _TOOLBOX_SWAP_INODE=$existing; return 0
    fi
    if [[ -e $file ]]; then
        if _toolbox_system_swap_listed "$list" "$file"; then
            _toolbox_system_error "$file 是活动 swap 但没有本工具的单元，无法断言归属；未改动。"
        else
            _toolbox_system_error "$file 已存在且未启用，也没有本工具的单元，无法断言归属；未改动。"
        fi
        return 1
    fi
    _TOOLBOX_SWAP_MODE='create'
}

# 回滚：先让 systemd 停用并确认 swapoff，再删单元，最后按 inode 删文件。
# 顺序不可交换：单元先删会留下“文件仍在 swap 里但没有单元”的状态。
# 外层用子 shell 隔离 errexit，回滚里任何一步失败都不中断剩下的清理。
_toolbox_system_swap_rollback() {
    ( set +e; _toolbox_system_swap_rollback_body "$1" "$2" "${3-}" )
}
_toolbox_system_swap_rollback_body() {
    local file=$1 unit=$2 ino=${3-} i now=''
    if _toolbox_system_swap_member "$file"; then
        systemctl disable --now "$_TOOLBOX_SWAP_UNIT" >/dev/null 2>&1
        for ((i = 0; i < 20; i++)); do
            _toolbox_system_swap_member "$file" || break
            sleep 0.5
        done
        if _toolbox_system_swap_member "$file"; then
            swapoff -- "$file" >/dev/null 2>&1
        fi
        if _toolbox_system_swap_member "$file"; then
            _toolbox_system_error "swapoff 未完成（$file 仍是活动 swap），单元保留在 $unit；请手工处理后重试。"
            return 1
        fi
    fi
    if [[ -e $unit ]]; then
        rm -f -- "$unit" && systemctl daemon-reload >/dev/null 2>&1
    fi
    if [[ -e $file || -L $file ]]; then
        now=$(stat -c '%d:%i' -- "$file" 2>/dev/null) || now=''
        if [[ -n $ino && $now != "$ino" ]]; then
            _toolbox_system_error "文件已不是本次创建的那个（inode ${now:-读不到} ≠ $ino），保留：$file"
        elif _toolbox_system_swap_member "$file"; then
            _toolbox_system_error "文件仍是活动 swap，保留：$file"
        else
            rm -f -- "$file" && _toolbox_system_error "已删除本次创建的 swap 文件：$file"
        fi
    fi
    rm -f -- "$(_toolbox_system_swap_journal)"
    return 0
}

_toolbox_system_swap_abort() {
    local sig=$1 rc=$? msg=${2-}
    case $sig in INT) rc=130;; TERM) rc=143;; esac
    (( rc != 0 )) || rc=1
    trap - INT TERM EXIT
    printf '\n' >&2
    [[ -n $msg ]] && _toolbox_system_error "$msg"
    _toolbox_system_error "开始回滚本次写入（$sig）。"
    _toolbox_system_swap_rollback "$_TOOLBOX_SWAP_TXN_FILE" "$_TOOLBOX_SWAP_TXN_UNIT" "$_TOOLBOX_SWAP_TXN_INODE" \
        || _toolbox_system_error '回滚未完成，见上面的残留说明。'
    _toolbox_system_swap_lock_release
    _toolbox_system_error '已回滚；本次未启用 swap。'
    exit "$rc"
}

# 上一次运行没走完（SIGKILL、断电、机器被杀）：先按日志认回自己的残留。
_toolbox_system_swap_recover() {
    local journal path='' unit='' ino='' phase='' key value
    journal=$(_toolbox_system_swap_journal)
    while IFS='=' read -r key value; do
        case $key in PHASE) phase=$value;; PATH) path=$value;; UNIT) unit=$value;; INODE) ino=$value;; esac
    done < "$journal"
    if [[ -z $path || -z $unit ]]; then
        _toolbox_system_error "事务日志 $journal 不完整（缺少 PATH/UNIT）；未改动。"
        return 1
    fi
    _toolbox_system_error "发现上次未完成的事务（阶段 ${phase:-未知}），先回滚残留。"
    _toolbox_system_swap_rollback "$path" "$unit" "$ino" || return 1
    printf '上次残留已处理，继续本次检查。\n' >&2
}

_toolbox_system_swap_size() {
    local __value=${1-} value=${TOOLBOX_SWAP_SIZE_MB:-}
    if [[ -n $value ]]; then
        _toolbox_system_positive_int "$value" || { _toolbox_system_error "大小不正确：$value"; return 1; }
    else
        printf 'swap 文件大小（MiB，128-8192，默认 1024）: ' >&2
        IFS= read -r value || { _toolbox_system_error '大小未输入。'; return 1; }
        value=${value:-1024}
        _toolbox_system_positive_int "$value" || { _toolbox_system_error "大小不正确：$value"; return 1; }
    fi
    (( value >= 128 && value <= 8192 )) || { _toolbox_system_error "大小超范围：$value MiB（128-8192）。"; return 1; }
    printf -v "$__value" '%s' "$value"
}

_toolbox_system_swap() {
    local file unit fstab size=1024 mode_before=0
    _toolbox_system_root || return
    file=$(_toolbox_system_swap_file); unit=$(_toolbox_system_swap_unit); fstab="$(_toolbox_system_swap_root)/etc/fstab"

    _toolbox_system_swap_lock_acquire || return

    if [[ -e $(_toolbox_system_swap_journal) ]]; then
        _toolbox_system_swap_recover || { _toolbox_system_swap_lock_release; return 1; }
    fi
    if ! _toolbox_system_swap_preflight; then
        _toolbox_system_swap_lock_release
        return 1
    fi
    mode_before=$_TOOLBOX_SWAP_MODE

    if [[ $mode_before == idempotent ]]; then
        # 已启用：只补一次 daemon-reload 并复核，不动文件、不动单元。
        systemctl daemon-reload >/dev/null 2>&1 || true
        _toolbox_system_swap_member "$file" && systemctl is-active --quiet "$_TOOLBOX_SWAP_UNIT" \
            || { _toolbox_system_error '状态复核不一致（活动 swap 或单元）；未改动，请人工检查。'
                 _toolbox_system_swap_lock_release; return 1; }
        _toolbox_system_swap_lock_release
        printf 'swap 已启用且单元在位（%s，开机自启）；未修改任何配置。\n' "$file"
        return 0
    fi

    if [[ $mode_before == resume ]]; then
        size=$(( $(stat -c '%s' -- "$file") / 1048576 ))
        printf '发现上次未启用的残留（单元已在，文件 %s MiB）；将重新启用。\n' "$size"
    else
        _toolbox_system_swap_size size || { _toolbox_system_swap_lock_release; return 1; }
        _toolbox_system_swap_check_space "$size" || { _toolbox_system_swap_lock_release; return 1; }
    fi

    printf '\nB6 swap（systemd 单元，不写 fstab）\n'
    printf '  文件    : %s（%s MiB，权限 0600）\n' "$file" "$size"
    printf '  单元    : %s\n' "$unit"
    printf '  开机    : systemd 单元 enable，重启后自动启用\n'
    printf '  fstab   : 不修改（两套机制并存会互相覆盖）\n'
    printf '  验证    : 启用后核对 swapon 活动项与单元 active 状态\n'
    printf '  回滚    : 任一步失败、Ctrl-C 或 SIGTERM 自动撤销本次写入\n'
    if grep -qE "^[[:space:]]*${file//\//\\/}[[:space:]]" "$fstab" 2>/dev/null; then
        printf '  注意    : %s 里已有该路径的条目；本工具不改它，两份配置指向同一文件。\n' "$fstab"
    fi
    _toolbox_system_confirm "将在 $file 创建 swap 文件并启用 systemd 单元，确认？" || {
        _toolbox_system_swap_lock_release; return 1; }

    # 确认期间外部可能改动过；锁只能挡住本工具，所以再校验一遍并比对判定。
    if ! _toolbox_system_swap_preflight; then
        _toolbox_system_error '确认期间状态已变化，判定不再一致；未写入。'
        _toolbox_system_swap_lock_release
        return 1
    fi
    if [[ $_TOOLBOX_SWAP_MODE != "$mode_before" ]]; then
        _toolbox_system_error "确认期间状态已变化（$mode_before → $_TOOLBOX_SWAP_MODE）；未写入，请重跑。"
        _toolbox_system_swap_lock_release
        return 1
    fi

    _TOOLBOX_SWAP_TXN_FILE=$file
    _TOOLBOX_SWAP_TXN_UNIT=$unit
    _TOOLBOX_SWAP_TXN_INODE=$_TOOLBOX_SWAP_INODE
    # 先记下调用者原有的 trap，成功时原样恢复，不静默丢掉别人的清理。
    local old_int old_term old_exit
    old_int=$(trap -p INT); old_term=$(trap -p TERM); old_exit=$(trap -p EXIT)
    trap '_toolbox_system_swap_abort INT' INT
    trap '_toolbox_system_swap_abort TERM' TERM
    trap '_toolbox_system_swap_abort EXIT' EXIT

    if [[ $mode_before == create ]]; then
        _toolbox_system_swap_journal_write create "$file" "$unit" '' \
            || _toolbox_system_swap_abort FAIL '写事务日志失败；未创建文件。'
        dd if=/dev/zero of="$file" bs=1M count="$size" conv=fsync status=none \
            || _toolbox_system_swap_abort FAIL '创建 swap 文件失败。'
        # 写完再认一次：路径可能在 dd 期间被换成链接（如 /var 挂载变化）。
        [[ -f $file && ! -L $file ]] \
            || _toolbox_system_swap_abort FAIL "$file 创建后不是普通文件（可能被同时替换）。"
        ino=$(stat -c '%d:%i' -- "$file" 2>/dev/null) \
            || _toolbox_system_swap_abort FAIL "无法读取 $file 的 inode。"
        _TOOLBOX_SWAP_TXN_INODE=$ino
        _toolbox_system_swap_journal_write file "$file" "$unit" "$ino" \
            || _toolbox_system_swap_abort FAIL '更新事务日志失败。'
        [[ $(stat -c '%s' -- "$file") == "$(( size * 1048576 ))" ]] \
            || _toolbox_system_swap_abort FAIL "文件大小不是 ${size} MiB。"
        chmod 0600 -- "$file" || _toolbox_system_swap_abort FAIL 'chmod 0600 失败。'
        mkswap -- "$file" >/dev/null || _toolbox_system_swap_abort FAIL 'mkswap 失败。'
        {
            printf '%s\n' "$_TOOLBOX_SYS_MARK_B6"
            printf '# 由 Terry Toolbox B6 管理；删除请用菜单，不要手工混改。\n'
            printf '[Unit]\nDescription=Terry Toolbox swap file\n\n'
            printf '[Swap]\nWhat=%s\n\n' "$file"
            printf '[Install]\nWantedBy=swap.target\n'
        } | _toolbox_system_put "$unit" 0644 || _toolbox_system_swap_abort FAIL '写入 systemd 单元失败。'
        _toolbox_system_swap_journal_write unit "$file" "$unit" "$ino" \
            || _toolbox_system_swap_abort FAIL '更新事务日志失败。'
    fi

    systemctl daemon-reload || _toolbox_system_swap_abort FAIL 'systemctl daemon-reload 失败。'
    systemctl enable --now "$_TOOLBOX_SWAP_UNIT" >/dev/null 2>&1 \
        || _toolbox_system_swap_abort FAIL 'systemctl 启用单元失败。'
    systemctl is-active --quiet "$_TOOLBOX_SWAP_UNIT" \
        || _toolbox_system_swap_abort FAIL '单元未进入 active 状态。'
    _toolbox_system_swap_member "$file" \
        || _toolbox_system_swap_abort FAIL '单元为 active，但 swapon 活动列表里没有该文件。'

    rm -f -- "$(_toolbox_system_swap_journal)"
    eval "${old_int:-trap - INT}"
    eval "${old_term:-trap - TERM}"
    eval "${old_exit:-trap - EXIT}"
    _toolbox_system_swap_lock_release
    printf '\nswap 已启用：%s（%s MiB），单元 %s 已 enable 并 active。\n' "$file" "$size" "$unit"
    printf '查看：swapon --show；systemctl status %s；free -h\n' "$_TOOLBOX_SWAP_UNIT"
    printf '注意：fstab 未改，持久化只依赖 systemd 单元；请勿再手工给同一路径加 fstab 条目。\n'
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
        B7|7) _toolbox_system_traffic;;
        B8|8) _toolbox_system_password;;
        B10|10) _toolbox_system_unimplemented 'WebSSH 安装（缺少安全认证和部署方案）';;
        B11|11) _toolbox_system_panel;;
        B14|14) _toolbox_system_trace;;
        B15|15) _toolbox_system_tg;;
        B16|16) _toolbox_system_netopt;;
        B19|19) _toolbox_system_alpine;;
        *) _toolbox_system_error "未知系统工具编号: ${1-}"; return 2;;
    esac
}
