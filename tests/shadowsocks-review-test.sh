#!/usr/bin/env bash
# Signal registration and all-process deletion gates: mocked manager, real ELF/PIDs.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/scratch-root.sh"
toolbox_test_scratch
export VMESS_FIXTURE_ONLY=1
source "$root/tests/vmess-test.sh"
source "${SS_MODULE_UNDER_TEST:-$root/modules/shadowsocks.sh}"
ssx_require() { ssreview_parent=$BASHPID; }
ssx_fetch() { cp "$T/native" "$1/xray"; }
vmess_bin() { ssx_bin; }; vmess_unit() { ssx_unit; }
ss() {
 [[ $* == -ltnpH || $* == -uanpH ]] || return 99
 [[ ${SS_FAIL:-0} != 1 ]] || return 1
 local pid=$(<"$C/pid") state=$(<"$C/state")
 if [[ $state == active ]]; then
  if [[ $1 == -ltnpH ]]; then printf 'LISTEN 0 128 127.0.0.1:24443 0.0.0.0:* users:(("fixture",pid=%s,fd=3))\n' "$pid"
  else printf 'UNCONN 0 0 127.0.0.1:24443 0.0.0.0:* users:(("fixture",pid=%s,fd=4))\n' "$pid"; fi
 fi
}
setup() {
 fixture "$1"
 export TOOLBOX_SS_ETC="$C/etc" TOOLBOX_SS_BIN_DIR="$C/bin" TOOLBOX_SS_UNIT_DIR="$C/units" TOOLBOX_SS_LOCK="$C/lock" TOOLBOX_SS_STAGE_DIR="$C" TOOLBOX_SS_LISTEN=127.0.0.1
 unset INJECT
}
eval "${_ss_fs_definition:=$(declare -f ssx_fs)}"
f=$(declare -f ssx_fs); eval "${f/ssx_fs ()/ssreview_real_fs ()}"
ssx_fs() {
 ssreview_real_fs "$@" || return $?
 if [[ $1 == lock && ${INJECT:-0} == 1 ]]; then
  kill -TERM "$ssreview_parent"
  command sleep .05
 fi
}
install_yes() { toolbox_shadowsocks systemd install 127.0.0.1 24443 <<< $'YES\nYES' >"$C/output" 2>&1; }
uninstall_yes() { toolbox_shadowsocks systemd uninstall <<< $'YES\nYES' >"$C/uninstall-output" 2>&1; }
setup install-lock-window
INJECT=1
if install_yes; then child=0; else child=$?; fi
[[ $child == 143 ]] || fail "TERM install child=$child"
[[ ! -e $C/lock && ! -e $C/etc ]] || fail 'TERM before lock registration left lock'
unset INJECT
install_yes || fail 'retry after interrupted lock failed'
uninstall_yes || fail 'positive lifecycle after signal failed'
pass 'TERM during install lock registration releases only owned lock and retry works'
setup uninstall-lock-window
install_yes || fail 'positive install before uninstall signal failed'
INJECT=1
if uninstall_yes; then child=0; else child=$?; fi
[[ $child == 143 && ! -e $C/lock && -e $C/etc && $(<"$C/state") == active ]] || fail "uninstall TERM failed child=$child"
unset INJECT
uninstall_yes || fail 'retry uninstall failed'
pass 'TERM during uninstall lock registration preserves live service and releases lock'
# Catchable signals must be masked before removing the EXIT cleanup handler.
# This hook runs the real builtin, then sends a real TERM at that command boundary.
trap() {
 builtin trap "$@"
 if [[ $* == '- EXIT' && ${CLEANUP_INJECT:-0} == 1 ]]; then
  kill -TERM "$BASHPID"
  command sleep .05
 fi
}
setup cleanup-transition-install
CLEANUP_INJECT=1
if toolbox_shadowsocks systemd install 127.0.0.1 24443 <<< '' >"$C/output" 2>&1; then child=0; else child=$?; fi
unset CLEANUP_INJECT
[[ $child == 1 && ! -e $C/lock && ! -e $C/etc ]] || fail "cleanup transition cancel child=$child; lock must be released"
install_yes || fail 'retry after cleanup transition cancellation failed'
CLEANUP_INJECT=1
if uninstall_yes; then child=0; else child=$?; fi
unset CLEANUP_INJECT
[[ $child == 0 && ! -e $C/lock && ! -e $C/etc ]] || fail "cleanup transition uninstall child=$child"
install_yes || fail 'positive reinstall after cleanup transition failed'
uninstall_yes || fail 'positive cleanup after transition failed'
unset -f trap
pass 'TERM after EXIT handler removal cannot interrupt cleanup; cancellation and uninstall preserve original exit status'

setup extra-systemd-process
install_yes || fail 'install for extra executable failed'
mkdir "$C/extra"
pid=$(python3 -c 'import subprocess,sys;from pathlib import Path;p=subprocess.Popen([sys.argv[1]],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);Path(sys.argv[2]).write_text(str(p.pid));print(p.pid)' "$(ssx_bin)" "$C/extra/pid")
for ((i=0;i<100;i++)); do [[ $(readlink "/proc/$pid/exe" 2>/dev/null || :) == "$(ssx_bin)" ]] && break; command sleep .01; done
if uninstall_yes; then child=0; else child=$?; fi
[[ $child != 0 && -e $C/etc && -e $(ssx_bin) && -e $(ssx_unit) && -e /proc/$pid/exe ]] || fail 'extra live executable did not preserve resources'
python3 - "$pid" "$(ssx_bin)" <<'PY'
import os,sys,signal,time
pid=int(sys.argv[1]);target=os.stat(sys.argv[2]);actual=os.stat(f'/proc/{pid}/exe');assert (target.st_dev,target.st_ino)==(actual.st_dev,actual.st_ino)
f=os.pidfd_open(pid);signal.pidfd_send_signal(f,signal.SIGTERM);os.close(f)
for _ in range(100):
 try:os.stat(f'/proc/{pid}/exe')
 except FileNotFoundError:break
 time.sleep(.01)
else:raise AssertionError('fixture executable still alive')
PY
uninstall_yes || fail 'uninstall after exact extra child exit failed'
pass 'systemd stop success does not permit deletion while another same-inode process lives'
setup extra-alpine-process
cp "$T/native" "$(ssx_bin)"
mkdir "$C/extra"
pid=$(python3 -c 'import subprocess,sys;from pathlib import Path;p=subprocess.Popen([sys.argv[1]],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);Path(sys.argv[2]).write_text(str(p.pid));print(p.pid)' "$(ssx_bin)" "$C/extra/pid")
for ((i=0;i<100;i++)); do [[ $(readlink "/proc/$pid/exe" 2>/dev/null || :) == "$(ssx_bin)" ]] && break; command sleep .01; done
rc-service() { [[ $2 == status ]] || return 99; return 3; }
ssx_port_free() { :; }
if ssx_alpine_stop 24443 1; then child=0; else child=$?; fi
[[ $child != 0 && -e /proc/$pid/exe && -e $(ssx_bin) ]] || fail 'Alpine absent pidfile gate accepted living executable'
python3 - "$pid" <<'PY'
import os,signal,sys
fd=os.pidfd_open(int(sys.argv[1]));signal.pidfd_send_signal(fd,signal.SIGTERM);os.close(fd)
PY
pass 'Alpine stopped/no-pidfile state still checks all live same-inode executables'
printf 'PASS shadowsocks review regressions\n'
