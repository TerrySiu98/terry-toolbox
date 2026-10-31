#!/usr/bin/env bash
# Isolated dependency tests: every package-manager call is a shell mock, PATH
# contains only fixture commands during checks, and Docker is never contacted.
set -euo pipefail
deps_test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
deps_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-dependencies.XXXXXXXX")
trap 'rm -rf -- "$deps_test_dir"' EXIT
source "$deps_test_root/modules/dependencies.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_stderr() { [[ $(< "$deps_test_dir/stderr") == *"$1"* ]] || fail "missing stderr: $1"; }
assert_log() { [[ $(< "$deps_test_dir/manager.log") == *"$1"* ]] || fail "missing manager call: $1"; }
assert_untouched() {
    [[ ! -s $deps_test_dir/manager.log ]] || fail 'package manager ran unexpectedly'
    [[ ! -s $deps_test_dir/stdout ]] || fail 'dependency output polluted stdout'
}
make_command() {
    printf '#!/bin/sh\nexit 0\n' > "$deps_test_dir/bin/$1"
    chmod 755 "$deps_test_dir/bin/$1"
}
reset_case() {
    rm -rf -- "$deps_test_dir/bin"
    mkdir "$deps_test_dir/bin"
    : > "$deps_test_dir/manager.log"
    : > "$deps_test_dir/root.log"
    : > "$deps_test_dir/stdout"
    : > "$deps_test_dir/stderr"
    : > "$deps_test_dir/docker.log"
    : > "$deps_test_dir/hash.log"
    : > "$deps_test_dir/ca.log"
    printf 'ID=debian\n' > "$deps_test_dir/os-release"
    export TOOLBOX_OS_RELEASE="$deps_test_dir/os-release"
    MOCK_COMMANDS=(virt-what)
    MOCK_ROOT_OK=1 MOCK_FAIL_UPDATE=0 MOCK_FAIL_INSTALL=0 MOCK_SKIP_COMMAND=''
    MOCK_REMOVE_COMMAND='' MOCK_DOCKER_FAIL=0 MOCK_DOCKER_CONFIRM=0
    MOCK_KERNEL_RELEASE=6.1.0-42-arm64 MOCK_HEADERS_INSTALL=0
    MOCK_HEADERS_BUILD="$deps_test_dir/headers/build"
    MOCK_CA_STATUS=installed MOCK_CA_READBACK_FAIL=0
    rm -rf -- "$deps_test_dir/headers"
}
# Confirm the real root boundary before replacing it for portable host tests.
if [[ $EUID == 0 ]]; then
    _toolbox_deps_root || fail 'actual root refused'
elif _toolbox_deps_root 2> "$deps_test_dir/root-denial"; then
    fail 'non-root accepted by production root boundary'
fi
_toolbox_deps_root() {
    printf 'root\n' >> "$deps_test_dir/root.log"
    [[ $MOCK_ROOT_OK == 1 ]] || { _toolbox_deps_error '补装依赖需要 root；未执行安装。'; return 1; }
}
# Test the actual _toolbox_deps_exec wrapper, including its stdin/stdout routing.
mock_install() {
    local c
    for c in "${MOCK_COMMANDS[@]}"; do
        [[ $c != "$MOCK_SKIP_COMMAND" ]] || continue
        printf '#!/bin/sh\nexit 0\n' > "$deps_test_dir/bin/$c"
        /bin/chmod 755 "$deps_test_dir/bin/$c"
    done
    [[ -z $MOCK_REMOVE_COMMAND ]] || /bin/rm -f -- "$deps_test_dir/bin/$MOCK_REMOVE_COMMAND"
}
mock_manager() {
    local manager=$1 swallowed=''
    shift
    if [[ $manager == apk && $1 == info ]]; then
        printf '%s\n' "$manager $*" >> "$deps_test_dir/ca.log"
        case $MOCK_CA_STATUS in installed) return 0;; absent) return 1;; *) return 2;; esac
    fi
    printf '%s %s\n' "$manager" "$*" >> "$deps_test_dir/manager.log"
    printf 'manager stdout\n'
    printf 'manager stderr\n' >&2
    if IFS= read -r swallowed; then
        printf 'SWALLOWED %s\n' "$swallowed" >> "$deps_test_dir/manager.log"
        return 90
    fi
    case $manager:$1 in
        apt-get:update) [[ $MOCK_FAIL_UPDATE == 0 ]];;
        apt-get:install|apk:add)
            [[ $MOCK_FAIL_INSTALL == 0 ]] || return 42
            if [[ " $* " == *' ca-certificates '* && $MOCK_CA_READBACK_FAIL == 0 ]]; then MOCK_CA_STATUS=installed; fi
            if [[ $MOCK_HEADERS_INSTALL == 1 ]]; then
                /bin/mkdir -p "$MOCK_HEADERS_BUILD"
                printf '# kernel Makefile fixture\n' > "$MOCK_HEADERS_BUILD/Makefile"
            fi
            mock_install;;
        *) fail "unexpected package-manager operation: $manager $*";;
    esac
}
apt-get() { [[ ${DEBIAN_FRONTEND:-} == noninteractive ]] || fail 'apt can prompt'; mock_manager apt-get "$@"; }
apk() { mock_manager apk "$@"; }
dpkg-query() {
    printf '%s\n' "dpkg-query $*" >> "$deps_test_dir/ca.log"
    case $MOCK_CA_STATUS in
        installed) printf 'install ok installed';;
        absent) return 1;;
        config-files) printf 'deinstall ok config-files';;
        *) return 2;;
    esac
}
hash() { printf '%s\n' "$*" >> "$deps_test_dir/hash.log"; builtin hash "$@"; }
run_require() {
    PATH="$deps_test_dir/bin" toolbox_require_commands '测试功能' "$@" > "$deps_test_dir/stdout" 2> "$deps_test_dir/stderr"
}
_toolbox_system_docker() {
    printf 'B1\n' >> "$deps_test_dir/docker.log"
    printf 'B1 stdout\n'
    [[ $MOCK_DOCKER_FAIL == 0 ]] || return 42
    if [[ $MOCK_DOCKER_CONFIRM == 1 ]]; then
        local first second
        IFS= read -r first && IFS= read -r second && [[ $first == YES && $second == YES ]] || return 1
    fi
    mock_install
}
run_docker() {
    PATH="$deps_test_dir/bin" toolbox_require_docker 'Docker功能' > "$deps_test_dir/stdout" 2> "$deps_test_dir/stderr"
}
toolbox_network_detect_os() { printf 'debian\n'; }

# Existing commands need no OS, root, confirmation, refresh or install.
reset_case
TOOLBOX_OS_RELEASE="$deps_test_dir/absent"
MOCK_ROOT_OK=0
run_require printf </dev/null || fail 'existing shell builtin refused'
assert_untouched
[[ ! -s $deps_test_dir/root.log && ! -s $deps_test_dir/hash.log ]] || fail 'existing command checked root/refreshed cache'
reset_case
make_command virt-what
run_require virt-what </dev/null || fail 'existing executable refused'
assert_untouched

# A single exact affirmative consumes one line; package manager cannot eat the
# next answer. Package output stays on stderr even under command substitution.
for affirmative in y Y yes YES; do
    reset_case
    {
        captured=$(PATH="$deps_test_dir/bin" toolbox_require_commands 'M3 重装预检' virt-what virt-what 2> "$deps_test_dir/stderr") || fail "affirmative failed: $affirmative"
        IFS= read -r next_answer || fail 'next feature answer missing'
    } <<< "$affirmative
NEXT_FEATURE_ANSWER"
    [[ -z $captured && $next_answer == NEXT_FEATURE_ANSWER ]] || fail 'stdout/stdin contaminated'
    assert_log 'apt-get update -o APT::Update::Error-Mode=any'
    assert_log 'apt-get install -y --no-upgrade --no-install-recommends -- virt-what'
    [[ $(< "$deps_test_dir/manager.log") != *'virt-what virt-what'* ]] || fail 'duplicate package not deduplicated'
    [[ $(< "$deps_test_dir/manager.log") != *SWALLOWED* ]] || fail 'package manager swallowed answer'
    assert_stderr 'manager stdout'
    assert_stderr 'manager stderr'
    assert_stderr '命令回读通过'
    [[ $(< "$deps_test_dir/hash.log") == '-r' ]] || fail 'command cache not refreshed'
done

for denial in n N no NO '' ' yes' 'yes ' YeS; do
    reset_case
    if run_require virt-what <<< "$denial"; then fail "non-affirmative accepted: $denial"; fi
    assert_untouched
    assert_stderr '已取消补装'
done
reset_case
if run_require virt-what </dev/null; then fail 'EOF accepted'; fi
assert_untouched
assert_stderr 'EOF'
reset_case
# An unterminated y followed by EOF is not a complete affirmative line.
if printf y | run_require virt-what; then fail 'partial input at EOF accepted'; fi
assert_untouched

# Apt updates once and deduplicates the packages shared by many commands.
reset_case
printf 'ID="ubuntu"\n' > "$TOOLBOX_OS_RELEASE"
MOCK_COMMANDS=(cp mv sha256sum ssh-keygen ss cpio dmidecode python3)
run_require "${MOCK_COMMANDS[@]}" <<< y || fail 'Ubuntu dependencies failed'
assert_log 'apt-get install -y --no-upgrade --no-install-recommends -- coreutils openssh-client iproute2 cpio dmidecode python3'
[[ ! -s $deps_test_dir/stdout ]] || fail 'install wrote stdout'

# Alpine: required util-linux, networking and OpenSSH providers are split.
reset_case
printf "ID='alpine'\n" > "$TOOLBOX_OS_RELEASE"
MOCK_COMMANDS=(virt-what lsblk findmnt flock blkid lsmem fdisk mkswap swapon swapoff mountpoint ss ip tc ssh-keygen free)
run_require "${MOCK_COMMANDS[@]}" <<< yes || fail 'Alpine dependencies failed'
assert_log 'apk add --no-cache -- virt-what lsblk findmnt flock blkid util-linux-misc iproute2-ss iproute2-minimal iproute2-tc openssh-keygen procps-ng'
[[ $(< "$deps_test_dir/manager.log") != *apt-get* ]] || fail 'Alpine invoked apt'
[[ ! -s $deps_test_dir/stdout ]] || fail 'apk wrote stdout'

# B8 passwd uses the distro provider and retains the ordinary consent/readback
# contract. Existing BusyBox/packaged passwd never triggers installation.
for distro in debian ubuntu alpine; do
    if [[ $distro == alpine ]]; then provider=shadow; else provider=passwd; fi
    for result in declined install-failed no-readback installed present; do
        reset_case
        printf 'ID=%s\n' "$distro" > "$TOOLBOX_OS_RELEASE"
        MOCK_COMMANDS=(passwd)
        case $result in
            declined)
                if run_require passwd <<< n; then fail "$distro passwd accepted refusal"; fi
                assert_untouched;;
            install-failed)
                MOCK_FAIL_INSTALL=1
                if run_require passwd <<< y; then fail "$distro passwd ignored install failure"; fi;;
            no-readback)
                MOCK_SKIP_COMMAND=passwd
                if run_require passwd <<< y; then fail "$distro passwd ignored missing readback"; fi
                assert_stderr 'passwd';;
            installed)
                run_require passwd <<< y || fail "$distro passwd install failed"
                assert_stderr '命令回读通过';;
            present)
                make_command passwd
                run_require passwd </dev/null || fail "$distro existing passwd refused"
                assert_untouched;;
        esac
        case $result in
            install-failed|no-readback|installed)
                if [[ $distro == alpine ]]; then assert_log "apk add --no-cache -- $provider"
                else assert_log "apt-get install -y --no-upgrade --no-install-recommends -- $provider"; fi;;
        esac
    done
done

# HTTPS tools include an absent CA package in the same confirmation and read it
# back. Existing CA packages and explicit trust paths are not repaired/replaced.
for distro in debian alpine; do
    reset_case
    printf 'ID=%s\n' "$distro" > "$TOOLBOX_OS_RELEASE"
    MOCK_COMMANDS=(curl wget openssl)
    MOCK_CA_STATUS=absent
    run_require "${MOCK_COMMANDS[@]}" <<< y || fail "missing CA package on $distro"
    assert_log '-- curl wget openssl ca-certificates'
    [[ $MOCK_CA_STATUS == installed ]] || fail 'CA package was not installed'
    [[ ! -s $deps_test_dir/stdout ]] || fail 'CA queries polluted stdout'
done
reset_case
MOCK_COMMANDS=(curl)
run_require curl <<< y || fail 'curl with installed CA package failed'
[[ $(< "$deps_test_dir/manager.log") != *ca-certificates* ]] || fail 'existing CA package reinstalled'
reset_case
MOCK_COMMANDS=(curl)
MOCK_CA_STATUS=absent
if run_require curl <<< n; then fail 'declined CA install accepted'; fi
assert_untouched
assert_stderr 'curl ca-certificates'
reset_case
MOCK_COMMANDS=(curl)
MOCK_CA_STATUS=absent MOCK_CA_READBACK_FAIL=1
if run_require curl <<< y; then fail 'missing CA package after install ignored'; fi
assert_stderr 'ca-certificates 包状态回读失败'
reset_case
MOCK_COMMANDS=(openssl)
MOCK_CA_STATUS=error
if run_require openssl <<< y; then fail 'unknown CA package status accepted'; fi
assert_untouched
assert_stderr '无法可靠确认 ca-certificates'
reset_case
if ( unset -f dpkg-query; run_require curl <<< y ); then fail 'missing CA query tool accepted'; fi
assert_untouched
assert_stderr '缺少 dpkg-query'
reset_case
MOCK_COMMANDS=(curl openssl)
MOCK_CA_STATUS=absent
printf 'custom trust anchors\n' > "$deps_test_dir/custom-ca"
(
    export CURL_CA_BUNDLE="$deps_test_dir/custom-ca" SSL_CERT_FILE="$deps_test_dir/custom-ca"
    export SSL_CERT_DIR="$deps_test_dir/custom-ca-dir" REQUESTS_CA_BUNDLE="$deps_test_dir/custom-ca"
    export TOOLBOX_NET_CAFILE='' TOOLBOX_NET_CAPATH="$deps_test_dir/custom-ca-dir"
    export TOOLBOX_HY2_CAFILE="$deps_test_dir/custom-ca" TOOLBOX_HY2_CAPATH=''
    run_require curl openssl <<< y || fail 'CA override dependency install failed'
    [[ $CURL_CA_BUNDLE == "$deps_test_dir/custom-ca" && $SSL_CERT_FILE == "$deps_test_dir/custom-ca" &&
       $REQUESTS_CA_BUNDLE == "$deps_test_dir/custom-ca" && $SSL_CERT_DIR == "$deps_test_dir/custom-ca-dir" &&
       $TOOLBOX_NET_CAFILE == '' && $TOOLBOX_NET_CAPATH == "$deps_test_dir/custom-ca-dir" &&
       $TOOLBOX_HY2_CAFILE == "$deps_test_dir/custom-ca" && $TOOLBOX_HY2_CAPATH == '' ]] || fail 'CA override changed'
)
[[ $(< "$deps_test_dir/custom-ca") == 'custom trust anchors' ]] || fail 'custom CA file changed'
assert_log '-- curl openssl ca-certificates'
reset_case
make_command curl
MOCK_CA_STATUS=absent
run_require curl </dev/null || fail 'existing curl unexpectedly required CA remediation'
[[ ! -s $deps_test_dir/ca.log ]] || fail 'existing commands queried CA package'
assert_untouched

# OS files are data, supported IDs are exact, and ambiguous IDs fail closed.
for metadata in 'ID=fedora' 'ID=unknown
ID_LIKE=debian' 'ID=debian
ID=alpine' 'PRETTY_NAME=debian'; do
    reset_case
    printf '%s\n' "$metadata" > "$TOOLBOX_OS_RELEASE"
    if run_require virt-what <<< y; then fail 'unsupported/ambiguous OS accepted'; fi
    assert_untouched
    assert_stderr '系统信息未知或不受支持'
done
reset_case
printf 'ID=$(touch "%s")\n' "$deps_test_dir/os-executed" > "$TOOLBOX_OS_RELEASE"
if run_require virt-what <<< y; then fail 'executable OS data accepted'; fi
[[ ! -e $deps_test_dir/os-executed ]] || fail 'os-release executed shell'
assert_untouched
reset_case
TOOLBOX_OS_RELEASE="$deps_test_dir/absent"
if run_require virt-what <<< y; then fail 'absent OS metadata accepted'; fi
assert_untouched
assert_stderr '无法读取系统信息'

# Missing/unknown commands never guess a package or partially install a batch.
reset_case
if run_require virt-what made-up-tool <<< y; then fail 'unknown command accepted'; fi
assert_untouched
assert_stderr '未定义 debian 上命令 made-up-tool 的软件包映射'
for protected in docker dockerd systemctl systemd-detect-virt journalctl resolvectl rc-service rc-status rc-update openrc-run init grub-mkconfig update-grub extlinux linux-headers-current apt-get apk; do
    reset_case
    # Package managers are mocked shell functions and therefore present; direct
    # package mapping below separately confirms they cannot be guessed.
    case $protected in apt-get|apk) continue;; esac
    if run_require virt-what "$protected" <<< y; then fail "protected dependency accepted: $protected"; fi
    assert_untouched
done
reset_case
if run_require '/usr/bin/curl' <<< y; then fail 'command path accepted'; fi
assert_untouched
if PATH="$deps_test_dir/bin" toolbox_require_commands '' curl > "$deps_test_dir/stdout" 2> "$deps_test_dir/stderr"; then fail 'blank feature accepted'; fi
assert_untouched
reset_case
MOCK_ROOT_OK=0
if run_require virt-what <<< y; then fail 'non-root install accepted'; fi
assert_untouched
assert_stderr '需要 root'

# Update failure must stop before install; failures never claim success.
reset_case
MOCK_FAIL_UPDATE=1
if run_require virt-what <<< y; then fail 'apt update failure accepted'; fi
[[ $(< "$deps_test_dir/manager.log") == 'apt-get update -o APT::Update::Error-Mode=any' ]] || fail 'install ran after update failure'
assert_stderr 'apt-get update 失败'
[[ ! -s $deps_test_dir/hash.log ]] || fail 'failed update claimed cache refresh'
reset_case
MOCK_FAIL_INSTALL=1
if run_require virt-what <<< y; then fail 'apt install failure accepted'; fi
assert_stderr 'apt-get install 失败'
reset_case
printf 'ID=alpine\n' > "$TOOLBOX_OS_RELEASE"
MOCK_FAIL_INSTALL=1
if run_require virt-what <<< y; then fail 'apk failure accepted'; fi
assert_stderr 'apk add 失败'
reset_case
MOCK_SKIP_COMMAND=virt-what
if run_require virt-what <<< y; then fail 'successful package manager hid missing command'; fi
assert_stderr '安装后仍缺少命令：virt-what'
reset_case
make_command curl
MOCK_REMOVE_COMMAND=curl
if run_require virt-what curl <<< y; then fail 'full requested list was not rechecked'; fi
assert_stderr '安装后仍缺少命令：curl'

# No manager in PATH: mocks are unset inside a subshell so no real host manager
# can be found even when the regression runs as root on Linux.
reset_case
if ( unset -f apt-get apk; run_require virt-what <<< y ); then fail 'missing manager accepted'; fi
assert_untouched
assert_stderr '未找到系统包管理器 apt-get'

# Package mappings that differ substantially between distributions.
while IFS=' ' read -r distro command provider; do
    [[ $(_toolbox_deps_package "$distro" "$command") == "$provider" ]] || fail "provider mismatch: $distro $command"
done <<'MAPPINGS'
debian certbot certbot
ubuntu nginx nginx
alpine certbot certbot
alpine getent musl-utils
debian getent libc-bin
alpine mount mount
debian mount mount
debian swapon mount
ubuntu swapoff mount
debian losetup mount
debian mkswap util-linux
alpine swapon util-linux-misc
debian logger bsdutils
debian uuidgen uuid-runtime
debian hostname hostname
debian domainname hostname
alpine hostname net-tools
alpine domainname net-tools
debian fdisk fdisk
debian hexdump bsdextrautils
debian dig bind9-dnsutils
alpine dig bind-tools
debian host bind9-host
alpine host bind-tools
debian ssh-keygen openssh-client
alpine ssh-keygen openssh-keygen
debian modprobe kmod
alpine modprobe kmod
debian dkms dkms
alpine gpg gnupg
debian gpgv gpgv
alpine gpgv gpgv
debian cc gcc
debian ar binutils
alpine unzip unzip
alpine ip6tables iptables
debian sha256sum coreutils
alpine xargs findutils
MAPPINGS
for unknown in made-up-tool grub-mkconfig systemctl rc-service linux-headers-current docker dockerd apt-get apk; do
    if _toolbox_deps_package debian "$unknown" >/dev/null; then fail "guessed package for $unknown"; fi
done

# Docker goes through B1 exactly once and keeps B1's original confirmations.
reset_case
make_command docker
MOCK_ROOT_OK=0
run_docker </dev/null || fail 'existing Docker refused'
[[ ! -s $deps_test_dir/root.log && ! -s $deps_test_dir/docker.log ]] || fail 'existing Docker invoked installer'
for denial in n ''; do
    reset_case
    if run_docker <<< "$denial"; then fail 'Docker denial accepted'; fi
    [[ ! -s $deps_test_dir/docker.log ]] || fail 'Docker ran after denial'
    assert_untouched
done
reset_case
if run_docker </dev/null; then fail 'Docker EOF accepted'; fi
[[ ! -s $deps_test_dir/docker.log ]] || fail 'Docker ran after EOF'
reset_case
MOCK_COMMANDS=(docker)
MOCK_DOCKER_CONFIRM=1
{
    run_docker || fail 'Docker B1 delegation failed'
    IFS= read -r next_answer || fail 'Docker ate next feature answer'
} <<< $'y\nYES\nYES\nNEXT_FEATURE_ANSWER'
[[ $next_answer == NEXT_FEATURE_ANSWER ]] || fail 'Docker changed next feature answer'
[[ $(< "$deps_test_dir/docker.log") == B1 ]] || fail 'Docker did not run B1 once'
assert_untouched
assert_stderr 'B1 stdout'
assert_stderr 'Docker 安装完成'
reset_case
MOCK_COMMANDS=(docker)
MOCK_DOCKER_CONFIRM=1
if run_docker <<< $'y\nno\nno'; then fail 'B1 refusal ignored'; fi
assert_stderr 'B1 Docker 安装未完成'
reset_case
MOCK_DOCKER_FAIL=1
if run_docker <<< y; then fail 'Docker B1 failure accepted'; fi
assert_stderr 'B1 Docker 安装未完成'
reset_case
MOCK_COMMANDS=(docker)
MOCK_SKIP_COMMAND=docker
if run_docker <<< y; then fail 'Docker readback failure accepted'; fi
assert_stderr '仍缺少 docker'

# Lazy loading must happen only after consent, using adjacent local modules.
# These adjacent fixtures only define mocks; the real B1 module is never loaded.
reset_case
mkdir "$deps_test_dir/lazy"
cp "$deps_test_root/modules/dependencies.sh" "$deps_test_dir/lazy/dependencies.sh"
cat > "$deps_test_dir/lazy/network.sh" <<'NETWORK'
printf 'network\n' >> "$deps_test_dir/lazy.log"
toolbox_network_detect_os() { printf 'debian\n'; }
NETWORK
cat > "$deps_test_dir/lazy/system.sh" <<'SYSTEM'
printf 'system\n' >> "$deps_test_dir/lazy.log"
_toolbox_system_docker() { printf 'B1\n' >> "$deps_test_dir/lazy.log"; mock_install; }
SYSTEM
(
    unset -f _toolbox_system_docker toolbox_network_detect_os
    cd "$deps_test_dir/lazy"
    source dependencies.sh
    cd "$deps_test_dir"
    _toolbox_deps_root() { :; }
    if run_docker <<< n; then fail 'lazy loader accepted refusal'; fi
    [[ ! -e $deps_test_dir/lazy.log ]] || fail 'loaded modules before consent'
    MOCK_COMMANDS=(docker)
    run_docker <<< y || fail 'lazy-loaded Docker installer failed'
    [[ $(< "$deps_test_dir/lazy.log") == $'network\nsystem\nB1' ]] || fail 'wrong lazy loading order'
)
assert_untouched
reset_case
: > "$deps_test_dir/lazy.log"
(
    # A caller can source system.sh alone; the network function must still be
    # independently loaded, without replacing its existing Docker installer.
    unset -f toolbox_network_detect_os
    cd "$deps_test_dir"
    export CDPATH="$deps_test_root"
    source lazy/dependencies.sh
    cd /
    _toolbox_deps_root() { :; }
    MOCK_COMMANDS=(docker)
    run_docker <<< y || fail 'preloaded B1 without network helper failed'
    [[ $(< "$deps_test_dir/lazy.log") == network ]] || fail 'system reloaded or network not loaded'
    [[ $(< "$deps_test_dir/docker.log") == B1 ]] || fail 'existing B1 installer not preserved'
)
assert_untouched
reset_case
: > "$deps_test_dir/lazy.log"
(
    # A standalone bundle never sources arbitrary adjacent network/system files.
    unset _TOOLBOX_DEPS_MODULE_DIR
    TOOLBOX_BUNDLED=1
    source "$deps_test_dir/lazy/dependencies.sh"
    _toolbox_deps_root() { :; }
    [[ -z ${_TOOLBOX_DEPS_MODULE_DIR:-} ]] || fail 'bundle captured a filesystem peer directory'
    unset -f toolbox_network_detect_os
    if run_docker <<< y; then fail 'incomplete bundle loaded local network'; fi
    [[ ! -s $deps_test_dir/lazy.log && ! -s $deps_test_dir/docker.log ]] || fail 'incomplete bundle invoked local code'
    assert_stderr '独立打包文件缺少 B1 函数'
)
assert_untouched

# Headers use only the matching running-kernel package, protect the next answer,
# and never install kernel images or guess a different release after a failure.
_toolbox_deps_kernel_release() { printf '%s\n' "$MOCK_KERNEL_RELEASE"; }
_toolbox_deps_kernel_build() { printf '%s\n' "$MOCK_HEADERS_BUILD"; }
run_headers() {
    PATH="$deps_test_dir/bin" toolbox_require_kernel_headers 'TCP Brutal' "$1" > "$deps_test_dir/stdout" 2> "$deps_test_dir/stderr"
}
reset_case
mkdir -p "$MOCK_HEADERS_BUILD"
printf '# headers\n' > "$MOCK_HEADERS_BUILD/Makefile"
MOCK_ROOT_OK=0
TOOLBOX_OS_RELEASE="$deps_test_dir/absent"
run_headers "$MOCK_KERNEL_RELEASE" </dev/null || fail 'existing kernel headers refused'
assert_untouched
[[ ! -s $deps_test_dir/root.log ]] || fail 'existing headers checked root'
for denial in n ''; do
    reset_case
    if run_headers "$MOCK_KERNEL_RELEASE" <<< "$denial"; then fail 'headers denial accepted'; fi
    assert_untouched
done
reset_case
if run_headers "$MOCK_KERNEL_RELEASE" </dev/null; then fail 'headers EOF accepted'; fi
assert_untouched
reset_case
if run_headers 6.1.0-incorrect <<< y; then fail 'headers for another kernel accepted'; fi
assert_untouched
assert_stderr '不一致'
reset_case
if run_headers '6.1/../../other' <<< y; then fail 'unsafe kernel release accepted'; fi
assert_untouched
reset_case
printf 'ID=alpine\n' > "$TOOLBOX_OS_RELEASE"
if run_headers "$MOCK_KERNEL_RELEASE" <<< y; then fail 'Alpine generic kernel headers install accepted'; fi
assert_untouched
reset_case
MOCK_ROOT_OK=0
if run_headers "$MOCK_KERNEL_RELEASE" <<< y; then fail 'non-root headers install accepted'; fi
assert_untouched
reset_case
MOCK_HEADERS_INSTALL=1
{
    run_headers "$MOCK_KERNEL_RELEASE" || fail 'matching kernel headers installation failed'
    IFS= read -r next_answer || fail 'headers install consumed next answer'
} <<< $'y\nNEXT_FEATURE_ANSWER'
[[ $next_answer == NEXT_FEATURE_ANSWER ]] || fail 'headers changed next answer'
assert_log 'apt-get install -y --no-upgrade --no-install-recommends -- linux-headers-6.1.0-42-arm64'
assert_stderr 'headers 补装完成'
[[ ! -s $deps_test_dir/stdout ]] || fail 'headers install polluted stdout'
reset_case
MOCK_FAIL_UPDATE=1
if run_headers "$MOCK_KERNEL_RELEASE" <<< y; then fail 'headers update failure ignored'; fi
[[ $(< "$deps_test_dir/manager.log") == 'apt-get update -o APT::Update::Error-Mode=any' ]] || fail 'headers installed after failed update'
reset_case
MOCK_FAIL_INSTALL=1
if run_headers "$MOCK_KERNEL_RELEASE" <<< y; then fail 'headers package failure ignored'; fi
assert_stderr '当前软件源可能没有此内核的 headers'
reset_case
if run_headers "$MOCK_KERNEL_RELEASE" <<< y; then fail 'missing headers Makefile after install ignored'; fi
assert_stderr '编译目录回读失败'
printf 'PASS: dependency installation, CA packages, refusal, failures, mapping, I/O, Docker/lazy loading and kernel headers\n'
