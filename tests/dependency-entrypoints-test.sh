#!/usr/bin/env bash
# Wiring only: package managers, Docker and embedded engines never run.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rc=$?; if [[ -s $work/packages.log ]]; then printf "FAIL: dependency wiring invoked an unmocked package command\n" >&2; cat "$work/packages.log" >&2; rc=1; fi; rm -rf -- "$work"; exit "$rc"' EXIT
trace=$work/trace
export trace TMPDIR=$work
mkdir "$work/deny"
: > "$work/packages.log"
for manager in sudo apt apt-get apt-cache aptitude apk dpkg dpkg-query dpkg-deb; do
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$0 $*" >> %q\n' "$work/packages.log"
        printf 'printf "UNMOCKED package boundary: %%s\\n" "$0" >&2\nexit 99\n'
    } > "$work/deny/$manager"
    chmod 0755 "$work/deny/$manager"
done
export PATH="$work/deny:$PATH"
# Each child has a fresh function table; the executable deny layer remains.
package_guard_probe='for manager in sudo apt apt-get apk dpkg; do [[ $(command -v "$manager") == "$1/$manager" ]] || exit 1; rc=0; "$manager" --fixture-guard-probe || rc=$?; [[ $rc == 99 ]] || exit 1; done'
bash --noprofile --norc -c "$package_guard_probe" guard "$work/deny" >/dev/null 2>&1
env -i PATH="$PATH" bash --noprofile --norc -c "$package_guard_probe" guard "$work/deny" >/dev/null 2>&1
[[ $(wc -l < "$work/packages.log") == 10 ]]
: > "$work/packages.log"
mkdir "$work/systemd"
printf 'ID=debian\n' > "$work/os-release"
export TOOLBOX_VM_WS_OS_RELEASE=$work/os-release TOOLBOX_VM_WS_SYSTEMD_RUN=$work/systemd
export TOOLBOX_TLS_ACME_OS_RELEASE=$work/os-release TOOLBOX_TLS_ACME_SYSTEMD_RUN=$work/systemd
for module in vmess tls-acme webssh-containers alpine-swap docker-ipv6; do source "$ROOT/modules/$module.sh"; done
fail() { printf 'FAIL dependency entrypoint: %s\n' "$*" >&2; cat "$trace" >&2; exit 1; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
reset() { : > "$trace"; MISSING=''; DEPENDENCY_RC=0; DOCKER_RC=0; }
seen() { grep -Fqx -- "$1" "$trace" || fail "missing trace $1"; }
absent() { ! grep -Fq -- "$1" "$trace" || fail "unexpected trace $1"; }
command() {
    if [[ $1 == -v ]]; then
        [[ " $MISSING " != *" $2 "* ]] || return 1
        printf '/fixture/bin/%s\n' "$2"; return 0
    fi
    builtin command "$@"
}
toolbox_require_commands() {
    local label=$1; shift
    printf 'require:%s:%s\n' "$label" "$*" >> "$trace"
    [[ $DEPENDENCY_RC == 0 ]] || return "$DEPENDENCY_RC"
    MISSING=''
}
toolbox_require_docker() {
    local dependency remaining=''
    printf 'docker-route:%s\n' "$1" >> "$trace"
    [[ $DOCKER_RC == 0 ]] || return "$DOCKER_RC"
    for dependency in $MISSING; do
        [[ $dependency == docker ]] || remaining="$remaining $dependency"
    done
    MISSING=$remaining
}
python3() { printf 'engine-python\n' >> "$trace"; }
_toolbox_alpine_swap_engine() { printf 'fixture engine\n'; }
_toolbox_docker_ipv6_engine() { printf 'import base64\n'; }
net_check_cert() { :; }; net_tls_trusted() { :; }
net_a5_zip_url() { :; }; net_a5_sha256() { :; }
vmess_arch() { printf amd64; }
tls_acme_fs() { printf 'tls-fs:%s\n' "$*" >> "$trace"; }
certbot() { printf 'certbot 2.1.0\n'; }

# Existing installations retain the prompt-free path; status stays minimal.
reset
vmess_dependencies python3 openssl
tls_acme_dependencies python3
wsc_dependencies
toolbox_alpine_swap status
toolbox_docker_ipv6 status
toolbox_tls_acme status
absent 'require:'; absent 'docker-route:'
seen 'tls-fs:status '
reset; MISSING='docker dockerd ip ss iptables ip6tables'
toolbox_docker_ipv6 status
absent 'require:'; absent 'docker-route:'; seen engine-python
reset; MISSING='python3 docker dockerd'
toolbox_docker_ipv6 status
seen 'require:B1 Docker IPv6:python3 cat'; absent 'docker-route:'

# Each missing set is batched before the embedded engine or filesystem gate.
reset; MISSING='python3 openssl'
vmess_dependencies python3 openssl curl
seen 'require:A5 VMess:python3 openssl curl'
[[ $(wc -l < "$trace") == 1 ]] || fail 'duplicate dependency request'
reset; MISSING='python3'
toolbox_tls_acme status
seen 'require:TLS 证书管理:python3'; seen 'tls-fs:status '
reset; MISSING='python3 mkswap'
toolbox_alpine_swap install 128
seen 'require:B19 Alpine swap:python3 cat flock dd mkswap swapon swapoff rc-service openrc-run'
seen engine-python
[[ $(head -n 1 "$trace") == require:* ]] || fail 'swap engine preceded consent'
reset; MISSING='python3 ss'
toolbox_docker_ipv6 apply
seen 'require:B1 Docker IPv6:python3 cat docker dockerd ip ss iptables ip6tables'
seen engine-python
[[ $(head -n 1 "$trace") == require:* ]] || fail 'IPv6 engine preceded consent'

# Declining or failing installation blocks every downstream resource operation.
for rc in 1 7; do
    for call in 'toolbox_alpine_swap status' 'toolbox_docker_ipv6 status' 'toolbox_tls_acme status' 'vmess_dependencies python3'; do
        reset; MISSING=python3; DEPENDENCY_RC=$rc
        reject $call
        absent engine-python; absent 'tls-fs:'
    done
done

# Docker must use the dedicated B1 installer, never the ordinary package route.
reset; MISSING=docker
wsc_dependencies
seen 'docker-route:B10 WebSSH 容器'
seen 'require:B10 WebSSH 容器:python3 ss flock mktemp'
[[ $(head -n 1 "$trace") == docker-route:* ]] || fail 'Docker route ordering'
reset; MISSING=docker
toolbox_docker_ipv6 apply
seen 'docker-route:B1 Docker IPv6'; seen engine-python
reset; MISSING='docker python3'
toolbox_docker_ipv6 apply
seen 'docker-route:B1 Docker IPv6'
seen 'require:B1 Docker IPv6:python3 cat docker dockerd ip ss iptables ip6tables'
seen engine-python
[[ $(head -n 1 "$trace") == docker-route:* ]] || fail 'IPv6 Docker route ordering'
reset; MISSING=dockerd; DEPENDENCY_RC=1
reject toolbox_docker_ipv6 apply
seen 'require:B1 Docker IPv6:python3 cat docker dockerd ip ss iptables ip6tables'
absent 'docker-route:'; absent engine-python
for call in 'wsc_dependencies' 'toolbox_docker_ipv6 apply'; do
    reset; MISSING=docker; DOCKER_RC=1
    reject $call
    absent 'require:'; absent engine-python
done

# Platform/program checks still run after successful dependency preparation.
if (( EUID == 0 )); then
    reset; MISSING=python3
    vmess_require; seen engine-python
    reset; MISSING=python3; DEPENDENCY_RC=1
    reject vmess_require; absent engine-python
    reset; MISSING=certbot
    tls_acme_require
    seen "tls-fs:platform $work/os-release $work/systemd"
    seen 'tls-fs:program /fixture/bin/certbot'
    reset; MISSING=certbot
    certbot() { printf 'certbot development\n'; }
    reject tls_acme_require; absent 'tls-fs:program'
    (
        reset; MISSING=python3; DEPENDENCY_RC=1
        mktemp() { printf 'wsc-probe\n' >> "$trace"; return 1; }
        wsc_local_gate() { printf 'wsc-gate\n' >> "$trace"; return 1; }
        reject toolbox_webssh_container personal status
        seen 'require:B10 WebSSH 容器:python3 ss flock mktemp'
        absent wsc-probe; absent wsc-gate
    )
fi
reset
docker() {
    case "$*" in
        'context show') printf 'default\n';;
        'context inspect default --format {{.Endpoints.docker.Host}}') printf 'unix:///var/run/docker.sock\n';;
        *) fail 'unexpected Docker operation';;
    esac
}
wsc_docker() { [[ $1 == version ]] || fail 'old version reached daemon info'; printf '27.5.1\n'; }
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION
reject wsc_local_gate
absent 'require:'; absent 'docker-route:'

# System dependency preparation must precede sysctl reads and service writes.
(
    source "$ROOT/modules/system.sh"
    _toolbox_system_root() { :; }
    _toolbox_system_os() { printf 'debian\n'; }
    _toolbox_system_systemd() { :; }
    sysctl() { printf 'sysctl-read\n' >> "$trace"; printf 'bbr\n'; }
    for action in _toolbox_system_bbr _toolbox_system_netopt_apply _toolbox_system_netopt_rollback; do
        reset; MISSING=sysctl; DEPENDENCY_RC=1
        reject "$action"
        seen 'require:系统工具:sysctl'; absent sysctl-read
    done
    reset; MISSING=sysctl
    _toolbox_system_bbr >/dev/null
    seen 'require:系统工具:sysctl'; seen sysctl-read
    [[ $(head -n 1 "$trace") == require:* ]] || fail 'BBR read preceded dependencies'
    reset; MISSING=hostname; DEPENDENCY_RC=1
    reject _toolbox_system_tg
    seen 'require:系统工具:hostname'

    # B7 completes only dependency preparation here. The test stops before any
    # real filesystem transaction while checking consent order and input use.
    _toolbox_system_timer_preflight() { printf 'traffic-preflight\n' >> "$trace"; return "${CONFLICT:-0}"; }
    _toolbox_system_timer_begin() { printf 'traffic-transaction\n' >> "$trace"; return 1; }
    _toolbox_system_traffic_cleanup() { :; }
    _toolbox_system_vnstat_json_ok() { :; }
    systemctl() { printf 'traffic-service:%s\n' "$*" >> "$trace"; }
    install() { printf 'traffic-directory\n' >> "$trace"; }
    toolbox_require_commands() {
        local answer
        printf 'require:%s:%s\n' "$1" "${*:2}" >> "$trace"
        IFS= read -r answer && [[ $answer == y ]] || return 1
        MISSING=''
    }
    reset; MISSING=vnstat; CONFLICT=1
    reject _toolbox_system_traffic </dev/null
    seen traffic-preflight; absent require:; absent traffic-service:
    CONFLICT=0
    reset; MISSING=vnstat
    reject _toolbox_system_traffic <<< $'n\n2\nYES\nYES'
    absent traffic-service:; absent traffic-directory
    reset; MISSING=vnstat
    reject _toolbox_system_traffic <<< $'y\n2\nYES\nNO'
    seen 'require:系统工具:vnstat'; absent traffic-service:; absent traffic-directory
    reset; MISSING=vnstat
    reject _toolbox_system_traffic <<< $'y\n2\nYES\nYES'
    seen 'traffic-service:enable --now vnstat'; seen traffic-transaction
    [[ $(head -n 1 "$trace") == traffic-preflight ]] || fail 'B7 dependencies preceded conflict gate'
    [[ $(grep -c '^require:' "$trace") == 1 ]] || fail 'B7 duplicate dependency confirmation'

    # Package consent alone never authorizes B15's explicit service enable/start.
    hostname() { printf 'fixture-host\n'; }
    _toolbox_system_tg_cleanup() { :; }
    for input in y $'y\n123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-1001234567890\nYES\nNO'; do
        reset; MISSING=vnstat
        reject _toolbox_system_tg <<< "$input"
        seen 'require:系统工具:vnstat'
        absent traffic-service:; absent traffic-directory; absent traffic-transaction
    done
    reset; MISSING=vnstat; CONFLICT=1
    reject _toolbox_system_tg <<< $'y\n123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-1001234567890\nYES\nYES'
    absent traffic-service:; absent traffic-directory; absent traffic-transaction
    CONFLICT=0
    reset; MISSING=vnstat
    reject _toolbox_system_tg <<< $'y\n123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-1001234567890\nYES\nYES'
    seen traffic-transaction; absent traffic-service:
    _toolbox_system_timer_begin() { printf 'traffic-transaction\n' >> "$trace"; return 0; }
    _toolbox_system_put() { builtin command cat >/dev/null; return 1; }
    reset; MISSING=vnstat
    reject _toolbox_system_tg <<< $'y\n123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-1001234567890\nYES\nYES'
    seen 'traffic-service:enable --now vnstat'
    [[ $(grep -n '^traffic-transaction$' "$trace" | cut -d: -f1) -lt $(grep -n '^traffic-service:' "$trace" | cut -d: -f1) ]] || fail 'B15 service preceded ownership transaction'
)

# Distro detection uses shell builtins before sed/head can be installed. Init
# absence remains a hard prerequisite even when its runtime directory exists.
for module in network hy2 webssh; do
    (
        source "$ROOT/modules/$module.sh"
        export TOOLBOX_NET_OS_RELEASE=$work/os-release TOOLBOX_NET_SYSTEMD_RUN=$work/systemd
        export TOOLBOX_HY2_OS_RELEASE=$work/os-release TOOLBOX_HY2_SYSTEMD_RUN=$work/systemd
        export TOOLBOX_WEBSSH_OS_RELEASE=$work/os-release TOOLBOX_WEBSSH_SYSTEMD_RUN=$work/systemd
        sed() { fail 'distro detection used missing sed'; }
        head() { fail 'distro detection used missing head'; }
        case $module in network) prefix=net;; *) prefix=$module;; esac
        reset; MISSING='sed head'
        "${prefix}_require_debian"
        reset; MISSING=systemctl
        reject "${prefix}_require_systemd"
        absent require:
        if [[ $module == webssh ]]; then
            reset; MISSING=python3
            webssh_require_python
            seen 'require:WebSSH:python3'; seen engine-python
            reset; MISSING=python3; DEPENDENCY_RC=1
            reject webssh_require_python
            absent engine-python
            reset
            python3() { [[ ${1-} == --version ]] && printf 'Python 3.9.2\n'; return 1; }
            reject webssh_require_python
            absent require:
        fi
        if [[ $module == network ]]; then
            mkdir "$work/headers"
            export TOOLBOX_NET_KERNEL_RELEASE=6.1.0-fixture TOOLBOX_NET_MODDIR=$work/headers
            reset
            reject net_brutal_require_kernel
            absent require:
            printf '# fixture headers\n' > "$work/headers/Makefile"
            net_brutal_require_kernel
            absent require:
        fi
    )
done

# Standalone source stays inert, handles basename and relative paths, and keeps
# its adjacent core after cd. Each subprocess has an isolated function table.
mkdir "$work/modules"
modules=(system network hy2 webssh apps diagnostics vmess tls-acme webssh-containers alpine-swap docker-ipv6)
for module in "${modules[@]}"; do cp "$ROOT/modules/$module.sh" "$work/modules/"; done
cat > "$work/modules/dependencies.sh" <<'CORE'
printf 'core-loaded\n' >> "$trace"
toolbox_require_commands() { printf 'lazy-require\n' >> "$trace"; return 1; }
toolbox_require_docker() { printf 'lazy-docker\n' >> "$trace"; return 1; }
CORE
for module in "${modules[@]}"; do
    for mode in absolute basename relative bundle; do
        (
            reset
            unset -f toolbox_require_commands toolbox_require_docker
            unset TOOLBOX_BUNDLED
            export CDPATH=$work/unused
            case $mode in
                absolute) source "$work/modules/$module.sh";;
                basename) cd "$work/modules"; source "$module.sh";;
                relative) cd "$work"; source "modules/$module.sh";;
                bundle) TOOLBOX_BUNDLED=1; source "$work/modules/$module.sh";;
            esac
            [[ ! -s $trace ]] || fail 'source performed dependency work'
            cd /
            MISSING=python3
            case $module in
                system) reject _toolbox_system_need_tools python3;;
                network) reject net_require_cmds python3;;
                hy2) MISSING=curl; reject hy2_require_tools;;
                webssh) reject webssh_require_tools;;
                apps) MISSING=docker; reject toolbox_app 3;;
                diagnostics)
                    MISSING=ss
                    uname() { :; }; uptime() { :; }; free() { :; }; df() { :; }; ip() { :; }; netstat() { :; }
                    toolbox_diagnostics >/dev/null;;
                vmess) reject vmess_dependencies python3;;
                tls-acme) reject toolbox_tls_acme status;;
                webssh-containers) reject wsc_dependencies;;
                alpine-swap) reject toolbox_alpine_swap status;;
                docker-ipv6) reject toolbox_docker_ipv6 status;;
            esac
            if [[ $mode == bundle ]]; then
                absent core-loaded; absent lazy-require; absent lazy-docker
            else
                seen core-loaded
                if [[ $module == apps ]]; then seen lazy-docker; else seen lazy-require; fi
            fi
            absent engine-python
        )
    done
done
printf 'PASS dependency entrypoints: batching, rejection, minimal status, Docker route, sysctl, B7 ordering, retained gates, source directories\n'
