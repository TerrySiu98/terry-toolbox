#!/usr/bin/env bash
# B10 WebSSH：Debian + systemd 上的「浏览器 SSH」安全部署。
#
# 上游 huashengdun/webssh 只发布 PyPI 源码包，没有官方镜像。因此本模块：
#   * 从 PyPI 固定 sdist（版本 + SHA-256 白名单），装进独立 venv，不用 latest；
#   * WebSSH 本身没有页面级认证，所以前面加一个独立 nginx 实例做 HTTP Basic 认证；
#   * WebSSH 和 nginx 都只监听 127.0.0.1（nginx 用可配置的回环端口），
#     nginx 只接受来自回环的 upstream，并拒绝非回环的上游地址（tdstream）；
#   * 不碰系统 nginx：使用独立配置、独立单元、独立端口，卸载时只删自己的东西；
#   * 任一项前置条件不满足都在写盘前失败；写盘后失败则整体回滚。
#
# 已知边界：Basic 认证走明文 HTTP，远程访问需自行加 TLS（反代/隧道），本模块不改防火墙。
# 固定的是 webssh 版本与 sdist 哈希；paramiko/tornado 等依赖仍按上游声明由 pip 解析（未做全量锁）。

readonly WEBSSH_VERSION='1.6.3'
# PyPI sdist 白名单（https://pypi.org/project/webssh/1.6.3/）。版本漂移必须先人工复核。
readonly WEBSSH_SDIST_SHA256='2bce5bbaf206ad345910c7e4dc8024b3c418e681c9f5ff098f1802beff76e100'
readonly WEBSSH_SDIST_URL='https://files.pythonhosted.org/packages/fe/8d/aba7feaaaaa15a54decff18c5df79df27f17c833e6f9fd274a217ec7077b/webssh-1.6.3.tar.gz'
readonly WEBSSH_UNIT_NAME='terry-toolbox-webssh.service'
readonly WEBSSH_NGINX_UNIT_NAME='terry-toolbox-webssh-nginx.service'
readonly WEBSSH_DEFAULT_PORT=8080
readonly WEBSSH_DEFAULT_USER='admin'
readonly WEBSSH_MIN_PASS=12
readonly WEBSSH_REALM='Terry Toolbox WebSSH'
readonly WEBSSH_WEB_USER='www-data'

# 测试可覆盖的路径；默认值即真实主机路径。
webssh_etc()       { printf '%s\n' "${TOOLBOX_WEBSSH_ETC:-/etc/terry-toolbox-webssh}"; }
webssh_opt()       { printf '%s\n' "${TOOLBOX_WEBSSH_OPT:-/opt/terry-toolbox-webssh}"; }
webssh_lib()       { printf '%s\n' "${TOOLBOX_WEBSSH_LIB:-/var/lib/terry-toolbox-webssh}"; }
webssh_log()       { printf '%s\n' "${TOOLBOX_WEBSSH_LOG:-/var/log/terry-toolbox-webssh}"; }
webssh_run()       { printf '%s\n' "${TOOLBOX_WEBSSH_RUN:-/run/terry-toolbox-webssh}"; }
webssh_unit_dir()  { printf '%s\n' "${TOOLBOX_WEBSSH_UNIT_DIR:-/etc/systemd/system}"; }
webssh_lock()      { printf '%s\n' "${TOOLBOX_WEBSSH_LOCK:-/run/terry-toolbox-webssh.lock}"; }
webssh_unit()      { printf '%s/%s\n' "$(webssh_unit_dir)" "$WEBSSH_UNIT_NAME"; }
webssh_nginx_unit(){ printf '%s/%s\n' "$(webssh_unit_dir)" "$WEBSSH_NGINX_UNIT_NAME"; }
webssh_wssh()      { printf '%s/venv/bin/wssh\n' "$(webssh_opt)"; }
# 解析 nginx 实际路径：Debian 是 /usr/sbin/nginx，但仍以命令解析结果为准。
webssh_nginx() {
    [[ -n ${TOOLBOX_WEBSSH_NGINX:-} ]] && { printf '%s\n' "$TOOLBOX_WEBSSH_NGINX"; return 0; }
    command -v nginx 2>/dev/null || printf '/usr/sbin/nginx\n'
}

webssh_err() { printf '%s\n' "$*" >&2; }
webssh_die() { webssh_err "$*"; return 1; }

# ---------------------------------------------------------------- 前置条件

webssh_require_root() {
    [[ ${TOOLBOX_WEBSSH_UID:-${EUID:-$(id -u)}} -eq 0 ]] \
        || webssh_die '需要 root 权限运行（会写 /etc、/opt、/var/lib 和 systemd 单元）。'
}

webssh_require_debian() {
    local file=${TOOLBOX_WEBSSH_OS_RELEASE:-/etc/os-release} id=''
    [[ -r $file ]] || webssh_die "无法读取 $file，不能确认发行版。"
    id=$(sed -n 's/^ID=//p' "$file" | head -n1)
    id=${id%\"}; id=${id#\"}; id=${id%\'}; id=${id#\'}
    [[ ${id,,} == debian ]] || webssh_die "仅支持 Debian（当前 ID=${id:-未知}）；Alpine/Ubuntu 未验证。"
}

webssh_require_systemd() {
    local run_dir=${TOOLBOX_WEBSSH_SYSTEMD_RUN:-/run/systemd/system}
    command -v systemctl >/dev/null 2>&1 || webssh_die '未找到 systemctl，本机不是 systemd 系统。'
    [[ -d $run_dir ]] || webssh_die 'systemd 未作为 init 运行（缺少 /run/systemd/system）。'
}

webssh_require_tools() {
    local missing=() c
    for c in openssl sha256sum curl flock ss awk sed mktemp install python3 getent; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    (( ${#missing[@]} == 0 )) || { webssh_die "缺少必需命令：${missing[*]}"; return 1; }
    # venv 模块可能缺（python3-venv 未装），交给 ensure_packages 补装后再复查。
    getent passwd "$WEBSSH_WEB_USER" >/dev/null 2>&1 \
        || webssh_die "缺少系统用户 $WEBSSH_WEB_USER（nginx 工作进程用它降权）。"
}

# 只补装缺的包；已装的不动。滚动升级/清理交给系统包管理器。
webssh_ensure_packages() {
    local pkgs=()
    command -v nginx >/dev/null 2>&1 || pkgs+=(nginx)
    python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || pkgs+=(python3-venv)
    (( ${#pkgs[@]} )) || return 0
    webssh_err "安装系统包：${pkgs[*]}（apt-get）"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || { webssh_die 'apt-get update 失败。'; return 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" \
        || { webssh_die "apt-get install 失败：${pkgs[*]}"; return 1; }
    python3 -c 'import venv, ensurepip' >/dev/null 2>&1 \
        || { webssh_die 'python3-venv 安装后仍不可用。'; return 1; }
}

# ---------------------------------------------------------------- 输入校验

webssh_valid_port() {
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    (( $1 <= 65535 ))
}

webssh_valid_user() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$ ]]; }

# 只允许可打印、无空白字符：能安全写进 meta，也能经 printf/openssl 传递。
webssh_valid_pass() {
    (( ${#1} >= WEBSSH_MIN_PASS && ${#1} <= 64 )) || return 1
    # '|' 是 meta 的分隔符，[[::graph:]] 之外单独排除，避免 status 解析错位。
    [[ $1 =~ ^[[:graph:]]+$ && $1 != *'|'* ]]
}

# 空密码由本模块生成；有密码时要求二次输入，避免打错后只能看哈希。
webssh_read_credentials() {
    local user=${1:-} pass=${2:-} again
    WEBSSH_PASS_GENERATED=0
    WEBSSH_USER_INPUT=''; WEBSSH_PASS_INPUT=''
    if [[ -z $user ]]; then
        printf '登录用户名 [默认 %s]（[A-Za-z0-9._-]，2-32 位）: ' "$WEBSSH_DEFAULT_USER"
        IFS= read -r user || { webssh_die '输入结束，已取消。'; return 1; }
        user=${user:-$WEBSSH_DEFAULT_USER}
    fi
    webssh_valid_user "$user" || { webssh_die "用户名格式不正确：$user"; return 1; }

    if [[ -z $pass ]]; then
        while :; do
            printf '登录密码（至少 %s 位，输入不回显，留空自动生成）: ' "$WEBSSH_MIN_PASS"
            if ! IFS= read -rs pass; then
                printf '\n'; webssh_die '密码输入结束，已取消。'; return 1
            fi
            printf '\n'
            if [[ -z $pass ]]; then
                pass=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24)
                [[ ${#pass} -eq 24 ]] || { webssh_die '密码生成失败。'; return 1; }
                WEBSSH_PASS_GENERATED=1
                break
            fi
            webssh_valid_pass "$pass" || {
                webssh_err "密码需 $WEBSSH_MIN_PASS-64 位且不含空白字符，请重试。"
                continue
            }
            printf '再输入一次: '
            if ! IFS= read -rs again; then
                printf '\n'; webssh_die '密码确认输入结束，已取消。'; return 1
            fi
            printf '\n'
            [[ $again == "$pass" ]] && break
            webssh_err '两次输入不一致，请重试。'
        done
    else
        webssh_valid_pass "$pass" || { webssh_die '密码需 12-64 位且不含空白字符。'; return 1; }
    fi
    WEBSSH_USER_INPUT=$user
    WEBSSH_PASS_INPUT=$pass
}

# ---------------------------------------------------------------- 本机事实

webssh_tcp_port_busy() {
    ss -ltnH 2>/dev/null | awk -v p=":$1" '$4 ~ p "$" { found=1 } END { exit !found }'
}

webssh_port_owner() {
    ss -ltnpH 2>/dev/null | awk -v p=":$1" '$4 ~ p "$" { print; exit }' | cut -c1-200
}

# 端口是否由指定单元的 MainPID 持有（不猜「看起来像」）。
webssh_port_owned_by() {
    local port=$1 unit=$2 line main=''
    main=$(systemctl show -p MainPID --value "$unit" 2>/dev/null) || main=''
    [[ $main =~ ^[0-9]+$ ]] || return 1
    while IFS= read -r line; do
        if [[ $line == *"pid=$main,"* || $line == *"pid=$main)"* ]]; then return 0; fi
    done < <(ss -ltnpH 2>/dev/null | awk -v p="127.0.0.1:$port" '$4 == p')
    return 1
}

webssh_wait_active() {
    local unit=$1 i tries=${TOOLBOX_WEBSSH_WAIT_TRIES:-20}
    for ((i = 0; i < tries; i++)); do
        systemctl is-active --quiet "$unit" 2>/dev/null && return 0
        sleep 0.5
    done
    return 1
}

webssh_wait_owned() {
    local port=$1 unit=$2 i tries=${TOOLBOX_WEBSSH_WAIT_TRIES:-20}
    for ((i = 0; i < tries; i++)); do
        webssh_port_owned_by "$port" "$unit" && return 0
        sleep 0.5
    done
    return 1
}

# 单元的三种归属：absent / ours（ExecStart 指纹匹配）/ foreign。
webssh_unit_state() {
    local file=$1 needle=$2
    [[ ! -L $file ]] || { printf 'foreign\n'; return 0; }
    [[ -e $file ]] || { printf 'absent\n'; return 0; }
    if grep -qF -- "$needle" "$file" 2>/dev/null; then printf 'ours\n'; else printf 'foreign\n'; fi
}

# 内部端口：随机高端口，跳过已占用和与前端端口相同的值（同一回环地址不能共用）。
webssh_pick_internal_port() {
    local avoid=${1:-} p i
    for ((i = 0; i < 200; i++)); do
        p=$(( 21000 + RANDOM % 19000 ))
        [[ $p == "$avoid" ]] && continue
        webssh_tcp_port_busy "$p" || { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------- 写入与回滚

# 独占创建并记录 dev:inode；删除时先原子移到隔离名，再校验 inode。
# 不对“检查后又被换掉”的路径直接 rm -rf，也不跟随任一父目录的符号链接。
webssh_owned_fs() {
    python3 -c '# webssh-owned-fs
import ctypes, grp, os, secrets, shutil, stat, sys
libc = ctypes.CDLL(None, use_errno=True)
rename = libc.renameat2
rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
def move(fd, source, target):
    if rename(fd, os.fsencode(source), fd, os.fsencode(target), 1):
        raise OSError(ctypes.get_errno(), "exclusive rename failed")
def parent(path):
    if not path.startswith("/") or path == "/" or any(c.isspace() or c == "|" for c in path):
        raise ValueError("unsafe path")
    parts = path[1:].split("/")
    if any(p in ("", ".", "..") for p in parts): raise ValueError("unsafe path component")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts[:-1]:
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = nxt
        return fd, parts[-1]
    except BaseException:
        os.close(fd); raise
def identity(s): return "%d:%d" % (s.st_dev, s.st_ino)
def present(fd, name):
    try: return os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError: return None
op, path = sys.argv[1:3]
fd = None
try:
    if op == "preflight":
        paths = sys.argv[2:]
        for p in paths:
            path = p
            pf, name = parent(p)
            try:
                if present(pf, name) is not None: raise FileExistsError("existing target")
            finally: os.close(pf)
        for i, p in enumerate(paths):
            if any(p == q or p.startswith(q + "/") or q.startswith(p + "/") for q in paths[i+1:]):
                raise ValueError("overlapping targets")
    else:
        fd, name = parent(path)
        if op in ("create-dir", "publish-file"):
            stage = ".webssh-new-" + secrets.token_hex(16)
            handle = None
            try:
                if op == "create-dir":
                    os.mkdir(stage, 0o700, dir_fd=fd)
                    handle = os.open(stage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    os.fchown(handle, 0, grp.getgrnam(sys.argv[4]).gr_gid)
                    os.fchmod(handle, int(sys.argv[3], 8))
                else:
                    handle = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
                    with open(sys.argv[3], "rb") as source:
                        with os.fdopen(os.dup(handle), "wb") as dest: shutil.copyfileobj(source, dest)
                    os.fchmod(handle, 0o644)
                token = identity(os.fstat(handle))
                move(fd, stage, name)
                print(token)
            finally:
                if handle is not None: os.close(handle)
                try:
                    if op == "create-dir": os.rmdir(stage, dir_fd=fd)
                    else: os.unlink(stage, dir_fd=fd)
                except FileNotFoundError: pass
        elif op in ("write-data", "create-temp"):
            expected = sys.argv[3]
            handle = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            stage = ".webssh-new-" + secrets.token_hex(16)
            try:
                if identity(os.fstat(handle)) != expected: raise ValueError("ownership changed")
                if op == "write-data":
                    leaf, mode, group, replace = sys.argv[4:8]
                    if not leaf or "/" in leaf or leaf in (".", ".."): raise ValueError("unsafe leaf")
                    data = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=handle)
                    try:
                        with os.fdopen(os.dup(data), "wb") as dest: shutil.copyfileobj(sys.stdin.buffer, dest)
                        os.fchown(data, 0, grp.getgrnam(group).gr_gid)
                        os.fchmod(data, int(mode, 8))
                    finally: os.close(data)
                    if replace == "replace": os.replace(stage, leaf, src_dir_fd=handle, dst_dir_fd=handle)
                    else: move(handle, stage, leaf)
                else:
                    gid = grp.getgrnam(sys.argv[4]).gr_gid
                    os.mkdir(stage, 0o700, dir_fd=handle)
                    temps = os.open(stage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=handle)
                    try:
                        os.fchown(temps, gid, gid); os.fchmod(temps, 0o770)
                        for leaf in ("client", "proxy", "fastcgi", "uwsgi", "scgi"):
                            os.mkdir(leaf, 0o700, dir_fd=temps)
                            child = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=temps)
                            try: os.fchown(child, gid, gid); os.fchmod(child, 0o770)
                            finally: os.close(child)
                    finally: os.close(temps)
                    move(handle, stage, "tmp")
                current = present(fd, name)
                if current is None or identity(current) != expected: raise ValueError("ownership changed during write")
            finally:
                try:
                    if op == "create-temp" and present(handle, stage) is not None:
                        shutil.rmtree(stage, dir_fd=handle)
                    elif op == "write-data": os.unlink(stage, dir_fd=handle)
                except FileNotFoundError: pass
                os.close(handle)
        elif op in ("check", "remove"):
            expected = sys.argv[3]
            found = present(fd, name)
            if found is None and op == "check": raise ValueError("owned target missing")
            if found is not None:
                if identity(found) != expected or stat.S_ISLNK(found.st_mode): raise ValueError("ownership changed")
                if op == "remove":
                    stage = ".webssh-delete-" + secrets.token_hex(16)
                    move(fd, name, stage)
                    moved = present(fd, stage)
                    if identity(moved) != expected or stat.S_ISLNK(moved.st_mode):
                        try: move(fd, stage, name)
                        except OSError: pass
                        raise ValueError("ownership changed during removal; retained")
                    if stat.S_ISDIR(moved.st_mode):
                        if not shutil.rmtree.avoids_symlink_attacks: raise ValueError("unsafe rmtree platform")
                    try:
                        if stat.S_ISDIR(moved.st_mode): shutil.rmtree(stage, dir_fd=fd)
                        else: os.unlink(stage, dir_fd=fd)
                    except (OSError, ValueError):
                        # 部分删除/I/O 失败时恢复同 inode 的原路径；绝不覆盖新来目标。
                        retained = present(fd, stage)
                        if retained is not None and identity(retained) == expected:
                            try: move(fd, stage, name)
                            except OSError:
                                print("清理未完成，隔离内容保留：" + os.path.dirname(path) + "/" + stage, file=sys.stderr)
                        raise
        else: raise ValueError("unknown operation")
except (OSError, ValueError, KeyError):
    print("路径操作拒绝或失败，未删除外来内容：" + path, file=sys.stderr)
    sys.exit(1)
finally:
    if fd is not None: os.close(fd)
' "$@"
}

webssh_preflight_paths() {
    webssh_owned_fs preflight "$(webssh_etc)" "$(webssh_opt)" "$(webssh_lib)" \
        "$(webssh_log)" "$(webssh_run)" "$(webssh_unit)" "$(webssh_nginx_unit)"
}

webssh_save_owned() {
    local path etc
    etc=$(webssh_etc)
    [[ -n ${WEBSSH_OWNED[$etc]:-} ]] || return 0
    webssh_check_owned || return 1
    for path in "${!WEBSSH_OWNED[@]}"; do printf '%s|%s\n' "$path" "${WEBSSH_OWNED[$path]}"; done \
        | webssh_owned_fs write-data "$etc" "${WEBSSH_OWNED[$etc]}" owned-paths 0600 root replace
}

webssh_store_owned_file() {
    local dir=$1 leaf=$2 source=$3 mode=$4 group=$5
    [[ -n ${WEBSSH_OWNED[$dir]:-} ]] || return 1
    webssh_owned_fs write-data "$dir" "${WEBSSH_OWNED[$dir]}" "$leaf" "$mode" "$group" new < "$source"
}

webssh_create_owned_dir() {
    local path=$1 token
    token=$(webssh_owned_fs create-dir "$@") || return 1
    WEBSSH_OWNED[$path]=$token
    webssh_save_owned
}

webssh_publish_owned_unit() {
    local path=$1 token
    token=$(webssh_owned_fs publish-file "$@") || return 1
    WEBSSH_OWNED[$path]=$token
    webssh_save_owned
}

webssh_check_owned() {
    local path
    for path in "${!WEBSSH_OWNED[@]}"; do
        webssh_owned_fs check "$path" "${WEBSSH_OWNED[$path]}" || return 1
    done
}

webssh_remove_owned() {
    local path failed=0
    # 配置目录（含恢复清单）最后删除；任何已换 inode 的路径只保留。
    for path in "$(webssh_nginx_unit)" "$(webssh_unit)" "$(webssh_run)" "$(webssh_log)" "$(webssh_lib)" "$(webssh_opt)"; do
        [[ -n ${WEBSSH_OWNED[$path]:-} ]] || continue
        webssh_owned_fs remove "$path" "${WEBSSH_OWNED[$path]}" || failed=1
    done
    path=$(webssh_etc)
    if (( failed == 0 )) && [[ -n ${WEBSSH_OWNED[$path]:-} ]]; then
        webssh_owned_fs remove "$path" "${WEBSSH_OWNED[$path]}" || failed=1
    fi
    (( failed == 0 ))
}

webssh_load_owned() {
    local path token extra etc
    etc=$(webssh_etc)
    [[ -f $etc/owned-paths && ! -L $etc/owned-paths ]] \
        || { webssh_die "缺少可信归属清单 $etc/owned-paths；未自动删除，请人工确认旧安装。"; return 1; }
    while IFS='|' read -r path token extra; do
        [[ -n $path && -z $extra && $token =~ ^[0-9]+:[0-9]+$ ]] || return 1
        [[ -z ${WEBSSH_OWNED[$path]:-} ]] || return 1
        case $path in
            "$etc"|"$(webssh_opt)"|"$(webssh_lib)"|"$(webssh_log)"|"$(webssh_run)"|"$(webssh_unit)"|"$(webssh_nginx_unit)") ;;
            *) webssh_die '归属清单含有非本模块路径；未删除。'; return 1 ;;
        esac
        WEBSSH_OWNED[$path]=$token
    done < "$etc/owned-paths"
    [[ -n ${WEBSSH_OWNED[$etc]:-} ]] || return 1
    # 允许失败安装只创建部分目标，但绝不允许现存目标漏出归属清单。
    for path in "$etc" "$(webssh_opt)" "$(webssh_lib)" "$(webssh_log)" "$(webssh_run)" "$(webssh_unit)" "$(webssh_nginx_unit)"; do
        if [[ -e $path || -L $path ]]; then
            [[ -n ${WEBSSH_OWNED[$path]:-} ]] \
                || { webssh_die "归属清单遗漏现存路径 $path；未停止或删除。"; return 1; }
        fi
    done
    webssh_check_owned
}

# 所有属性必须各出现一次；缺字段、重复字段或读取失败都不是可靠状态。
webssh_unit_facts() {
    local unit=$1 facts key value
    local -A seen=()
    WEBSSH_LOAD_STATE=''; WEBSSH_ACTIVE_STATE=''; WEBSSH_SUB_STATE=''; WEBSSH_MAIN_PID=''
    facts=$(systemctl show -p LoadState -p ActiveState -p SubState -p MainPID "$unit" 2>/dev/null) \
        || { webssh_die "无法读取 $unit 状态，保留所有文件。"; return 1; }
    while IFS='=' read -r key value; do
        case $key in
            LoadState|ActiveState|SubState) [[ $value =~ ^[a-z-]+$ ]] || return 1 ;;
            MainPID) [[ $value =~ ^[0-9]+$ ]] || return 1 ;;
            *) webssh_die "$unit 状态含有未知字段，保留所有文件。"; return 1 ;;
        esac
        [[ -z ${seen[$key]:-} ]] || { webssh_die "$unit 状态字段重复，保留所有文件。"; return 1; }
        seen[$key]=1
        case $key in
            LoadState) WEBSSH_LOAD_STATE=$value ;; ActiveState) WEBSSH_ACTIVE_STATE=$value ;;
            SubState) WEBSSH_SUB_STATE=$value ;; MainPID) WEBSSH_MAIN_PID=$value ;;
        esac
    done <<< "$facts"
    (( ${#seen[@]} == 4 )) || { webssh_die "$unit 状态不完整，保留所有文件。"; return 1; }
}

# is-active 的非零同时表示 inactive 和通信失败，不能作为删除依据。
webssh_stopped() {
    webssh_unit_facts "$1" || return 1
    if [[ ( $WEBSSH_LOAD_STATE == loaded || $WEBSSH_LOAD_STATE == not-found ) && $WEBSSH_MAIN_PID == 0 \
        && ( $WEBSSH_ACTIVE_STATE == inactive && $WEBSSH_SUB_STATE == dead \
            || $WEBSSH_ACTIVE_STATE == failed && $WEBSSH_SUB_STATE == failed ) ]]; then return 0; fi
    webssh_die "$1 未确认停止（或状态不完整），保留所有文件。"
}

webssh_stop_confirmed() {
    local failed=0 unit
    for unit in "$WEBSSH_NGINX_UNIT_NAME" "$WEBSSH_UNIT_NAME"; do
        if ! systemctl disable --now "$unit" >/dev/null 2>&1; then
            webssh_err "停止/禁用 $unit 失败，保留所有文件。"; failed=1
        fi
        webssh_stopped "$unit" || failed=1
    done
    (( failed == 0 ))
}

webssh_rollback() {
    webssh_err '--- 开始回滚 ---'
    # 先停 nginx 再停 webssh，避免回滚期间反向代理打到已停的后端。
    if [[ ${WEBSSH_SERVICES_TOUCHED:-0} == 1 ]]; then
        if ! webssh_check_owned || ! webssh_stop_confirmed || ! webssh_check_owned; then
            webssh_err '回滚未完成；单元、配置和 venv 保留，请人工确认停服后重试。'; return 1
        fi
    fi
    webssh_remove_owned || { webssh_err '回滚未完成：归属变化或清理失败，保留恢复清单。'; return 1; }
    if [[ ${WEBSSH_SERVICES_TOUCHED:-0} == 1 ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || { webssh_die '回滚文件已清理，但 daemon-reload 失败。'; return 1; }
        systemctl reset-failed "$WEBSSH_NGINX_UNIT_NAME" "$WEBSSH_UNIT_NAME" >/dev/null 2>&1 || true
    fi
    webssh_err '已恢复到安装前状态（新增的单元、目录和 venv 已删除；apt 补装的包保留）。'
}

webssh_fetch() {
    local dest=$1 expected=${TOOLBOX_WEBSSH_SDIST_SHA256:-$WEBSSH_SDIST_SHA256} actual url
    url=${TOOLBOX_WEBSSH_SDIST_URL:-$WEBSSH_SDIST_URL}
    if [[ -n ${TOOLBOX_WEBSSH_SDIST_SRC:-} ]]; then
        cp -- "$TOOLBOX_WEBSSH_SDIST_SRC" "$dest" || { webssh_die '复制本地源码包失败。'; return 1; }
    else
        webssh_err "下载 webssh $WEBSSH_VERSION 源码包（PyPI）…"
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \
            -o "$dest" "$url" || { webssh_die '下载失败（网络或 PyPI 不可达）。'; return 1; }
    fi
    actual=$(sha256sum -- "$dest" | cut -d' ' -f1)
    [[ $actual == "$expected" ]] \
        || { webssh_die "SHA-256 不匹配：期望 $expected，实际 $actual（版本漂移或下载被篡改）。"; return 1; }
}

webssh_install_venv() {
    local opt tmp=$1
    opt=$(webssh_opt)
    python3 -m venv "$opt/venv" || { webssh_die '创建 venv 失败。'; return 1; }
    "$opt/venv/bin/pip" install --disable-pip-version-check --no-cache-dir --no-input \
        "$tmp/webssh.tar.gz" || { webssh_die 'pip 安装 webssh 失败。'; return 1; }
    # 装完回读版本：索引上的 name/version 与源码包内版本不一致时要立刻发现。
    local got
    got=$("$opt/venv/bin/pip" show webssh 2>/dev/null) \
        || { webssh_die 'pip 无法回读 webssh 版本。'; return 1; }
    got=$(sed -n 's/^Version: //p' <<< "$got")
    [[ $got == "$WEBSSH_VERSION" ]] \
        || { webssh_die "venv 中 webssh 版本为 ${got:-未知}，期望 $WEBSSH_VERSION。"; return 1; }
    "$opt/venv/bin/python" -c 'import webssh' >/dev/null 2>&1 \
        || { webssh_die 'webssh 无法导入，安装不完整。'; return 1; }
}

webssh_write_htpasswd() {
    local file=$1 user=$2 pass=$3 hash
    # apr1（= htpasswd -m）是 nginx 支持的格式；-stdin 让密码里的前导 '-' 也安全。
    hash=$(printf '%s\n' "$pass" | openssl passwd -apr1 -salt "$(openssl rand -hex 4)" -stdin) \
        || { webssh_die '生成 htpasswd 哈希失败。'; return 1; }
    [[ $hash == \$apr1\$* ]] || { webssh_die 'htpasswd 哈希格式异常。'; return 1; }
    printf '%s:%s\n' "$user" "$hash" > "$file" || { webssh_die "写入 $file 失败。"; return 1; }
    chown "root:$WEBSSH_WEB_USER" "$file" && chmod 0640 "$file"
}

webssh_write_nginx_conf() {
    local file=$1 port=$2 internal=$3 etc
    etc=$(webssh_etc)
    cat > "$file" <<EOF || { webssh_die "写入 $file 失败。"; return 1; }
# 由 terry-toolbox B10 生成；独立实例，不与 /etc/nginx 的站点互相影响。
user $WEBSSH_WEB_USER;
worker_processes 1;
pid $(webssh_lib)/nginx.pid;
error_log stderr notice;

events { worker_connections 256; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    access_log $(webssh_log)/access.log;
    client_body_temp_path $(webssh_lib)/tmp/client;
    proxy_temp_path $(webssh_lib)/tmp/proxy;
    fastcgi_temp_path $(webssh_lib)/tmp/fastcgi;
    uwsgi_temp_path $(webssh_lib)/tmp/uwsgi;
    scgi_temp_path $(webssh_lib)/tmp/scgi;
    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

    server {
        listen 127.0.0.1:$port;
        server_name _;
        client_max_body_size 1m;

        auth_basic "$WEBSSH_REALM";
        auth_basic_user_file $etc/htpasswd;

        add_header X-Frame-Options DENY always;
        add_header X-Content-Type-Options nosniff always;
        add_header Referrer-Policy no-referrer always;

        location / {
            proxy_pass http://127.0.0.1:$internal;
            proxy_http_version 1.1;
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
        }
    }
}
EOF
    [[ -s $file ]] && chmod 0644 "$file"
}

webssh_write_units() {
    local staging=$1 internal=$2 etc opt
    etc=$(webssh_etc); opt=$(webssh_opt)

    cat > "$staging/backend.service" <<EOF || { webssh_die '写入 WebSSH 单元失败。'; return 1; }
[Unit]
Description=Terry Toolbox WebSSH backend (loopback only)
Documentation=https://github.com/huashengdun/webssh
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PYTHONUNBUFFERED=1
ExecStart=$opt/venv/bin/wssh --address=127.0.0.1 --port=$internal --redirect=False --fbidhttp=False --tdstream=127.0.0.1 --policy=warning --hostfile=$etc/known_hosts --maxconn=10 --timeout=10 --wpintvl=30 --origin=same
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
ReadWritePaths=$etc

[Install]
WantedBy=multi-user.target
EOF

    cat > "$staging/front.service" <<EOF || { webssh_die '写入 nginx 单元失败。'; return 1; }
[Unit]
Description=Terry Toolbox WebSSH front (nginx + basic auth, loopback only)
After=network-online.target $WEBSSH_UNIT_NAME
Wants=network-online.target
Requires=$WEBSSH_UNIT_NAME

[Service]
Type=simple

ExecStart=$(webssh_nginx) -c $etc/nginx.conf -g 'daemon off;'
Restart=on-failure
RestartSec=3
UMask=0027
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
ReadWritePaths=$(webssh_lib) $(webssh_log)

[Install]
WantedBy=multi-user.target
EOF
    webssh_publish_owned_unit "$(webssh_unit)" "$staging/backend.service" || return 1
    webssh_publish_owned_unit "$(webssh_nginx_unit)" "$staging/front.service"
}

# ---------------------------------------------------------------- HTTP 验证

# 凭据经 stdin 送进 curl config，不出现在进程 argv / mock 命令日志。
webssh_curl_auth() {
    local creds=$1
    shift
    creds=${creds//\\/\\\\}; creds=${creds//\"/\\\"}
    printf 'user = "%s"\n' "$creds" | curl --config - "$@"
}

# 只打印状态码；所有请求都直连回环端口，不经外网。
webssh_http_code() {
    local url=$1 creds=${2:-}
    if [[ -n $creds ]]; then
        webssh_curl_auth "$creds" -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null
    else
        curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null
    fi
}

# Origin 必须带上端口：webssh 的默认 origin 策略是「同源」，Host 带端口而 Origin 不带会 403。
webssh_ws_code() {
    local url=$1 creds=${2:-} origin=$3
    local -a client=(curl)
    [[ -z $creds ]] || client=(webssh_curl_auth "$creds")
    "${client[@]}" -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Origin: $origin" -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        "$url" 2>/dev/null
}

# 认证必须「有则通、无则挡」：只用正确密码通过不算证明。
webssh_verify_http() {
    local port=$1 internal=$2 user=$3 pass=$4 body code
    local base="http://127.0.0.1:$port"

    code=$(webssh_http_code "$base/")
    [[ $code == 401 ]] || { webssh_die "未认证访问首页返回 $code，期望 401。"; return 1; }

    code=$(webssh_http_code "$base/" "$user:wrong-$pass")
    [[ $code == 401 ]] || { webssh_die "错误密码返回 $code，期望 401（认证可能未生效）。"; return 1; }

    body=$(mktemp) || return 1
    code=$(webssh_curl_auth "$user:$pass" -s -o "$body" -w '%{http_code}' --max-time 5 "$base/" 2>/dev/null)
    if [[ $code != 200 ]] || ! grep -qi 'webssh' "$body"; then
        rm -f -- "$body"
        webssh_die "认证后首页返回 $code，或页面不是 WebSSH（内部端口 $internal）。"
        return 1
    fi
    rm -f -- "$body"

    code=$(webssh_curl_auth "$user:$pass" -s -o /dev/null -w '%{http_code}' --max-time 5 "$base/static/js/main.js" 2>/dev/null)
    [[ $code == 200 ]] || { webssh_die "静态资源返回 $code，期望 200。"; return 1; }

    # 终端依赖 websocket：升级到 101 才说明 nginx 的 Upgrade 转发可用；
    # 认证缺失时必须先被 401 挡住，而不是把 websocket 直接放行。
    code=$(webssh_ws_code "$base/ws?id=probe" '' "$base")
    [[ $code == 401 ]] || { webssh_die "未认证 websocket 返回 $code，期望 401。"; return 1; }
    code=$(webssh_ws_code "$base/ws?id=probe" "$user:$pass" "$base")
    [[ $code == 101 ]] || { webssh_die "websocket 升级返回 $code，期望 101（终端会连不上）。"; return 1; }
}

# ---------------------------------------------------------------- 安装

_webssh_install() {
    local port=${1:-} user='' pass='' internal='' answer
    local etc opt lib log run state tmp
    local -A WEBSSH_OWNED=()
    local WEBSSH_SERVICES_TOUCHED=0

    webssh_require_root || return 1
    webssh_require_debian || return 1
    webssh_require_systemd || return 1
    webssh_require_tools || return 1

    if [[ -n $port ]]; then
        webssh_valid_port "$port" || { webssh_die "端口不正确：$port（1-65535，无前导零）"; return 1; }
    else
        port=$WEBSSH_DEFAULT_PORT
    fi

    # 冲突判定全部在写盘前，并区分「我们的残留」和「别人的文件」。
    state=$(webssh_unit_state "$(webssh_unit)" "ExecStart=$(webssh_wssh)")
    case $state in
        foreign) webssh_die "$(webssh_unit) 已存在且不是本模块生成，未覆盖；请人工确认。"; return 1 ;;
        ours)
            if systemctl is-active --quiet "$WEBSSH_UNIT_NAME" 2>/dev/null; then
                webssh_die "WebSSH 已在运行（$(webssh_unit)）。重装请先执行 toolbox_webssh uninstall。"
            else
                webssh_die "发现上次残留（$(webssh_unit) 未运行）。请先 uninstall 清理。"
            fi
            return 1
            ;;
    esac
    state=$(webssh_unit_state "$(webssh_nginx_unit)" "ExecStart=$(webssh_nginx) -c $(webssh_etc)/nginx.conf")
    case $state in
        foreign) webssh_die "$(webssh_nginx_unit) 已存在且不是本模块生成，未覆盖。"; return 1 ;;
        ours) webssh_die "发现残留的 nginx 单元，请先 uninstall。"; return 1 ;;
    esac
    webssh_preflight_paths || return 1
    if webssh_tcp_port_busy "$port"; then
        webssh_err "TCP 端口 $port 已被占用："
        webssh_port_owner "$port" >&2 || true
        webssh_die '换成其他端口，或先停止占用方。'
        return 1
    fi
    internal=$(webssh_pick_internal_port "$port") || { webssh_die '找不到可用的内部端口。'; return 1; }

    webssh_read_credentials "$user" "$pass" || return 1
    user=$WEBSSH_USER_INPUT
    pass=$WEBSSH_PASS_INPUT

    etc=$(webssh_etc); opt=$(webssh_opt); lib=$(webssh_lib); log=$(webssh_log); run=$(webssh_run)
    printf '\n即将安装 WebSSH（浏览器 SSH）：\n'
    printf '  版本    : %s（PyPI 源码包，安装前校验 SHA-256）\n' "$WEBSSH_VERSION"
    printf '  访问    : http://127.0.0.1:%s/（仅回环）\n' "$port"
    printf '  后端    : 127.0.0.1:%s（仅回环，WebSSH 自身无页面认证）\n' "$internal"
    printf '  认证    : nginx HTTP Basic，用户名 %s，密码%s\n' "$user" \
        "$([[ ${WEBSSH_PASS_GENERATED:-0} == 1 ]] && printf '随机生成、仅保存于 root 可读的凭据文件' || printf '按输入设置、仅保存于 root 可读的凭据文件')"
    printf '  目录    : %s（配置）、%s（venv）、%s、%s\n' "$etc" "$opt" "$lib" "$log"
    printf '  不涉及  : 系统 nginx 配置、防火墙、TLS\n'
    printf '确认安装？输入 YES 继续：'
    IFS= read -r answer || { webssh_die '输入结束，已取消。'; return 1; }
    [[ ${answer^^} == YES ]] || { webssh_die '已取消，未修改系统。'; return 1; }

    exec 9>>"$(webssh_lock)" || { webssh_die "无法创建锁文件 $(webssh_lock)"; return 1; }
    flock -n 9 || { webssh_die '另一个安装/卸载正在进行，稍后再试。'; return 1; }
    # 用户输入期间、等锁期间可能出现新文件；独占创建仍是最终冲突门槛。
    webssh_preflight_paths || return 1

    # 补包不属于回滚范围：失败时本模块还没写任何文件。
    webssh_ensure_packages || return 1

    tmp=$(mktemp -d) || { webssh_die '无法创建临时目录'; return 1; }
    webssh_err '--- 开始写入 ---'
    webssh_create_owned_dir "$etc" 0755 root || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_create_owned_dir "$opt" 0755 root || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_create_owned_dir "$lib" 0750 "$WEBSSH_WEB_USER" || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_create_owned_dir "$log" 0750 "$WEBSSH_WEB_USER" || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_owned_fs create-temp "$lib" "${WEBSSH_OWNED[$lib]}" "$WEBSSH_WEB_USER" \
        || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_create_owned_dir "$run" 0755 root || { rm -rf -- "$tmp"; webssh_rollback; return 1; }

    webssh_store_owned_file "$etc" known_hosts /dev/null 0600 root \
        || { rm -rf -- "$tmp"; webssh_rollback; return 1; }

    webssh_fetch "$tmp/webssh.tar.gz" || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_check_owned || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_install_venv "$tmp" || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_check_owned || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_write_htpasswd "$tmp/htpasswd" "$user" "$pass" || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_store_owned_file "$etc" htpasswd "$tmp/htpasswd" 0640 "$WEBSSH_WEB_USER" \
        || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_write_nginx_conf "$tmp/nginx.conf" "$port" "$internal" || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_store_owned_file "$etc" nginx.conf "$tmp/nginx.conf" 0644 root \
        || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_write_units "$tmp" "$internal" || { rm -rf -- "$tmp"; webssh_rollback; return 1; }

    # 语法检查必须在启用之前；nginx -t 会同时证明配置与 mime.types 可用。
    if ! "$(webssh_nginx)" -t -c "$etc/nginx.conf" >/dev/null 2>&1; then
        webssh_err 'nginx 配置自检失败：'
        "$(webssh_nginx)" -t -c "$etc/nginx.conf" >&2 2>&1 || true
        rm -rf -- "$tmp"; webssh_rollback; return 1
    fi

    webssh_check_owned || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    WEBSSH_SERVICES_TOUCHED=1
    if ! systemctl daemon-reload; then
        rm -rf -- "$tmp"; webssh_rollback; return 1
    fi
    if ! systemctl enable --now "$WEBSSH_UNIT_NAME" >/dev/null 2>&1; then
        webssh_err 'webssh 单元启动失败：'
        webssh_unit_summary "$WEBSSH_UNIT_NAME" >&2 || true
        rm -rf -- "$tmp"; webssh_rollback; return 1
    fi
    if ! webssh_wait_active "$WEBSSH_UNIT_NAME" || ! webssh_wait_owned "$internal" "$WEBSSH_UNIT_NAME"; then
        webssh_err "webssh 未在 127.0.0.1:$internal 上运行："
        webssh_unit_summary "$WEBSSH_UNIT_NAME" >&2 || true
        rm -rf -- "$tmp"; webssh_rollback; return 1
    fi

    if ! systemctl enable --now "$WEBSSH_NGINX_UNIT_NAME" >/dev/null 2>&1; then
        webssh_err 'nginx 单元启动失败：'
        webssh_unit_summary "$WEBSSH_NGINX_UNIT_NAME" >&2 || true
        rm -rf -- "$tmp"; webssh_rollback; return 1
    fi
    if ! webssh_wait_active "$WEBSSH_NGINX_UNIT_NAME" || ! webssh_wait_owned "$port" "$WEBSSH_NGINX_UNIT_NAME"; then
        webssh_err "nginx 未在 127.0.0.1:$port 上运行："
        webssh_unit_summary "$WEBSSH_NGINX_UNIT_NAME" >&2 || true
        rm -rf -- "$tmp"; webssh_rollback; return 1
    fi

    if ! webssh_verify_http "$port" "$internal" "$user" "$pass"; then
        webssh_err 'HTTP/认证验证失败。'
        rm -rf -- "$tmp"; webssh_rollback; return 1
    fi

    webssh_check_owned || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    printf '%s|%s|%s|%s|%s|%s\n' "$user" "$pass" "$port" "$internal" "$WEBSSH_VERSION" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        | webssh_owned_fs write-data "$etc" "${WEBSSH_OWNED[$etc]}" meta 0600 root new \
        || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    webssh_check_owned || { rm -rf -- "$tmp"; webssh_rollback; return 1; }
    rm -rf -- "$tmp"

    webssh_report "$port"
}

webssh_report() {
    local port=$1
    printf '\n安装完成，%s 与 %s 已设为开机自启。\n' "$WEBSSH_UNIT_NAME" "$WEBSSH_NGINX_UNIT_NAME"
    printf '访问地址（本机）：http://127.0.0.1:%s/\n' "$port"
    printf '凭据保存在 %s/meta（仅 root 可读；密码不输出）。\n' "$(webssh_etc)"
    printf '\n已验证：\n'
    printf '  [已验证] 两个单元 active，且仅监听 127.0.0.1（%s / 内部端口）\n' "$port"
    printf '  [已验证] 未认证 401、错误密码 401、正确密码 200，websocket 升级 101\n'
    printf '\n仍需人工处理：\n'
    printf '  - 远程访问：自行用 TLS 反代或隧道指向 127.0.0.1:%s（Basic 认证是明文 HTTP）\n' "$port"
    printf '    反代必须保留原 Host 头（WebSSH 默认同源校验，改 Host 会 403）\n'
    printf '  - 防火墙/安全组：本模块不改；放行的是你的 TLS 入口，不是这个回环端口\n'
    printf '  - 首次登录后自行在页面里填 SSH 目标、用户名和密码\n'
    printf '  - 卸载：toolbox_webssh uninstall\n'
}

# ---------------------------------------------------------------- 卸载 / 状态

_webssh_uninstall() {
    local etc opt lib log run state answer
    local -A WEBSSH_OWNED=()
    webssh_require_root || return 1
    webssh_require_systemd || return 1
    etc=$(webssh_etc); opt=$(webssh_opt); lib=$(webssh_lib); log=$(webssh_log); run=$(webssh_run)
    state=$(webssh_unit_state "$(webssh_unit)" "ExecStart=$(webssh_wssh)")
    if [[ $state == absent && ! -e $(webssh_nginx_unit) && ! -d $etc && ! -d $opt ]]; then
        webssh_die '没有找到本模块的安装。'
        return 1
    fi
    if [[ $state == foreign ]]; then
        webssh_die "$(webssh_unit) 不是本模块生成的，未删除；请人工确认。"
        return 1
    fi
    if [[ -e $(webssh_nginx_unit) ]] \
        && ! grep -qF -- "ExecStart=$(webssh_nginx) -c $(webssh_etc)/nginx.conf" "$(webssh_nginx_unit)"; then
        webssh_die "$(webssh_nginx_unit) 不是本模块生成的，未删除；请人工确认。"
        return 1
    fi

    webssh_load_owned || return 1
    printf '将停止并删除：\n  %s\n  %s\n  %s\n  %s\n  %s\n  %s\n  %s\n' \
        "$(webssh_nginx_unit)" "$(webssh_unit)" "$etc" "$opt" "$lib" "$log" "$run"
    printf '确认卸载？输入 YES：'
    IFS= read -r answer || { webssh_die '输入结束，已取消。'; return 1; }
    [[ ${answer^^} == YES ]] || { webssh_die '已取消。'; return 1; }

    exec 9>>"$(webssh_lock)" || { webssh_die '无法创建锁文件'; return 1; }
    flock -n 9 || { webssh_die '另一个安装/卸载正在进行。'; return 1; }

    webssh_check_owned || return 1
    webssh_stop_confirmed || return 1
    # disable --now 期间也可能置换目录；在删除任意目标前复查全部归属。
    webssh_check_owned || return 1
    webssh_remove_owned || return 1
    systemctl daemon-reload >/dev/null 2>&1 || { webssh_die '文件已清理，但 daemon-reload 失败。'; return 1; }
    systemctl reset-failed "$WEBSSH_NGINX_UNIT_NAME" >/dev/null 2>&1 || true
    systemctl reset-failed "$WEBSSH_UNIT_NAME" >/dev/null 2>&1 || true

    printf '已卸载（apt 补装的 nginx/python3-venv 保留）。\n'
}

webssh_unit_summary() {
    webssh_unit_facts "$1" || return 1
    printf '  LoadState=%s\n  ActiveState=%s\n  SubState=%s\n  MainPID=%s\n' \
        "$WEBSSH_LOAD_STATE" "$WEBSSH_ACTIVE_STATE" "$WEBSSH_SUB_STATE" "$WEBSSH_MAIN_PID"
}

webssh_status() {
    local user pass port internal version installed
    if [[ ! -e $(webssh_unit) ]]; then
        printf '未安装。\n'
        return 1
    fi
    IFS='|' read -r user pass port internal version installed < "$(webssh_etc)/meta" 2>/dev/null || true
    printf '单元: %s\n' "$(webssh_unit)"
    webssh_unit_summary "$WEBSSH_UNIT_NAME" || return 1
    printf '前端: %s\n' "$(webssh_nginx_unit)"
    webssh_unit_summary "$WEBSSH_NGINX_UNIT_NAME" || return 1
    if webssh_valid_port "${port:-}"; then
        printf '监听 127.0.0.1:%s：' "$port"
        webssh_port_owned_by "$port" "$WEBSSH_NGINX_UNIT_NAME" && printf '由本模块 nginx 持有\n' \
            || printf '不是本模块 nginx\n'
        printf '访问：http://127.0.0.1:%s/\n' "$port"
        printf '凭据文件：%s/meta（仅 root 可读；密码不输出）\n' "$(webssh_etc)"
    fi
    [[ -n ${version:-} ]] && printf '版本 %s，安装于 %s\n' "$version" "${installed:-未知}"
}

# 安装/卸载放子 shell：锁随子 shell 释放；失败显式检查，不依赖条件调用中的 errexit。
webssh_install() { ( set -e; _webssh_install "$@" ) ; }
webssh_uninstall() { ( set -e; _webssh_uninstall "$@" ) ; }

# ---------------------------------------------------------------- 入口

toolbox_webssh() {
    local action=${1:-install}
    if (( $# > 0 )); then shift; fi
    case $action in
        install) webssh_install "$@" ;;
        uninstall) webssh_uninstall "$@" ;;
        status) webssh_status ;;
        *) webssh_die '用法: toolbox_webssh [install [回环端口] | uninstall | status]' ;;
    esac
}

# 直接执行也可用；sourcing 不产生副作用。
if [[ ${BASH_SOURCE[0]:-} == "$0" && ${TOOLBOX_BUNDLED:-0} != 1 ]]; then
    toolbox_webssh "$@"
fi
