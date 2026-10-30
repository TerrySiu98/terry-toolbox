#!/usr/bin/env bash
# Focused post-review regressions. Only scratch files + mocked privileged commands.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export TMPDIR=/root/.hermes/cache/scratch
R=$(mktemp -d "$TMPDIR/toolbox-system-review.XXXXXXXX")
trap 'rm -rf -- "$R"' EXIT
export HOME=$R/home PATH=$R/deny:/usr/bin:/bin
export TOOLBOX_SYSTEM_STATE=$R/state TOOLBOX_SYSTEM_UNIT_DIR=$R/units TOOLBOX_SWAP_ROOT=$R/swap
export TOOLBOX_SYSTEM_SYSCTL_DIR=$R/sysctl TOOLBOX_SYSTEMD_RUN=$R/run
mkdir -p "$HOME" "$R/deny" "$R/state" "$R/units" "$R/swap" "$R/sysctl" "$R/run"
for c in apt-get apt-cache systemctl sysctl swapon swapoff dd mkswap docker curl wget gpg passwd reboot; do
    printf '#!/bin/bash\nprintf "UNMOCKED privileged command\\n" >&2\nexit 99\n' > "$R/deny/$c"
    chmod 0755 "$R/deny/$c"
done
install() {
    local a
    for a in "$@"; do case $a in /*) [[ $a == "$R"/* ]] || return 99;; esac; done
    /usr/bin/install "$@"
}
source "$ROOT/modules/system.sh"
_toolbox_system_root() { :; }
_toolbox_system_os() { printf 'debian\n'; }
_toolbox_system_confirm() { return 0; }
fail() { printf 'FAIL: %s\n' "$*" >&2; for evidence in "$R/out" "$R/first.out" "$R/second.out" "$R/rollback.out"; do [[ ! -f $evidence ]] || /usr/bin/cat "$evidence" >&2; done; exit 1; }
LOG=$R/commands.log
: > "$LOG"
printf 'inactive\n' > "$R/active"
printf '0\n' > "$R/job"
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$LOG"
    case "$*" in
        'show -p FragmentPath'*|'show -p DropInPaths'*) return 0;;
        'show -p LoadState'*) [[ -e $TOOLBOX_SYSTEM_UNIT_DIR/swapfile_toolbox.swap ]] && printf 'loaded\n' || printf 'not-found\n';;
        'show -p ActiveState'*) [[ ${FAIL_STATE:-0} != 1 ]] || return 1; /usr/bin/cat "$R/active";;
        'show -p Job'*) [[ ${FAIL_JOB:-0} != 1 ]] || return 1; /usr/bin/cat "$R/job";;
        'show -p UnitFileState'*) printf 'disabled\n';;
        'enable --now '*)
            printf 'activating\n' > "$R/active"; printf '42\n' > "$R/job"
            [[ ${SIGNAL_START:-0} != 1 ]] || { kill -TERM "$BASHPID"; return 0; }
            return 1;;
        'disable --now '*|'stop '*)
            [[ ${FAIL_STOP:-0} != 1 ]] || return 1
            [[ ${STOP_LIES:-0} != 1 ]] || return 0
            printf 'inactive\n' > "$R/active"; printf '0\n' > "$R/job";;
        daemon-reload) return 0;;
        *) return 1;;
    esac
}
swapon() { printf 'swapon %s\n' "$*" >> "$LOG"; return 0; }
swapoff() { printf 'swapoff %s\n' "$*" >> "$LOG"; return 0; }
swap_fixture() {
    f=$TOOLBOX_SWAP_ROOT/swapfile_toolbox; u=$TOOLBOX_SYSTEM_UNIT_DIR/swapfile_toolbox.swap
    printf 'swap\n' > "$f"
    printf '%s\n[Swap]\nWhat=%s\n' "$_TOOLBOX_SYS_MARK_B6" "$f" > "$u"
    ino=$(stat -c '%d:%i' -- "$f")
    printf 'PHASE=unit\nPATH=%s\nUNIT=%s\nINODE=%s\n' "$f" "$u" "$ino" > "$TOOLBOX_SYSTEM_STATE/swap.txn"
    printf 'activating\n' > "$R/active"; printf '42\n' > "$R/job"
    : > "$LOG"
}
swap_tests() {
    swap_fixture
    _toolbox_system_swap_rollback "$f" "$u" "$ino" > "$R/out" 2>&1 || fail 'pending start rollback failed'
    [[ $(<"$R/active") == inactive && $(<"$R/job") == 0 ]] || fail 'deleted with a pending systemd start job'
    [[ ! -e $f && ! -e $u && ! -e $TOOLBOX_SYSTEM_STATE/swap.txn ]] || fail 'confirmed rollback not cleaned'
    for flag in FAIL_STOP STOP_LIES FAIL_STATE FAIL_JOB; do
        swap_fixture
        if ( export "$flag=1"; _toolbox_system_swap_rollback "$f" "$u" "$ino" ) > "$R/out" 2>&1; then fail "unknown stop/state accepted: $flag"; fi
        [[ -f $f && -f $u && -f $TOOLBOX_SYSTEM_STATE/swap.txn ]] || fail "rollback erased evidence: $flag"
    done
    rm -f -- "$f" "$u" "$TOOLBOX_SYSTEM_STATE/swap.txn"
    findmnt() { printf 'ext4\n'; }
    df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 1000000 0 1000000 0 /\n'; }
    for signal in 0 1; do
        swap_fixture
        rm -f -- "$TOOLBOX_SYSTEM_STATE/swap.txn"
        truncate -s 134217728 "$f"
        printf 'inactive\n' > "$R/active"; printf '0\n' > "$R/job"
        rc=0
        ( trap - EXIT; export SIGNAL_START=$signal; _toolbox_system_swap ) > "$R/out" 2>&1 || rc=$?
        [[ $rc != 0 ]] || fail 'start client failure claimed success'
        [[ $signal != 1 || $rc == 143 ]] || fail 'TERM exit code not preserved'
        [[ $(<"$R/active") == inactive && $(<"$R/job") == 0 ]] || fail 'full failure path left pending activation'
        [[ ! -e $f && ! -e $u && ! -e $TOOLBOX_SYSTEM_STATE/swap.txn ]] || fail 'full rollback did not finish safely'
    done
    printf 'PASS swap pending-job, unknown state, start failure and real SIGTERM\n'
}
# File-backed MOCK_VALUES_FILE keep mutations visible across command substitutions.
MOCK_VALUES_FILE=$R/MOCK_VALUES_FILE
for ((i=0; i<${#_TOOLBOX_NETOPT_KEYS[@]}; i++)); do
    printf '%s=111\n' "${_TOOLBOX_NETOPT_KEYS[i]}" >> "$MOCK_VALUES_FILE"
done
sysctl() {
    local key value line found=0
    printf 'sysctl %s\n' "$*" >> "$LOG"
    case $1 in
        -n)
            [[ $2 != net.ipv4.tcp_available_congestion_control ]] || { printf 'cubic bbr\n'; return 0; }
            [[ $2 != "${SKIP_KEY:-}" ]] || return 1
            while IFS='=' read -r key value; do [[ $key != "$2" ]] || { printf '%s\n' "$value"; found=1; }; done < "$MOCK_VALUES_FILE"
            (( found == 1 ));;
        -w)
            key=${2%%=*}; value=${2#*=}
            while IFS= read -r line; do [[ $line == "$key="* ]] || printf '%s\n' "$line"; done < "$MOCK_VALUES_FILE" > "$MOCK_VALUES_FILE.new"
            printf '%s=%s\n' "$key" "$value" >> "$MOCK_VALUES_FILE.new"; mv -- "$MOCK_VALUES_FILE.new" "$MOCK_VALUES_FILE";;
        -p)
            while IFS='=' read -r key value; do
                [[ $key == '#'* || -z $key ]] && continue
                key=${key// /}; value=${value# }; sysctl -w "$key=$value" || return 1
            done < "$2"; return 0;;
        *) return 1;;
    esac
}
sysctl_tests() {
    SKIP_KEY=net.core.rmem_max
    _toolbox_system_netopt_apply > "$R/first.out" 2>&1 || fail 'first limited sysctl apply failed'
    unset SKIP_KEY
    if _toolbox_system_netopt_apply > "$R/second.out" 2>&1; then
        _toolbox_system_netopt_rollback > "$R/rollback.out" 2>&1 || fail 'rollback returned error'
        [[ $(sysctl -n net.core.rmem_max) == 111 ]] || fail 'new key original value lost after successful rollback'
    else
        # Conservative fix may refuse expansion until the old plan is rolled back.
        [[ $(sysctl -n net.core.rmem_max) == 111 ]] || fail 'refused expansion still mutated new key'
        _toolbox_system_netopt_rollback > "$R/rollback.out" 2>&1 || fail 'old plan rollback failed'
    fi
    _toolbox_system_netopt_apply > "$R/first.out" 2>&1 || fail 'full sysctl apply failed'
    state=$TOOLBOX_SYSTEM_STATE/net-opt.previous
    while IFS= read -r line; do [[ $line == 'net.core.rmem_max='* ]] || printf '%s\n' "$line"; done < "$state" > "$state.new"
    mv -- "$state.new" "$state"
    if _toolbox_system_netopt_rollback > "$R/rollback.out" 2>&1; then fail 'truncated rollback state claimed success'; fi
    [[ -f $state && -f $TOOLBOX_SYSTEM_SYSCTL_DIR/99-terry-toolbox.conf ]] || fail 'truncated rollback discarded evidence'
    printf 'PASS sysctl key expansion and truncated rollback state\n'
}
case ${SYSTEM_REVIEW_CASE:-ALL} in
    SWAP) swap_tests;;
    SYSCTL) sysctl_tests;;
    ALL) swap_tests; sysctl_tests;;
    *) fail 'unknown review case';;
esac
