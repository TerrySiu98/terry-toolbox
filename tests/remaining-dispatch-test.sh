#!/usr/bin/env bash
# Pure dispatch tests: all mutating implementations are mocks or missing-module refusal.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/toolbox.sh" --help >/dev/null
source "$ROOT/modules/system.sh"
source "$ROOT/modules/network.sh"
fail() { printf 'FAIL remaining-dispatch: %s\n' "$*" >&2; exit 1; }
for key in B1 MAIN_REINSTALL TLS; do
    _tb_managed_key "$key" || fail "missing management page $key"
done
_tb_service_choice_valid B1 4 || fail 'B1 IPv6 restore selection'
_tb_service_choice_valid B10 9 || fail 'B10 Easynode status selection'
_tb_service_choice_valid A5 10 || fail 'A5 update-cert selection'
_tb_service_choice_valid MAIN_REINSTALL 4 || fail 'M3 cancellation selection'
_tb_service_choice_valid TLS 6 || fail 'TLS deploy selection'
! _tb_service_choice_valid B10 10 || fail 'B10 accepted invalid selection'
(
    _toolbox_system_docker() { printf 'docker-install\n'; }
    toolbox_docker_ipv6() { printf 'ipv6:%s\n' "$*"; return 7; }
    out=$(run_service_action B1 1); [[ $out == docker-install ]] || fail B1-install
    for pair in '2 apply' '3 status' '4 restore'; do
        read -r number action <<< "$pair"
        rc=0; out=$(run_service_action B1 "$number") || rc=$?
        [[ $rc == 7 && $out == "ipv6:$action" ]] || fail "B1-$action propagation"
    done
)
(
    toolbox_webssh() { printf 'python:%s\n' "$*"; }
    toolbox_webssh_container() { printf 'container:<%s>\n' "$@"; return 7; }
    for pair in '1 install' '2 uninstall' '3 status'; do
        read -r number action <<< "$pair"; out=$(run_service_action B10 "$number")
        [[ $out == "python:$action" ]] || fail "legacy-WebSSH-$action"
    done
    for pair in '4 personal install' '5 personal uninstall' '6 personal status' '7 easynode install' '8 easynode uninstall' '9 easynode status'; do
        read -r number kind action <<< "$pair"; rc=0
        out=$(run_service_action B10 "$number") || rc=$?
        expected=$(printf 'container:<%s>\n' "$kind" "$action")
        [[ $rc == 7 && $out == "$expected" ]] || fail "B10-$number"
    done
)
(
    toolbox_vmess() { printf '<%s>\n' "$@"; return 7; }
    for action in enable-boot disable-boot boot-status; do
        rc=0; out=$(toolbox_network A5 "$action-ws") || rc=$?
        [[ $rc == 7 && $out == "<$action>" ]] || fail "VMess-$action"
    done
    rc=0; out=$(toolbox_network A5 update-cert-ws 'cert with spaces.pem' 'key with spaces.pem') || rc=$?
    expected=$(printf '<%s>\n' update-cert 'cert with spaces.pem' 'key with spaces.pem')
    [[ $rc == 7 && $out == "$expected" ]] || fail VMess-cert-boundaries
)
(
    toolbox_network() { printf 'network:<%s>\n' "$@"; return 7; }
    for pair in '7 enable-boot-ws' '8 disable-boot-ws' '9 boot-status-ws'; do
        read -r number action <<< "$pair"; rc=0; out=$(run_service_action A5 "$number") || rc=$?
        expected=$(printf 'network:<%s>\n' A5 "$action")
        [[ $rc == 7 && $out == "$expected" ]] || fail "A5-$number"
    done
)
(
    toolbox_reinstall() { printf 'reinstall:%s\n' "$*"; return 7; }
    for pair in '1 preflight debian' '2 prepare debian 13' '3 status' '4 cancel'; do
        read -r number action <<< "$pair"; rc=0; out=$(run_service_action MAIN_REINSTALL "$number" <<< '1') || rc=$?
        [[ $rc == 7 && $out == "reinstall:$action" ]] || fail "M3-$number"
    done
    for pair in '1 debian 13' '2 ubuntu 24.04' '3 alpine 3.24'; do
        read -r selection distro version <<< "$pair"
        rc=0; out=$(run_service_action MAIN_REINSTALL 2 <<< "$selection") || rc=$?
        [[ $rc == 7 && $out == "reinstall:prepare $distro $version" ]] || fail "M3-target-$selection"
    done
    for input in '' 0 invalid; do
        rc=0; out=$(run_service_action MAIN_REINSTALL 2 <<< "$input") || rc=$?
        [[ $rc == 1 && -z $out ]] || fail 'M3 cancelled target reached adapter'
    done
)
(
    toolbox_tls_acme() { printf 'tls:%s\n' "$*"; return 7; }
    for pair in '1 issue' '2 status' '3 renew' '4 enable-renewal' '5 disable-renewal' '6 deploy-vmess'; do
        read -r number action <<< "$pair"; rc=0; out=$(run_service_action TLS "$number") || rc=$?
        [[ $rc == 7 && $out == "tls:$action" ]] || fail "TLS-$number"
    done
)
# Missing implementations must not fall through to an installation or return success.
for call in '_toolbox_system_docker_ipv6 status' '_toolbox_system_reinstall status' '_toolbox_webssh_container personal status' '_toolbox_tls_acme status'; do
    rc=0; out=$($call 2>&1) || rc=$?
    [[ $rc != 0 && $out == *'模块未加载'* ]] || fail "missing-module $call"
done
printf 'PASS remaining feature management dispatch and fail-closed missing modules\n'
