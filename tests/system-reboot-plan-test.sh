#!/usr/bin/env bash
# Read-only/mock regressions for the production reboot gate; never reboot a host.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/scratch-root.sh"
toolbox_test_scratch
work=$(mktemp -d "$TMPDIR/toolbox-reboot-plan.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
source "$ROOT/modules/system.sh"
_toolbox_system_root() { return 0; }
reboot() { printf 'reboot\n' >> "$work/reboot.log"; }
STATUS='M3 phase=failed target=debian 13 disk=/dev/vda commit=abc'
STATUS_RC=0
STATUS_NEXT=''
toolbox_reinstall() {
    [[ $1 == status ]] || return 99
    if [[ -n $STATUS_NEXT && -e $work/status-read ]]; then printf '%s\n' "$STATUS_NEXT"
    else printf '%s\n' "$STATUS"; fi
    : > "$work/status-read"
    return "$STATUS_RC"
}
checks=0
blocked() {
    local name=$1 input=$2
    : > "$work/reboot.log"; rm -f -- "$work/status-read"
    if printf '%s' "$input" | _toolbox_system_reboot >"$work/out" 2>&1; then
        printf 'FAIL %s: unsafe state reached reboot boundary\n' "$name" >&2; exit 1
    fi
    [[ ! -s $work/reboot.log ]] || { printf 'FAIL %s: reboot called\n' "$name" >&2; exit 1; }
    checks=$((checks+1)); printf 'PASS blocked %s\n' "$name"
}
allowed() {
    local name=$1 input=$2
    : > "$work/reboot.log"; rm -f -- "$work/status-read"
    printf '%s' "$input" | _toolbox_system_reboot >"$work/out" 2>&1
    [[ $(<"$work/reboot.log") == reboot ]]
    checks=$((checks+1)); printf 'PASS allowed %s\n' "$name"
}
for phase in failed interrupted preparing cancelling cancel-interrupted reset-failed restore-failed new-unknown-phase; do
    STATUS="M3 phase=$phase target=debian 13 disk=/dev/vda commit=abc"
    blocked "$phase" $'YES\nYES\n/dev/vda\nREBOOT\n'
done
STATUS='blocking: unknown plan'; STATUS_RC=1
blocked unknown-status $'YES\nYES\nREBOOT\n'
STATUS_RC=0; STATUS='unexpected status text'
blocked malformed-status $'YES\nYES\nREBOOT\n'
STATUS='M3 phase=prepared target=debian 13 disk=/dev/vda commit=abc'
blocked prepared-no-disk $'YES\nYES\n'
blocked prepared-wrong-disk $'YES\nYES\n/dev/vdb\n'
blocked prepared-disk-no-newline $'YES\nYES\n/dev/vda'
allowed prepared-explicit-disk $'YES\nYES\n/dev/vda\n'
STATUS_NEXT='M3 phase=failed target=debian 13 disk=/dev/vda commit=abc'
blocked prepared-changed-before-reboot $'YES\nYES\n/dev/vda\n'
STATUS_NEXT=''; STATUS='没有本工具 owned plan；只读，未调用上游。'
allowed no-owned-plan $'YES\nYES\n'
STATUS_NEXT='M3 phase=prepared target=debian 13 disk=/dev/vda commit=abc'
blocked plan-created-before-reboot $'YES\nYES\n'
STATUS_NEXT=''; STATUS='M3 phase=cancelled target=debian 13 disk=/dev/vda commit=abc'
allowed cancelled-validated-status $'YES\nYES\n'
printf 'Reboot plan gate: %s checks passed; no real reboot/service/disk mutation.\n' "$checks"
