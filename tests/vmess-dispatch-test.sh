#!/usr/bin/env bash
# Dispatch-only tests; no privileged commands or service operations run.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/modules/network.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Missing module is an error, not an invitation to download or install anything.
for action in install-ws uninstall-ws status-ws; do
    rc=0
    out=$(toolbox_network A5 "$action" 2>&1) || rc=$?
    [[ $rc != 0 && $out == *'VMess 模块未加载'* ]] || fail "missing module: $action"
done
# Preserve argument boundaries and a nonzero callee status through all adapters.
(
    toolbox_vmess() { printf '<%s>\n' "$@"; return 7; }
    for action in install uninstall status; do
        rc=0
        out=$(toolbox_network A5 "$action-ws" 'cert with spaces.pem' 'key with spaces.pem' example.test 18443 /websocket) || rc=$?
        expected=$(printf '<%s>\n' "$action" 'cert with spaces.pem' 'key with spaces.pem' example.test 18443 /websocket)
        [[ $rc == 7 && $out == "$expected" ]] || fail "argument/return forwarding: $action"
    done
)
# Legacy REALITY actions are unchanged.
(
    _net_a5_install() { printf 'legacy-install:%s\n' "$*"; }
    _net_a5_uninstall() { printf 'legacy-uninstall\n'; }
    net_a5_status() { printf 'legacy-status\n'; }
    [[ $(toolbox_network A5 install target.test server.test 18443) == 'legacy-install:target.test server.test 18443' ]] || fail legacy-install
    [[ $(toolbox_network A5 uninstall) == legacy-uninstall ]] || fail legacy-uninstall
    [[ $(toolbox_network A5 status) == legacy-status ]] || fail legacy-status
)
printf 'PASS VMess dispatch, missing-module gate, argument boundaries and legacy REALITY actions\n'
