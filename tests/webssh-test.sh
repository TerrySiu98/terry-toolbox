#!/usr/bin/env bash
# Isolated regression for B10 WebSSH: every system command is a mock; no host
# service, package, port or systemd unit is touched. Real files are written only
# under a fresh temporary directory via the TOOLBOX_WEBSSH_* path override.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-webssh.XXXXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

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
pid_seq=4200

# ------------------------------------------------------------------ mocks
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$LOG"
    local unit port name
    case ${1-} in
        is-active)
            [[ -e $STATE/active/${3-} ]]
            ;;
        show)
            [[ -e $STATE/pid/${5-} ]] && cat "$STATE/pid/${5-}"; return 0
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
            rm -f "$STATE/active/$unit"
            if [[ -e $STATE/pid/$unit ]]; then
                grep -v " $(cat "$STATE/pid/$unit") " "$STATE/ports" > "$STATE/ports.new" || :
                mv "$STATE/ports.new" "$STATE/ports"
                rm -f "$STATE/pid/$unit"
            fi
            ;;
        daemon-reload|reset-failed) : ;;
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
    printf 'curl %s\n' "$*" >> "$LOG"
    local url='' out='' creds='' code path
    while (( $# )); do
        case $1 in
            -o) out=$2; shift 2 ;;
            -u) creds=$2; shift 2 ;;
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
            local stdin=''
            read -r _pass || :   # 密码经 stdin 传入，读取只为证明管道可用
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
    show) [[ ${MOCK_BAD_VERSION:-0} == 1 ]] && printf 'Version: 9.9.9\n' || printf 'Version: 1.6.3\n' ;;
    install) [[ ${MOCK_PIP_FAIL:-0} != 1 ]] ;;
esac
EOS
    printf '#!/bin/bash\nexit 0\n' > "$dir/bin/python"
    chmod +x "$dir/bin/wssh" "$dir/bin/pip" "$dir/bin/python"
}
python3() {
    printf 'python3 %s\n' "$*" >> "$LOG"
    case ${1-} in
        -c) return 0 ;;
        -m)
            [[ ${MOCK_VENV_FAIL:-0} != 1 ]] || return 1
            write_stubs "${!#}"
            ;;
    esac
}
apt-get() { printf 'apt-get %s\n' "$*" >> "$LOG"; }
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
export -f systemctl ss curl openssl python3 apt-get getent write_stubs
export LOG STATE MOCK_USER MOCK_PASS TOOLBOX_WEBSSH_ETC TOOLBOX_WEBSSH_UNIT_DIR TOOLBOX_WEBSSH_SDIST_SRC

reset() {
    : > "$LOG"
    : > "$STATE/ports"
    rm -rf "$STATE/active" "$STATE/pid" "$TOOLBOX_WEBSSH_ETC" "$TOOLBOX_WEBSSH_OPT" \
        "$TOOLBOX_WEBSSH_LIB" "$TOOLBOX_WEBSSH_LOG" "$TOOLBOX_WEBSSH_RUN"
    rm -f "$TOOLBOX_WEBSSH_UNIT_DIR/terry-toolbox-webssh.service" \
        "$TOOLBOX_WEBSSH_UNIT_DIR/terry-toolbox-webssh-nginx.service" "$TOOLBOX_WEBSSH_LOCK"
    mkdir -p "$STATE/active" "$STATE/pid"
    unset MOCK_PIP_FAIL MOCK_ENABLE_WEBSSH_FAIL MOCK_ENABLE_NGINX_FAIL MOCK_ACTIVE_WEBSSH_FAIL \
        MOCK_NGINX_T_FAIL MOCK_ALWAYS_200 MOCK_WS_401 MOCK_BAD_VERSION MOCK_VENV_FAIL MOCK_DL_FAIL || :
}
install_ok() { toolbox_webssh install "$public_port" <<< "$input_ok"; }
webssh_unit_file="$TOOLBOX_WEBSSH_UNIT_DIR/terry-toolbox-webssh.service"
nginx_unit_file="$TOOLBOX_WEBSSH_UNIT_DIR/terry-toolbox-webssh-nginx.service"

# ------------------------------------------------------------------ sourcing
source "$script_dir/../modules/webssh.sh"
[[ ! -s $LOG ]] || fail 'sourcing executed commands'

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
grep -qF 'Requires=terry-toolbox-webssh.service' "$nginx_unit_file" || fail 'nginx not ordered after backend'
grep -qF "ExecStart=$TOOLBOX_WEBSSH_NGINX -c" "$nginx_unit_file" || fail 'nginx binary not pinned by path'
grep -qF "listen 127.0.0.1:$public_port;" "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'front not on loopback'
! grep -qF '0.0.0.0' "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'front exposed on all addresses'
grep -qF 'auth_basic "Terry Toolbox WebSSH";' "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'basic auth missing'
grep -qF 'auth_basic_user_file' "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'htpasswd not referenced'
grep -qF 'proxy_set_header Upgrade $http_upgrade;' "$TOOLBOX_WEBSSH_ETC/nginx.conf" || fail 'websocket upgrade not forwarded'
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
[[ $status_out == *'访问：http://127.0.0.1:18081/'* && $status_out == *'terry /'* ]] || fail 'status incomplete'
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
printf '127.0.0.1 %s 9999 other\n' "$public_port" > "$STATE/ports"
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
    (
        if (( ${#envs[@]} )); then export "${envs[@]}"; fi
        if (( ${#drops[@]} )); then unset "${drops[@]}"; fi
        toolbox_webssh install "$public_port" <<< "$input_ok"
    ) > "$TEST_DIR/out" 2>&1 || true
    out=$(<"$TEST_DIR/out")
    [[ $out == *'回滚'* ]] || { printf '%s\n' "$out" >&2; fail "$label did not roll back"; }
    :
    [[ ! -e $webssh_unit_file && ! -e $nginx_unit_file ]] || fail "$label left units"
    [[ ! -e $TOOLBOX_WEBSSH_ETC && ! -e $TOOLBOX_WEBSSH_OPT && ! -e $TOOLBOX_WEBSSH_LIB ]] || fail "$label left files"
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
# Password is generated when left blank and shown once.
reset
out=$(toolbox_webssh install "$public_port" <<< $'terry\n\nYES\n' 2>&1) || fail 'generated password install failed'
grep -qE '^terry:\$apr1\$' "$TOOLBOX_WEBSSH_ETC/htpasswd" || fail 'generated password not hashed'
[[ $out == *'随机'* && $out == *'只显示这一次'* ]] || fail 'generated password not reported once'

printf 'WebSSH tests passed.\n'
