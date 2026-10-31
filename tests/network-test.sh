#!/usr/bin/env bash
# Isolated tests: these never execute a real installer or touch system settings.
# shellcheck disable=SC2016,SC2317
# Fixture dollars are literal; command mocks are callbacks used by sourced code.
#
# B12/A3/B31 的边界全部指向临时目录，外部命令全部打桩（dkms/modprobe/sysctl/
# systemctl/ss/curl/…）。真实执行的只有模块逻辑本身、openssl、tar、sha256sum、
# install/stat 和一次真的 socat 转发（用生成的 ExecStart，跑在临时高位端口）。
set -eu
source "$(dirname -- "${BASH_SOURCE[0]}")/scratch-root.sh"
toolbox_test_scratch
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/root/.cache/terry-toolbox-tests}/toolbox-network-test.XXXXXXXX")
cleanup() {
    python3 -c '
import os, signal, time
marker = ("TOOLBOX_TEST_WORK=" + os.environ["TOOLBOX_TEST_WORK"]).encode()
skip = {os.getpid(), os.getppid()}
def owned(pid):
    try:
        return marker in open("/proc/%s/environ" % pid, "rb").read().split(b"\0")
    except (OSError, ProcessLookupError):
        return False
pids = [int(p) for p in os.listdir("/proc") if p.isdigit() and int(p) not in skip and owned(p)]
for pid in pids:
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: pass
time.sleep(0.05)
for pid in pids:
    if owned(pid):
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass
'
    rm -rf -- "${work:?}"
}
trap cleanup EXIT
export HOME=$work/home TOOLBOX_TEST_WORK=$work
export TMPDIR=$work
mkdir -p "$HOME"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$work/bin" "$work/pathbin"
for cmd in curl wget apk apt apt-get dnf yum systemctl rc-service rc-update sysctl modprobe rmmod dkms depmod; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" invoked >> "$NETWORK_TEST_MARKER"\nexit 99\n' > "$work/bin/$cmd"
    chmod +x "$work/bin/$cmd"
done
export NETWORK_TEST_MARKER="$work/invoked"
SD=$work/state
mkdir -p "$SD"
export SD
# 打桩目录优先于兜底目录，否则 exit 99 的桩会挡住真实流程。
export PATH="$work/pathbin:$work/bin:$PATH"
# 早期 B23 status 也是只读桩，不能调用兜底 systemctl 或真实解析器。
systemctl() {
    [[ ${1:-} == is-active ]] || { printf forbidden >> "$NETWORK_TEST_MARKER"; return 99; }
    return 3
}
resolvectl() { [[ ${1:-} == status ]]; }
export TOOLBOX_DNS_DROPIN_DIR=$work/dns TOOLBOX_DNS_RESOLV_CONF=$work/resolv.conf
# Source must be inert and keep the caller alive.
out=$(bash -ec 'source "$1"; printf sourced' _ "$ROOT/modules/network.sh") || fail 'source failed'
[[ $out == sourced ]] || fail 'source has output or side effects'
[[ ! -e $NETWORK_TEST_MARKER ]] || fail 'source ran a command'
out=$(bash -euc 'source "$1"; source "$1"; declare -F toolbox_network >/dev/null; printf sourced-twice' _ "$ROOT/modules/network.sh" 2>"$work/source-twice.err") \
    || fail '重复 source network.sh 失败'
[[ $out == sourced-twice && ! -s $work/source-twice.err ]] || fail '重复 source network.sh 有输出或 readonly 报错'
source "$ROOT/modules/dependencies.sh"
_toolbox_deps_exec() { printf 'dependency-package:%s\n' "$*" >> "$NETWORK_TEST_MARKER"; return 99; }
# Keep fixture CA metadata off the host. PATH guards also protect child shells
# and any lazy core reload after an unset; reset never removes the marker.
_toolbox_deps_ca_package() { return 0; }
_toolbox_deps_root() { return 0; }
export -f _toolbox_deps_exec _toolbox_deps_ca_package _toolbox_deps_root
source "$ROOT/modules/network.sh"
printf 'ID=alpine\n' > "$work/alpine"
printf 'ID=debian\n' > "$work/debian"
export TOOLBOX_OS_RELEASE=$work/debian
printf 'ID=ubuntu\n' > "$work/ubuntu"
printf 'ID=other\nID_LIKE="debian ubuntu"\n' > "$work/derived"
printf 'ID=unknown\n' > "$work/unknown"
[[ $(toolbox_network_detect_os "$work/alpine") == alpine ]] || fail 'Alpine detection'
[[ $(toolbox_network_detect_os "$work/debian") == debian ]] || fail 'Debian detection'
[[ $(toolbox_network_detect_os "$work/ubuntu") == ubuntu ]] || fail 'Ubuntu detection'
[[ $(toolbox_network_detect_os "$work/derived") == debian ]] || fail 'Debian derivative detection'
if toolbox_network_detect_os "$work/unknown" >/dev/null 2>&1; then fail 'unknown OS accepted'; fi
# Detection reads data only; an os-release must not be interpreted as shell code.
printf 'ID=$(touch %s)\n' "$work/pwned" > "$work/hostile"
toolbox_network_detect_os "$work/hostile" >/dev/null 2>&1 && fail 'hostile OS accepted'
[[ ! -e $work/pwned ]] || fail 'OS file executed'
for choice in A1 A2 A4 A5; do
    if printf 'yes\nYES\n' | toolbox_network "$choice" >"$work/out" 2>&1; then
        fail "$choice falsely reported success"
    fi
    [[ -s $work/out ]] || fail "$choice failed silently"
done
# A1/A2 未安装时的入口约定（Alpine 服务由 A1/A2 自己负责，这里只验分发）
for choice in A1 A2; do
    printf '3\n' | toolbox_network "$choice" >"$work/out" 2>&1 && fail "$choice 未安装时 status 仍成功"
    grep -q '未安装' "$work/out" || fail "$choice 未进入 status"
    toolbox_network "$choice" bogus >"$work/out" 2>&1 && fail "$choice 未知动作被接受"
    grep -q '用法' "$work/out" || fail "$choice 未知动作未给用法"
done
# B23：安装前置不满足时必须 fail-closed，且不改任何文件。
(
    command() {
        if [[ ${1:-} == -v && ${2:-} == resolvectl ]]; then return 1; fi
        builtin command "$@"
    }
    toolbox_network B23 install 1.1.1.1 >"$work/dns-missing.out" 2>&1 && fail 'B23 accepted missing resolver'
    [[ $(<"$work/dns-missing.out") == *'未找到 resolvectl'* ]] || fail 'B23 missing-resolver refusal'
)
# B23 ordinary dependencies must be resolved before interpreting readlink/grep
# failures as foreign ownership. Package and service calls below are fixtures.
(
    dns_work=$work/dns-dependencies
    export TOOLBOX_NET_UID=0 TOOLBOX_DNS_DROPIN_DIR=$dns_work/dropin
    export TOOLBOX_DNS_RESOLVE_RUN=$dns_work/systemd/resolve
    export TOOLBOX_DNS_RESOLV_CONF=$dns_work/resolv.conf TOOLBOX_NET_LOCK_DIR=$dns_work/locks
    mkdir -p "$TOOLBOX_DNS_DROPIN_DIR" "$TOOLBOX_DNS_RESOLVE_RUN" "$TOOLBOX_NET_LOCK_DIR" "$dns_work/installed"
    dns_file=$(net_dns_dropin)
    command() {
        if [[ ${1:-} == -v ]]; then
            [[ ${2:-} != "${DNS_CAPABILITY:-}" ]] || return 1
            [[ " ${DNS_MISSING:-} " != *" ${2:-} "* || -e $dns_work/installed/${2:-} ]] || return 1
        fi
        builtin command "$@"
    }
    _toolbox_deps_exec() {
        local dependency
        printf 'package:%s\n' "$*" >> "$dns_work/trace"
        [[ ${1:-} == apt-get ]] || return 99
        case ${2:-} in
            update) return 0;;
            install)
                [[ ${DNS_INSTALL_FAIL:-0} == 0 ]] || return 71
                for dependency in $DNS_MISSING; do : > "$dns_work/installed/$dependency"; done;;
            *) return 99;;
        esac
    }
    systemctl() {
        printf 'service:%s\n' "$*" >> "$dns_work/trace"
        case ${1:-} in
            is-active) [[ ${DNS_INACTIVE:-0} == 0 ]];;
            restart) return 0;;
            *) return 99;;
        esac
    }
    resolvectl() {
        printf 'resolver:%s\n' "$*" >> "$dns_work/trace"
        case ${1:-} in
            status) printf 'Global\n       DNS Servers: 1.1.1.1\n';;
            query|revert|dns|domain) return 0;;
            *) return 99;;
        esac
    }
    flock() { printf 'lock\n' >> "$dns_work/trace"; }
    sleep() { :; }
    dns_reset() {
        DNS_MISSING='' DNS_CAPABILITY='' DNS_INACTIVE=0 DNS_INSTALL_FAIL=0
        rm -f -- "$dns_work/installed/"* "$TOOLBOX_DNS_DROPIN_DIR/"* "$TOOLBOX_NET_LOCK_DIR/"* "$TOOLBOX_DNS_RESOLV_CONF"
        : > "$TOOLBOX_DNS_RESOLVE_RUN/stub-resolv.conf"
        ln -s "$TOOLBOX_DNS_RESOLVE_RUN/stub-resolv.conf" "$TOOLBOX_DNS_RESOLV_CONF"
        : > "$dns_work/trace"
        if [[ $dns_action == restore ]]; then
            printf '# 由 Terry Toolbox B23 生成\n[Resolve]\nDNS=1.1.1.1\n' > "$dns_file"
        fi
    }
    dns_call() {
        if [[ $dns_action == install ]]; then toolbox_network B23 install 1.1.1.1
        else toolbox_network B23 restore; fi
    }
    dns_untouched() {
        if [[ $dns_action == install ]]; then [[ ! -e $dns_file ]] || fail 'B23 refused apply wrote drop-in'
        else [[ $(<"$dns_file") == $'# 由 Terry Toolbox B23 生成\n[Resolve]\nDNS=1.1.1.1' ]] || fail 'B23 refused restore changed drop-in'; fi
        [[ ! -e $dns_file.pre-toolbox && ! -e $TOOLBOX_NET_LOCK_DIR/terry-toolbox-dns.lock ]] || fail 'B23 refusal wrote backup/lock'
        ! grep -qE '^service:restart|^resolver:(dns|domain|revert)|^lock' "$dns_work/trace" || fail 'B23 refusal crossed service/write boundary'
    }
    for dns_action in install restore; do
        if [[ $dns_action == install ]]; then dns_tools='readlink grep wc tr dirname install cp chmod mv rm flock sleep'
        else dns_tools='grep sed mv rm sleep'; fi
        for dependency in $dns_tools; do
            dns_reset; DNS_MISSING=$dependency
            dns_call <<< n > "$dns_work/out" 2>&1 && fail "B23 $dns_action accepted missing $dependency"
            [[ $(<"$dns_work/out") == *"网络服务 缺少命令：$dependency"* && $(<"$dns_work/out") == *'已取消补装'* ]] || fail "B23 $dns_action missing $dependency was misdiagnosed"
            [[ $(<"$dns_work/out") != *'确认执行'* ]] || fail 'B23 reached feature confirmation before dependencies'
            ! grep -q '^package:' "$dns_work/trace" || fail 'B23 declined dependency called package boundary'
            dns_untouched
        done
        # Init/service capability must fail before asking to install ordinary tools.
        for capability in resolvectl systemctl inactive stub; do
            dns_reset; DNS_MISSING=$dns_tools
            case $capability in
                resolvectl|systemctl) DNS_CAPABILITY=$capability;;
                inactive) DNS_INACTIVE=1;;
                stub) rm -f "$TOOLBOX_DNS_RESOLVE_RUN/stub-resolv.conf";;
            esac
            dns_call <<< y > "$dns_work/out" 2>&1 && fail "B23 $dns_action accepted missing capability $capability"
            [[ $(<"$dns_work/out") != *'缺少命令'* && $(<"$dns_work/out") != *'仅补装'* ]] || fail 'B23 ordinary installation preceded resolved capability'
            ! grep -q '^package:' "$dns_work/trace" || fail 'B23 missing capability called package boundary'
            dns_untouched
        done
        dns_reset; DNS_MISSING=$dns_tools
        dns_call </dev/null > "$dns_work/out" 2>&1 && fail 'B23 dependency EOF accepted'
        [[ $(<"$dns_work/out") == *'未收到完整确认（EOF）'* ]] || fail 'B23 dependency EOF unexplained'
        dns_untouched
        dns_reset; DNS_MISSING=$dns_tools; DNS_INSTALL_FAIL=1
        dns_call <<< y > "$dns_work/out" 2>&1 && fail 'B23 failed dependency install continued'
        [[ $(<"$dns_work/out") == *'apt-get install 失败'* ]] || fail 'B23 dependency failure unexplained'
        dns_untouched
        dns_reset; DNS_MISSING=$dns_tools
        dns_call <<< $'y\nn' > "$dns_work/out" 2>&1 && fail 'B23 dependency y replaced feature confirmation'
        [[ $(<"$dns_work/out") == *'确认执行'* ]] || fail 'B23 dependency install did not resume same action'
        dns_untouched
        dns_reset; DNS_MISSING=$dns_tools
        dns_call <<< $'y\nYES' > "$dns_work/out" 2>&1 || fail "B23 $dns_action did not continue after dependency installation"
        [[ $(grep -c '^package:apt-get install ' "$dns_work/trace") == 1 ]] || fail 'B23 dependencies were not batched once'
        grep -q '^service:restart systemd-resolved' "$dns_work/trace" || fail 'B23 successful action did not restart fixture service'
        if [[ $dns_action == install ]]; then
            grep -qx 'DNS=1.1.1.1' "$dns_file" || fail 'B23 successful apply did not write fixture config'
        else [[ ! -e $dns_file ]] || fail 'B23 successful restore retained owned config'; fi
        # Successful dependency installation must not override ownership refusal.
        dns_reset; DNS_MISSING=$dns_tools
        if [[ $dns_action == install ]]; then
            rm -f "$TOOLBOX_DNS_RESOLV_CONF"
            ln -s "$dns_work/NetworkManager/resolv.conf" "$TOOLBOX_DNS_RESOLV_CONF"
        else printf 'foreign config\n' > "$dns_file"; fi
        dns_call <<< $'y\nYES' > "$dns_work/out" 2>&1 && fail 'B23 dependency success bypassed ownership'
        if [[ $dns_action == install ]]; then
            [[ $(<"$dns_work/out") == *'被其他程序接管'* && ! -e $dns_file ]] || fail 'B23 foreign resolver gate changed'
        else [[ $(<"$dns_file") == 'foreign config' && $(<"$dns_work/out") == *'不是本工具生成'* ]] || fail 'B23 foreign drop-in gate changed'; fi
        ! grep -q '^service:restart' "$dns_work/trace" || fail 'B23 ownership refusal restarted resolver'
    done
    dns_action=install; dns_reset
    ( readlink() { return 1; }; dns_call ) <<< YES > "$dns_work/out" 2>&1 && fail 'B23 accepted unreadable link target'
    [[ $(<"$dns_work/out") == *'无法读取'* && $(<"$dns_work/out") != *'被其他程序接管'* ]] || fail 'B23 readlink failure misreported ownership'
    dns_untouched
    for dependency in readlink sed; do
        dns_reset; DNS_MISSING=$dependency
        toolbox_network B23 status <<< n > "$dns_work/out" 2>&1 && fail 'B23 status silently accepted missing reader'
        [[ $(<"$dns_work/out") == *'DNS 状态读取不完整'* ]] || fail 'B23 missing status reader unexplained'
        [[ ! -s $dns_work/trace ]] || fail 'B23 declined status dependency crossed package/service boundary'
    done
    for capability in resolvectl systemctl; do
        dns_reset; DNS_MISSING='readlink sed'; DNS_CAPABILITY=$capability
        toolbox_network B23 status <<< y > "$dns_work/out" 2>&1 && fail "B23 status accepted missing $capability"
        [[ $(<"$dns_work/out") == *"未找到 $capability"* && $(<"$dns_work/out") != *'缺少命令'* && ! -s $dns_work/trace ]] || fail 'B23 status misreported missing resolver capability'
    done
)
toolbox_network B23 bogus >"$work/out" 2>&1 && fail 'B23 未知动作被接受'
printf '9\n' | toolbox_network B23 >"$work/out" 2>&1 && fail 'B23 非法菜单编号被接受'
# 具备解析器能力时，status 用显式读取桩报告状态，不依赖宿主机命令。
(
    status_trace=$work/dns-status.trace
    : > "$status_trace"
    systemctl() {
        printf 'systemctl:%s\n' "$*" >> "$status_trace"
        [[ $# == 3 && $1 == is-active && $2 == --quiet && $3 == systemd-resolved ]] || {
            printf 'B23 status unexpected systemctl:%s\n' "$*" >> "$NETWORK_TEST_MARKER"; return 99;
        }
        return 3
    }
    resolvectl() {
        printf 'resolvectl:%s\n' "$*" >> "$status_trace"
        [[ $# == 1 && $1 == status ]] || {
            printf 'B23 status unexpected resolvectl:%s\n' "$*" >> "$NETWORK_TEST_MARKER"; return 99;
        }
        printf 'Global\n       DNS Servers: 1.1.1.1\n'
    }
    toolbox_network B23 status >"$work/out" 2>&1 || fail 'B23 status 失败'
    [[ $(<"$work/out") == *'systemd-resolved: 未运行'* && $(<"$work/out") == *'DNS Servers: 1.1.1.1'* ]] || fail 'B23 status 未报告读取桩的解析器状态'
    [[ $(<"$status_trace") == $'systemctl:is-active --quiet systemd-resolved\nresolvectl:status\nresolvectl:status' ]] || fail 'B23 status 执行了预期读取以外的命令'
    [[ ! -e $NETWORK_TEST_MARKER ]] || fail 'B23 status 跨过写入/包管理边界'
)
if toolbox_network BAD >"$work/out" 2>&1; then fail 'invalid choice accepted'; fi
if toolbox_network >"$work/out" 2>&1; then fail 'missing choice accepted'; fi
if toolbox_network A1 unexpected >"$work/out" 2>&1; then fail 'extra argument accepted'; fi
# A4 由 modules/hy2.sh 实现：没加载模块时 fail closed，加载后与菜单等价。
(
    unset -f toolbox_hy2
    printf '%s\n%s\n443\nINSTALL\n' "$work/missing.crt" "$work/missing.key" | toolbox_network A4 > "$work/a4.out" 2>&1 && fail '缺 hy2 模块的 A4 仍报成功'
    [[ $(<"$work/a4.out") == *'未加载'* && $(<"$work/a4.out") == *'未修改系统'* ]] || fail 'A4 未说明缺少模块'
)
export TOOLBOX_HY2_ETC=$work/hy2/etc TOOLBOX_HY2_BIN_DIR=$work/hy2/bin
export TOOLBOX_HY2_UNIT_DIR=$work/hy2/units TOOLBOX_HY2_LOCK=$work/hy2/lock
export TOOLBOX_HY2_CLIENT_DIR=$work/hy2/verify TOOLBOX_HY2_SYSTEMD_RUN=$work/hy2/no-systemd
export TOOLBOX_HY2_OS_RELEASE=$work/debian
source "$ROOT/modules/hy2.sh"
(
    toolbox_hy2() { printf '<%s>\n' "$@"; return 7; }
    rc=0
    toolbox_network A4 install "$work/cert with spaces.pem" "$work/key.pem" example.test 18443 >"$work/a4-forward.out" || rc=$?
    [[ $rc == 7 ]] || fail 'A4 未保留 HY2 的退出码'
    expected=$(printf '<%s>\n' install "$work/cert with spaces.pem" "$work/key.pem" example.test 18443)
    [[ $(<"$work/a4-forward.out") == "$expected" ]] || fail 'A4 转发吞掉/拆分参数'
)
toolbox_network A4 status > "$work/a4.out" 2>&1 && fail 'A4 未安装时 status 仍成功'
grep -q '未安装' "$work/a4.out" || fail 'A4 未转发到 hy2 status'
toolbox_network A4 frobnicate > "$work/a4.out" 2>&1 && fail 'A4 未知动作被接受'
grep -q '用法' "$work/a4.out" || fail 'A4 未知动作未给用法'
# Unsafe installer entry points must not be callable directly after sourcing.
for helper in toolbox_network_hy2_preflight toolbox_network_hy2_apply; do
    if declare -F "$helper" >/dev/null; then fail "unsafe helper remains callable: $helper"; fi
done
# 缺参数/缺证书时仍在写盘前失败，且不碰 systemctl。
(
    for input in '' "$(printf '%s\n%s\nexample.test\n443\nINSTALL\n' "$work/missing.crt" "$work/missing.key")" 'INSTALL'; do
        printf '%s' "$input" | toolbox_network A4 > "$work/a4-refusal" 2>&1 && fail 'A4 accepted input'
        [[ -s $work/a4-refusal ]] || fail 'A4 refused silently'
    done
)
# Disabled A5 cannot be bypassed by calling formerly exposed install helpers.
for helper in toolbox_network_xray_preflight toolbox_network_xray_apply toolbox_network_xray_validate; do
    if declare -F "$helper" >/dev/null; then fail "unsafe A5 helper remains callable: $helper"; fi
done

# ================================================================ 打桩环境
# 真实命令在子 shell 里覆盖为「只记录 + 改状态文件」的函数，绝不碰本机。
unset TOOLBOX_NET_BRUTAL_URL TOOLBOX_NET_BRUTAL_SHA256 TOOLBOX_NET_TUIC_URL
unset TOOLBOX_NET_TUIC_SHA256 TOOLBOX_NET_TUIC_SHA256_ARM64 TOOLBOX_NET_UUID

export TOOLBOX_NET_OS_RELEASE=$work/os-release
export TOOLBOX_OS_RELEASE=$work/os-release
export TOOLBOX_NET_SYSTEMD_RUN=$work/systemd-run
export TOOLBOX_NET_ETC=$work/etc
export TOOLBOX_NET_BIN_DIR=$work/instbin
export TOOLBOX_NET_UNIT_DIR=$work/units
export TOOLBOX_NET_LOCK_DIR=$work/run
export TOOLBOX_NET_MODLOAD_DIR=$work/modules-load.d
export TOOLBOX_NET_SYSCTL_DIR=$work/sysctl.d
export TOOLBOX_NET_DKMS_DIR=$work/var/lib/dkms
export TOOLBOX_NET_SRC_DIR=$work/usr/src
export TOOLBOX_NET_MODDIR=$work/modbuild
export TOOLBOX_NET_KERNEL_RELEASE=6.1.0-test
export TOOLBOX_NET_SOCAT=$work/pathbin/socat
mkdir -p "$TOOLBOX_NET_SYSTEMD_RUN" "$TOOLBOX_NET_UNIT_DIR" "$TOOLBOX_NET_LOCK_DIR" \
    "$TOOLBOX_NET_BIN_DIR" "$work/modbuild" "$work/pkg"
printf '# Fixture headers: native compilation is replaced by the make/dkms shims.\n' > "$work/modbuild/Makefile"
printf 'ID=debian\nVERSION_ID="13"\n' > "$TOOLBOX_NET_OS_RELEASE"

# B12 源码包夹具：结构与官方 tarball 一致，哈希由测试算出后注入。
mkdir -p "$work/pkg/src/dkms_source_tree/tools"
printf 'PACKAGE_NAME="tcp-brutal"\nPACKAGE_VERSION="2.0.1"\nBUILT_MODULE_NAME[0]="brutal"\n' \
    > "$work/pkg/src/dkms_source_tree/dkms.conf"
printf 'all:\n\tmake -C $(KERNEL_DIR) M=$(PWD) modules\n' > "$work/pkg/src/dkms_source_tree/Makefile"
printf 'brutalctl: brutalctl.c\n' > "$work/pkg/src/dkms_source_tree/tools/Makefile"
tar -C "$work/pkg/src" -czf "$work/pkg/tcp-brutal.dkms.tar.gz" ./dkms_source_tree
export TOOLBOX_NET_BRUTAL_TGZ=$work/pkg/tcp-brutal.dkms.tar.gz
BRUTAL_SHA_TEST=$(sha256sum -- "$TOOLBOX_NET_BRUTAL_TGZ" | cut -d' ' -f1)
export TOOLBOX_NET_BRUTAL_SHA256=$BRUTAL_SHA_TEST

# 桩脚本：路径上的裸命令（在 shell 函数不生效的子进程里也能用）。
mk_stub() { # <名字> <正文>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$work/pathbin/$1"
    chmod +x "$work/pathbin/$1"
}
mk_stub socat "printf '%s\\n' \"\$*\" >> \"\$SD/socat.log\"; exit 0"
mk_stub systemd-detect-virt "printf '%s\\n' \"\${MOCK_VIRT:-none}\"; exit 0"

# sysctl：-n 读状态，-w 写状态；不可用的算法来自 cc_available。
sysctl() {
    local key val
    case ${1:-} in
        -n)
            key=${2##*.}
            case $key in
                tcp_congestion_control) cat "$SD/cc_current" 2>/dev/null || printf 'cubic\n' ;;
                tcp_available_congestion_control) cat "$SD/cc_available" 2>/dev/null || printf 'reno cubic\n' ;;
            esac
            return 0
            ;;
        -w)
            key=${2%%=*}; val=${2#*=}
            printf '%s\n' "${key##*.}=$val" >> "$SD/sysctl.log"
            [[ -e $SD/sysctl_fail ]] && return 1
            [[ $key == net.ipv4.tcp_congestion_control ]] && printf '%s\n' "$val" > "$SD/cc_current"
            return 0
            ;;
        *) return 0 ;;
    esac
}
modprobe() {
    printf '%s\n' "modprobe $*" >> "$SD/mod.log"
    [[ -e $SD/modprobe_fail ]] && return 1
    printf '%s\n' 'brutal' > "$SD/loaded"
    [[ -e $SD/no_register ]] || printf '%s\n' 'reno cubic brutal' > "$SD/cc_available"
    return 0
}
rmmod() {
    printf '%s\n' "rmmod $*" >> "$SD/mod.log"
    [[ -e $SD/loaded ]] || return 1
    rm -f "$SD/loaded"
    printf '%s\n' 'reno cubic' > "$SD/cc_available"
    return 0
}
lsmod() {
    printf '%s\n' 'Module Size Used by'
    [[ -e $SD/loaded ]] && printf '%s\n' 'brutal 262144 0'
    return 0
}
depmod() { printf '%s\n' "depmod $*" >> "$SD/mod.log"; }
dkms() {
    printf '%s\n' "dkms $*" >> "$SD/dkms.log"
    local action=${1:-} name
    name=${2:-}; name=${name%%/*}
    case $action in
        add)
            [[ -e $SD/dkms_add_fail ]] && return 1
            mkdir -p "$TOOLBOX_NET_DKMS_DIR/$(basename -- "$2")"
            ;;
        build) [[ -e $SD/dkms_build_fail ]] && return 1 ;;
        install)
            [[ -e $SD/dkms_install_fail ]] && return 1
            mkdir -p "$TOOLBOX_NET_DKMS_DIR/tcp-brutal"
            ;;
        remove) rm -rf "$TOOLBOX_NET_DKMS_DIR/${name:-tcp-brutal}" ;;
    esac
    return 0
}
make() {
    printf '%s\n' "make $*" >> "$SD/make.log"
    [[ -e $SD/make_fail ]] && return 1
    local dir='' prev=''
    for a in "$@"; do [[ $prev == -C ]] && dir=$a; prev=$a; done
    if [[ -n $dir ]]; then
        printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/brutalctl"
        chmod +x "$dir/brutalctl"
    fi
    return 0
}
systemctl() {
    printf '%s\n' "systemctl $*" >> "$SD/systemctl.log"
    case ${1:-} in
        is-active) [[ -e $SD/active ]] && return 0 || return 3 ;;
        enable)
            [[ -e $SD/enable_fail ]] && return 1
            if [[ $* == *--now* && ! -e $SD/noactivate ]]; then
                : > "$SD/active"
                [[ -n ${MOCK_PORT:-} && -n ${MOCK_PROTO:-} ]] && emit_port "$MOCK_PROTO" "$MOCK_PORT" '/usr/bin/tuic-stub' 4242
            fi
            return 0
            ;;
        disable) [[ $* == *--now* ]] && rm -f "$SD/active"; return 0 ;;
        show) [[ -e $SD/mainpid ]] && cat "$SD/mainpid" || printf '0\n'; return 0 ;;
        is-active-fg) return 0 ;;
        *) return 0 ;;
    esac
}
emit_port() { # <proto> <port> <exe> <pid>
    if [[ $1 == tcp ]]; then
        printf 'LISTEN 0 5 0.0.0.0:%s 0.0.0.0:* users:(("socat",pid=%s,fd=5))\n' "$2" "$4" >> "$SD/ports"
    else
        printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:* users:(("tuic-server",pid=%s,fd=6))\n' "$2" "$4" >> "$SD/ports"
    fi
}
ss() {
    [[ -e $SD/ports ]] || return 0
    # 尊重 -ltn / -lun 的协议过滤，否则 UDP 行会污染 TCP 判定。
    case " $* " in
        *" -ltn"*) grep '^LISTEN' "$SD/ports" || true ;;
        *" -lun"*) grep '^UNCONN' "$SD/ports" || true ;;
        *) cat "$SD/ports" ;;
    esac
    return 0
}
sleep() { command sleep 0.01; }
curl() {
    printf '%s\n' "curl $*" >> "$SD/curl.log"
    [[ -e $SD/download_fail ]] && return 22
    local out='' prev='' src=''
    for a in "$@"; do [[ $prev == -o ]] && out=$a; prev=$a; done
    [[ -n $out ]] || return 1
    case $out in
        *.tar.gz) src=$work/pkg/tcp-brutal.dkms.tar.gz ;;
        *) src=$work/pkg/tuic-server ;;
    esac
    cp -- "$src" "$out"
    return 0
}

# 断言工具
reset() {
    rm -rf "$TOOLBOX_NET_ETC" "$TOOLBOX_NET_LOCK_DIR" "$TOOLBOX_NET_MODLOAD_DIR" \
        "$TOOLBOX_NET_SYSCTL_DIR" "$TOOLBOX_NET_DKMS_DIR" "$TOOLBOX_NET_SRC_DIR" "$work/client"
    find "$TOOLBOX_NET_UNIT_DIR" -mindepth 1 -delete
    find "$TOOLBOX_NET_BIN_DIR" -mindepth 1 -delete
    rm -f "$SD"/*.log "$SD/ports" "$SD/loaded" "$SD/active" "$SD/mainpid" "$SD/mainexe" "$SD"/a5_*
    rm -f "$SD/cc_current" "$SD/cc_available"
    for f in "$SD"/*_fail "$SD"/noactivate "$SD"/no_register "$SD"/sysctl_fail "$SD"/tuic_badconf; do
        [[ -e $f ]] && rm -f "$f"
    done
    unset MOCK_PORT MOCK_PROTO MOCK_VIRT TOOLBOX_NET_KERNEL_RELEASE
    printf '4242\n' > "$SD/mainpid"
    export TOOLBOX_NET_KERNEL_RELEASE=6.1.0-test
    mkdir -p "$TOOLBOX_NET_LOCK_DIR"
}
wrote_brutal() {
    [[ -d $TOOLBOX_NET_ETC/terry-toolbox-brutal || -e $TOOLBOX_NET_MODLOAD_DIR/brutal.conf \
        || -e $TOOLBOX_NET_BIN_DIR/brutalctl || -d $TOOLBOX_NET_DKMS_DIR/tcp-brutal ]]
}
wrote_tuic() {
    [[ -d $TOOLBOX_NET_ETC/terry-toolbox-tuic || -e $TOOLBOX_NET_BIN_DIR/terry-toolbox-tuic \
        || -e $TOOLBOX_NET_UNIT_DIR/terry-toolbox-tuic.service ]]
}
wrote_a5() {
    [[ -d $TOOLBOX_NET_ETC/terry-toolbox-xray || -e $TOOLBOX_NET_BIN_DIR/terry-toolbox-xray ]]
}
wrote_unit() { [[ -n $(ls "$TOOLBOX_NET_UNIT_DIR" 2>/dev/null) ]]; }
clean() { ! wrote_brutal && ! wrote_tuic && ! wrote_a5 && ! wrote_unit; }
assert_clean() { if ! clean; then ls -R "$TOOLBOX_NET_ETC" "$TOOLBOX_NET_UNIT_DIR" "$TOOLBOX_NET_BIN_DIR" >&2; fail "$1：留下了写入"; fi; }
called() { grep -qF -- "$1" "$SD/$2" 2>/dev/null || fail "缺少 $2 调用: $1"; }

# 证书夹具（真实 openssl）
mk_cert() {
    local name=$1 host=$2
    shift 2
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
        -keyout "$work/$name.key" -out "$work/$name.crt" \
        -subj "/CN=$host" -addext "subjectAltName=DNS:$host" "$@" >/dev/null 2>&1 \
        || fail "无法生成测试证书 $name"
}
mk_cert good tuic.example.test
mk_cert other wrong.example.test
mkdir -p "$work/client"

# ================================================================ B12 TCP Brutal
# 全部前置条件不具备时，必须在写盘前失败。
inst_brutal() { printf 'YES\nBRUTAL\n' | toolbox_network B12 install; }

if TOOLBOX_NET_UID=1000 toolbox_network B12 install </dev/null >"$work/o" 2>&1; then fail 'B12 非 root 被接受'; fi
grep -q 'root' "$work/o" || fail 'B12 非 root 未说明'
assert_clean 'B12 非 root'
TOOLBOX_NET_OS_RELEASE=$work/ubuntu toolbox_network B12 install </dev/null >"$work/o" 2>&1 && fail 'B12 Ubuntu 被接受'
grep -q '仅支持 Debian' "$work/o" || fail 'B12 Ubuntu 未说明'
assert_clean 'B12 Ubuntu'

TOOLBOX_NET_SYSTEMD_RUN=$work/nope toolbox_network B12 install </dev/null >"$work/o" 2>&1 && fail 'B12 无 systemd 被接受'
assert_clean 'B12 无 systemd'
MOCK_VIRT=docker toolbox_network B12 install </dev/null >"$work/o" 2>&1 && fail 'B12 容器被接受'
grep -q '容器' "$work/o" || fail 'B12 容器未说明'
assert_clean 'B12 容器'
MOCK_VIRT=none TOOLBOX_NET_KERNEL_RELEASE=5.4.0-1 toolbox_network B12 install </dev/null >"$work/o" 2>&1 && fail 'B12 老内核被接受'
grep -q '过旧' "$work/o" || fail 'B12 老内核未说明'
assert_clean 'B12 老内核'
TOOLBOX_NET_MODDIR=$work/nomod toolbox_network B12 install </dev/null >"$work/o" 2>&1 && fail 'B12 缺头文件被接受'
grep -q '内核头文件' "$work/o" || fail 'B12 缺头文件未说明'
assert_clean 'B12 缺头文件'
mv "$work/modbuild/Makefile" "$work/modbuild/Makefile.saved"
toolbox_network B12 install </dev/null >"$work/o" 2>&1 && fail 'B12 空 headers 目录被接受'
grep -q 'Makefile' "$work/o" || fail 'B12 空 headers 目录未说明'
assert_clean 'B12 空 headers 目录'
mv "$work/modbuild/Makefile.saved" "$work/modbuild/Makefile"

# 冲突：别人的 drop-in 不得覆盖
mkdir -p "$TOOLBOX_NET_MODLOAD_DIR"
printf 'tcp_brutal\n' > "$TOOLBOX_NET_MODLOAD_DIR/brutal.conf"
inst_brutal >"$work/o" 2>&1 && fail 'B12 陌生 modules-load 被覆盖'
grep -q '内容不同' "$work/o" || fail 'B12 陌生 modules-load 未说明'
[[ $(<"$TOOLBOX_NET_MODLOAD_DIR/brutal.conf") == tcp_brutal ]] || fail 'B12 覆盖了陌生 modules-load'
reset
mkdir -p "$TOOLBOX_NET_SYSCTL_DIR"
printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$TOOLBOX_NET_SYSCTL_DIR/terry-toolbox-brutal.conf"
inst_brutal >"$work/o" 2>&1 && fail 'B12 陌生 sysctl drop-in 被覆盖'
grep -q '内容不同' "$work/o" || fail 'B12 陌生 sysctl 未说明'
reset
mkdir -p "$TOOLBOX_NET_BIN_DIR"
printf '#!/bin/sh\nexit 0\n' > "$TOOLBOX_NET_BIN_DIR/brutalctl"
inst_brutal >"$work/o" 2>&1 && fail 'B12 陌生 brutalctl 被覆盖'
grep -q '不覆盖' "$work/o" || fail 'B12 陌生 brutalctl 未说明'
reset
mkdir -p "$TOOLBOX_NET_DKMS_DIR/tcp-brutal"
inst_brutal >"$work/o" 2>&1 && fail 'B12 已有 dkms 被接管'
grep -q 'DKMS' "$work/o" || fail 'B12 已有 dkms 未说明'
reset
: > "$SD/loaded"
# 模块已载入但没有任何文件（上次卸载的残留）：提示后继续安装，不阻断。
inst_brutal >"$work/o" 2>&1 || { cat "$work/o" >&2; fail 'B12 残留模块被误拒'; }
grep -q '已载入' "$work/o" || { cat "$work/o" >&2; fail 'B12 已载入未说明'; }
grep -q '继续安装' "$work/o" || fail 'B12 已载入未说明会继续'
called 'modprobe brutal' mod.log
toolbox_network B12 uninstall <<< 'YES' >/dev/null 2>&1 || fail 'B12 残留模块安装后无法卸载'
assert_clean 'B12 残留模块'
reset

# 两次确认：只有 YES 或第二词不符都不得写盘
printf 'YES\n' | toolbox_network B12 install >"$work/o" 2>&1 && fail 'B12 单次确认通过'
grep -q '二次确认' "$work/o" || fail 'B12 未要求二次确认'
assert_clean 'B12 单次确认'
printf 'YES\nnope\n' | toolbox_network B12 install >"$work/o" 2>&1 && fail 'B12 错误二次确认通过'
grep -q '二次确认不匹配' "$work/o" || fail 'B12 二次确认不匹配未说明'
assert_clean 'B12 二次确认不符'
printf 'no\n' | toolbox_network B12 install >"$work/o" 2>&1 && fail 'B12 取消被当成安装'
assert_clean 'B12 取消'

# 下载 / 校验 / 编译 / 载入失败都要回滚并恢复默认算法
TOOLBOX_NET_BRUTAL_TGZ=''
: > "$SD/download_fail"
inst_brutal >"$work/o" 2>&1 && fail 'B12 下载失败被当成成功'
grep -q '下载失败' "$work/o" || fail 'B12 下载失败未说明'
assert_clean 'B12 下载失败'
reset
TOOLBOX_NET_BRUTAL_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    inst_brutal >"$work/o" 2>&1 && fail 'B12 校验和不符被接受'
grep -q 'SHA-256 不匹配' "$work/o" || fail 'B12 校验失败未说明'
assert_clean 'B12 校验失败'
reset
: > "$SD/make_fail"
inst_brutal >"$work/o" 2>&1 && fail 'B12 brutalctl 编译失败被当成成功'
grep -q '编译失败' "$work/o" || fail 'B12 brutalctl 编译失败未说明'
assert_clean 'B12 make 失败'
reset
: > "$SD/dkms_add_fail"
inst_brutal >"$work/o" 2>&1 && fail 'B12 dkms add 失败被当成成功'
assert_clean 'B12 dkms add 失败'
reset
: > "$SD/dkms_build_fail"
inst_brutal >"$work/o" 2>&1 && fail 'B12 dkms build 失败被当成成功'
assert_clean 'B12 dkms build 失败'
reset
: > "$SD/dkms_install_fail"
inst_brutal >"$work/o" 2>&1 && fail 'B12 dkms install 失败被当成成功'
assert_clean 'B12 dkms install 失败'
reset
: > "$SD/modprobe_fail"
inst_brutal >"$work/o" 2>&1 && fail 'B12 modprobe 失败被当成成功'
assert_clean 'B12 modprobe 失败'
reset
: > "$SD/no_register"
inst_brutal >"$work/o" 2>&1 && fail 'B12 算法未注册被当成成功'
grep -q '未注册' "$work/o" || fail 'B12 未注册未说明'
assert_clean 'B12 未注册'
reset
: > "$SD/sysctl_fail"
inst_brutal >"$work/o" 2>&1 && fail 'B12 sysctl 失败被当成成功'
assert_clean 'B12 sysctl 失败'
reset

# 成功路径
inst_brutal >"$work/o" 2>&1 || { cat "$work/o" >&2; fail 'B12 正常安装失败'; }
modload=$TOOLBOX_NET_MODLOAD_DIR/brutal.conf
sysctldrop=$TOOLBOX_NET_SYSCTL_DIR/terry-toolbox-brutal.conf
[[ -e $TOOLBOX_NET_BIN_DIR/brutalctl && -x $TOOLBOX_NET_BIN_DIR/brutalctl ]] || fail 'brutalctl 未安装'
[[ $(<"$modload") == brutal ]] || fail 'modules-load 内容不对'
grep -q '^net.ipv4.tcp_congestion_control = brutal$' "$sysctldrop" || fail 'sysctl drop-in 内容不对'
[[ $(stat -c %a "$sysctldrop") == 644 ]] || fail 'sysctl drop-in 权限不对'
[[ -d $TOOLBOX_NET_SRC_DIR/tcp-brutal-2.0.1/dkms_source_tree || -d $TOOLBOX_NET_SRC_DIR/tcp-brutal-2.0.1 ]] || fail '源码未落盘'
[[ $(<"$SD/cc_current") == brutal ]] || fail '默认算法未改'
[[ -s "$TOOLBOX_NET_ETC/terry-toolbox-brutal/meta" ]] || fail 'meta 未写'
[[ $(stat -c %a "$TOOLBOX_NET_ETC/terry-toolbox-brutal/meta") == 600 ]] || fail 'meta 权限不对'
grep -q '^cubic|2.0.1|' <<< "$(<"$TOOLBOX_NET_ETC/terry-toolbox-brutal/meta")" || fail 'meta 未记录安装前算法/版本'
called 'modprobe brutal' mod.log
called 'dkms install' dkms.log
[[ -z $(ls "$TOOLBOX_NET_UNIT_DIR") ]] || fail 'B12 不该创建 systemd 单元'
# 报告要如实标注已验证项和人工步骤
grep -q '\[已验证\]' <<< "$(<"$work/o")" || fail '报告缺少验证说明'
grep -q 'brutalctl add' <<< "$(<"$work/o")" || fail '报告缺少限速说明'
grep -q '规则不随重启' <<< "$(<"$work/o")" || fail '报告未提醒规则不持久'

# 重复安装必须拒绝且不改文件
sum=$(sha256sum "$sysctldrop" | cut -d' ' -f1)
inst_brutal >"$work/o" 2>&1 && fail 'B12 重复安装未拒绝'
[[ $(sha256sum "$sysctldrop" | cut -d' ' -f1) == "$sum" ]] || fail 'B12 重复安装改了 drop-in'

# status 只读
toolbox_network B12 status >"$work/o" 2>&1 || fail 'B12 status 失败'
grep -q '已载入' "$work/o" || fail 'status 未显示模块状态'
grep -q 'brutal' "$work/o" || fail 'status 未显示当前算法'

# 卸载：删净自己写的、恢复原算法、保留无关文件
printf 'keep\n' > "$work/untouched"
toolbox_network B12 uninstall <<< 'YES' >"$work/o" 2>&1 || { cat "$work/o" >&2; fail 'B12 卸载失败'; }
assert_clean 'B12 卸载'
[[ $(<"$SD/cc_current") == cubic ]] || fail '卸载未恢复默认算法'
[[ -e $work/untouched ]] || fail '卸载删了无关文件'
toolbox_network B12 status >/dev/null 2>&1 && fail '卸载后 status 仍报存在'
printf 'YES\n' | toolbox_network B12 uninstall >/dev/null 2>&1 && fail '未安装时卸载仍成功'
reset

# 并发锁
mkdir -p "$TOOLBOX_NET_LOCK_DIR"
( flock 9; command sleep 30 ) 9>"$TOOLBOX_NET_LOCK_DIR/terry-toolbox-brutal.lock" &
lockpid=$!
command sleep 0.4
inst_brutal >"$work/o" 2>&1 && fail 'B12 锁被占时仍安装'
grep -q '正在进行' "$work/o" || fail 'B12 未报告并发'
assert_clean 'B12 并发'
kill "$lockpid" 2>/dev/null || true
wait "$lockpid" 2>/dev/null || true
reset

# ================================================================ A3 TUIC
inst_tuic() { printf 'YES\nTUIC\n' | toolbox_network A3 install "$@"; }
# 服务二进制桩：解析配置、报告监听、占住端口直到被杀。
cat > "$work/pkg/tuic-server" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SD/tuic.log"
conf=''
for ((i = 1; i <= $#; i++)); do [[ ${!i} == -c ]] && { j=$((i + 1)); conf=${!j}; }; done
[[ -e $SD/tuic_badconf ]] && { printf 'No such file or directory (os error 2)\n'; exit 1; }
port=$(sed -n 's/.*:\([0-9]*\)".*/\1/p' "$conf" | head -n1)
line="UNCONN 0 0 0.0.0.0:$port 0.0.0.0:* users:((\"tuic-server\",pid=$$,fd=6))"
printf '%s\n' "$line" >> "$SD/ports"
printf '[WARN ] server started, listening on [::]:%s\n' "$port"
trap 'grep -v "pid=$$," "$SD/ports" > "$SD/ports.n" 2>/dev/null; mv "$SD/ports.n" "$SD/ports" 2>/dev/null' EXIT
while :; do command sleep 1; done
STUB
chmod +x "$work/pkg/tuic-server"
export TOOLBOX_NET_TUIC_BIN_SRC=$work/pkg/tuic-server
TUIC_SHA_TEST=$(sha256sum -- "$TOOLBOX_NET_TUIC_BIN_SRC" | cut -d' ' -f1)
export TOOLBOX_NET_TUIC_SHA256=$TUIC_SHA_TEST
export TOOLBOX_NET_UUID=3f2a0f2e-1111-4222-8333-444455556666

if TOOLBOX_NET_UID=1000 toolbox_network A3 install "$work/good.crt" "$work/good.key" tuic.example.test </dev/null >"$work/o" 2>&1; then fail 'A3 非 root 被接受'; fi
assert_clean 'A3 非 root'
TOOLBOX_NET_OS_RELEASE=$work/alpine toolbox_network A3 install "$work/good.crt" "$work/good.key" tuic.example.test </dev/null >"$work/o" 2>&1 && fail 'A3 Alpine 被接受'
assert_clean 'A3 Alpine'
for p in 0 65536 0080 abc; do
    inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test "$p" >"$work/o" 2>&1 && fail "A3 非法端口被接受: $p"
done
assert_clean 'A3 非法端口'
inst_tuic "$work/good.crt" "$work/good.key" 'Bad_Host' >"$work/o" 2>&1 && fail 'A3 非法主机名被接受'
assert_clean 'A3 非法主机名'
inst_tuic "$work/none.crt" "$work/good.key" tuic.example.test >"$work/o" 2>&1 && fail 'A3 缺证书被接受'
inst_tuic "$work/good.crt" "$work/other.key" tuic.example.test >"$work/o" 2>&1 && fail 'A3 不配对私钥被接受'
inst_tuic "$work/good.crt" "$work/good.key" wrong.example.test >"$work/o" 2>&1 && fail 'A3 域名不符被接受'
grep -q '不包含主机名' "$work/o" || fail 'A3 域名不符未说明'
assert_clean 'A3 证书'

mkdir -p "$TOOLBOX_NET_UNIT_DIR"
printf '[Service]\nExecStart=/usr/bin/someone-else\n' > "$TOOLBOX_NET_UNIT_DIR/terry-toolbox-tuic.service"
inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 8443 >"$work/o" 2>&1 && fail 'A3 外来单元被覆盖'
grep -q '不是本模块生成' "$work/o" || fail 'A3 外来单元未说明'
[[ ! -e $TOOLBOX_NET_BIN_DIR/terry-toolbox-tuic ]] || fail 'A3 外来单元仍写了二进制'
toolbox_network A3 uninstall <<< 'YES' >"$work/o" 2>&1 && fail 'A3 卸载删了外来单元'
[[ -e $TOOLBOX_NET_UNIT_DIR/terry-toolbox-tuic.service ]] || fail 'A3 外来单元被删'
reset
mkdir -p "$TOOLBOX_NET_UNIT_DIR"
printf '[Service]\nExecStart=%s/terry-toolbox-tuic -c x\n' "$TOOLBOX_NET_BIN_DIR" > "$TOOLBOX_NET_UNIT_DIR/terry-toolbox-tuic.service"
: > "$SD/active"
inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 8443 >"$work/o" 2>&1 && fail 'A3 运行中未拒绝重装'
grep -q '已在运行' "$work/o" || fail 'A3 运行中未说明'
reset

printf 'UNCONN 0 0 0.0.0.0:8443 0.0.0.0:* users:(("nginx",pid=7,fd=3))\n' > "$SD/ports"
inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 8443 >"$work/o" 2>&1 && fail 'A3 端口占用被接受'
grep -q '已被占用' "$work/o" || fail 'A3 端口占用未说明'
grep -q 'nginx' "$work/o" || fail 'A3 未给出占用者'
assert_clean 'A3 端口占用'
reset

printf 'YES\n' | toolbox_network A3 install "$work/good.crt" "$work/good.key" tuic.example.test >"$work/o" 2>&1 && fail 'A3 单次确认通过'
assert_clean 'A3 单次确认'
printf 'YES\nnope\n' | toolbox_network A3 install "$work/good.crt" "$work/good.key" tuic.example.test >"$work/o" 2>&1 && fail 'A3 错误二次确认通过'
assert_clean 'A3 二次确认不符'
reset

TOOLBOX_NET_TUIC_BIN_SRC=''
: > "$SD/download_fail"
inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 8443 >"$work/o" 2>&1 && fail 'A3 下载失败被当成成功'
assert_clean 'A3 下载失败'
reset
TOOLBOX_NET_TUIC_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    TOOLBOX_NET_TUIC_BIN_SRC='' inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 8443 >"$work/o" 2>&1 && fail 'A3 校验和不符被接受'
grep -q 'SHA-256 不匹配' "$work/o" || fail 'A3 校验失败未说明'
assert_clean 'A3 校验失败'
reset
: > "$SD/tuic_badconf"
inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 8443 >"$work/o" 2>&1 && fail 'A3 冒烟失败被当成成功'
assert_clean 'A3 冒烟失败'
reset
: > "$SD/enable_fail"
inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 8443 >"$work/o" 2>&1 && fail 'A3 enable 失败被当成成功'
assert_clean 'A3 enable 失败'
reset
: > "$SD/noactivate"
inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 8443 >"$work/o" 2>&1 && fail 'A3 未 active 被当成成功'
assert_clean 'A3 未 active'
reset
# 端口不是本服务持有（没有 MainPID 证据）也要回滚
rm -f "$SD/mainpid"
MOCK_PORT=8443 MOCK_PROTO=udp inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 8443 >"$work/o" 2>&1 \
    && fail 'A3 端口不归本服务时仍成功'
reset

# 成功路径
MOCK_PORT=18445 MOCK_PROTO=udp
export MOCK_PORT MOCK_PROTO
printf '4242\n' > "$SD/mainpid"
inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 18445 >"$work/o" 2>&1 \
    || { cat "$work/o" >&2; fail 'A3 正常安装失败'; }
conf=$TOOLBOX_NET_ETC/terry-toolbox-tuic/config.json
unit=$TOOLBOX_NET_UNIT_DIR/terry-toolbox-tuic.service
bin=$TOOLBOX_NET_BIN_DIR/terry-toolbox-tuic
[[ -x $bin && -s $conf && -e $unit ]] || fail 'A3 产物不全'
[[ $(stat -c %a "$conf") == 600 ]] || fail 'A3 配置权限不是 600'
[[ $(stat -c %a "$TOOLBOX_NET_ETC/terry-toolbox-tuic/key.pem") == 600 ]] || fail 'A3 私钥副本权限不是 600'
cmp -s "$work/good.key" "$TOOLBOX_NET_ETC/terry-toolbox-tuic/key.pem" || fail 'A3 私钥副本不一致'
[[ -e $work/good.key ]] || fail 'A3 移走了原始私钥'
grep -q '"server": "\[::\]:18445"' "$conf" || fail 'A3 监听地址不对'
grep -q '"3f2a0f2e-1111-4222-8333-444455556666"' "$conf" || fail 'A3 UUID 未写入'
grep -qE '"(3f2a0f2e[^"]*)": "[A-Za-z0-9]{32}"' "$conf" || fail 'A3 密码格式不对'
grep -q '"congestion_control": "bbr"' "$conf" || fail 'A3 未设置 bbr'
grep -q '"dual_stack": true' "$conf" || fail 'A3 未开双栈'
# 单元：绝对路径、能力最小化、沙箱
grep -qF "ExecStart=$bin -c $conf" "$unit" || fail 'A3 ExecStart 不是精确绝对路径'
for f in 'NoNewPrivileges=yes' 'ProtectSystem=strict' 'PrivateTmp=yes' 'CAP_NET_BIND_SERVICE' \
    'RestrictAddressFamilies=AF_INET AF_INET6' "ReadWritePaths=$TOOLBOX_NET_ETC/terry-toolbox-tuic"; do
    grep -qF "$f" "$unit" || fail "A3 单元缺少 $f"
done
! grep -qE '^(User|DynamicUser)=' "$unit" || fail 'A3 意外切换用户'
called 'enable --now terry-toolbox-tuic.service' systemctl.log
[[ $(stat -c %a "$TOOLBOX_NET_ETC/terry-toolbox-tuic/meta") == 600 ]] || fail 'A3 meta 权限不对'
grep -q 'tuic://3f2a0f2e-1111-4222-8333-444455556666' <<< "$(<"$work/o")" || fail 'A3 未输出客户端链接'
grep -q '\[未验证\] 认证' <<< "$(<"$work/o")" || fail 'A3 未标注认证未验证'
grep -q 'UDP 18445' <<< "$(<"$work/o")" || fail 'A3 未提示放行端口'

toolbox_network A3 status >"$work/o" 2>&1 || fail 'A3 status 失败'
grep -q '由本服务持有' "$work/o" || fail 'A3 status 未识别自有监听'
# MainPID 不符 → 不算自己的
printf '999\n' > "$SD/mainpid"
toolbox_network A3 status >"$work/o" 2>&1 || true
grep -q '不是本服务' "$work/o" || fail 'A3 status 误认他人监听'
printf '0\n' > "$SD/mainpid"

toolbox_network A3 uninstall <<< "YES" >"$work/o" 2>&1 || { cat "$work/o" >&2; fail "A3 卸载失败"; }
assert_clean 'A3 卸载'
[[ -e $work/good.crt ]] || fail 'A3 卸载删了原始证书'
reset
# 菜单不带参数：缺的证书/私钥/主机名要逐项补问，端口回车用默认
MOCK_PORT=443 MOCK_PROTO=udp; export MOCK_PORT MOCK_PROTO
out=$(printf '1\n%s\n%s\n%s\n\nYES\nTUIC\n' "$work/good.crt" "$work/good.key" tuic.example.test \
    | toolbox_network A3 2>&1) || { printf '%s\n' "$out" >&2; fail 'A3 交互式补全参数后安装失败'; }
grep -q '"server": "\[::\]:443"' "$TOOLBOX_NET_ETC/terry-toolbox-tuic/config.json" || fail 'A3 交互式安装端口不是默认 443'
toolbox_network A3 uninstall <<< "YES" >/dev/null 2>&1 || fail 'A3 交互式安装后卸载失败'
reset
printf '%s\n' "$work/good.crt" | toolbox_network A3 install >/dev/null 2>&1 && fail 'A3 EOF 被当成安装'
assert_clean 'A3 交互式 EOF'
unset MOCK_PORT MOCK_PROTO

# ================================================================ A5 Xray (Debian)
# A5 的落盘路径、systemd、冲突与回滚全部在临时目录 + 桩内完成；真实执行的只有模块
# 逻辑、openssl、sha256sum、install/mv/stat。xray 二进制用桩（覆盖 uuid/x25519/
# 自检/监听），探针与目标 TLS 检查各自单独测（探针见文件末尾的真实块）。
export TOOLBOX_NET_RUN=$work/run
export TOOLBOX_NET_UID=0
mkdir -p "$TOOLBOX_NET_RUN"
A5_ETC=$TOOLBOX_NET_ETC/terry-toolbox-xray
A5_BIN=$TOOLBOX_NET_BIN_DIR/terry-toolbox-xray
A5_UNIT=$TOOLBOX_NET_UNIT_DIR/terry-toolbox-xray.service
export TOOLBOX_A5_LIMITS=10485760:524288:1048576:262144:524288

# ---------- RSS 桩：只实现模块用到的子命令 ----------
cat > "$work/pkg/xray-stub" <<'STUB'
#!/usr/bin/env bash
conf=''; test_only=0
case ${1:-} in
    uuid) printf '3f2a0f2e-1111-4222-8333-444455556666\n'; exit 0 ;;
    x25519) printf 'PrivateKey: 0LHifSE0_fQEYRl_kTW3YtJRQi4J0HjJY_u0qOgKlFQ\nPassword (PublicKey): LekO3lYTCagolRongTjy_XMM5A_K_bbwLScIWEZneQE\n'; exit 0 ;;
    run) shift ;;
    *) exit 2 ;;
esac
while (( $# )); do
    case $1 in
        -test) test_only=1 ;;
        -c) shift; conf=${1:-} ;;
    esac
    shift
done
if (( test_only )); then
    [[ -e $SD/a5_badconf ]] && { printf 'failed to load config\n'; exit 1; }
    exit 0
fi
[[ -r $conf ]] || exit 1
if [[ -e $SD/a5_listen_fail ]]; then printf 'failed to listen\n'; exit 1; fi
port=$(sed -n 's/.*"port": *\([0-9]*\),\{0,1\}$/\1/p' "$conf" | head -n1)
printf 'transport/internet/tcp: listening tcp on 0.0.0.0:%s\n' "$port"
trap 'grep -v "a5stub,pid=4242," "$SD/ports" > "$SD/ports.n" 2>/dev/null; mv "$SD/ports.n" "$SD/ports" 2>/dev/null' EXIT
printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:(("a5stub",pid=4242,fd=3))\n' "$port" >> "$SD/ports"
while :; do
    if [[ -e $SD/a5_hit ]]; then
        who=$(cat "$SD/a5_hit"); rm -f "$SD/a5_hit"
        if [[ $who == good ]]; then
            [[ -e $SD/a5_no_accept ]] || printf 'from 127.0.0.1:5000 accepted tcp:dest.example.test:443 [vless-in >> direct]\n'
        else
            printf 'from 127.0.0.1:5001 rejected  proxy/vless/encoding: invalid request user id: 1111\n'
        fi
        : > "$SD/a5_ack"
    fi
    command sleep 0.02
done
STUB
chmod +x "$work/pkg/xray-stub"
python3 - "$work/pkg/xray-stub" "$work/pkg/xray.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], 'w') as z:
    z.write(sys.argv[1], 'xray')
PY
export TOOLBOX_A5_ZIP_SRC=$work/pkg/xray.zip
TOOLBOX_A5_SHA256=$(sha256sum -- "$TOOLBOX_A5_ZIP_SRC" | cut -d' ' -f1)
export TOOLBOX_A5_SHA256

# 模块的探针在桩环境里换成「写命中标记 + 等 a5stub 落日志」，判据仍由模块自己算。
net_a5_probe() { # bin port uuid pub shortid sni label
    local who=good
    [[ -e $SD/a5_probe_fail ]] && return 1
    if [[ $3 == '11111111-1111-4111-8111-111111111111' ]]; then who=bad; fi
    [[ $who == bad && -e $SD/a5_no_reject ]] || printf '%s\n' "$who" > "$SD/a5_hit"
    local i
    for ((i = 0; i < 200; i++)); do [[ -e $SD/a5_ack ]] && break; command sleep 0.01; done
    rm -f -- "$SD/a5_ack" "$SD/a5_hit"
    return 0
}

inst_a5() { printf 'YES\nXRAY\n' | toolbox_network A5 install "$@"; }

# ---------- 目标能力：TLS 1.3 / h2 / 证书覆盖，缺一即拒 ----------
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
    -keyout "$work/a5t.key" -out "$work/a5t.crt" -subj '/CN=dest.example.test' \
    -addext 'subjectAltName=DNS:dest.example.test' >/dev/null 2>&1 || fail '无法生成目标证书'
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
    -keyout "$work/a5u.key" -out "$work/a5u.crt" -subj '/CN=other.example.test' \
    -addext 'subjectAltName=DNS:other.example.test' >/dev/null 2>&1 || fail '无法生成目标证书'
# 目标握手桩：必须是脚本，模块用 `timeout openssl` 调用，函数拦截不到。
cat > "$work/pathbin/openssl" <<'OSTUB'
#!/usr/bin/env bash
echo "SD=[$SD] tls12=$([[ -e $SD/a5_tls12 ]] && echo y || echo n)" >> "$SD/stub.log"
if [[ ${1:-} == s_client ]]; then
    printf 'CONNECTED(00000003)\n'
    if [[ -e $SD/a5_tls12 ]]; then
        printf 'New, TLSv1.2, Cipher is ECDHE\n    Protocol  : TLSv1.2\n'
    else
        printf 'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\n    Protocol  : TLSv1.3\n'
    fi
    [[ -e $SD/a5_noalpn ]] || printf 'ALPN protocol: h2\n'
    if [[ -e $SD/a5_wrongcert ]]; then cat "$A5_WRONG_CRT"; else cat "$A5_GOOD_CRT"; fi
    printf '---\n'
    exit 0
fi
exec /usr/bin/openssl "$@"
OSTUB
chmod +x "$work/pathbin/openssl"
hash -r   # 之前已解析过 /usr/bin/openssl，必须丢掉路径缓存
export SD A5_GOOD_CRT=$work/a5t.crt A5_WRONG_CRT=$work/a5u.crt
net_a5_check_target dest.example.test 443 dest.example.test || fail 'A5 目标检查误拒正常目标'
# 上游产物名按架构不同：arm64 是 -arm64-v8a，写成 -arm64 会 404。
[[ $(net_a5_zip_url amd64) == */Xray-linux-64.zip ]] || fail "A5 amd64 产物名不对: $(net_a5_zip_url amd64)"
[[ $(net_a5_zip_url arm64) == */Xray-linux-arm64-v8a.zip ]] || fail "A5 arm64 产物名不对: $(net_a5_zip_url arm64)"
: > "$SD/a5_tls12"
net_a5_check_target dest.example.test 443 dest.example.test 2>"$work/o" && fail 'A5 只支持 TLS1.2 的目标被接受'
grep -q 'TLS 1.3' "$work/o" || fail 'A5 未说明 TLS 1.3 要求'
rm -f "$SD/a5_tls12"; : > "$SD/a5_noalpn"
net_a5_check_target dest.example.test 443 dest.example.test 2>"$work/o" && fail 'A5 无 h2 的目标被接受'
grep -q 'h2' "$work/o" || fail 'A5 未说明 h2 要求'
rm -f "$SD/a5_noalpn"; : > "$SD/a5_wrongcert"
net_a5_check_target dest.example.test 443 dest.example.test 2>"$work/o" && fail 'A5 证书不覆盖 SNI 的目标被接受'
grep -q '不覆盖' "$work/o" || fail 'A5 未说明证书覆盖'
rm -f "$SD/a5_wrongcert"

# ---------- 前置条件：全部在写盘前拒绝 ----------
# 从这里起目标检查改为桩，避免依赖网络。
TOOLBOX_NET_UID=1000 toolbox_network A5 install dest.example.test dest.example.test </dev/null >"$work/o" 2>&1 && fail 'A5 非 root 被接受'
grep -q 'root' "$work/o" || fail 'A5 非 root 未说明'
assert_clean 'A5 非 root'
TOOLBOX_NET_OS_RELEASE=$work/ubuntu toolbox_network A5 install dest.example.test dest.example.test </dev/null >"$work/o" 2>&1 && fail 'A5 Ubuntu 被接受'
grep -q '仅支持 Debian' "$work/o" || fail 'A5 Ubuntu 未说明'
assert_clean 'A5 Ubuntu'
TOOLBOX_NET_SYSTEMD_RUN=$work/nope toolbox_network A5 install dest.example.test dest.example.test </dev/null >"$work/o" 2>&1 && fail 'A5 无 systemd 被接受'
assert_clean 'A5 无 systemd'
net_a5_check_target() { return 0; }   # 前置条件测试不联网

inst_a5 >"$work/o" 2>&1 && fail 'A5 缺目标被接受'
grep -q '回落目标' "$work/o" || fail 'A5 缺目标未说明'
inst_a5 dest.example.test >"$work/o" 2>&1 && fail 'A5 缺 SNI 被接受'
grep -q 'SNI' "$work/o" || fail 'A5 缺 SNI 未说明'
inst_a5 'dest.example.test:0' dest.example.test >"$work/o" 2>&1 && fail 'A5 目标端口非法被接受'
inst_a5 'bad host' dest.example.test >"$work/o" 2>&1 && fail 'A5 目标主机非法被接受'
inst_a5 dest.example.test 'Bad_SNI' >"$work/o" 2>&1 && fail 'A5 SNI 非法被接受'
inst_a5 dest.example.test dest.example.test 0080 >"$work/o" 2>&1 && fail 'A5 监听端口非法被接受'
TOOLBOX_A5_LIMITS=1:2:3 inst_a5 dest.example.test dest.example.test >"$work/o" 2>&1 && { cat "$work/o" >&2; fail 'A5 限速参数残缺被接受'; }
grep -q 'TOOLBOX_A5_LIMITS' "$work/o" || { cat "$work/o" >&2; fail 'A5 限速参数残缺未说明'; }
assert_clean 'A5 参数'

# 安装路径里的目标检查：失败必须发生在写盘前
net_a5_check_target() { net_err '模拟目标不合格'; return 1; }
inst_a5 dest.example.test dest.example.test >"$work/o" 2>&1 && fail 'A5 目标不合格仍安装'
assert_clean 'A5 目标不合格'
net_a5_check_target() { return 0; }

# ---------- 归属冲突 ----------
mkdir -p "$TOOLBOX_NET_UNIT_DIR"
printf '[Service]\nExecStart=/usr/bin/someone-else\n' > "$A5_UNIT"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 外来单元被覆盖'
grep -q '不是本模块生成' "$work/o" || fail 'A5 外来单元未说明'
[[ ! -e $A5_BIN ]] || fail 'A5 外来单元仍写了二进制'
toolbox_network A5 uninstall <<< 'YES' >"$work/o" 2>&1 && fail 'A5 卸载删了外来单元'
[[ -e $A5_UNIT ]] || fail 'A5 外来单元被删'
reset
printf '[Service]\nExecStart=%s run -c x\n' "$A5_BIN" > "$A5_UNIT"
: > "$SD/active"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 运行中未拒绝重装'
grep -q '已在运行' "$work/o" || fail 'A5 运行中未说明'
rm -f "$SD/active"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 残留未拒绝重装'
grep -q '残留' "$work/o" || fail 'A5 残留未说明'
reset
mkdir -p "$A5_ETC"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 无单元但有配置目录仍安装'
reset
: > "$A5_BIN"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 无单元但有二进制仍安装'
reset

# ---------- 端口占用 ----------
printf 'LISTEN 0 128 0.0.0.0:8443 0.0.0.0:* users:(("nginx",pid=7,fd=3))\n' > "$SD/ports"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 端口占用被接受'
grep -q 'nginx' "$work/o" || fail 'A5 未给出占用者'
assert_clean 'A5 端口占用'
reset

# ---------- 确认、下载、校验 ----------
printf 'YES\n' | toolbox_network A5 install dest.example.test dest.example.test >"$work/o" 2>&1 && fail 'A5 单次确认通过'
assert_clean 'A5 单次确认'
printf 'YES\nnope\n' | toolbox_network A5 install dest.example.test dest.example.test >"$work/o" 2>&1 && fail 'A5 二次确认不符通过'
assert_clean 'A5 二次确认'
reset
TOOLBOX_A5_ZIP_SRC='' : > "$SD/download_fail"
TOOLBOX_A5_ZIP_SRC='' inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 下载失败被当成成功'
assert_clean 'A5 下载失败'
reset
TOOLBOX_A5_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 校验和不符被接受'
grep -q 'SHA-256 不匹配' "$work/o" || fail 'A5 校验失败未说明'
assert_clean 'A5 校验失败'
reset

# ---------- 写盘后失败：一律回滚干净 ----------
: > "$SD/a5_badconf"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 配置自检失败被当成成功'
grep -q '配置自检失败' "$work/o" || fail 'A5 自检失败未说明'
assert_clean 'A5 自检失败'
reset
: > "$SD/a5_listen_fail"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 冒烟不监听被当成成功'
grep -q '冒烟启动失败' "$work/o" || fail 'A5 冒烟失败未说明'
assert_clean 'A5 冒烟失败'
reset
: > "$SD/a5_probe_fail"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 正向探测失败被当成成功'
grep -q '认证探测失败' "$work/o" || fail 'A5 探测失败未说明'
assert_clean 'A5 正向探测失败'
reset
# 数据面通、但服务端没有认证通过记录 → 只可能是回退转发，必须失败
: > "$SD/a5_no_accept"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 无认证记录被当成成功'
grep -q '没有认证通过记录' "$work/o" || { cat "$work/o" >&2; fail 'A5 无认证记录未说明'; }
assert_clean 'A5 无认证记录'
reset
# 错误 UUID 未被拒绝
: > "$SD/a5_no_reject"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 错误 UUID 未被拒仍成功'
grep -q '没有被拒绝' "$work/o" || fail 'A5 错误 UUID 未被拒未说明'
assert_clean 'A5 错误 UUID 未被拒'
reset
: > "$SD/enable_fail"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 enable 失败被当成成功'
assert_clean 'A5 enable 失败'
reset
: > "$SD/noactivate"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 未 active 被当成成功'
assert_clean 'A5 未 active'
reset
rm -f "$SD/mainpid"
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 端口不归本服务时仍成功'
grep -q '监听进程不是' "$work/o" || fail 'A5 端口归属失败未说明'
assert_clean 'A5 端口不归属'
reset
printf '4242\n' > "$SD/mainpid"

# ---------- 清单回滚：只删登记过且未改动的路径，外来单元不动 ----------
mkdir -p "$A5_ETC"
printf 'keep-original\n' > "$A5_ETC/config.json"
printf 'bin\n' > "$A5_BIN"
printf '[Service]\nExecStart=/usr/bin/other\n' > "$A5_UNIT"
# 这两个全局量由模块的 net_a5_rollback 读取，测试里只需预设。
# shellcheck disable=SC2034
net_a5_manifest=(); net_a5_etc_created=0
net_a5_record "$A5_ETC/config.json"; net_a5_record "$A5_BIN"
printf 'touched\n' >> "$A5_ETC/config.json"
net_a5_rollback >/dev/null 2>&1
[[ -e $A5_ETC/config.json ]] || fail 'A5 回滚删了被改动的文件'
[[ ! -e $A5_BIN ]] || fail 'A5 回滚没删登记过的文件'
[[ -e $A5_UNIT ]] || fail 'A5 回滚删了外来单元'
rm -rf "$A5_ETC" "$A5_BIN" "$A5_UNIT"
# shellcheck disable=SC2034
net_a5_manifest=()

# ---------- 并发锁 ----------
mkdir -p "$TOOLBOX_NET_LOCK_DIR"
( flock 9; command sleep 30 ) 9>"$TOOLBOX_NET_LOCK_DIR/terry-toolbox-a5.lock" &
lockpid=$!
command sleep 0.4
inst_a5 dest.example.test dest.example.test 8443 >"$work/o" 2>&1 && fail 'A5 锁被占时仍安装'
grep -q '正在进行' "$work/o" || fail 'A5 未报告并发'
assert_clean 'A5 并发'
kill "$lockpid" 2>/dev/null || true
wait "$lockpid" 2>/dev/null || true
reset

# ---------- 成功路径 ----------
inst_a5 dest.example.test dest.example.test 18445 >"$work/o" 2>&1 || { cat "$work/o" >&2; fail 'A5 正常安装失败'; }
conf=$A5_ETC/config.json
[[ -x $A5_BIN && -s $conf && -e $A5_UNIT ]] || fail 'A5 产物不全'
[[ $(stat -c %a "$conf") == 600 ]] || fail 'A5 配置权限不是 600'
grep -q '"target": "dest.example.test:443"' "$conf" || fail 'A5 目标未写入'
grep -q '"serverNames": \[ "dest.example.test" \]' "$conf" || fail 'A5 serverNames 不对'
grep -q '"port": 18445' "$conf" || fail 'A5 监听端口未写入'
grep -q '"flow": "xtls-rprx-vision"' "$conf" || fail 'A5 未开 vision'
grep -q '"3f2a0f2e-1111-4222-8333-444455556666"' "$conf" || fail 'A5 UUID 未写入'
grep -q '"shortIds": \[ "[0-9a-f]\{16\}" \]' "$conf" || fail 'A5 shortId 不是 16 位十六进制'
# 回退限速：两个方向都在，且 afterBytes/burst 有值、burst ≥ bytesPerSec
grep -q '"limitFallbackUpload"' "$conf" || fail 'A5 缺上行限速'
grep -q '"limitFallbackDownload"' "$conf" || fail 'A5 缺下行限速'
for dir in Upload Download; do
    after=$(sed -n "/limitFallback$dir/,/}/p" "$conf" | sed -n 's/.*"afterBytes": \([0-9]*\).*/\1/p')
    bps=$(sed -n "/limitFallback$dir/,/}/p" "$conf" | sed -n 's/.*"bytesPerSec": \([0-9]*\).*/\1/p')
    burst=$(sed -n "/limitFallback$dir/,/}/p" "$conf" | sed -n 's/.*"burstBytesPerSec": \([0-9]*\).*/\1/p')
    [[ -n $after && -n $bps && -n $burst ]] || fail "A5 $dir 限速缺字段"
    (( after >= 4194304 && after <= 16777216 )) || fail "A5 $dir afterBytes 不在 4-16 MiB: $after"
    (( bps > 0 && burst >= bps )) || fail "A5 $dir 令牌桶参数不合理 bps=$bps burst=$burst"
done
grep -q '"limitFallbackUpload": {' "$conf" || fail 'A5 上行限速不是对象'
grep -q '"decryption": "none"' "$conf" || fail 'A5 decryption 不对'
grep -q '"show": false' "$conf" || fail 'A5 打开了 show'
# 单元：精确绝对路径、沙箱、开机自启
grep -qF "ExecStart=$A5_BIN run -c $conf" "$A5_UNIT" || fail 'A5 ExecStart 不是精确绝对路径'
for f in 'Type=simple' 'Restart=on-failure' 'NoNewPrivileges=yes' 'ProtectSystem=strict' \
    'PrivateTmp=yes' 'CAP_NET_BIND_SERVICE' 'RestrictAddressFamilies=AF_INET AF_INET6' "ReadWritePaths=$A5_ETC"; do
    grep -qF "$f" "$A5_UNIT" || fail "A5 单元缺少 $f"
done
grep -q 'WantedBy=multi-user.target' "$A5_UNIT" || fail 'A5 未设开机自启'
called 'enable --now terry-toolbox-xray.service' systemctl.log
[[ $(stat -c %a "$A5_ETC/meta") == 600 ]] || fail 'A5 meta 权限不对'
grep -q 'vless://3f2a0f2e-1111-4222-8333-444455556666' <<< "$(<"$work/o")" || fail 'A5 未输出客户端链接'
grep -q '\[已验证\] 正确 UUID' <<< "$(<"$work/o")" || fail 'A5 未标注认证已验证'
grep -q '\[已限制\]' <<< "$(<"$work/o")" || fail 'A5 未报告回退限速'
! grep -q '\[未验证\]' <<< "$(<"$work/o")" || fail 'A5 仍留未验证项'
grep -q 'TCP 18445' <<< "$(<"$work/o")" || fail 'A5 未提示放行端口'

toolbox_network A5 status >"$work/o" 2>&1 || fail 'A5 status 失败'
grep -q '由本服务持有' "$work/o" || fail 'A5 status 未识别自有监听'
printf '999\n' > "$SD/mainpid"
toolbox_network A5 status >"$work/o" 2>&1 || true
grep -q '不是本服务' "$work/o" || fail 'A5 status 误认他人监听'
printf '4242\n' > "$SD/mainpid"

toolbox_network A5 uninstall <<< 'YES' >"$work/o" 2>&1 || { cat "$work/o" >&2; fail 'A5 卸载失败'; }
assert_clean 'A5 卸载'
reset

# ---------- 菜单不带参数：缺的回落目标/SNI 要逐项补问 ----------
MOCK_PORT=443 MOCK_PROTO=tcp; export MOCK_PORT MOCK_PROTO
out=$(printf '1\ndest.example.test\ndest.example.test\n\nYES\nXRAY\n' | toolbox_network A5 2>&1) \
    || { printf '%s\n' "$out" >&2; fail 'A5 交互式补全参数后安装失败'; }
[[ $(sed -n 's/.*"port": \([0-9]*\),/\1/p' "$A5_ETC/config.json" | head -n1) == 443 ]] || fail 'A5 交互式安装端口不是默认 443'
grep -q '"target": "dest.example.test:443"' "$A5_ETC/config.json" || fail 'A5 交互式安装目标不对'
toolbox_network A5 uninstall <<< 'YES' >"$work/o" 2>&1 || fail 'A5 交互式安装后卸载失败'
reset
# 问到一半就 EOF 也要在写盘前退出
printf 'dest.example.test\n' | toolbox_network A5 install >/dev/null 2>&1 && fail 'A5 EOF 被当成安装'
assert_clean 'A5 交互式 EOF'

# ---------- A3/A5 菜单自定义端口，不能把端口输入吞作确认 ----------
MOCK_PORT=18443 MOCK_PROTO=udp; export MOCK_PORT MOCK_PROTO
out=$(printf '%s\n%s\ntuic.example.test\n18443\nYES\nTUIC\n' "$work/good.crt" "$work/good.key" | toolbox_network A3 install 2>&1) \
    || { printf '%s\n' "$out" >&2; fail 'A3 交互自定义端口失败'; }
grep -q '"server": "\[::\]:18443"' "$(net_tuic_etc)/config.json" || fail 'A3 交互端口被忽略'
toolbox_network A3 uninstall <<< YES >/dev/null 2>&1 || fail 'A3 自定义端口卸载失败'
reset
MOCK_PORT=18443 MOCK_PROTO=tcp; export MOCK_PORT MOCK_PROTO
out=$(printf 'dest.example.test:8443\ndest.example.test\n18443\nYES\nXRAY\n' | toolbox_network A5 install 2>&1) \
    || { printf '%s\n' "$out" >&2; fail 'A5 交互自定义端口失败'; }
grep -q '"port": 18443' "$A5_ETC/config.json" || fail 'A5 监听端口被忽略'
grep -q '"target": "dest.example.test:8443"' "$A5_ETC/config.json" || fail 'A5 回落端口被忽略'
toolbox_network A5 uninstall <<< YES >/dev/null 2>&1 || fail 'A5 自定义端口卸载失败'
reset

# 真 Xray + 公网回落目标验收只在指定一次性主机单独运行，不属于隔离套件。

# ---------- 分发 ----------
toolbox_network A5 bogus >"$work/o" 2>&1 && fail 'A5 未知动作被接受'
grep -q '用法' "$work/o" || fail 'A5 未知动作未给用法'
printf '9\n' | toolbox_network A5 >"$work/o" 2>&1 && fail 'A5 非法菜单编号被接受'
printf '3\n' | toolbox_network A5 >"$work/o" 2>&1 && fail 'A5 未安装时 status 仍成功'
grep -q '未安装' "$work/o" || fail 'A5 未进入 status'
toolbox_network_xray status >"$work/o" 2>&1 && fail 'A5 别名 status 未安装仍成功'
grep -q '未安装' "$work/o" || fail 'A5 别名未转到 status'

# ================================================================ B31 Relay
inst_relay() { printf 'YES\nRELAY\n' | toolbox_network B31 install "$@"; }
for p in 0 70000 abc; do
    inst_relay tcp "$p" 10.0.0.1 443 >"$work/o" 2>&1 && fail "B31 非法本地端口被接受: $p"
done
inst_relay sctp 8080 10.0.0.1 443 >"$work/o" 2>&1 && fail 'B31 非法协议被接受'
inst_relay tcp 8080 'bad host' 443 >"$work/o" 2>&1 && fail 'B31 非法目标被接受'
inst_relay tcp 8080 10.0.0.1 0 >"$work/o" 2>&1 && fail 'B31 非法目标端口被接受'
assert_clean 'B31 参数'
TOOLBOX_NET_SOCAT=$work/none inst_relay tcp 8080 10.0.0.1 443 >"$work/o" 2>&1 && fail 'B31 缺 socat 被接受'
grep -q 'socat' "$work/o" || fail 'B31 缺 socat 未说明'
MOCK_PORT=8080 MOCK_PROTO=tcp; export MOCK_PORT MOCK_PROTO
printf 'LISTEN 0 5 0.0.0.0:8080 0.0.0.0:* users:(("nginx",pid=7,fd=5))\n' > "$SD/ports"
inst_relay tcp 8080 10.0.0.1 443 >"$work/o" 2>&1 && fail 'B31 端口占用被接受'
grep -q 'nginx' "$work/o" || fail 'B31 未给出占用者'
assert_clean 'B31 端口占用'
reset
MOCK_PORT=8080 MOCK_PROTO=tcp; export MOCK_PORT MOCK_PROTO

mkdir -p "$TOOLBOX_NET_UNIT_DIR"
printf '[Service]\nExecStart=/usr/bin/socat TCP-LISTEN:8080\n' > "$TOOLBOX_NET_UNIT_DIR/terry-toolbox-relay-tcp-8080.service"
inst_relay tcp 8080 10.0.0.1 443 >"$work/o" 2>&1 && fail 'B31 外来单元被覆盖'
grep -q '不是本模块生成' "$work/o" || fail 'B31 外来单元未说明'
reset
MOCK_PORT=8080 MOCK_PROTO=tcp; export MOCK_PORT MOCK_PROTO

printf 'YES\n' | toolbox_network B31 install tcp 8080 10.0.0.1 443 >"$work/o" 2>&1 && fail 'B31 单次确认通过'
assert_clean 'B31 单次确认'
reset
MOCK_PORT=8080 MOCK_PROTO=tcp; export MOCK_PORT MOCK_PROTO
: > "$SD/enable_fail"
inst_relay tcp 8080 10.0.0.1 443 >"$work/o" 2>&1 && fail 'B31 enable 失败被当成成功'
assert_clean 'B31 enable 失败'
reset
MOCK_PORT=8080 MOCK_PROTO=tcp; export MOCK_PORT MOCK_PROTO
: > "$SD/noactivate"
inst_relay tcp 8080 10.0.0.1 443 >"$work/o" 2>&1 && fail 'B31 未 active 被当成成功'
assert_clean 'B31 未 active'
reset
MOCK_PORT=8080 MOCK_PROTO=udp; export MOCK_PORT MOCK_PROTO
rm -f "$SD/mainpid"
inst_relay tcp 8080 10.0.0.1 443 >"$work/o" 2>&1 && fail 'B31 端口不归本服务时仍成功'
reset

# 成功：TCP 与 UDP 单元内容必须精确
MOCK_PORT=18080 MOCK_PROTO=tcp; export MOCK_PORT MOCK_PROTO
inst_relay tcp 18080 relay.example.test 443 >"$work/o" 2>&1 || { cat "$work/o" >&2; fail 'B31 TCP 安装失败'; }
tcp_unit=$TOOLBOX_NET_UNIT_DIR/terry-toolbox-relay-tcp-18080.service
[[ -e $tcp_unit ]] || fail 'B31 未写单元'
grep -qxF "ExecStart=$TOOLBOX_NET_SOCAT -d -d TCP-LISTEN:18080,fork,reuseaddr TCP:relay.example.test:443" "$tcp_unit" \
    || { cat "$tcp_unit" >&2; fail 'B31 TCP ExecStart 不对'; }
for f in 'Type=simple' 'Restart=on-failure' 'NoNewPrivileges=yes' 'ProtectSystem=strict' 'LimitNOFILE=65536'; do
    grep -qF "$f" "$tcp_unit" || fail "B31 单元缺少 $f"
done
grep -q 'WantedBy=multi-user.target' "$tcp_unit" || fail 'B31 未设开机自启'
called 'enable --now terry-toolbox-relay-tcp-18080.service' systemctl.log
grep -q '\[未验证\] 端到端' <<< "$(<"$work/o")" || fail 'B31 未标注端到端未验证'

MOCK_PORT=18081 MOCK_PROTO=udp; export MOCK_PORT MOCK_PROTO
inst_relay udp 18081 relay.example.test 443 >"$work/o" 2>&1 || { cat "$work/o" >&2; fail 'B31 UDP 安装失败'; }
udp_unit=$TOOLBOX_NET_UNIT_DIR/terry-toolbox-relay-udp-18081.service
grep -qxF "ExecStart=$TOOLBOX_NET_SOCAT -d -d UDP-LISTEN:18081,reuseaddr,fork UDP:relay.example.test:443" "$udp_unit" \
    || { cat "$udp_unit" >&2; fail 'B31 UDP ExecStart 不对'; }

# 同一端口换协议允许并存
MOCK_PORT=18081 MOCK_PROTO=tcp; export MOCK_PORT MOCK_PROTO
inst_relay tcp 18081 relay.example.test 443 >"$work/o" 2>&1 || { cat "$work/o" >&2; fail 'B31 同端口 TCP+UDP 并存失败'; }
[[ $(find "$TOOLBOX_NET_UNIT_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 3 ]] || fail 'B31 单元数不对'
# 重复同协议同端口必须拒绝
inst_relay tcp 18080 relay.example.test 443 >"$work/o" 2>&1 && fail 'B31 重复单元被覆盖'
grep -q '已存在' "$work/o" || fail 'B31 重复单元未说明'

toolbox_network B31 status >"$work/o" 2>&1 || fail 'B31 status 失败'
grep -q 'terry-toolbox-relay-udp-18081.service' "$work/o" || fail 'B31 status 未列出单元'
grep -q 'ExecStart' "$work/o" || fail 'B31 status 未显示 ExecStart'

# 逐个卸载只删指定的，另一个保留
toolbox_network B31 uninstall udp 18081 <<< 'YES' >"$work/o" 2>&1 || fail 'B31 单条卸载失败'
[[ ! -e $udp_unit && -e $tcp_unit ]] || fail 'B31 单条卸载删错单元'
# 参数个数不对要拒绝
toolbox_network B31 uninstall tcp <<< 'YES' >/dev/null 2>&1 && fail 'B31 卸载参数不全被接受'
toolbox_network B31 uninstall all <<< 'YES' >"$work/o" 2>&1 || fail 'B31 全部卸载失败'
[[ -z $(ls "$TOOLBOX_NET_UNIT_DIR") ]] || fail 'B31 全部卸载有残留'
toolbox_network B31 status >/dev/null 2>&1 && fail 'B31 卸载后 status 仍报存在'
reset

# B31 空参数补问，默认 tcp 与显式 udp 均生成对应单元；EOF 不写盘。
for proto in tcp udp; do
    MOCK_PORT=18090 MOCK_PROTO=$proto; export MOCK_PORT MOCK_PROTO
    input=$proto; [[ $proto == tcp ]] && input=''
    out=$(printf '1\n%s\n18090\nrelay.example.test\n8443\nYES\nRELAY\n' "$input" | toolbox_network B31 2>&1) \
        || { printf '%s\n' "$out" >&2; fail 'B31 交互补全失败'; }
    grep -q "${proto^^}:relay.example.test:8443" "$TOOLBOX_NET_UNIT_DIR/terry-toolbox-relay-$proto-18090.service" || fail 'B31 目标/协议被忽略'
    toolbox_network B31 uninstall "$proto" 18090 <<< YES >/dev/null 2>&1 || fail 'B31 交互安装卸载失败'
    reset
done
for input in '' $'tcp\n' $'tcp\n18090\n' $'tcp\n18090\nrelay.example.test\n'; do
    printf '%s' "$input" | toolbox_network B31 install >/dev/null 2>&1 && fail 'B31 EOF 仍安装'
    assert_clean 'B31 交互 EOF'
done

# 真实 socat 往返：显式启用才运行；默认隔离测试不改动真实网络。
if [[ ${TOOLBOX_NETWORK_REAL_TESTS:-0} == 1 ]]; then
    [[ -x /usr/bin/socat || -x /bin/socat ]] || fail '显式启用真实转发测试，但缺少 /usr/bin/socat 或 /bin/socat'
    # PATH 里的 socat 是桩，真实往返必须用真身。
    real_socat=/usr/bin/socat
    [[ -x $real_socat ]] || real_socat=/bin/socat
    save_socat=$TOOLBOX_NET_SOCAT
    TOOLBOX_NET_SOCAT=$real_socat
    net_relay_write_unit tcp 18590 127.0.0.1 18591 || fail 'B31 真实单元生成失败'
    exec_line=$(sed -n 's/^ExecStart=//p' "$TOOLBOX_NET_UNIT_DIR/terry-toolbox-relay-tcp-18590.service")
    [[ -n $exec_line ]] || fail 'B31 真实单元无 ExecStart'
    exec_line=${exec_line/TCP-LISTEN:18590,/TCP-LISTEN:18590,bind=127.0.0.1,}
    out=$(timeout 15 bash -c '
        set -u
        "$1" -d -d TCP-LISTEN:18591,bind=127.0.0.1,fork,reuseaddr EXEC:/bin/cat >/dev/null 2>&1 &
        t=$!
        '"$exec_line"' >/dev/null 2>&1 &
        r=$!
        trap '"'"'kill "$r" "$t" 2>/dev/null || true; wait "$r" "$t" 2>/dev/null || true'"'"' EXIT
        for i in $(seq 50); do ss -ltn 2>/dev/null | grep -q ":18590 " && break; sleep 0.1; done
        exec 3<>/dev/tcp/127.0.0.1/18590 || exit 9
        printf "relay-through\n" >&3
        read -r -t 5 line <&3
        printf "%s" "$line"
        kill $r $t 2>/dev/null
    ' _ "$real_socat" 2>&1) || true
    [[ $out == relay-through ]] || { printf 'GOT:[%s]\n' "$out" >&2; fail 'B31 真实转发未通'; }
    printf 'B31 loopback socat roundtrip passed (127.0.0.1:18590 -> 127.0.0.1:18591)\n'
    TOOLBOX_NET_SOCAT=$save_socat
    reset
fi

# 菜单入口（无参数）走子菜单，编号 3 是状态
printf '3\n' | toolbox_network B12 >"$work/o" 2>&1 && fail 'B12 未安装时 status 应失败'
grep -q '未安装' "$work/o" || fail 'B12 子菜单未进入 status'
printf '9\n' | toolbox_network B31 >"$work/o" 2>&1 && fail 'B31 子菜单非法编号被接受'
printf '3\n' | toolbox_network B31 >"$work/o" 2>&1 && fail 'B31 未安装时 status 应失败'
printf '3\n' | toolbox_network A3 >"$work/o" 2>&1 && fail 'A3 未安装时 status 应失败'
printf '9\n' | toolbox_network A3 >"$work/o" 2>&1 && fail 'A3 子菜单非法编号被接受'
printf '3\n' | toolbox_network B12 2>/dev/null | grep -q 'B12 TCP Brutal' && fail 'B12 子菜单标题漏到 stdout'

# 条件上下文中非空 cat 写入后报错，必须失败而不是继续安装。
for key in A3 A5 B31; do
    reset
    (
        cat() { if (( $# == 0 )); then command cat; return 1; fi; command cat "$@"; }
        case $key in
            A3) MOCK_PORT=18443 MOCK_PROTO=udp; export MOCK_PORT MOCK_PROTO
                inst_tuic "$work/good.crt" "$work/good.key" tuic.example.test 18443 >"$work/write-fail-$key.out" 2>&1 && fail 'A3 配置写入失败被忽略' ;;
            A5) inst_a5 dest.example.test dest.example.test 18443 >"$work/write-fail-$key.out" 2>&1 && fail 'A5 配置写入失败被忽略' ;;
            B31) MOCK_PORT=18443 MOCK_PROTO=tcp; export MOCK_PORT MOCK_PROTO
                inst_relay tcp 18443 relay.example.test 8443 >"$work/write-fail-$key.out" 2>&1 && fail 'B31 单元写入失败被忽略' ;;
        esac
        :
    )
    assert_clean "$key 写入失败"
done
reset

# 完整菜单交互的最后端口输入与任意前置输入 EOF 不能套默认继续。
for key in A3 A5; do
    reset
    if [[ $key == A3 ]]; then
        input=$(printf '%s\n%s\ntuic.example.test\n' "$work/good.crt" "$work/good.key")
    else
        input=$(printf 'dest.example.test\ndest.example.test\n')
    fi
    printf '%s' "$input" | toolbox_network "$key" install >/dev/null 2>&1 && fail "$key 端口 EOF 仍安装"
    assert_clean "$key 端口 EOF"
done
reset

# Extra ordinary commands must be checked before CPU/certificate/ownership
# probes; accepted dependency installation resumes this call at the same gate.
(
    net_dep_trace=$work/network-dependency.trace
    command() {
        if [[ ${1:-} == -v ]]; then
            [[ ${2:-} != "${NET_MISSING_CAPABILITY:-}" ]] || return 1
            [[ " ${NET_MISSING:-} " != *" ${2:-} "* || ${NET_DEPS_READY:-0} == 1 ]] || return 1
            return 0
        fi
        builtin command "$@"
    }
    _toolbox_deps_exec() {
        printf 'package:%s\n' "$*" >> "$net_dep_trace"
        [[ ${1:-} == apt-get ]] || return 99
        case ${2:-} in update) return 0;; install) NET_DEPS_READY=1;; *) return 99;; esac
    }
    net_require_root() { :; }
    net_require_debian() { :; }
    net_tuic_arch() { printf 'next-gate\n' >> "$net_dep_trace"; return 71; }
    net_alpine_arch() { printf 'next-gate\n' >> "$net_dep_trace"; return 71; }
    net_prompt() { printf 'next-gate\n' >> "$net_dep_trace"; return 71; }
    for entry in A3 A5 B31; do
        case $entry in
            A3) added='uname grep date cut tr readlink cp chmod install dirname cat rm sleep';;
            A5) added='uname grep readlink cp chmod mkdir mv rm rmdir dirname cat sleep';;
            B31) added='grep cut readlink cat chmod rm sleep';;
        esac
        for dependency in $added; do
            : > "$net_dep_trace"; NET_MISSING=$dependency; NET_DEPS_READY=0
            toolbox_network "$entry" install <<< n > "$work/net-deps.out" 2>&1 && fail "$entry accepted missing $dependency"
            [[ $(<"$work/net-deps.out") == *"网络服务 缺少命令：$dependency"* && ! -s $net_dep_trace ]] || fail "$entry reached a probe before dependency $dependency"
        done
        : > "$net_dep_trace"; NET_MISSING=$added; NET_DEPS_READY=0
        toolbox_network "$entry" install <<< y > "$work/net-deps.out" 2>&1 && fail "$entry mocked next gate ignored"
        [[ $(<"$net_dep_trace") == *$'package:apt-get install '*$'\nnext-gate' ]] || fail "$entry dependency install did not resume same call"
    done
    # The kernel reader precedes B12's build-tool check; version refusal stays.
    unset TOOLBOX_NET_KERNEL_RELEASE
    uname() { printf 'kernel-read\n' >> "$net_dep_trace"; printf '5.4.0-fixture\n'; }
    : > "$net_dep_trace"; NET_MISSING=uname; NET_DEPS_READY=0
    net_brutal_require_kernel <<< n > "$work/net-deps.out" 2>&1 && fail 'B12 missing uname accepted'
    [[ ! -s $net_dep_trace && $(<"$work/net-deps.out") == *'缺少命令：uname'* ]] || fail 'B12 missing uname misreported kernel version'
    net_brutal_require_kernel <<< y > "$work/net-deps.out" 2>&1 && fail 'B12 dependency install bypassed old kernel'
    [[ $(<"$net_dep_trace") == *$'\nkernel-read' && $(<"$work/net-deps.out") == *'过旧'* ]] || fail 'B12 did not resume original kernel gate'
    for dependency in awk grep tr cut cp chmod rm rmmod install dirname; do
        : > "$net_dep_trace"; NET_MISSING=$dependency; NET_DEPS_READY=0
        net_brutal_require_toolchain <<< n > "$work/net-deps.out" 2>&1 && fail "B12 omitted $dependency"
        [[ ! -s $net_dep_trace ]] || fail 'B12 declined dependency reached package execution'
    done
    # No installation means no package request for uninstall/status.
    for entry in A3 A5 B31 B12; do
        for action in uninstall status; do
            : > "$net_dep_trace"; NET_MISSING='grep flock rm sed ss readlink cut uname lsmod awk sysctl tr'; NET_DEPS_READY=0
            toolbox_network "$entry" "$action" <<< n > "$work/net-deps.out" 2>&1 && fail "$entry absent installation returned success"
            [[ ! -s $net_dep_trace ]] || fail "$entry absent installation requested packages"
        done
    done
    mkdir -p "$(net_brutal_etc)"
    printf 'ExecStart=%s\n' "$(net_tuic_bin)" > "$(net_tuic_unit)"
    printf 'ExecStart=%s\n' "$(net_a5_bin)" > "$(net_a5_unit)"
    printf 'ExecStart=%s -d -d TCP-LISTEN:18443,fork,reuseaddr TCP:example.test:8443\n' \
        "$(net_relay_socat)" > "$(net_relay_unit tcp 18443)"
    for entry in A3 A5 B31 B12; do
        if [[ $entry == B12 ]]; then added='flock sysctl tr rmmod sleep lsmod awk grep rm dkms depmod uname'
        else added='grep flock rm'; fi
        for dependency in $added; do
            : > "$net_dep_trace"; NET_MISSING=$dependency; NET_DEPS_READY=0
            toolbox_network "$entry" uninstall <<< n > "$work/net-deps.out" 2>&1 && fail "$entry uninstall accepted missing $dependency"
            [[ $(<"$work/net-deps.out") == *"网络服务 缺少命令：$dependency"* && ! -s $net_dep_trace ]] || fail "$entry uninstall misreported missing $dependency"
        done
        : > "$net_dep_trace"; NET_MISSING=$added; NET_DEPS_READY=0
        toolbox_network "$entry" uninstall <<< $'y\nn' > "$work/net-deps.out" 2>&1 && fail "$entry package y replaced uninstall confirmation"
        [[ $(<"$work/net-deps.out") == *'确认执行'* ]] || fail "$entry did not retain uninstall confirmation"
        case $entry in
            A3|A5) added='sed ss readlink grep cut';;
            B31) added='sed ss';;
            B12) added='uname lsmod awk grep sysctl tr';;
        esac
        for dependency in $added; do
            : > "$net_dep_trace"; NET_MISSING=$dependency; NET_DEPS_READY=0
            toolbox_network "$entry" status <<< n > "$work/net-deps.out" 2>&1 && fail "$entry status accepted missing reader"
            [[ $(<"$work/net-deps.out") == *'状态读取不完整'* && ! -s $net_dep_trace ]] || fail "$entry status misreported missing $dependency"
        done
        if [[ $entry != B12 ]]; then
            : > "$net_dep_trace"; NET_MISSING=$added; NET_MISSING_CAPABILITY=systemctl
            toolbox_network "$entry" status <<< y > "$work/net-deps.out" 2>&1 && fail "$entry status accepted missing systemctl"
            [[ $(<"$work/net-deps.out") == *'未找到 systemctl'* && $(<"$work/net-deps.out") != *'缺少命令'* && ! -s $net_dep_trace ]] || fail "$entry status confused missing init with state or ordinary dependencies"
            NET_MISSING_CAPABILITY=''
            TOOLBOX_NET_SYSTEMD_RUN=$work/no-systemd toolbox_network "$entry" status <<< y > "$work/net-deps.out" 2>&1 && fail "$entry status accepted inactive init"
            [[ $(<"$work/net-deps.out") == *'systemd 未作为 init 运行'* && ! -s $net_dep_trace ]] || fail "$entry status did not preserve init gate"
        fi
    done
)
reset
[[ ! -e $NETWORK_TEST_MARKER ]] || fail '命中了真实命令兜底拒绝桩'
printf 'network tests passed\n'
