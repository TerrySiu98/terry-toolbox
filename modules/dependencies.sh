#!/usr/bin/env bash
# Source-only dependency support. No package operation runs until a caller asks
# for missing commands and the operator confirms. Compatible with Bash 3.2+.
# Public: toolbox_require_commands 'feature' cmd...; toolbox_require_docker 'feature';
# toolbox_require_kernel_headers 'feature' running-release.
# Return 0 only after command readback, 1 on refusal/failure, 2 for bad arguments.

# Anchor lazy loading at source time; BASH_SOURCE may be a basename and the
# caller may change directory before requesting Docker. Bundles have no peers.
if [[ ${TOOLBOX_BUNDLED:-0} != 1 ]]; then
    _TOOLBOX_DEPS_MODULE_DIR=${BASH_SOURCE[0]%/*}
    [[ $_TOOLBOX_DEPS_MODULE_DIR != "${BASH_SOURCE[0]}" ]] || _TOOLBOX_DEPS_MODULE_DIR=.
    _TOOLBOX_DEPS_MODULE_DIR=$(CDPATH= builtin cd -- "$_TOOLBOX_DEPS_MODULE_DIR" && builtin pwd -P) || return 1
fi

_toolbox_deps_error() { printf '%s\n' "$*" >&2; }
_toolbox_deps_has() { command -v "$1" >/dev/null 2>&1; }
_toolbox_deps_root() {
    [[ ${EUID:-$(id -u)} == 0 ]] || {
        _toolbox_deps_error '补装依赖需要 root；未执行安装。'; return 1;
    }
}
_toolbox_deps_exec() {
    # Package managers must not consume the caller's next menu/feature answer.
    # stdout also belongs on stderr: callers may themselves capture stdout.
    "$@" </dev/null >&2
}
_toolbox_deps_os() {
    local file=${TOOLBOX_OS_RELEASE:-/etc/os-release} line value id='' count=0
    [[ -f $file && -r $file ]] || {
        _toolbox_deps_error "无法读取系统信息：${file}；未执行安装。"; return 1;
    }
    # Read metadata as data. Never source/eval os-release or infer an unrelated
    # distribution from ID_LIKE; package mappings below are explicitly scoped.
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*ID=(.*)$ ]] || continue
        value=${BASH_REMATCH[1]}
        case $value in \"*\"|\'*\') value=${value:1:${#value}-2};; esac
        id=$value
        count=$((count + 1))
    done < "$file"
    if [[ $count == 1 ]]; then
        case $id in debian|ubuntu|alpine) printf '%s\n' "$id"; return 0;; esac
    fi
    _toolbox_deps_error '依赖自动补装仅支持 ID=debian、ubuntu 或 alpine；系统信息未知或不受支持，未执行安装。'
    return 1
}
# Return 0 when the distribution CA package is installed, 1 when absent, and 2
# for an unreadable state. Do not inspect/repair CA files or change any caller
# CA override: package installation only supplies the distribution's defaults.
_toolbox_deps_ca_package() {
    local os=$1 status='' rc=0
    case $os in
        debian|ubuntu)
            _toolbox_deps_has dpkg-query || {
                _toolbox_deps_error '缺少 dpkg-query，无法确认 ca-certificates 包状态；未继续。'; return 2;
            }
            status=$(dpkg-query -W -f='${Status}' -- ca-certificates </dev/null 2>/dev/null) || rc=$?
            case $rc:$status in
                '0:install ok installed') return 0;;
                1:*|0:*' not-installed'|0:*' config-files') return 1;;
            esac;;
        alpine)
            _toolbox_deps_has apk || {
                _toolbox_deps_error '缺少 apk，无法确认 ca-certificates 包状态；未继续。'; return 2;
            }
            apk info --exists ca-certificates </dev/null >/dev/null 2>&1 || rc=$?
            case $rc in 0) return 0;; 1) return 1;; esac;;
    esac
    _toolbox_deps_error '无法可靠确认 ca-certificates 包状态；请检查包管理器，未继续。'
    return 2
}
_toolbox_deps_package() {
    local os=$1 command=$2 package=''
    case $command in
        bash|curl|wget|socat|sudo|nano|openssl|python3|tar|unzip|zip|gzip|bzip2|cpio|dmidecode|virt-what|certbot|nginx|jq|lsof|strace|tcpdump|ethtool|iperf3|vnstat|make|dkms|efibootmgr|mokutil)
            package=$command;;
        awk) package=gawk;;
        grep) package=grep;;
        sed) package=sed;;
        find|xargs) package=findutils;;
        xz|unxz) if [[ $os == alpine ]]; then package=xz; else package=xz-utils; fi;;
        gpg) package=gnupg;;
        gpgv) package=gpgv;;
        cc|gcc) package=gcc;;
        c++|g++) package=g++;;
        ar|as|ld|nm|objcopy|objdump|ranlib|readelf|strip|strings) package=binutils;;
        modprobe|lsmod|depmod|modinfo|insmod|rmmod) package=kmod;;
        cat|cp|mv|rm|mkdir|rmdir|env|id|uname|stat|readlink|realpath|sha256sum|sha512sum|md5sum|sha1sum|sort|head|tail|wc|cut|tr|tee|touch|chmod|chown|chgrp|install|mktemp|timeout|date|sleep|ln|dd|df|du|sync|truncate|base64|basename|dirname|seq|od|shred|nproc|whoami|cksum|comm|split|uniq|yes|chroot|mkfifo|mknod|nice|nohup|stty)
            package=coreutils;;
        ps|free|uptime|top|pgrep|pkill|pmap|pwdx|sysctl|vmstat|watch)
            if [[ $os == alpine ]]; then package=procps-ng; else package=procps; fi;;
        killall|fuser|pstree) package=psmisc;;
        ip|ss|tc|bridge)
            if [[ $os == alpine ]]; then
                case $command in ip) package=iproute2-minimal;; ss) package=iproute2-ss;; tc) package=iproute2-tc;; bridge) package=iproute2;; esac
            else package=iproute2; fi;;
        iptables|ip6tables|iptables-save|iptables-restore|ip6tables-save|ip6tables-restore) package=iptables;;
        nft) package=nftables;;
        netstat|ifconfig|route|arp) package=net-tools;;
        hostname|domainname|dnsdomainname)
            if [[ $os == alpine ]]; then package=net-tools; else package=hostname; fi;;
        ping|ping6) package=iputils-ping;;
        tracepath|tracepath6) package=iputils-tracepath;;
        traceroute) package=traceroute;;
        mtr) if [[ $os == alpine ]]; then package=mtr; else package=mtr-tiny; fi;;
        nc|netcat) package=netcat-openbsd;;
        dig|nslookup) if [[ $os == alpine ]]; then package=bind-tools; else package=bind9-dnsutils; fi;;
        host) if [[ $os == alpine ]]; then package=bind-tools; else package=bind9-host; fi;;
        ssh-keygen) if [[ $os == alpine ]]; then package=openssh-keygen; else package=openssh-client; fi;;
        ssh|scp|sftp) if [[ $os == alpine ]]; then package=openssh-client-default; else package=openssh-client; fi;;
        getent) if [[ $os == alpine ]]; then package=musl-utils; else package=libc-bin; fi;;
        tput) if [[ $os == alpine ]]; then package=ncurses; else package=ncurses-bin; fi;;
        lsblk|findmnt|flock|blkid|lscpu|losetup|uuidgen|wipefs|fstrim|sfdisk|partx|mount|umount|dmesg|logger|hexdump)
            # Alpine splits these out of util-linux. Installing the meta-package
            # also pulls unrelated login/OpenRC pieces, so use only each provider.
            if [[ $os == alpine ]]; then package=$command
            else
                case $command in
                    mount|umount|losetup) package=mount;;
                    sfdisk) package=fdisk;;
                    hexdump) package=bsdextrautils;;
                    logger) package=bsdutils;;
                    uuidgen) package=uuid-runtime;;
                    *) package=util-linux;;
                esac
            fi;;
        fdisk|lsmem|mountpoint|mkswap|swapon|swapoff|fallocate|nsenter|unshare|setsid|getopt|ionice)
            if [[ $os == alpine ]]; then package=util-linux-misc
            else
                case $command in fdisk) package=fdisk;; swapon|swapoff) package=mount;; *) package=util-linux;; esac
            fi;;
        apt-cache|dpkg|dpkg-query|dpkg-deb)
            [[ $os != alpine ]] || return 1
            case $command in apt-cache) package=apt;; *) package=dpkg;; esac;;
        *) return 1;;
    esac
    printf '%s\n' "$package"
}
_toolbox_deps_confirm() {
    local answer=''
    printf '%s [y/N]：' "$1" >&2
    if ! IFS= read -r answer; then
        _toolbox_deps_error '未收到完整确认（EOF）；已取消补装。'; return 1
    fi
    case $answer in y|Y|yes|YES) return 0;; esac
    _toolbox_deps_error '已取消补装；未执行安装。'
    return 1
}

toolbox_require_commands() {
    if (( $# < 2 )) || [[ -z $1 ]]; then
        _toolbox_deps_error "用法：toolbox_require_commands '功能名' 命令..."; return 2
    fi
    local feature=$1 command os manager package invalid=0 needs_ca=0 install_ca=0 ca_status=0
    local missing=() packages=() remaining=()
    shift
    for command in "$@"; do
        [[ $command =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.+-]*$ ]] || {
            _toolbox_deps_error "无效的依赖命令名：$command"; return 2;
        }
        _toolbox_deps_has "$command" && continue
        [[ " ${missing[*]-} " == *" $command "* ]] || missing+=("$command")
    done
    (( ${#missing[@]} > 0 )) || return 0
    _toolbox_deps_error "$feature 缺少命令：${missing[*]}"
    # A missing product, init or bootloader is not permission to replace it.
    # Reject the whole batch before a prompt or any package-manager operation.
    for command in "${missing[@]}"; do
        case $command in
            docker)
                _toolbox_deps_error 'Docker 需要通过 B1 安装；请调用 toolbox_require_docker 或进入 B1 完成安装。'; invalid=1;;
            dockerd)
                _toolbox_deps_error '缺少 dockerd：Docker 安装不完整；已有 Docker/数据需要人工修复，不能通过普通依赖补装接管。'; invalid=1;;
            systemctl|systemd-*|journalctl|resolvectl|rc-service|rc-status|rc-update|openrc*|init|reboot|shutdown|grub*|update-grub*|extlinux|syslinux|linux-headers*)
                _toolbox_deps_error "$command 属于 init、引导器或内核环境，不能作为普通依赖自动安装或切换；请先确认本机现有环境。"; invalid=1;;
            apt-get|apk)
                _toolbox_deps_error "缺少系统包管理器 ${command}；无法自动补装包管理器。"; invalid=1;;
        esac
    done
    (( invalid == 0 )) || return 1
    os=$(_toolbox_deps_os) || return 1
    for command in "${missing[@]}"; do
        if ! package=$(_toolbox_deps_package "$os" "$command"); then
            _toolbox_deps_error "未定义 $os 上命令 $command 的软件包映射；未猜测包名，未执行安装。"
            invalid=1
            continue
        fi
        [[ " ${packages[*]-} " == *" $package "* ]] || packages+=("$package")
        case $command in curl|wget|openssl|certbot) needs_ca=1;; esac
    done
    (( invalid == 0 )) || return 1
    if (( needs_ca == 1 )); then
        _toolbox_deps_ca_package "$os" || ca_status=$?
        case $ca_status in
            0) ;;
            1) packages+=(ca-certificates); install_ca=1;;
            *) return 1;;
        esac
    fi
    case $os in debian|ubuntu) manager=apt-get;; alpine) manager=apk;; esac
    _toolbox_deps_error "对应软件包（${manager}）：${packages[*]}"
    _toolbox_deps_has "$manager" || {
        _toolbox_deps_error "未找到系统包管理器 ${manager}；未执行安装。"; return 1;
    }
    _toolbox_deps_root || return 1
    _toolbox_deps_confirm '仅补装上述缺失依赖，成功后继续当前功能？' || return 1
    case $manager in
        apt-get)
            if ! DEBIAN_FRONTEND=noninteractive _toolbox_deps_exec apt-get update -o APT::Update::Error-Mode=any; then
                _toolbox_deps_error 'apt-get update 失败；请检查网络、软件源或包管理锁；未继续安装。'; return 1
            fi
            if ! DEBIAN_FRONTEND=noninteractive _toolbox_deps_exec apt-get install -y --no-upgrade --no-install-recommends -- "${packages[@]}"; then
                _toolbox_deps_error "apt-get install 失败：${packages[*]}；请检查上方错误，当前功能已停止。"; return 1
            fi;;
        apk)
            # --no-cache fetches current indexes without changing repositories.
            if ! _toolbox_deps_exec apk add --no-cache -- "${packages[@]}"; then
                _toolbox_deps_error "apk add 失败：${packages[*]}；请检查网络、现有软件源或包管理锁，当前功能已停止。"; return 1
            fi;;
    esac
    hash -r
    for command in "$@"; do
        _toolbox_deps_has "$command" && continue
        [[ " ${remaining[*]-} " == *" $command "* ]] || remaining+=("$command")
    done
    if (( ${#remaining[@]} > 0 )); then
        _toolbox_deps_error "安装后仍缺少命令：${remaining[*]}；命令回读失败，请检查包输出和 PATH，当前功能已停止。"
        return 1
    fi
    if (( install_ca == 1 )) && ! _toolbox_deps_ca_package "$os"; then
        _toolbox_deps_error '安装后 ca-certificates 包状态回读失败；当前功能已停止。'
        return 1
    fi
    _toolbox_deps_error "$feature 依赖补装完成，命令回读通过。"
    return 0
}

# B12 needs headers for the running kernel, rather than another kernel image or
# a generic headers meta-package. These two boundaries allow isolated tests.
_toolbox_deps_kernel_release() { uname -r; }
_toolbox_deps_kernel_build() { printf '/lib/modules/%s/build\n' "$1"; }
toolbox_require_kernel_headers() {
    if (( $# != 2 )) || [[ -z $1 || ! $2 =~ ^[0-9][a-zA-Z0-9._+-]*$ ]]; then
        _toolbox_deps_error "用法：toolbox_require_kernel_headers '功能名' 当前内核版本"; return 2
    fi
    local feature=$1 release=$2 running build os package
    running=$(_toolbox_deps_kernel_release) || {
        _toolbox_deps_error '无法读取正在运行的内核版本；未安装 headers。'; return 1;
    }
    [[ $release == "$running" ]] || {
        _toolbox_deps_error "请求的内核版本 $release 与正在运行的内核 $running 不一致；未安装 headers。"; return 1;
    }
    build=$(_toolbox_deps_kernel_build "$release") || return 1
    [[ -d $build && -r $build/Makefile ]] && return 0
    os=$(_toolbox_deps_os) || return 1
    case $os in
        debian|ubuntu) ;;
        *) _toolbox_deps_error '当前功能仅支持 Debian/Ubuntu 的匹配内核 headers 补装；未安装或更换内核。'; return 1;;
    esac
    package=linux-headers-$release
    _toolbox_deps_error "$feature 缺少当前内核 $release 的编译 headers：$build"
    _toolbox_deps_error "对应软件包（apt-get）：$package"
    _toolbox_deps_has apt-get || {
        _toolbox_deps_error '未找到系统包管理器 apt-get；未安装 headers。'; return 1;
    }
    _toolbox_deps_root || return 1
    _toolbox_deps_confirm '仅安装与正在运行内核完全匹配的 headers，成功后继续当前功能？' || return 1
    if ! DEBIAN_FRONTEND=noninteractive _toolbox_deps_exec apt-get update -o APT::Update::Error-Mode=any; then
        _toolbox_deps_error 'apt-get update 失败；请检查网络、软件源或包管理锁；未继续安装 headers。'; return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive _toolbox_deps_exec apt-get install -y --no-upgrade --no-install-recommends -- "$package"; then
        _toolbox_deps_error "apt-get install 失败：${package}；当前软件源可能没有此内核的 headers，当前功能已停止。"; return 1
    fi
    if [[ ! -d $build || ! -r $build/Makefile ]]; then
        _toolbox_deps_error "headers 安装后编译目录回读失败：$build/Makefile；当前功能已停止。"; return 1
    fi
    _toolbox_deps_error "${feature}：当前内核 headers 补装完成。"
    return 0
}

toolbox_require_docker() {
    if (( $# != 1 )) || [[ -z $1 ]]; then
        _toolbox_deps_error "用法：toolbox_require_docker '功能名'"; return 2
    fi
    _toolbox_deps_has docker && return 0
    _toolbox_deps_error "$1 缺少 Docker；可先运行 B1 安装流程，完成后继续当前功能。"
    _toolbox_deps_root || return 1
    _toolbox_deps_confirm '先安装 Docker？B1 仍会核对现有环境并要求原有安全确认' || return 1
    local directory=${_TOOLBOX_DEPS_MODULE_DIR:-}
    if [[ ${TOOLBOX_BUNDLED:-0} == 1 ]] &&
        { ! declare -F toolbox_network_detect_os >/dev/null 2>&1 || ! declare -F _toolbox_system_docker >/dev/null 2>&1; }; then
        _toolbox_deps_error '独立打包文件缺少 B1 函数，无法安装 Docker；请重新获取完整工具箱。'; return 1
    fi
    if ! declare -F toolbox_network_detect_os >/dev/null 2>&1; then
        [[ -n $directory && -r $directory/network.sh ]] || {
            _toolbox_deps_error '缺少 network.sh，无法加载 B1 安装流程；请下载完整项目。'; return 1;
        }
        # shellcheck source=/dev/null
        source "$directory/network.sh" >&2 || return 1
    fi
    if ! declare -F _toolbox_system_docker >/dev/null 2>&1; then
        [[ -r $directory/system.sh ]] || {
            _toolbox_deps_error '缺少 system.sh，无法加载 B1 安装流程；请下载完整项目。'; return 1;
        }
        # shellcheck source=/dev/null
        source "$directory/system.sh" >&2 || return 1
    fi
    # Keep stdin attached for B1's own confirmations. B1's package-manager
    # boundaries protect stdin separately; never pipe synthetic approval to it.
    if ! _toolbox_system_docker >&2; then
        _toolbox_deps_error 'B1 Docker 安装未完成；当前功能已停止。'; return 1
    fi
    hash -r
    _toolbox_deps_has docker || {
        _toolbox_deps_error 'B1 返回后仍缺少 docker；命令回读失败，当前功能已停止。'; return 1;
    }
    _toolbox_deps_error "$1：Docker 安装完成，继续当前功能。"
    return 0
}
