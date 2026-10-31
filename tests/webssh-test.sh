#!/usr/bin/env bash
# Isolated regression for B10 WebSSH: every system command is a mock; no host
# service, package, port or systemd unit is touched. Real files are written only
# under a fresh temporary directory via the TOOLBOX_WEBSSH_* path override.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/scratch-root.sh"
toolbox_test_scratch
TEST_SCRATCH=$TMPDIR
TEST_DIR=$(mktemp -d "$TMPDIR/toolbox-webssh.XXXXXXXX")
cleanup_packages() {
    local rc=$?
    if [[ -s $TEST_DIR/package-boundary.log ]]; then
        printf 'FAIL: unmocked package command\n' >&2
        command cat "$TEST_DIR/package-boundary.log" >&2
        rc=1
    fi
    rm -rf -- "$TEST_DIR"
    exit "$rc"
}
trap cleanup_packages EXIT
# Physical package guards also cover child Bash and an empty environment.
mkdir -p "$TEST_DIR/package-deny"
: > "$TEST_DIR/package-boundary.log"
for manager in sudo apt apt-get apt-cache aptitude apk dpkg dpkg-query dpkg-deb dnf yum rpm; do
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$0 $*" >> %q\n' "$TEST_DIR/package-boundary.log"
        printf 'exit 99\n'
    } > "$TEST_DIR/package-deny/$manager"
    chmod 0755 "$TEST_DIR/package-deny/$manager"
done
export PATH="$TEST_DIR/package-deny:$PATH"
for guard_env in inherited empty; do
    if [[ $guard_env == empty ]]; then
        env -i PATH="$PATH" bash --noprofile --norc -c 'apt-get --fixture-guard-probe' && exit 1 || [[ $? == 99 ]]
    else
        bash --noprofile --norc -c 'apt-get --fixture-guard-probe' && exit 1 || [[ $? == 99 ]]
    fi
done
[[ $(wc -l < "$TEST_DIR/package-boundary.log") -eq 2 ]]
: > "$TEST_DIR/package-boundary.log"
export HOME="$TEST_DIR/home" TMPDIR="$TEST_DIR/tmp"
mkdir -p "$HOME" "$TMPDIR"

export LOG="$TEST_DIR/commands.log"
export STATE="$TEST_DIR/state"
export TOOLBOX_WEBSSH_ETC="$TEST_DIR/etc"
export TOOLBOX_WEBSSH_OPT="$TEST_DIR/opt"
export TOOLBOX_WEBSSH_LIB="$TEST_DIR/lib"
export TOOLBOX_WEBSSH_LOG="$TEST_DIR/log"
export TOOLBOX_WEBSSH_RUN="$TEST_DIR/run"
export TOOLBOX_WEBSSH_UNIT_DIR="$TEST_DIR/units"
export TOOLBOX_WEBSSH_LOCK="$TEST_DIR/webssh.lock"
export TOOLBOX_WEBSSH_UID=0
export TOOLBOX_WEBSSH_WAIT_TRIES=2
mkdir -p "$TEST_DIR/bin"
export TOOLBOX_WEBSSH_NGINX="$TEST_DIR/bin/nginx"
export PATH="$TEST_DIR/bin:$PATH"
export TOOLBOX_WEBSSH_OS_RELEASE="$TEST_DIR/os-release"
export TOOLBOX_WEBSSH_SYSTEMD_RUN="$TEST_DIR/systemd-run"
export TOOLBOX_WEBSSH_SDIST_SRC="$TEST_DIR/webssh.tar.gz"
export TOOLBOX_WEBSSH_SDIST_SHA256
export MOCK_USER=terry MOCK_PASS='S3cret-pass-123'

printf 'ID=debian\n' > "$TOOLBOX_WEBSSH_OS_RELEASE"
mkdir -p "$TOOLBOX_WEBSSH_SYSTEMD_RUN"
printf 'fake sdist for webssh 1.6.3\n' > "$TOOLBOX_WEBSSH_SDIST_SRC"
TOOLBOX_WEBSSH_SDIST_SHA256=$(sha256sum "$TOOLBOX_WEBSSH_SDIST_SRC" | cut -d' ' -f1)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_log() { grep -F -- "$1" "$LOG" >/dev/null || fail "missing command: $1"; }
assert_no_log() { ! grep -F -- "$1" "$LOG" >/dev/null || fail "unexpected command: $1"; }
public_port=18081
password='S3cret-pass-123'
# username, password, password (confirmation), YES
# 用户名、密码、密码确认、YES
input_ok=$'terry\n'"$password"$'\n'"$password"$'\nYES\n'

mkdir -p "$STATE/active" "$STATE/pid" "$TOOLBOX_WEBSSH_UNIT_DIR"
: > "$STATE/ports"
# 模拟 PID 放到内核可分配范围之外，绝不与宿主真实进程碰撞。
pid_max=$(< /proc/sys/kernel/pid_max)
[[ $pid_max =~ ^[0-9]+$ ]] || fail 'cannot read kernel pid_max'
pid_seq=$((pid_max + 10000))
[[ ! -e /proc/$pid_seq ]] || fail 'mock PID collides with a live process'

test_isolation() {
    local path boundary
    [[ $TEST_DIR == "$TEST_SCRATCH"/toolbox-webssh.* && -d $TEST_DIR && ! -L $TEST_DIR ]] \
        || fail 'unsafe test root'
    for path in "$HOME" "$TMPDIR" "$LOG" "$STATE" "$TOOLBOX_WEBSSH_ETC" "$TOOLBOX_WEBSSH_OPT" \
        "$TOOLBOX_WEBSSH_LIB" "$TOOLBOX_WEBSSH_LOG" "$TOOLBOX_WEBSSH_RUN" "$TOOLBOX_WEBSSH_UNIT_DIR" \
        "$TOOLBOX_WEBSSH_LOCK" "$TOOLBOX_WEBSSH_NGINX" "$TOOLBOX_WEBSSH_OS_RELEASE" \
        "$TOOLBOX_WEBSSH_SYSTEMD_RUN" "$TOOLBOX_WEBSSH_SDIST_SRC"; do
        [[ $path == "$TEST_DIR/"* && $path != *'/../'* ]] || fail "unisolated path: $path"
    done
    for boundary in systemctl ss curl openssl python3 apt-get getent install cat; do
        [[ $(type -t "$boundary") == function ]] || fail "unmocked boundary: $boundary"
    done
}

# ------------------------------------------------------------------ mocks
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$LOG"
    local unit port name
    case ${1-} in
        is-active)
            [[ -e $STATE/active/${3-} ]]
            ;;
        show)
            unit=${!#}
            [[ ${MOCK_STATUS_UNREADABLE:-0} != 1 ]] || return 1
            [[ ${MOCK_STATUS_EMPTY:-0} != 1 ]] || return 0
            local -a properties=()
            local value_only=0 property value
            shift
            while (( $# > 1 )); do
                case $1 in
                    -p|--property) properties+=("$2"); shift 2 ;;
                    --value) value_only=1; shift ;;
                    *) printf 'unexpected systemctl show option: %s\n' "$1" >&2; return 1 ;;
                esac
            done
            for property in "${properties[@]}"; do
                [[ ${MOCK_STATUS_PARTIAL:-0} != 1 || $property != SubState ]] || continue
                case $property in
                    LoadState)
                        [[ -e $TOOLBOX_WEBSSH_UNIT_DIR/$unit ]] && value=loaded || value=not-found ;;
                    ActiveState)
                        [[ -e $STATE/active/$unit ]] && value=active || value=inactive ;;
                    SubState)
                        [[ -e $STATE/active/$unit ]] && value=running || value=dead ;;
                    MainPID)
                        value=0; [[ ! -e $STATE/pid/$unit ]] || value=$(<"$STATE/pid/$unit") ;;
                    *) printf 'unexpected systemctl show property: %s\n' "$property" >&2; return 1 ;;
                esac
                if (( value_only )); then printf '%s\n' "$value"; else printf '%s=%s\n' "$property" "$value"; fi
            done
            if [[ ${MOCK_STATUS_CONFLICT:-0} == 1 ]]; then printf 'ActiveState=active\nActiveState=inactive\n'; fi
            return 0
            ;;
        enable)
            unit=${3-}
            [[ $unit == *nginx* ]] && name=nginx || name=wssh
            if [[ $name == nginx ]]; then
                [[ ${MOCK_ENABLE_NGINX_FAIL:-0} != 1 ]] || return 1
                port=$(sed -n 's/.*listen 127\.0\.0\.1:\([0-9]*\);.*/\1/p' "$TOOLBOX_WEBSSH_ETC/nginx.conf" | head -n1)
            else
                [[ ${MOCK_ENABLE_WEBSSH_FAIL:-0} != 1 ]] || return 1
                port=$(sed -n 's/.*--port=\([0-9]*\).*/\1/p' "$TOOLBOX_WEBSSH_UNIT_DIR/terry-toolbox-webssh.service" | head -n1)
            fi
            ((pid_seq += 1))
            printf '%s\n' "$pid_seq" > "$STATE/pid/$unit"
            if [[ $name == wssh && ${MOCK_ACTIVE_WEBSSH_FAIL:-0} == 1 ]]; then :; else
                : > "$STATE/active/$unit"
                printf '127.0.0.1 %s %s %s\n' "$port" "$pid_seq" "$name" >> "$STATE/ports"
            fi
            ;;
        disable)
            unit=${3-}
            [[ ${MOCK_DISABLE_FAIL:-0} != 1 && ${MOCK_DISABLE_FAIL_UNIT:-} != "$unit" ]] || return 1
            [[ ${MOCK_DISABLE_LIES:-0} != 1 ]] || return 0
            rm -f "$STATE/active/$unit"
            if [[ ${MOCK_REPLACE_LIB_ON_STOP:-0} == 1 && $unit == "$WEBSSH_UNIT_NAME" ]]; then
                mv "$TOOLBOX_WEBSSH_LIB" "$TEST_DIR/lib-original"
                mkdir "$TOOLBOX_WEBSSH_LIB"; printf foreign > "$TOOLBOX_WEBSSH_LIB/sentinel"
            fi
            if [[ -e $STATE/pid/$unit ]]; then
                grep -v " $(cat "$STATE/pid/$unit") " "$STATE/ports" > "$STATE/ports.new" || :
                mv "$STATE/ports.new" "$STATE/ports"
                rm -f "$STATE/pid/$unit"
            fi
            ;;
        daemon-reload)
            printf '%s\n' "$(( $(<"$STATE/reload-count") + 1 ))" > "$STATE/reload-count"
            [[ ${MOCK_RELOAD_FAIL_AT:-0} != $(<"$STATE/reload-count") ]] ;;
        reset-failed) : ;;
        status) printf 'mock unit status for %s\n' "${4-}" ;;
        --no-pager) printf 'mock unit status for %s\n' "${5-}" ;;
        *) printf 'unexpected systemctl: %s\n' "$*" >&2; return 1 ;;
    esac
}
ss() {
    printf 'ss %s\n' "$*" >> "$LOG"
    local addr port pid name
    while read -r addr port pid name; do
        printf 'LISTEN 0 511 %s:%s 0.0.0.0:* users:(("%s",pid=%s,fd=5))\n' "$addr" "$port" "$name" "$pid"
    done < "$STATE/ports"
}
curl() {
    local url='' out='' creds='' code path
    printf 'curl' >> "$LOG"
    local redact=0 arg
    for arg in "$@"; do
        if (( redact )); then printf ' [REDACTED]' >> "$LOG"; redact=0
        else printf ' %s' "$arg" >> "$LOG"; [[ $arg != -u ]] || redact=1; fi
    done
    printf '\n' >> "$LOG"
    while (( $# )); do
        case $1 in
            -o) out=$2; shift 2 ;;
            -u) creds=$2; shift 2 ;;
            --config)
                IFS= read -r creds || :
                creds=${creds#user = \"}; creds=${creds%\"}
                shift 2 ;;
            --max-time|-H|-w) shift 2 ;;
            -*) shift ;;
            *) url=$1; shift ;;
        esac
    done
    if [[ $url == *.tar.gz ]]; then
        [[ ${MOCK_DL_FAIL:-0} != 1 ]] || return 1
        cp -- "$TOOLBOX_WEBSSH_SDIST_SRC" "$out"; return 0
    fi
    path=${url#http://127.0.0.1:}; path=/${path#*/}
    # 正确密码由用户输入或随机生成，测试端拿不到明文；约定「错误密码」带 wrong- 前缀。
    local cuser=${creds%%:*} cpass=${creds#*:}
    if [[ ${MOCK_ALWAYS_200:-0} == 1 ]]; then
        code=200
    elif [[ -n $creds && $cuser == "$MOCK_USER" && $cpass != wrong-* ]]; then
        if [[ $path == /ws* ]]; then
            if [[ ${MOCK_WS_401:-0} == 1 ]]; then code=401; else code=101; fi
        elif [[ $path == /static/* ]]; then code=200
        else code=200; fi
    else
        code=401
    fi
    if [[ $code == 200 && $path != /static/* ]]; then
        [[ -n $out && $out != /dev/null ]] && printf '<title>WebSSH</title>\n' > "$out"
    fi
    printf '%s' "$code"
}

openssl() {
    printf 'openssl %s\n' "$*" >> "$LOG"
    case $* in
        'rand -base64 48') printf 'abcdefghijklmnopqrstuvwxABCDEFGH\n' ;;
        'rand -hex 4') printf '0badcafe\n' ;;
        'passwd -apr1'*)
            read -r _pass || :   # 密码经 stdin 传入，读取只为证明管道可用
            # shellcheck disable=SC2016 # 固定的测试哈希，不展开为 shell 变量。
            printf '$apr1$0badcafe$M2l.4TYXnyM/reK20xwlY.\n'
            ;;
        *) return 1 ;;
    esac
}
# 模拟 venv 内容：wssh/pip/python 都是记录调用的小脚本，错误注入靠环境变量。
write_stubs() {
    local dir=$1
    mkdir -p "$dir/bin"
    cat > "$dir/bin/wssh" <<'EOS'
#!/bin/bash
printf 'wssh %s\n' "$*" >> "$LOG"
EOS
    cat > "$dir/bin/pip" <<'EOS'
#!/bin/bash
printf 'pip %s\n' "$*" >> "$LOG"
case ${1-} in
    show)
        [[ ${MOCK_BAD_VERSION:-0} == 1 ]] && printf 'Version: 9.9.9\n' || printf 'Version: 1.6.3\n'
        [[ ${MOCK_VENV_SHOW_FAIL:-0} != 1 ]] ;;
    install) [[ ${MOCK_PIP_FAIL:-0} != 1 ]] ;;
esac
EOS
    printf '#!/bin/bash\nexit 0\n' > "$dir/bin/python"
    chmod +x "$dir/bin/wssh" "$dir/bin/pip" "$dir/bin/python"
}
python3() {
    printf 'python3 %s\n' "$*" >> "$LOG"
    if [[ ${2-} == '# webssh-python-capabilities'* ]]; then
        [[ ${MOCK_PYTHON_OLD:-0} == 0 ]] || return 1
        command python3 "$@"; return
    fi
    if [[ ${2-} == '# webssh-owned-fs'* ]]; then
        if [[ ${3-} == create-dir && ${4-} == "${MOCK_RACE_DIR:-}" ]]; then
            mkdir -p "${4}"; printf 'foreign-race\n' > "${4}/sentinel"
        fi
        if [[ ${MOCK_REMOVE_IO_FAIL:-0} == 1 && ${3-} == remove && ${4-} == "$TOOLBOX_WEBSSH_LOG" ]]; then
            local code=$2
            # 隔离后真实 rmtree 抛 I/O 错误；要求把同 inode 目标放回以便重试。
            code=${code/'shutil.rmtree(stage, dir_fd=fd)'/'raise OSError("injected remove I/O failure")'}
            shift 2; command python3 -c "$code" "$@"
        elif [[ ${MOCK_REMOVE_RACE:-0} == 1 && ${3-} == remove && ${4-} == "$TOOLBOX_WEBSSH_LOG" ]]; then
            local code=$2
            # 在真实 helper 的检查与 renameat2 之间置换目录，验证隔离后复核。
            code=${code/'def move(fd, source, target):'/$'def move(fd, source, target):\n    if target.startswith(".webssh-delete-"):\n        os.rename(source, source + "-original", src_dir_fd=fd, dst_dir_fd=fd)\n        os.mkdir(source, dir_fd=fd)\n        f = os.open(source + "/sentinel", os.O_WRONLY | os.O_CREAT, 0o600, dir_fd=fd)\n        os.write(f, b"foreign-race"); os.close(f)'}
            shift 2; command python3 -c "$code" "$@"
        else command python3 "$@"; fi
        return
    fi
    case ${1-} in
        -c) return 0 ;;
        -m)
            if [[ ${MOCK_RACE_UNIT:-0} == 1 ]]; then
                printf 'foreign-unit\n' > "$TOOLBOX_WEBSSH_UNIT_DIR/terry-toolbox-webssh-nginx.service"
            fi
            if [[ -n ${MOCK_REPLACE_ETC_ON_SUCCESS:-} ]]; then
                mv "$TOOLBOX_WEBSSH_ETC" "$TEST_DIR/etc-original"
                mkdir "$TOOLBOX_WEBSSH_ETC"
                printf 'foreign-replacement\n' > "$TOOLBOX_WEBSSH_ETC/sentinel"
            fi
            if [[ ${MOCK_REPLACE_LIB_ON_FAIL:-0} == 1 ]]; then
                mv "$TOOLBOX_WEBSSH_LIB" "$TEST_DIR/lib-original"
                mkdir "$TOOLBOX_WEBSSH_LIB"
                printf 'foreign-replacement\n' > "$TOOLBOX_WEBSSH_LIB/sentinel"
                return 1
            fi
            [[ ${MOCK_VENV_FAIL:-0} != 1 ]] || return 1
            write_stubs "${!#}"
            ;;
    esac
}
apt-get() { printf 'apt-get %s\n' "$*" >> "$LOG"; }
install() {
    if [[ $* == *"${MOCK_RACE_DIR:-__no_race__}"* && ${MOCK_RACE_DIR:-} != '' ]]; then
        mkdir -p "$MOCK_RACE_DIR"; printf 'foreign-race\n' > "$MOCK_RACE_DIR/sentinel"
    fi
    command install "$@"
}
cat() {
    command cat "$@" || return 1
    # 模拟写入完整/部分内容后报告 I/O 错误；不能靠下一条命令掩盖失败。
    local writer_pid=$BASHPID
    if [[ ${MOCK_UNIT_WRITE_FAIL:-0} == 1 && $# == 0 \
        && $(readlink "/proc/$writer_pid/fd/1") == */backend.service ]]; then
        printf 'cat injected unit write failure\n' >> "$LOG"
        return 1
    fi
}
getent() { printf 'getent %s\n' "$*" >> "$LOG"; printf 'www-data:x:33:33::/var/www:/usr/sbin/nologin\n'; }
# nginx 必须是可执行的绝对路径（systemd ExecStart 需要），所以用文件而不是函数。
cat > "$TOOLBOX_WEBSSH_NGINX" <<'EOS'
#!/bin/bash
printf 'nginx %s\n' "$*" >> "$LOG"
if [[ ${1-} == -t ]]; then
    [[ ${MOCK_NGINX_T_FAIL:-0} != 1 ]] && exit 0 || exit 1
fi
exit 0
EOS
chmod +x "$TOOLBOX_WEBSSH_NGINX"
export -f systemctl ss curl openssl python3 apt-get getent write_stubs install cat
export TEST_DIR
export LOG STATE MOCK_USER MOCK_PASS TOOLBOX_WEBSSH_ETC TOOLBOX_WEBSSH_UNIT_DIR TOOLBOX_WEBSSH_SDIST_SRC

reset() {
    : > "$LOG"
    : > "$STATE/ports"
    printf '0\n' > "$STATE/reload-count"
    rm -rf "$STATE/active" "$STATE/pid" "$TOOLBOX_WEBSSH_ETC" "$TOOLBOX_WEBSSH_OPT" \
        "$TOOLBOX_WEBSSH_LIB" "$TOOLBOX_WEBSSH_LOG" "$TOOLBOX_WEBSSH_RUN"
    rm -f "$TOOLBOX_WEBSSH_UNIT_DIR/terry-toolbox-webssh.service" \
        "$TOOLBOX_WEBSSH_UNIT_DIR/terry-toolbox-webssh-nginx.service" "$TOOLBOX_WEBSSH_LOCK"
    mkdir -p "$STATE/active" "$STATE/pid"
    unset MOCK_PYTHON_OLD MOCK_PIP_FAIL MOCK_ENABLE_WEBSSH_FAIL MOCK_ENABLE_NGINX_FAIL MOCK_ACTIVE_WEBSSH_FAIL \
        MOCK_NGINX_T_FAIL MOCK_ALWAYS_200 MOCK_WS_401 MOCK_BAD_VERSION MOCK_VENV_FAIL MOCK_DL_FAIL \
        MOCK_DISABLE_FAIL MOCK_DISABLE_FAIL_UNIT MOCK_DISABLE_LIES MOCK_STATUS_UNREADABLE MOCK_STATUS_EMPTY \
        MOCK_RACE_DIR MOCK_RACE_UNIT MOCK_REPLACE_LIB_ON_FAIL MOCK_UNIT_WRITE_FAIL MOCK_REPLACE_ETC_ON_SUCCESS MOCK_STATUS_PARTIAL MOCK_STATUS_CONFLICT MOCK_REPLACE_LIB_ON_STOP MOCK_REMOVE_RACE MOCK_RELOAD_FAIL_AT MOCK_REMOVE_IO_FAIL MOCK_VENV_SHOW_FAIL || :
    rm -rf "$TEST_DIR/lib-original" "$TEST_DIR/etc-original" "$TEST_DIR/log-original" "$TEST_DIR/link-target"
}
install_ok() { toolbox_webssh install "$public_port" <<< "$input_ok"; }
webssh_unit_file="$TOOLBOX_WEBSSH_UNIT_DIR/terry-toolbox-webssh.service"
nginx_unit_file="$TOOLBOX_WEBSSH_UNIT_DIR/terry-toolbox-webssh-nginx.service"

# ------------------------------------------------------------------ sourcing
test_isolation
printf 'ISOLATION PASS: HOME/paths under scratch; privileged commands mocked; mock PID > %s\n' "$pid_max"
# shellcheck source=../modules/webssh.sh
source "$script_dir/../modules/webssh.sh"
[[ ! -s $LOG ]] || fail 'sourcing executed commands'

# Run each safety regression independently so RED evidence names every defect.
regression_stop_guard() {
    local injection=$1 action=${2:-uninstall}
    reset
    if [[ $action == uninstall ]]; then
        install_ok >/dev/null 2>&1 || fail 'guard fixture install failed'
        export "${injection?}"
        if out=$(toolbox_webssh uninstall <<< YES 2>&1); then fail "$injection uninstall succeeded"; fi
    else
        export "${injection?}" MOCK_WS_401=1
        if out=$(install_ok 2>&1); then fail "$injection rollback install succeeded"; fi
    fi
    [[ -e $webssh_unit_file && -e $nginx_unit_file && -e $TOOLBOX_WEBSSH_ETC/htpasswd \
        && -x $TOOLBOX_WEBSSH_OPT/venv/bin/wssh && -d $TOOLBOX_WEBSSH_LIB \
        && -d $TOOLBOX_WEBSSH_LOG && -d $TOOLBOX_WEBSSH_RUN ]] || fail "$injection deleted files before confirmed stop"
    [[ $out != *'已卸载'* && $out != *'已恢复到安装前状态'* ]] || fail "$injection claimed cleanup success"
}
regression_foreign_path() {
    local name=$1 kind=$2 path
    reset
    case $name in
        etc) path=$TOOLBOX_WEBSSH_ETC ;; opt) path=$TOOLBOX_WEBSSH_OPT ;;
        lib) path=$TOOLBOX_WEBSSH_LIB ;; log) path=$TOOLBOX_WEBSSH_LOG ;; run) path=$TOOLBOX_WEBSSH_RUN ;;
    esac
    case $kind in
        dir) mkdir "$path"; printf 'foreign\n' > "$path/sentinel" ;;
        file) printf 'foreign\n' > "$path" ;;
        link) mkdir "$TEST_DIR/link-target"; printf 'foreign\n' > "$TEST_DIR/link-target/sentinel"; ln -s "$TEST_DIR/link-target" "$path" ;;
        dangling) ln -s "$TEST_DIR/absent" "$path" ;;
    esac
    if out=$(TOOLBOX_WEBSSH_SDIST_SHA256=bad install_ok 2>&1); then fail "$name/$kind accepted"; fi
    [[ -e $path || -L $path ]] || fail "$name/$kind foreign path deleted"
    case $kind in
        dir|link) [[ $(<"$path/sentinel") == foreign ]] || fail "$name/$kind sentinel changed" ;;
        file) [[ $(<"$path") == foreign ]] || fail "$name/$kind file changed" ;;
        dangling) [[ -L $path ]] || fail "$name dangling symlink removed" ;;
    esac
    assert_no_log 'systemctl disable'
    assert_no_log 'python3 -m venv'
}
regression_race_dir() {
    reset
    export MOCK_RACE_DIR="$TOOLBOX_WEBSSH_LIB"
    if out=$(TOOLBOX_WEBSSH_SDIST_SHA256=bad install_ok 2>&1); then fail 'raced directory accepted'; fi
    [[ -e $TOOLBOX_WEBSSH_LIB/sentinel ]] || fail 'raced directory deleted'
    [[ ! -e $TOOLBOX_WEBSSH_ETC && ! -e $TOOLBOX_WEBSSH_OPT ]] || fail 'owned partial paths not cleaned'
    assert_no_log 'systemctl disable'
}
regression_race_unit() {
    reset
    export MOCK_RACE_UNIT=1
    if out=$(install_ok 2>&1); then fail 'raced foreign unit overwritten'; fi
    [[ -e $nginx_unit_file && $(<"$nginx_unit_file") == foreign-unit ]] || fail 'raced foreign unit deleted'
    assert_no_log 'systemctl disable'
}
regression_replaced_dir() {
    reset
    export MOCK_REPLACE_LIB_ON_FAIL=1
    if out=$(install_ok 2>&1); then fail 'replacement fixture install succeeded'; fi
    [[ -e $TOOLBOX_WEBSSH_LIB/sentinel ]] || fail 'replacement directory deleted'
}
regression_eof() {
    local label=$1 input=$2
    reset
    printf '%s' "$input" > "$TEST_DIR/credential-input"
    WEBSSH_PASS_GENERATED=1 WEBSSH_PASS_INPUT=stale WEBSSH_USER_INPUT=stale
    if webssh_read_credentials terry < "$TEST_DIR/credential-input" > "$TEST_DIR/credential-output" 2>&1; then fail "$label EOF accepted"; fi
    out=$(<"$TEST_DIR/credential-output")
    [[ $out == *'取消'* ]] || fail "$label EOF did not report cancellation"
    [[ $WEBSSH_PASS_GENERATED == 0 && -z $WEBSSH_PASS_INPUT && -z $WEBSSH_USER_INPUT ]] || fail "$label EOF left stale credentials"
    assert_no_log 'openssl rand -base64'
}
regression_secret_output() {
    reset
    out=$(install_ok 2>&1) || fail 'secret fixture install failed'
    [[ $out != *"$password"* ]] || fail 'hidden password printed at install'
    out=$(toolbox_webssh status 2>&1) || fail 'secret fixture status failed'
    [[ $out != *"$password"* ]] || fail 'password printed at status'
    assert_no_log "$password"
    assert_no_log ' -u '
}

regression_owned_uninstall() {
    local label=$1
    reset
    install_ok >/dev/null 2>&1 || fail 'ownership fixture install failed'
    case $label in
        lib) mv "$TOOLBOX_WEBSSH_LIB" "$TEST_DIR/lib-original"; mkdir "$TOOLBOX_WEBSSH_LIB"; printf foreign > "$TOOLBOX_WEBSSH_LIB/sentinel" ;;
        unit) printf 'foreign\n' > "$nginx_unit_file" ;;
        manifest) rm "$TOOLBOX_WEBSSH_ETC/owned-paths" ;;
        manifest-partial)
            grep -vF "$TOOLBOX_WEBSSH_LIB|" "$TOOLBOX_WEBSSH_ETC/owned-paths" > "$TEST_DIR/manifest-new"
            command cat "$TEST_DIR/manifest-new" > "$TOOLBOX_WEBSSH_ETC/owned-paths" ;;
        missing-dir) mv "$TOOLBOX_WEBSSH_LIB" "$TEST_DIR/lib-original" ;;
    esac
    : > "$LOG"
    if out=$(toolbox_webssh uninstall <<< YES 2>&1); then fail "foreign uninstall/$label succeeded"; fi
    [[ -e $webssh_unit_file && -e $nginx_unit_file && -e $TOOLBOX_WEBSSH_ETC/meta \
        && -x $TOOLBOX_WEBSSH_OPT/venv/bin/wssh ]] || fail "foreign uninstall/$label removed files"
    [[ -e $STATE/active/$WEBSSH_UNIT_NAME && -e $STATE/active/$WEBSSH_NGINX_UNIT_NAME ]] || fail "foreign uninstall/$label stopped services"
    assert_no_log 'systemctl disable'
}
regression_parent_symlink() {
    reset
    mkdir "$TEST_DIR/link-target"; ln -s "$TEST_DIR/link-target" "$TEST_DIR/parent-link"
    if out=$(TOOLBOX_WEBSSH_LIB="$TEST_DIR/parent-link/lib" install_ok 2>&1); then fail 'symlink parent accepted'; fi
    [[ ! -e $TEST_DIR/link-target/lib && ! -e $TOOLBOX_WEBSSH_ETC ]] || fail 'symlink parent wrote files'
    rm "$TEST_DIR/parent-link"
}
regression_stop_retry() {
    reset
    install_ok >/dev/null 2>&1 || fail 'retry fixture install failed'
    if out=$(MOCK_DISABLE_FAIL=1 toolbox_webssh uninstall <<< YES 2>&1); then fail 'failed stop retry fixture succeeded'; fi
    out=$(toolbox_webssh uninstall <<< YES 2>&1) || fail 'confirmed stop retry failed'
    [[ ! -e $TOOLBOX_WEBSSH_ETC && ! -e $webssh_unit_file && ! -e $nginx_unit_file ]] || fail 'retry left owned files'
}
regression_conditional_write() {
    reset
    export MOCK_UNIT_WRITE_FAIL=1
    # 父菜单在 || 中调用：整个调用链的 errexit 会被 Bash 禁用。
    if out=$(install_ok 2>&1); then fail 'conditional unit write failure accepted'; fi
    [[ ! -e $webssh_unit_file && ! -e $nginx_unit_file && ! -e $TOOLBOX_WEBSSH_ETC \
        && ! -e $TOOLBOX_WEBSSH_OPT ]] || fail 'conditional write failure left files'
    assert_log 'cat injected unit write failure'
    assert_no_log 'systemctl enable'
}
regression_missing_tool() {
    reset
    # 只覆盖命令发现；实际特权边界仍保留 mocks。
    # shellcheck disable=SC2317 # 此函数由被测模块里的 command -v 间接调用。
    command() {
        if [[ ${1-} == -v && ${2-} == curl ]]; then return 1; fi
        builtin command "$@"
    }
    source "$script_dir/../modules/dependencies.sh"
    _toolbox_deps_os() { printf 'debian\n'; }
    _toolbox_deps_ca_package() { return 0; }
    _toolbox_deps_confirm() { printf 'fixture: dependency installation declined\n' >&2; return 1; }
    if out=$(install_ok 2>&1); then fail 'missing curl accepted'; fi
    [[ $out == *'缺少命令：'* && ! -e $TOOLBOX_WEBSSH_ETC && ! -e $TOOLBOX_WEBSSH_LOCK ]] || fail 'missing curl wrote state'
    assert_no_log 'apt-get'
}
regression_python_old() {
    reset
    export MOCK_PYTHON_OLD=1
    if out=$(install_ok 2>&1); then fail 'unsupported Python install accepted'; fi
    [[ $out == *'Python 3.11+'* && ! -e $TOOLBOX_WEBSSH_ETC && ! -e $TOOLBOX_WEBSSH_LOCK ]] || fail 'unsupported Python wrote installation'
    assert_no_log 'apt-get'
    unset MOCK_PYTHON_OLD
    install_ok >/dev/null 2>&1 || fail 'Python uninstall setup'
    : > "$LOG"
    export MOCK_PYTHON_OLD=1
    if out=$(toolbox_webssh uninstall <<< 'YES' 2>&1); then fail 'unsupported Python uninstall accepted'; fi
    [[ $out == *'Python 3.11+'* && -d $TOOLBOX_WEBSSH_ETC ]] || fail 'unsupported Python damaged installation'
    assert_no_log 'systemctl disable'
}
regression_reload_failure() {
    local action=$1
    reset
    case $action in
        install) export MOCK_RELOAD_FAIL_AT=1 ;;
        uninstall|rollback) export MOCK_RELOAD_FAIL_AT=2 ;;
    esac
    case $action in
        uninstall)
            install_ok >/dev/null 2>&1 || fail 'reload fixture install failed'
            if out=$(toolbox_webssh uninstall <<< YES 2>&1); then fail 'uninstall reload failure accepted'; fi ;;
        rollback)
            export MOCK_WS_401=1
            if out=$(install_ok 2>&1); then fail 'rollback reload failure accepted'; fi ;;
        install)
            if out=$(install_ok 2>&1); then fail 'install reload failure accepted'; fi ;;
    esac
    [[ $out != *'已卸载'* && $out != *'安装完成'* ]] || fail 'reload failure claimed success'
    if [[ $action != install && $out == *'已恢复到安装前状态'* ]]; then fail 'failed cleanup reload claimed success'; fi
    [[ ! -e $TOOLBOX_WEBSSH_ETC && ! -e $webssh_unit_file && ! -e $nginx_unit_file ]] || fail 'reload failure left owned files'
    [[ ! -s $STATE/ports ]] || fail 'reload failure left mock listeners'
}
regression_remove_io_failure() {
    reset
    install_ok >/dev/null 2>&1 || fail 'remove I/O fixture install failed'
    if out=$(MOCK_REMOVE_IO_FAIL=1 toolbox_webssh uninstall <<< YES 2>&1); then fail 'remove I/O failure accepted'; fi
    [[ -e $TOOLBOX_WEBSSH_ETC/owned-paths && -d $TOOLBOX_WEBSSH_LOG ]] || fail 'remove I/O failure lost target or recovery path'
    [[ $out != *'已卸载'* ]] || fail 'remove I/O failure claimed success'
}
regression_venv_show_failure() {
    reset
    if out=$(MOCK_VENV_SHOW_FAIL=1 install_ok 2>&1); then fail 'failed pip show with valid output accepted'; fi
    [[ ! -e $TOOLBOX_WEBSSH_ETC && ! -e $webssh_unit_file ]] || fail 'failed pip show left files'
    assert_no_log 'systemctl enable'
}
regression_stop_replacement() {
    reset
    install_ok >/dev/null 2>&1 || fail 'stop replacement fixture install failed'
    if out=$(MOCK_REPLACE_LIB_ON_STOP=1 toolbox_webssh uninstall <<< YES 2>&1); then fail 'stop replacement accepted'; fi
    [[ $(<"$TOOLBOX_WEBSSH_LIB/sentinel") == foreign ]] || fail 'stop replacement deleted foreign files'
    [[ -e $webssh_unit_file && -e $nginx_unit_file && -e $TOOLBOX_WEBSSH_ETC/owned-paths \
        && -x $TOOLBOX_WEBSSH_OPT/venv/bin/wssh ]] || fail 'stop replacement removed other files'
}
regression_remove_race() {
    reset
    install_ok >/dev/null 2>&1 || fail 'remove race fixture install failed'
    if out=$(MOCK_REMOVE_RACE=1 toolbox_webssh uninstall <<< YES 2>&1); then fail 'remove race accepted'; fi
    [[ $(<"$TOOLBOX_WEBSSH_LOG/sentinel") == foreign-race ]] || fail 'remove race deleted foreign files'
    [[ -e $TOOLBOX_WEBSSH_ETC/owned-paths && $out != *'已卸载'* ]] || fail 'remove race discarded recovery or claimed success'
}
regression_status_guard() {
    local injection=$1
    reset
    install_ok >/dev/null 2>&1 || fail 'status fixture install failed'
    export "${injection?}"
    if out=$(toolbox_webssh status 2>&1); then fail "$injection status accepted"; fi
    [[ $out != *"$password"* ]] || fail 'status failure leaks password'
}
regression_replaced_config() {
    reset
    export MOCK_REPLACE_ETC_ON_SUCCESS=1
    if out=$(install_ok 2>&1); then fail 'replaced config install accepted'; fi
    [[ $(<"$TOOLBOX_WEBSSH_ETC/sentinel") == foreign-replacement ]] || fail 'replacement config sentinel changed'
    [[ ! -e $TOOLBOX_WEBSSH_ETC/htpasswd && ! -e $TOOLBOX_WEBSSH_ETC/nginx.conf \
        && ! -e $TOOLBOX_WEBSSH_ETC/owned-paths ]] || fail 'foreign config received writes'
    assert_no_log 'systemctl enable'
}
regression_install_eof() {
    local label=$1 input=$2
    reset
    printf '%s' "$input" > "$TEST_DIR/install-input"
    if out=$(toolbox_webssh install "$public_port" < "$TEST_DIR/install-input" 2>&1); then fail "$label install EOF accepted"; fi
    [[ $out == *'取消'* && ! -e $TOOLBOX_WEBSSH_ETC && ! -e $TOOLBOX_WEBSSH_LOCK ]] || fail "$label install EOF wrote files"
    assert_no_log 'openssl rand -base64'
    assert_no_log 'apt-get'
    assert_no_log 'python3 -m venv'
    assert_no_log 'systemctl enable'
}
run_regressions() {
    local failures=0 label injection name kind action input
    for injection in MOCK_DISABLE_FAIL=1 "MOCK_DISABLE_FAIL_UNIT=$WEBSSH_NGINX_UNIT_NAME" MOCK_DISABLE_LIES=1 MOCK_STATUS_UNREADABLE=1 MOCK_STATUS_EMPTY=1 MOCK_STATUS_PARTIAL=1 MOCK_STATUS_CONFLICT=1; do
        for action in uninstall rollback; do
            label="$action/$injection"
            if ( regression_stop_guard "$injection" "$action" ); then printf 'PASS %s\n' "$label"; else failures=$((failures + 1)); fi
        done
    done
    for name in etc opt lib log run; do
        for kind in dir file link dangling; do
            if ( regression_foreign_path "$name" "$kind" ); then printf 'PASS foreign/%s/%s\n' "$name" "$kind"; else failures=$((failures + 1)); fi
        done
    done
    for label in race_dir race_unit replaced_dir secret_output parent_symlink stop_retry conditional_write replaced_config stop_replacement remove_race missing_tool python_old remove_io_failure venv_show_failure; do
        if ( "regression_$label" ); then printf 'PASS %s\n' "$label"; else failures=$((failures + 1)); fi
    done
    for action in install uninstall rollback; do
        if ( regression_reload_failure "$action" ); then printf 'PASS reload-failure/%s\n' "$action"; else failures=$((failures + 1)); fi
    done
    for injection in MOCK_STATUS_UNREADABLE=1 MOCK_STATUS_EMPTY=1 MOCK_STATUS_PARTIAL=1 MOCK_STATUS_CONFLICT=1; do
        if ( regression_status_guard "$injection" ); then printf 'PASS status/%s\n' "$injection"; else failures=$((failures + 1)); fi
    done
    for label in lib unit manifest manifest-partial missing-dir; do
        if ( regression_owned_uninstall "$label" ); then printf 'PASS uninstall-ownership/%s\n' "$label"; else failures=$((failures + 1)); fi
    done
    for label in empty short confirm partial; do
        case $label in
            empty) input='' ;; short) input=$'short\n' ;; confirm) input="$password"$'\n' ;; partial) input=$'unterminated-valid-password' ;;
        esac
        if ( regression_eof "$label" "$input" ); then printf 'PASS EOF/%s\n' "$label"; else failures=$((failures + 1)); fi
    done
    for label in username password short confirm partial consent; do
        case $label in
            username) input='' ;; password) input=$'terry\n' ;; short) input=$'terry\nshort\n' ;;
            confirm) input=$'terry\n'"$password"$'\n' ;; partial) input=$'terry\nunterminated-valid-password' ;;
            consent) input=$'terry\n'"$password"$'\n'"$password"$'\nYES' ;;
        esac
        if ( regression_install_eof "$label" "$input" ); then printf 'PASS install-EOF/%s\n' "$label"; else failures=$((failures + 1)); fi
    done
    (( failures == 0 )) || fail "$failures safety regressions failed"
}
run_regressions
[[ ${WEBSSH_TEST_FOCUS:-} != regressions ]] || { printf 'WebSSH safety regressions passed.\n'; exit 0; }

# ------------------------------------------------------------------ happy path
reset
out=$(install_ok 2>&1) || { printf '%s\n' "$out" >&2; fail 'install failed'; }
[[ -e $webssh_unit_file && -e $nginx_unit_file ]] || fail 'units not written'
grep -qF -- '--address=127.0.0.1' "$webssh_unit_file" || fail 'webssh not bound to loopback'
grep -qF -- '--tdstream=127.0.0.1' "$webssh_unit_file" || fail 'webssh trusts non-loopback upstream'
grep -qF -- '--redirect=False' "$webssh_unit_file" || fail 'http redirect left enabled'
grep -qF -- '--fbidhttp=False' "$webssh_unit_file" || fail 'plain http still forbidden behind proxy'
grep -qF 'NoNewPrivileges=yes' "$webssh_unit_file" || fail 'webssh unit not hardened'
grep -qF 'ProtectSystem=strict' "$nginx_unit_file" || fail 'nginx unit not hardened'
grep -qxF "pid $TOOLBOX_WEBSSH_LIB/nginx.pid;" "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'pid path not derived from overridden lib'
grep -qxF "ReadWritePaths=$TOOLBOX_WEBSSH_LIB $TOOLBOX_WEBSSH_LOG" "$nginx_unit_file" || fail 'pid directory not writable in sandbox'
! grep -q '^RuntimeDirectory=' "$nginx_unit_file" || fail 'systemd may replace the owned run inode'
grep -qF 'Requires=terry-toolbox-webssh.service' "$nginx_unit_file" || fail 'nginx not ordered after backend'
grep -qF "ExecStart=$TOOLBOX_WEBSSH_NGINX -c" "$nginx_unit_file" || fail 'nginx binary not pinned by path'
grep -qF "listen 127.0.0.1:$public_port;" "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'front not on loopback'
! grep -qF '0.0.0.0' "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'front exposed on all addresses'
grep -qF 'auth_basic "Terry Toolbox WebSSH";' "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'basic auth missing'
grep -qF 'auth_basic_user_file' "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'htpasswd not referenced'
# shellcheck disable=SC2016 # nginx 变量应按字面匹配。
grep -qF 'proxy_set_header Upgrade $http_upgrade;' "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'websocket upgrade not forwarded'
# shellcheck disable=SC2016 # 匹配 apr1 哈希格式而非 shell 变量。
grep -qE '^terry:\$apr1\$' "$TOOLBOX_WEBSSH_ETC/htpasswd" || fail 'htpasswd format wrong'
[[ $(stat -c %a "$TOOLBOX_WEBSSH_ETC/htpasswd") == 640 ]] || fail 'htpasswd mode wrong'
[[ $(stat -c %a "$TOOLBOX_WEBSSH_ETC/meta") == 600 ]] || fail 'meta mode wrong'
[[ $(stat -c %a "$webssh_unit_file") == 644 ]] || fail 'unit mode wrong'
internal=$(sed -n 's/.*--port=\([0-9]*\).*/\1/p' "$webssh_unit_file")
[[ $internal =~ ^[0-9]+$ && $internal != "$public_port" ]] || fail 'internal port not distinct'
grep -qF "proxy_pass http://127.0.0.1:$internal;" "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'proxy target wrong'
[[ $(head -n1 "$TOOLBOX_WEBSSH_ETC/meta") == "terry|$password|$public_port|$internal|1.6.3|"* ]] || fail 'meta content wrong'
[[ -s $TOOLBOX_WEBSSH_ETC/known_hosts ]] || [[ -e $TOOLBOX_WEBSSH_ETC/known_hosts ]] || fail 'known_hosts missing'
[[ -x $TOOLBOX_WEBSSH_OPT/venv/bin/wssh ]] || fail 'venv entry point missing'
[[ $out == *'已验证'* && $out == *"$public_port"* && $out == *'401'* && $out == *'101'* ]] || fail 'verification not reported'
# websocket upgrade, static asset and the 401 negative probes must all have run.
assert_log 'curl -s -o /dev/null -w %{http_code} --max-time 5 http://127.0.0.1:18081/'
assert_log 'Upgrade: websocket'
assert_log 'Origin: http://127.0.0.1:18081'
# Config test must precede enabling nginx.
t_line=$(grep -n '^nginx -t' "$LOG" | head -n1 | cut -d: -f1) || true
e_line=$(grep -nF -- 'systemctl enable --now terry-toolbox-webssh-nginx' "$LOG" | head -n1 | cut -d: -f1) || true
[[ -n $t_line && -n $e_line ]] || fail 'missing config test or enable'
(( t_line < e_line )) || fail 'nginx enabled before config test'
# Nothing may listen outside loopback.
! grep -vE '^127\.0\.0\.1 ' "$STATE/ports" | grep -q . || fail 'non-loopback listener'
status_out=$(toolbox_webssh status 2>&1) || fail 'status failed'
[[ $status_out == *'访问：http://127.0.0.1:18081/'* && $status_out == *"$TOOLBOX_WEBSSH_ETC/meta"* && $status_out != *"$password"* ]] || fail 'status incomplete or leaks password'
# Uninstall must remove everything this module created.
toolbox_webssh uninstall <<< 'YES' >/dev/null || fail 'uninstall failed'
[[ ! -e $webssh_unit_file && ! -e $nginx_unit_file && ! -e $TOOLBOX_WEBSSH_ETC && ! -e $TOOLBOX_WEBSSH_OPT ]] \
    || fail 'uninstall left files'
if [[ -s $STATE/ports ]]; then fail 'uninstall left listeners'; fi

# ------------------------------------------------------------------ refusals
reset
mkdir -p "$TOOLBOX_WEBSSH_UNIT_DIR"
printf '[Service]\nExecStart=/usr/bin/other-webssh\n' > "$webssh_unit_file"
if toolbox_webssh install "$public_port" <<< "$input_ok" >/dev/null 2>&1; then fail 'foreign unit accepted'; fi
[[ ! -e $TOOLBOX_WEBSSH_ETC ]] || fail 'foreign unit wrote config'
rm -f "$webssh_unit_file"

for bad in 0 65536 0700; do
    reset
    if toolbox_webssh install "$bad" <<< "$input_ok" >/dev/null 2>&1; then fail "invalid port $bad"; fi
    [[ ! -e $TOOLBOX_WEBSSH_ETC ]] || fail "invalid port $bad wrote config"
done

reset
printf '127.0.0.1 %s %s other\n' "$public_port" "$pid_seq" > "$STATE/ports"
if out=$(toolbox_webssh install "$public_port" <<< "$input_ok" 2>&1); then fail 'busy port accepted'; fi
[[ $out == *"$public_port 已被占用"* ]] || fail 'busy port not explained'
[[ ! -e $TOOLBOX_WEBSSH_ETC ]] || fail 'busy port wrote config'

reset
if toolbox_webssh install "$public_port" <<< $'bad name\n'"$password"$'\nYES\n' >/dev/null 2>&1; then fail 'bad username accepted'; fi
if toolbox_webssh install "$public_port" <<< $'terry\nshort\nYES\n' >/dev/null 2>&1; then fail 'short password accepted'; fi
# Mismatched confirmation must retry and then succeed with the second pair.
out=$(toolbox_webssh install "$public_port" <<< $'terry\n'"$password"$'\nother-pass-999\ntyped-in-pass-123\ntyped-in-pass-123\nYES\n' 2>&1) \
    || fail 'password retry failed'
[[ $out == *'两次输入不一致'* ]] || fail 'mismatch not reported'

reset
out=$(toolbox_webssh install "$public_port" <<< $'terry\n'"$password"$'\nn\n' 2>&1) && fail 'cancel succeeded'
[[ $out == *'已取消'* && ! -e $TOOLBOX_WEBSSH_ETC ]] || fail 'cancel wrote config'

reset
printf 'ID=ubuntu\n' > "$TEST_DIR/ubuntu-release"
if TOOLBOX_WEBSSH_OS_RELEASE="$TEST_DIR/ubuntu-release" toolbox_webssh install "$public_port" <<< "$input_ok" >/dev/null 2>&1; then
    fail 'non-Debian accepted'
fi
if TOOLBOX_WEBSSH_SYSTEMD_RUN="$TEST_DIR/none" toolbox_webssh install "$public_port" <<< "$input_ok" >/dev/null 2>&1; then
    fail 'non-systemd accepted'
fi
[[ ! -e $TOOLBOX_WEBSSH_ETC ]] || fail 'prerequisite failure wrote config'

# ------------------------------------------------------------------ rollback
rollback_case() {
    local label=$1 expect=$2
    shift 2
    local -a envs=() drops=()
    while (( $# )); do
        case $1 in
            UNSET=*) drops+=("${1#UNSET=}") ;;
            *) envs+=("$1") ;;
        esac
        shift
    done
    reset
    if (
        if (( ${#envs[@]} )); then export "${envs[@]}"; fi
        if (( ${#drops[@]} )); then unset "${drops[@]}"; fi
        toolbox_webssh install "$public_port" <<< "$input_ok"
    ) > "$TEST_DIR/out" 2>&1; then fail "$label failure returned success"; fi
    out=$(<"$TEST_DIR/out")
    [[ $out == *'回滚'* ]] || { printf '%s\n' "$out" >&2; fail "$label did not roll back"; }
    :
    [[ ! -e $webssh_unit_file && ! -e $nginx_unit_file ]] || fail "$label left units"
    [[ ! -e $TOOLBOX_WEBSSH_ETC && ! -e $TOOLBOX_WEBSSH_OPT && ! -e $TOOLBOX_WEBSSH_LIB \
        && ! -e $TOOLBOX_WEBSSH_LOG && ! -e $TOOLBOX_WEBSSH_RUN ]] || fail "$label left files"
    [[ -z $(find "$STATE/active" -type f) ]] || fail "$label left active units"
    [[ $out == *"$expect"* ]] || { printf '%s\n' "$out" >&2; fail "$label reason missing"; }
}
rollback_case 'sha mismatch' 'SHA-256 不匹配' "TOOLBOX_WEBSSH_SDIST_SHA256=$(printf '0%.0s' {1..64})"
rollback_case 'download failure' '下载失败' MOCK_DL_FAIL=1 UNSET=TOOLBOX_WEBSSH_SDIST_SRC
rollback_case 'venv failure' 'venv' MOCK_VENV_FAIL=1
rollback_case 'pip failure' 'pip' MOCK_PIP_FAIL=1
rollback_case 'version drift' '版本' MOCK_BAD_VERSION=1
rollback_case 'nginx config test' 'nginx 配置自检失败' MOCK_NGINX_T_FAIL=1
rollback_case 'backend start' '启动失败' MOCK_ENABLE_WEBSSH_FAIL=1
rollback_case 'backend never active' '未在' MOCK_ACTIVE_WEBSSH_FAIL=1
rollback_case 'front start' '启动失败' MOCK_ENABLE_NGINX_FAIL=1
rollback_case 'missing 401' '期望 401' MOCK_ALWAYS_200=1
rollback_case 'websocket blocked' 'websocket 升级' MOCK_WS_401=1

# ------------------------------------------------------------------ misc
reset
if toolbox_webssh uninstall <<< 'YES' >/dev/null 2>&1; then fail 'uninstall without install succeeded'; fi
if toolbox_webssh bogus >/dev/null 2>&1; then fail 'invalid action accepted'; fi
if toolbox_webssh status >/dev/null 2>&1; then fail 'status without install succeeded'; fi
# Password is generated only for a completed blank line, never printed.
reset
out=$(toolbox_webssh install "$public_port" <<< $'terry\n\nYES\n' 2>&1) || fail 'generated password install failed'
# shellcheck disable=SC2016 # 匹配 apr1 哈希格式而非 shell 变量。
grep -qE '^terry:\$apr1\$' "$TOOLBOX_WEBSSH_ETC/htpasswd" || fail 'generated password not hashed'
[[ $out == *'随机'* && $out == *"$TOOLBOX_WEBSSH_ETC/meta"* && $out != *abcdefghijklmnopqrstuvwx* ]] || fail 'generated password leaked or storage not reported'

printf 'WebSSH tests passed.\n'
