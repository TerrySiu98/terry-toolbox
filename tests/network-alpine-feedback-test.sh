#!/usr/bin/env bash
# Alpine feedback regressions. No host package/service changes; all writers use scratch.
# /proc ownership checks use a real task-owned ELF process, not an ss name fallback.
# shellcheck disable=SC2317,SC2016,SC1090
set -uo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scratch-root.sh"
toolbox_test_scratch
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/root/.cache/terry-toolbox-tests}/network-alpine-feedback.XXXXXXXX") || exit 1
cleanup() {
    if [[ -s $work/children ]]; then
        while IFS= read -r child; do
            # Only kill children still executing the exact task-owned binary.
            [[ $(readlink "/proc/$child/exe" 2>/dev/null || :) == "$work/bin/terry-toolbox-xray" ]] || continue
            kill "$child" 2>/dev/null || :
            wait "$child" 2>/dev/null || :
        done < "$work/children"
    fi
    rm -rf -- "${work:?}"
}
trap cleanup EXIT
export TMPDIR=$work HOME=$work/home
mkdir -p "$HOME" "$work/bin" "$work/initd" "$work/run" "$work/openrc" "$work/lock" "$work/etc"
printf 'ID=alpine\nVERSION_ID=3.24\n' > "$work/os-release"
: > "$work/openrc/softlevel"
export TOOLBOX_NET_OS_RELEASE=$work/os-release TOOLBOX_NET_OPENRC_RUN=$work/openrc
export TOOLBOX_NET_UID=0 TOOLBOX_NET_BIN_DIR=$work/bin TOOLBOX_NET_INITD=$work/initd
export TOOLBOX_NET_RUN=$work/run TOOLBOX_NET_LOCK_DIR=$work/lock
export TOOLBOX_A1_ETC=$work/etc/hy2 TOOLBOX_A2_ETC=$work/etc/xray
source "${NETWORK_TEST_MODULE:-$ROOT/modules/network.sh}" || exit 1
# Never reach a real package manager, curl, OpenRC, or external network.
rc-service() {
    printf '%s\n' "$*" >> "$work/rc.log"
    case ${2:-} in
        status) [[ -e $work/active ]] && return 0; return "${STATUS_RC:-3}" ;;
        start)
            ( exec "$(net_a2_bin)" 300 ) 9>&- &
            daemon=$!
            printf '%s\n' "$daemon" >> "$work/children"
            printf '%s\n' "$daemon" > "$(net_a2_pid)"
            : > "$work/active"
            # Wait for exec: /proc must identify the copied native ELF.
            for ((n=0; n<100; n++)); do
                [[ $(readlink "/proc/$daemon/exe" 2>/dev/null || :) == "$(net_a2_bin)" ]] && break
                command sleep 0.01
            done
            printf 'LISTEN 0 0 0.0.0.0:18444 0.0.0.0:* users:(("terry-toolbox",pid=%s,fd=3))\n' "$daemon" > "$work/tcp"
            return 0 ;;
        stop)
            [[ ${STOP_FAIL:-0} == 0 ]] || return 1
            if [[ -r $(net_a2_pid) ]]; then
                IFS= read -r daemon < "$(net_a2_pid)"
                [[ $(readlink "/proc/$daemon/exe" 2>/dev/null || :) == "$(net_a2_bin)" ]] || return 1
                kill "$daemon" 2>/dev/null || :
                wait "$daemon" 2>/dev/null || :
            fi
            rm -f "$work/active" "$work/tcp" "$(net_a2_pid)"
            return 0 ;;
    esac
    return 1
}
rc-update() { printf '%s\n' "$*" >> "$work/update.log"; return 0; }
ss() {
    [[ ${SS_FAIL:-0} == 0 ]] || return 77
    case $1 in
        -ltnH|-ltnpH) [[ ! -f $work/tcp ]] || command cat "$work/tcp" ;;
        -lunH|-lunpH) [[ ! -f $work/udp ]] || command cat "$work/udp" ;;
        *) return 78 ;;
    esac
    return 0
}
curl() { printf forbidden >> "$work/forbidden"; return 99; }
apk() { printf forbidden >> "$work/forbidden"; return 99; }
net_check_cert() { :; }
net_tls_trusted() { :; }
net_alpine_fetch() { printf fetch >> "$work/fetch"; return 22; }
sleep() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
run() {
    local label=$1; shift
    if ( "$@" ); then printf 'PASS: %s\n' "$label"; else failures=$((failures + 1)); fi
}
failures=0
missing_gate() {
    local key=$1 MISSING_CMD=$2 rc=0
    command() {
        [[ ${1:-} != -v || ${2:-} != "$MISSING_CMD" ]] || return 1
        builtin command "$@"
    }
    # Actual menu shape: action || handler, disabling nested errexit.
    if [[ $key == A1 ]]; then
        toolbox_network "$key" install cert key a1.example.test 18443 <<< YES > "$work/missing.out" 2>&1 || rc=$?
    else
        toolbox_network "$key" install 18444 <<< YES > "$work/missing.out" 2>&1 || rc=$?
    fi
    [[ $rc != 0 ]] || { fail "$key missing $MISSING_CMD accepted"; return 1; }
    [[ ! -f $work/fetch && ! -f $work/rc.log && ! -f $work/update.log ]] || { fail "$key missing $MISSING_CMD crossed preflight"; return 1; }
    if builtin command grep -q '确认执行\|即将在\|开始写入' "$work/missing.out"; then fail "$key missing $MISSING_CMD prompted/wrote"; return 1; fi
    builtin command grep -q "缺少必需命令：.*$MISSING_CMD" "$work/missing.out" || { builtin command cat "$work/missing.out"; fail "$key missing $MISSING_CMD inaccurate error"; }
}
for key in A1 A2; do
    for c in ss timeout readlink sed cut grep tr chmod cp mkdir rm rmdir cat stat sha256sum install mktemp flock openssl uname sleep date; do
        rm -f "$work/fetch" "$work/rc.log" "$work/update.log"
        run "$key rejects missing $c before confirmation" missing_gate "$key" "$c"
    done
done
rm -f "$work/fetch" "$work/rc.log" "$work/update.log"
ss_failed_install() {
    local rc=0
    SS_FAIL=1 toolbox_network A2 install 18444 <<< YES > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 && ! -f $work/fetch ]] || fail 'ss failure treated as idle port' || return
    ! grep -q '确认执行\|开始写入' "$work/out" || fail 'ss failure reached confirmation'
}
run 'failed ss blocks install without writes' ss_failed_install
rm -f "$work/fetch" "$work/rc.log" "$work/update.log"
free_port_failure() { local rc=0; SS_FAIL=1 net_alpine_free_port 41000 > "$work/out" 2>&1 || rc=$?; [[ $rc != 0 ]] || fail 'free-port returned a port despite failed ss'; }
run 'free-port failure is not idle' free_port_failure
openrc_not_booted() {
    rm -f "$work/openrc/softlevel"
    local rc=0
    toolbox_network A2 install 18444 <<< YES > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 && ! -f $work/fetch ]] || fail 'empty OpenRC directory accepted as booted'
}
run 'OpenRC needs boot marker, not just directory' openrc_not_booted
: > "$work/openrc/softlevel"
rm -f "$work/fetch" "$work/rc.log" "$work/update.log"
# Real process + real /proc. ss itself stays mocked to avoid opening host ports.
cp /bin/sleep "$(net_a2_bin)"
"$(net_a2_bin)" 300 &
owner=$!
printf '%s\n' "$owner" >> "$work/children"
for ((n=0; n<100; n++)); do
    [[ $(readlink "/proc/$owner/exe" 2>/dev/null || :) == "$(net_a2_bin)" ]] && break
    command sleep 0.01
done
printf '%s\n' "$owner" > "$(net_a2_pid)"
line="LISTEN 0 0 0.0.0.0:18444 0.0.0.0:* users:((\"terry-toolbox\",pid=$owner,fd=3))"
printf '%s\n' "$line" > "$work/tcp"
run 'correct socket PID and exact ELF path accepted' net_alpine_port_owned_by tcp 18444 "$(net_a2_bin)" "$(net_a2_pid)"
wrong_port() { if net_alpine_port_owned_by tcp 443 "$(net_a2_bin)" "$(net_a2_pid)"; then fail 'unrelated port accepted'; fi; }
run 'same process on another port is not proof' wrong_port
wrong_pid() {
    printf '%s\n' "$BASHPID" > "$(net_a2_pid)"
    printf 'LISTEN 0 0 0.0.0.0:18444 0.0.0.0:* users:(("terry-toolbox-x",pid=%s,fd=3))\n' "$BASHPID" > "$work/tcp"
    if net_alpine_port_owned_by tcp 18444 "$(net_a2_bin)" "$(net_a2_pid)"; then fail 'foreign executable accepted by pidfile/name'; fi
}
run 'stale/foreign pidfile and comm collision rejected' wrong_pid
no_pid() {
    printf 'LISTEN 0 0 0.0.0.0:18444 0.0.0.0:* users:(("terry-toolbox-xray",fd=3))\n' > "$work/tcp"
    if net_alpine_port_owned_by tcp 18444 "$(net_a2_bin)" "$(net_a2_pid)"; then fail 'name without PID accepted'; fi
}
run 'process name without PID cannot prove ownership' no_pid
kill "$owner"; wait "$owner" 2>/dev/null || :
rm -f "$(net_a2_bin)" "$(net_a2_pid)" "$work/tcp"
foreign_rollback() {
    printf 'foreign init\n' > "$(net_a2_init)"
    printf 'foreign binary\n' > "$(net_a2_bin)"
    mkdir -p "$(net_a2_etc)" "$(net_a2_client)"
    printf keep > "$(net_a2_etc)/foreign"
    printf keep > "$(net_a2_client)/foreign"
    net_a2_rollback > "$work/out" 2>&1 || :
    [[ -f $(net_a2_init) && -f $(net_a2_bin) && -f $(net_a2_etc)/foreign && -f $(net_a2_client)/foreign ]] || fail 'rollback erased foreign/unregistered files'
}
run 'rollback does not erase unregistered foreign state' foreign_rollback
# Probe started != authenticated. Execute the real helper with only curl and the
# client boundary mocked; client prints started for both UUIDs, just as real Xray.
probe_behavior() {
    local original_probe fixture=$work/probe-client rc=0
    original_probe=$(declare -f net_xray_probe)
    # Reload the implementation (later installer tests deliberately mock the probe).
    eval "$original_probe"
    printf '#!/usr/bin/env bash\nprintf "Xray started\\n"\n' > "$fixture"
    chmod +x "$fixture"
    net_curl_socks() { printf '%s\n' "$*" >> "$work/probe-curl"; return "${DATA_RC:-1}"; }
    DATA_RC=1 net_xray_probe "$fixture" a.example.test 18444 fixture-uuid fixture-public aabbccdd good > "$work/probe.out" 2>&1 || rc=$?
    [[ $rc != 0 ]] || { fail 'client started plus failed data plane accepted'; return 1; }
    [[ -s $work/probe-curl ]] || { fail 'good UUID not exercised through socks'; return 1; }
    : > "$work/probe-curl"
    rc=0
    DATA_RC=1 net_xray_probe "$fixture" a.example.test 18444 wrong-uuid fixture-public aabbccdd bad 1 > "$work/probe.out" 2>&1 || rc=$?
    [[ $rc != 0 && -s $work/probe-curl ]] || { fail 'wrong UUID only tested local startup, not data plane'; return 1; }
    DATA_RC=0 net_xray_probe "$fixture" a.example.test 18444 fixture-uuid fixture-public aabbccdd good2 > "$work/probe.out" 2>&1 || { fail 'good data plane refused'; return 1; }
}
run 'probe authentication depends on socks HTTP for both UUIDs' probe_behavior
probe_no_proxy() {
    timeout() { shift; "$@"; }
    curl() {
        local saw=0 arg next=0
        for arg in "$@"; do
            if (( next )); then [[ -z $arg ]] || return 88; saw=1; next=0; fi
            [[ $arg != --noproxy ]] || next=1
        done
        [[ $saw == 1 ]] || return 89
        printf 200
    }
    NO_PROXY='*' net_curl_socks 41000 http://127.0.0.1:18080 || { fail 'curl can bypass socks via NO_PROXY'; return 1; }
}
run 'curl explicitly overrides NO_PROXY only for its request' probe_no_proxy
probe_start_failure() {
    local fixture=$work/probe-failed rc=0
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fixture"
    chmod +x "$fixture"
    net_xray_probe "$fixture" a.example.test 18444 wrong fixture-public aabbccdd startup 1 > "$work/probe.out" 2>&1 || rc=$?
    [[ $rc == 2 ]] || { fail 'failed negative client startup counted as credential rejection'; return 1; }
}
run 'negative startup error is indeterminate, not authentication rejection' probe_start_failure
# Installer with native /proc daemon: mock only credential command interface and archive/network.
rm -rf "$(net_a2_etc)" "$(net_a2_client)"; rm -f "$(net_a2_init)" "$(net_a2_bin)" "$work/rc.log"
net_alpine_fetch() { cp /bin/sleep "$2"; }
unzip() { mkdir -p "${5:?}"; cp "$2" "$5/xray"; }
# A Bash function can use an absolute executable name. OpenRC start uses builtin command
# to bypass it and exec the real ELF; credential generation/config validation are mocked.
eval "$(net_a2_bin)"'() {
    case ${1:-} in
        uuid) printf "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\n" ;;
        x25519) printf "PrivateKey: fixture-private\nPassword (PublicKey): fixture-public\n" ;;
        run) [[ " $* " == *" -test "* ]] ;;
        *) builtin command "'"$(net_a2_bin)"'" "$@" ;;
    esac
}'
net_xray_probe() { return 1; }
stop_failure() {
    local rc=0
    STOP_FAIL=1 toolbox_network A2 install 18444 <<< YES > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 ]] || fail 'probe failure reported success' || return
    [[ -s $(net_a2_init) && -s $(net_a2_bin) && -s $(net_a2_etc)/config.json && -s $(net_a2_pid) ]] || fail 'stop failure erased recovery files' || return
    grep -q '保留\|未确认' "$work/out" || fail 'stop failure did not disclose preserved state'
}
run 'failed stop preserves transaction recovery state' stop_failure
# Remove only a daemon proved to be this fixture before subsequent independent cases.
reset_install_fixture() {
    if [[ -r $(net_a2_pid) ]]; then
        IFS= read -r daemon < "$(net_a2_pid)"
        if [[ $(readlink "/proc/$daemon/exe" 2>/dev/null || :) == "$(net_a2_bin)" ]]; then
            kill "$daemon" 2>/dev/null || :
            for ((n=0; n<100; n++)); do
                [[ ! -e /proc/$daemon ]] && break
                command sleep 0.01
            done
        fi
    fi
    # Install executes in a subshell. Always reap/await its recorded native child,
    # even if an adversarial case replaced the pidfile before reset.
    while IFS= read -r daemon; do
        if [[ $(readlink "/proc/$daemon/exe" 2>/dev/null || :) == "$(net_a2_bin)" ]]; then
            kill "$daemon" 2>/dev/null || :
            for ((n=0; n<100; n++)); do
                [[ ! -e /proc/$daemon ]] && break
                command sleep 0.01
            done
        fi
    done < "$work/children"
    rm -f "$(net_a2_bin)" "$(net_a2_init)" "$(net_a2_pid)" "$work/tcp" "$work/active" "$work/rc.log" "$work/update.log"
    rm -rf -- "$(net_a2_etc)"
}
reset_install_fixture
safe_rollback() {
    mkdir -p "$(net_a2_client)"
    printf keep > "$(net_a2_client)/foreign"
    local rc=0
    toolbox_network A2 install 18444 <<< YES > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 ]] || { fail 'probe failure accepted'; return 1; }
    [[ ! -e $(net_a2_bin) && ! -e $(net_a2_init) && ! -d $(net_a2_etc) ]] || { fail 'owned stopped transaction not cleaned'; return 1; }
    grep -q 'terry-toolbox-xray stop' "$work/rc.log" || { fail 'rollback skipped stop'; return 1; }
    [[ -f $(net_a2_client)/foreign ]] || { fail 'rollback erased shared legacy probe directory'; return 1; }
}
run 'confirmed stopped owned transaction is removed' safe_rollback
reset_install_fixture
unknown_status() {
    local rc=0
    STATUS_RC=16 toolbox_network A2 install 18444 <<< YES > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 && -s $(net_a2_init) && -s $(net_a2_bin) ]] || { fail 'inactive/unknown OpenRC state removed files'; return 1; }
}
run 'OpenRC inactive is not stopped and preserves files' unknown_status
reset_install_fixture
foreign_pid_rollback() {
    net_xray_probe() { printf '%s\n' "$BASHPID" > "$(net_a2_pid)"; return 1; }
    local rc=0
    toolbox_network A2 install 18444 <<< YES > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 && -s $(net_a2_init) && -s $(net_a2_bin) && -s $(net_a2_pid) ]] || { fail 'foreign pidfile recovery state erased'; return 1; }
    if grep -q 'terry-toolbox-xray stop' "$work/rc.log"; then fail 'OpenRC asked to stop foreign PID'; return 1; fi
    # Record real child PID separately; reset helper must not use the substituted pidfile.
    for daemon in $(<"$work/children"); do
        if [[ $(readlink "/proc/$daemon/exe" 2>/dev/null || :) == "$(net_a2_bin)" ]]; then kill "$daemon" 2>/dev/null || :; fi
    done
}
run 'foreign pidfile is not signalled or removed' foreign_pid_rollback
reset_install_fixture
replacement_rollback() {
    net_xray_probe() { printf 'foreign replacement\n' > "$(net_a2_init)"; return 1; }
    local rc=0
    toolbox_network A2 install 18444 <<< YES > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 && -s $(net_a2_bin) ]] || { fail 'foreign init caused binary deletion'; return 1; }
    grep -qx 'foreign replacement' "$(net_a2_init)" || { fail 'foreign init replacement deleted'; return 1; }
    if grep -q 'terry-toolbox-xray stop' "$work/rc.log"; then fail 'foreign init executed during rollback'; return 1; fi
}
run 'changed init preserves entire live transaction' replacement_rollback
reset_install_fixture
foreign_file_rollback() {
    net_xray_probe() { printf 'keep\n' > "$(net_a2_etc)/foreign"; return 1; }
    local rc=0
    toolbox_network A2 install 18444 <<< YES > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 && -f $(net_a2_etc)/foreign && ! -e $(net_a2_bin) && ! -e $(net_a2_init) ]] || { fail 'foreign file inside owned directory erased'; return 1; }
}
run 'foreign files inside created directory survive rollback' foreign_file_rollback
reset_install_fixture
config_write_failure() {
    cat() { if (( $# == 0 )); then builtin command cat; return 1; fi; builtin command cat "$@"; }
    local rc=0
    toolbox_network A2 install 18444 <<< YES > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 && ! -e $(net_a2_init) && ! -e $(net_a2_bin) && ! -e $(net_a2_etc) && ! -e $work/rc.log ]] || { fail 'A2 failed config writer continued'; return 1; }
}
run 'A2 failed config writer stops in actual conditional caller' config_write_failure
reset_install_fixture
# Complete command inventory including action-specific tools and all Alpine actions.
run 'A2 rejects missing unzip' missing_gate A2 unzip
for c in curl awk ln; do
    run "A1 rejects missing $c" missing_gate A1 "$c"
    run "A2 rejects missing $c" missing_gate A2 "$c"
done
uninstall_missing_flock() {
    printf 'command="%s"\n' "$(net_a2_bin)" > "$(net_a2_init)"
    printf binary > "$(net_a2_bin)"
    command() { [[ ${1:-} != -v || ${2:-} != flock ]] || return 1; builtin command "$@"; }
    local rc=0
    toolbox_network A2 uninstall <<< YES > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 && -f $(net_a2_init) && -f $(net_a2_bin) && ! -f $work/rc.log ]] || { fail 'uninstall missing flock touched service/files'; return 1; }
}
run 'uninstall required tools fail before confirmation' uninstall_missing_flock
reset_install_fixture
status_missing_ss() {
    printf 'command="%s"\n' "$(net_a2_bin)" > "$(net_a2_init)"
    command() { [[ ${1:-} != -v || ${2:-} != ss ]] || return 1; builtin command "$@"; }
    local rc=0
    toolbox_network A2 status > "$work/out" 2>&1 || rc=$?
    [[ $rc != 0 && ! -f $work/rc.log ]] || { fail 'status missing ss became unverifiable success'; return 1; }
    builtin command grep -q '缺少必需命令：.*ss' "$work/out" || { fail 'status did not check its ss dependency'; return 1; }
}
run 'status missing ss fails before OpenRC query' status_missing_ss
[[ ! -f $work/forbidden ]] || { fail 'host/network boundary reached'; exit 1; }
if (( failures )); then printf '%s feedback regressions failed\n' "$failures" >&2; exit 1; fi
printf 'network alpine feedback tests passed\n'
