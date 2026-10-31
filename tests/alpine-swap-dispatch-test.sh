#!/usr/bin/env bash
# Dispatch-only checks. Never run real swap/OpenRC commands.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/toolbox.sh" --help >/dev/null
source "$root/modules/system.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
unset -f toolbox_alpine_swap 2>/dev/null || true
rc=0
out=$(_toolbox_system_alpine_swap install 128 2>&1) || rc=$?
[[ $rc != 0 && $out == *'Alpine swap 模块未加载'* ]] || fail 'missing module must fail with an explanation'
# Exact arguments and the callee failure survive the adapter.
toolbox_alpine_swap() { printf '<%s>\n' "$@"; return 7; }
for action in install status uninstall; do
    rc=0
    out=$(_toolbox_system_alpine_swap "$action" 'one argument' 2>&1) || rc=$?
    [[ $rc == 7 && $out == "$(printf '<%s>\n' "$action" 'one argument')" ]] || fail "adapter $action"
done
for choice in 4 5 6; do
    case $choice in 4) action=install;; 5) action=uninstall;; 6) action=status;; esac
    _tb_service_choice_valid B19 "$choice" || fail "B19 missing choice $choice"
    rc=0
    out=$(run_service_action B19 "$choice" 2>&1) || rc=$?
    [[ $rc == 7 && $out == "<$action>" ]] || fail "B19 action $choice"
done
for choice in 0 7 44 bad; do
    if _tb_service_choice_valid B19 "$choice"; then fail "invalid choice $choice"; fi
done
# Existing Webtop / hop actions retain their numbering.
_toolbox_system_alpine_webtop() { printf webtop; }
_toolbox_system_alpine_hop_apply() { printf hop; }
_toolbox_system_alpine_hop_remove() { printf remove-hop; }
[[ $(run_service_action B19 1) == webtop ]] || fail 'Webtop changed'
[[ $(run_service_action B19 2) == hop ]] || fail 'hop changed'
[[ $(run_service_action B19 3) == remove-hop ]] || fail 'remove-hop changed'
# The standalone system-module menu also dispatches to the same adapter.
toolbox_alpine_swap() { printf 'SWAP:%s\n' "$*"; }
for choice in 4 5 6; do
    case $choice in 4) action=install;; 5) action=uninstall;; 6) action=status;; esac
    out=$(_toolbox_system_alpine <<< "$choice" 2>&1)
    [[ $out == *"SWAP:$action"* ]] || fail "legacy B19 dispatch $choice"
done
printf 'PASS Alpine swap dispatch, missing-module refusal, argument/status forwarding and legacy B19 actions\n'
