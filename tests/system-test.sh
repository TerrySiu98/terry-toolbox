#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/modules/system.sh"
log=$(mktemp "${TMPDIR:-/tmp}/toolbox-system-test.XXXXXX")
docker_marker="${log}.docker"
trap 'rm -f "$log" "$docker_marker"' EXIT
# Replace system boundaries with functions; no real privileged command is run.
_toolbox_system_os() { printf '%s\n' "${TEST_OS:-debian}"; }
_toolbox_system_root() { return 0; }
apt-get() { printf 'apt-get %s\n' "$*" >> "$log"; [[ ${MOCK_FAIL:-0} != 1 ]] || return 9; if [[ $* == *docker.io* ]]; then touch "$docker_marker"; fi; }
apk() { printf 'apk %s\n' "$*" >> "$log"; }
traceroute() { printf 'traceroute %s\n' "$*" >> "$log"; [[ ${FAIL_TRACE:-} != "${*: -1}" ]]; }
curl() { printf 'unexpected curl %s\n' "$*" >> "$log"; return 1; }
wget() { printf 'unexpected wget %s\n' "$*" >> "$log"; return 1; }
command() {
 if [[ $* == '-v docker' ]]; then [[ ${MOCK_DOCKER_INSTALLED:-0} == 1 || -e $docker_marker ]];
 elif [[ $* == '-v traceroute' && ${MISSING_TRACE:-0} == 1 ]]; then return 1
 else builtin command "$@"; fi
}
reboot() { printf 'reboot\n' >> "$log"; }
passwd() { printf 'passwd %s\n' "$*" >> "$log"; }
sysctl() {
 case "$*" in
  '-n net.ipv4.tcp_available_congestion_control') echo 'cubic bbr';;
  '-n net.ipv4.tcp_congestion_control') if [[ -s $log ]]; then echo bbr; else echo "${TEST_CURRENT:-cubic}"; fi;;
  '-w net.ipv4.tcp_congestion_control=bbr') printf 'sysctl %s\n' "$*" >> "$log";;
  *) echo 'unexpected sysctl' >&2; return 1;;
 esac
}
# Cancellation and EOF are fail-closed.
if toolbox_system MAIN_DEPS </dev/null >/dev/null 2>&1; then exit 1; fi
[ ! -s "$log" ]
printf 'YES\nYES\n' | toolbox_system MAIN_DEPS >/dev/null
[ "$(<"$log")" = 'apt-get install -y curl socat wget sudo nano iptables' ]
: > "$log"
printf 'YES\nNO\n' | toolbox_system MAIN_REBOOT >/dev/null 2>&1 && exit 1
[ ! -s "$log" ]
printf 'YES\nYES\n' | toolbox_system MAIN_REBOOT >/dev/null
[ "$(<"$log")" = reboot ]
: > "$log"
printf 'YES\nYES\n' | toolbox_system B8 >/dev/null
[ "$(<"$log")" = 'passwd root' ]
: > "$log"
printf 'YES\nYES\n' | toolbox_system MAIN_BBR >/dev/null
[ "$(<"$log")" = 'sysctl -w net.ipv4.tcp_congestion_control=bbr' ]
: > "$log"
printf 'YES\nYES\n' | toolbox_system B1 >/dev/null
[ "$(<"$log")" = 'apt-get install -y docker.io' ]
: > "$log"
if printf 'YES\nYES\n' | toolbox_system 1 >/dev/null 2>&1; then exit 1; fi
[ ! -s "$log" ]
if toolbox_system B14 </dev/null >/dev/null 2>&1; then exit 1; fi
[ ! -s "$log" ]
if printf 'YES\nYES\n' | MISSING_TRACE=1 toolbox_system 14 >/dev/null 2>&1; then exit 1; fi
[ ! -s "$log" ]
if printf 'YES\nNO\n' | toolbox_system B14 >/dev/null 2>&1; then exit 1; fi
[ ! -s "$log" ]
printf 'YES\nYES\n' | toolbox_system B14 >/dev/null
[ "$(<"$log")" = $'traceroute -n -m 20 -w 2 -q 1 219.141.136.12\ntraceroute -n -m 20 -w 2 -q 1 202.106.50.1\ntraceroute -n -m 20 -w 2 -q 1 221.179.155.161' ]
: > "$log"
if printf 'YES\nYES\n' | FAIL_TRACE=202.106.50.1 toolbox_system 14 >/dev/null 2>&1; then exit 1; fi
[[ $(<"$log") == *'221.179.155.161'* ]]
: > "$log"
out=$(toolbox_system B2 </dev/null 2>&1) && exit 1
[[ $out == *'a92fca6c0067df29ddd03fdc2fee6f3000f64545'* && $out == *'4e1b25894cadf908ef61fb0d9ce874a75524c6dafc2ea26f0477107288e0c018'* && $out == *'未执行'* ]]
if printf 'YES\nYES\n' | toolbox_system 2 >/dev/null 2>&1; then exit 1; fi
[ ! -s "$log" ]
TEST_OS=alpine; export TEST_OS
printf 'YES\nYES\n' | toolbox_system MAIN_DEPS >/dev/null
[ "$(<"$log")" = 'apk add --no-cache curl socat wget sudo nano iptables' ]
unset TEST_OS
: > "$log"
if printf 'YES\nYES\n' | MOCK_FAIL=1 toolbox_system MAIN_DEPS >/dev/null 2>&1; then exit 1; fi
: > "$log"
for id in MAIN_REINSTALL B2 B4 B5 B7 B10 B11 B15 B16 B19 B99; do
 if toolbox_system "$id" </dev/null >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$id" >&2; exit 1; fi
done
[ ! -s "$log" ]
# B6 remains unavailable until swap transaction safety has been redesigned.
# These cases check refusal only: they do not exercise a swap transaction or
# prove rollback under races/signals. All fixture changes stay in swap_root.
# Each alias must reject before touching any host or swap-related boundary.
swap_root=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-swap-test.XXXXXX")
trap 'rm -f "$log" "$docker_marker"; rm -rf "$swap_root"' EXIT
mkdir -p "$swap_root/etc/systemd/system/swap.target.wants" "$swap_root/run/lock"
: > "$swap_root/etc/fstab"
printf 'preserve\n' > "$swap_root/victim"
for scenario in concurrent interrupt stale pathrace override; do
 for id in B6 6; do
 : > "$log"
 # A pre-existing drop-in must not be touched, even though a future implementation
 # must inspect effective units in all systemd search paths and generators.
 mkdir -p "$swap_root/etc/systemd/system/swapfile_toolbox.swap.d"
 printf '[Swap]\nWhat=/unexpected\n' > "$swap_root/etc/systemd/system/swapfile_toolbox.swap.d/override.conf"
 if (
  _toolbox_system_swap_root() { printf 'swap-root\n' >> "$log"; printf '%s\n' "$swap_root"; }
  _toolbox_system_swap_supported() { printf 'supported\n' >> "$log"; return 0; }
  _toolbox_system_confirm() { printf 'confirm\n' >> "$log"; [[ $scenario != stale ]] || touch "$swap_root/other"; return 0; }
  findmnt() { printf 'findmnt\n' >> "$log"; printf 'ext4\n'; }
  df() { printf 'df\n' >> "$log"; printf 'header\ntest 9000000 0 9000000 0 /\n'; }
  dd() {
   printf 'dd\n' >> "$log"
   if [[ $scenario == interrupt ]]; then kill -TERM "$BASHPID"; fi
   if [[ $scenario == pathrace ]]; then rm -f "$swap_root/swapfile_toolbox"; ln -s "$swap_root/victim" "$swap_root/swapfile_toolbox"; printf overwritten > "$swap_root/swapfile_toolbox"; fi
   return 0
  }
  mkswap() { printf 'mkswap\n' >> "$log"; return 0; }
  swapon() {
   printf 'swapon\n' >> "$log"
   if [[ ${1-} == --show=NAME ]]; then
    [[ ! -e $swap_root/other ]] || printf '/other-swap\n'
    [[ ! -e $swap_root/active ]] || printf '%s\n' "$swap_root/swapfile_toolbox"
    return 0
   fi
   touch "$swap_root/active"
   if [[ $scenario == concurrent ]]; then touch "$swap_root/other"; return 1; fi
   return 0
  }
  swapoff() { printf 'swapoff\n' >> "$log"; rm -f "$swap_root/active"; }
  systemctl() { printf 'systemctl\n' >> "$log"; return 0; }
  toolbox_system "$id" <<< $'1\nYES\nYES' > "$swap_root/output" 2>&1
 ); then printf 'unexpected B6 success: %s %s\n' "$scenario" "$id" >&2; exit 1; fi
 if [[ -s $log ]]; then printf 'B6 reached an unsafe boundary: %s %s\n' "$scenario" "$id" >&2; exit 1; fi
 [[ $(<"$swap_root/output") == *'未执行任何更改'* ]]
 # Refusal must explain why this is still disabled rather than promising rollback.
 [[ $(<"$swap_root/output") == *'systemd'* && $(<"$swap_root/output") == *'并发'* && $(<"$swap_root/output") == *'中断'* ]]
 [[ $(<"$swap_root/victim") == preserve && ! -e $swap_root/swapfile_toolbox ]]
 [[ ! -e $swap_root/active && ! -e $swap_root/other ]]
 [[ $(<"$swap_root/etc/systemd/system/swapfile_toolbox.swap.d/override.conf") == $'[Swap]\nWhat=/unexpected' ]]
 [[ ! -e $swap_root/etc/systemd/system/swapfile_toolbox.swap ]]
 [[ ! -L $swap_root/etc/systemd/system/swap.target.wants/swapfile_toolbox.swap ]]
 done
done
# A populated, apparently managed fixture must remain intact;
# denial happens before confirmation, privilege detection, or command probes.
mkdir -p "$swap_root/existing"
printf 'existing swap bytes\n' > "$swap_root/existing/swapfile_toolbox"
printf '/swapfile_toolbox none swap defaults 0 0\n' > "$swap_root/existing/fstab"
printf 'active external swap\n' > "$swap_root/existing/active"
printf 'preserve input\n' > "$swap_root/input"
for id in B6 6; do
 : > "$log"
 if (
  _toolbox_system_root() { printf 'root check\n' >> "$log"; return 1; }
  _toolbox_system_confirm() { printf 'confirm\n' >> "$log"; return 0; }
  for boundary in id stat readlink realpath findmnt df dd fallocate truncate mkswap swapon swapoff systemctl flock mount umount chmod chown mv cp rm install; do
   eval "$boundary() { printf '%s\\n' '$boundary' >> \"\$log\"; return 1; }"
  done
  trap ':' INT TERM EXIT
  before=$(trap -p INT TERM EXIT)
  exec 3< "$swap_root/input"
  if toolbox_system "$id" <&3 > "$swap_root/output" 2>&1; then exit 1; fi
  # Refusal must describe concrete blockers, not imply partial swap recovery exists.
  output=$(<"$swap_root/output")
  [[ $output == *'私有锁'* && $output == *'外部'* && $output == *'inode'* ]] || exit 1
  [[ $output == *'活动 swap'* && $output == *'systemd'* && $output == *'drop-in'* ]] || exit 1
  [[ $output == *'SIGKILL'* && $output == *'断电'* && $output == *'不会自动恢复'* ]] || exit 1
  [[ $output == *'未创建'* && $output == *'未启用'* ]] || exit 1
  after=$(trap -p INT TERM EXIT)
  [[ $before == "$after" ]] || exit 1
  IFS= read -r first <&3
  [[ $first == 'preserve input' ]]
 ); then :; else printf 'B6 refusal invariants failed: %s\n' "$id" >&2; exit 1; fi
 [[ ! -s $log ]]
 [[ $(<"$swap_root/existing/swapfile_toolbox") == 'existing swap bytes' ]]
 [[ $(<"$swap_root/existing/fstab") == '/swapfile_toolbox none swap defaults 0 0' ]]
 [[ $(<"$swap_root/existing/active") == 'active external swap' ]]
done
printf 'system tests passed\n'
