#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/scratch-root.sh"
toolbox_test_scratch
safetyroot=$(mktemp -d "$TMPDIR/toolbox-system-safety.XXXXXX")
export HOME="$safetyroot/home"
mkdir -p "$HOME" "$safetyroot/bin"
for cmd in apt-get apk docker systemctl sysctl swapon swapoff mkswap dd passwd reboot \
           iptables ip6tables rc-service mount umount chroot curl wget gpg dpkg dpkg-query; do
 printf '#!/usr/bin/env bash\nprintf "UNMOCKED privileged boundary: %%s\\n" "%s" >&2\nexit 99\n' "$cmd" > "$safetyroot/bin/$cmd"
 chmod 0755 "$safetyroot/bin/$cmd"
done
export PATH="$safetyroot/bin:$PATH"
# Real install is allowed only for scratch paths; this catches hardcoded /opt etc.
install() {
 local arg
 for arg in "$@"; do
  case $arg in /*) [[ $arg == "$TMPDIR"/* ]] || { printf 'UNSAFE install target: %s\n' "$arg" >&2; return 99; };; esac
 done
 /usr/bin/install "$@"
}
# shellcheck source=modules/system.sh
source "${SYSTEM_MODULE_UNDER_TEST:-$ROOT/modules/system.sh}"
package_status_impl=$(declare -f _toolbox_system_package_installed)
log=$(mktemp "$TMPDIR/toolbox-system-test.XXXXXX")
docker_marker="${log}.docker"
trap 'rm -f "$log" "$docker_marker"; rm -rf "$safetyroot"' EXIT
# Replace system boundaries with functions; no real privileged command is run.
_toolbox_system_os() { printf '%s\n' "${TEST_OS:-debian}"; }
_toolbox_system_root() { return 0; }
_toolbox_system_package_installed() { return 1; }
apt-get() { printf 'apt-get %s\n' "$*" >> "$log"; [[ ${MOCK_FAIL:-0} != 1 ]] || return 9; if [[ $* == *docker.io* ]]; then touch "$docker_marker"; fi
 if [[ -n ${mockroot:-} && $* == *vnstat* ]]; then touch "$mockroot/vnstat-installed"; fi; }
apk() { printf 'apk %s\n' "$*" >> "$log"; }
traceroute() { printf 'traceroute %s\n' "$*" >> "$log"; [[ ${FAIL_TRACE:-} != "${*: -1}" ]]; }
wget() { printf 'unexpected wget %s\n' "$*" >> "$log"; return 1; }
# Tool discovery is indirected in the module so tests steer it without PATH tricks.
_toolbox_system_has() {
 local t=$1
 case " ${MOCK_MISSING:-} " in *" $t "*) return 1;; esac
 case $t in
  docker) [[ ${MOCK_DOCKER_INSTALLED:-0} == 1 || -e $docker_marker ]];;
  traceroute) [[ ${MISSING_TRACE:-0} != 1 ]];;
  vnstat) [[ ${MOCK_NO_VNSTAT:-0} != 1 && -e ${mockroot:-/nonexistent}/vnstat-installed ]];;
  1pctl|1panel) [[ -e ${mockroot:-/nonexistent}/1pctl-installed ]];;
  *) return 0;;
 esac
}
# Only the 1Panel download reaches curl from this shell; Telegram/Telegram-report
# calls run in child processes and use the PATH stub below.
curl() {
 printf 'curl %s\n' "$*" >> "$log"
 local dest=''
 while (( $# )); do case $1 in -o) dest=$2; shift 2;; *) shift;; esac; done
 [[ -n $dest ]] || return 1
 [[ ${MOCK_CURL_FAIL:-0} != 1 ]] || return 22
 cp -- "$MOCK_DOWNLOAD" "$dest"
}
sleep() { :; }
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

# Focused audit regressions share production code; only privileged boundaries mocked.
# SYSTEM_AUDIT_CASE=S1..S7|S4|WEBTOP runs one slice; ALL runs every slice.
audit_setup() {
 auditroot=$(mktemp -d "$TMPDIR/toolbox-system-audit.XXXXXX")
 export TOOLBOX_SYSTEM_ETC="$auditroot/etc" TOOLBOX_SYSTEM_STATE="$auditroot/state"
 export TOOLBOX_SYSTEM_UNIT_DIR="$auditroot/units" TOOLBOX_SYSTEM_BIN_DIR="$auditroot/bin"
 export TOOLBOX_SYSTEM_SYSCTL_DIR="$auditroot/sysctl" TOOLBOX_SYSTEMD_RUN="$auditroot/run"
 export TOOLBOX_SWAP_ROOT="$auditroot/swap" TOOLBOX_WEBTOP_ROOT="$auditroot/webtop"
 export TOOLBOX_DOCKER_APT_ROOT="$auditroot/apt" TOOLBOX_DOCKER_DATA_ROOT="$auditroot/docker-data"
 export TOOLBOX_DOCKER_OS_RELEASE="$auditroot/os-release"
 mkdir -p "$TOOLBOX_SYSTEM_ETC" "$TOOLBOX_SYSTEM_STATE" "$TOOLBOX_SYSTEM_UNIT_DIR" \
  "$TOOLBOX_SYSTEM_BIN_DIR" "$TOOLBOX_SYSTEM_SYSCTL_DIR" "$TOOLBOX_SYSTEMD_RUN" "$TOOLBOX_SWAP_ROOT"
 printf 'ID=debian\nVERSION_CODENAME=trixie\n' > "$TOOLBOX_DOCKER_OS_RELEASE"
 : > "$log"; rm -f "$docker_marker"
 auditvals="$auditroot/values"
 printf '%s=%s\n' net.ipv4.tcp_available_congestion_control 'cubic bbr' \
  net.ipv4.tcp_congestion_control cubic net.core.default_qdisc pfifo_fast net.core.somaxconn 128 \
  net.ipv4.tcp_max_syn_backlog 1024 net.ipv4.tcp_fastopen 1 net.ipv4.tcp_slow_start_after_idle 1 \
  net.ipv4.tcp_mtu_probing 0 net.ipv4.ip_local_port_range '32768 60999' \
  net.core.rmem_max 212992 net.core.wmem_max 212992 > "$auditvals"
 sysctl() {
  printf 'sysctl %s\n' "$*" >> "$log"
  local k v line found=0
  case $1 in
   -n) while IFS='=' read -r k v; do
         [[ $k == "$2" ]] || continue
         if [[ $k == net.ipv4.ip_local_port_range && ${AUDIT_TABS:-0} == 1 ]]; then
          printf '%s\n' "${v/ /$'\t'}"
         else printf '%s\n' "$v"; fi
         found=1
        done < "$auditvals"; (( found == 1 ));;
   -w) k=${2%%=*}; v=${2#*=}
       [[ ${AUDIT_WRITE_FAIL:-} != "$k" ]] || return 1
       [[ ${AUDIT_WRITE_IGNORE:-} != "$k" ]] || return 0
       while IFS= read -r line; do [[ $line == "$k="* ]] || printf '%s\n' "$line"; done \
        < "$auditvals" > "$auditvals.new"
       printf '%s=%s\n' "$k" "$v" >> "$auditvals.new"; mv "$auditvals.new" "$auditvals";;
   -p) [[ ${AUDIT_APPLY_FAIL:-0} != 1 ]] || return 1
       while IFS='=' read -r k v; do
        [[ $k == '#'* || -z $k ]] && continue
        k=${k// /}; v=${v# }
        if [[ $k != "${AUDIT_DRIFT_KEY:-}" ]]; then sysctl -w "$k=$v"; fi
        [[ ${AUDIT_STDOUT:-0} != 1 ]] || printf '%s = %s\n' "$k" "$v"
       done < "$2"; return 0;;
   *) return 1;;
  esac
 }
 systemctl() {
  printf 'systemctl %s\n' "$*" >> "$log"
  local unit=${*: -1}
  case $* in
   'disable --now '*) [[ ${AUDIT_STOP_FAIL:-0} != 1 ]] || return 1
      rm -f "$auditroot/active-$unit" "$auditroot/enabled-$unit"
      if [[ ${AUDIT_SWAP_READ_AFTER_STOP:-0} == 1 ]]; then : > "$auditroot/swap-read-fail"; fi;;
   'enable --now '*) [[ ${AUDIT_ENABLE_FAIL:-0} != 1 ]] || return 1
      touch "$auditroot/active-$unit" "$auditroot/enabled-$unit";;
   'enable '*) touch "$auditroot/enabled-$unit";;
   'stop '*) [[ ${AUDIT_SERVICE_STOP_FAIL:-0} != 1 ]] || return 1
      rm -f "$auditroot/active-$unit";;
   'start '*) touch "$auditroot/active-$unit";;
   'show -p FragmentPath'*) [[ ${AUDIT_FOREIGN_UNIT:-} != "$unit" ]] || printf '/usr/lib/systemd/system/foreign.service\n';;
   'show -p DropInPaths'*) return 0;;
   'show -p ActiveState'*) if [[ -e $auditroot/active-$unit ]]; then printf 'active\n'; else printf 'inactive\n'; fi;;
   'show -p UnitFileState'*) [[ ${AUDIT_STATE_READ_FAIL:-0} != 1 ]] || return 1
      if [[ -e $auditroot/enabled-$unit ]]; then printf 'enabled\n'; else printf 'disabled\n'; fi;;
   'is-active --quiet '*) [[ -e $auditroot/active-$unit ]];;
   'is-enabled --quiet '*) [[ -e $auditroot/enabled-$unit ]];;
   *) return 0;;
  esac
 }
 vnstat() { printf '{"interfaces":[]}\n'; }
 _toolbox_system_has() {
  case " ${MOCK_MISSING:-} " in *" $1 "*) return 1;; esac
  case $1 in docker) [[ -e $docker_marker ]];; *) return 0;; esac
 }
 _toolbox_system_package_installed() { [[ " ${AUDIT_INSTALLED:-} " == *" $1 "* ]]; }
 apt-get() {
  printf 'apt-get %s\n' "$*" >> "$log"
  [[ $* != "${AUDIT_APT_FAIL:-}" ]] || return 9
  [[ ${AUDIT_APT_FAIL:-} != update || ${*: -1} != update ]] || return 9
  [[ ${AUDIT_APT_FAIL:-} != download || " $* " != *' download '* ]] || return 9
  if [[ " $* " == *' download '* ]]; then
   for fixture_pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    [[ ${AUDIT_DEB_MISSING:-} != "$fixture_pkg" ]] || continue
    : > "$fixture_pkg.deb"
   done
  fi
  [[ $* != *'install '* || $* != *docker-ce* ]] || touch "$docker_marker"
  return 0
 }
 apt-cache() {
  [[ ${AUDIT_POLICY_FAIL:-0} != 1 ]] || return 1
  printf '%s:\n  Installed: (none)\n  Candidate: %s\n  Version table:\n' "${*: -1}" "${AUDIT_CANDIDATE:-(none)}"
 }
 dpkg-deb() {
  printf 'dpkg-deb %s\n' "$*" >> "$log"
  [[ ${AUDIT_DEB_READ_FAIL:-0} != 1 ]] || return 1
  local fixture_pkg=${*: -1}; fixture_pkg=${fixture_pkg##*/}; fixture_pkg=${fixture_pkg%.deb}
  printf '%s %s %s' "$fixture_pkg" '5:29.1.1-1~debian.13~trixie' "${AUDIT_DEB_ARCH:-amd64}"
 }
 apk() { printf 'apk %s\n' "$*" >> "$log"; touch "$docker_marker"; }
 dpkg() { [[ $* == --print-architecture ]] && printf 'amd64\n'; }
 dpkg-query() { return 1; }
 curl() {
  printf 'curl %s\n' "$*" >> "$log"
  [[ ${AUDIT_DOWNLOAD_FAIL:-0} != 1 ]] || return 22
  local dest=''
  while (( $# )); do case $1 in -o) dest=$2; shift 2;; *) shift;; esac; done
  [[ -n $dest ]] && printf 'mock armored Docker GPG key\n' > "$dest"
 }
 gpg() {
  printf 'gpg %s\n' "$*" >> "$log"
  [[ ${AUDIT_KEY_FAIL:-0} != 1 ]] || return 1
  printf 'pub:-:4096:1:mock:0:0::-:::scSC:\nfpr:::::::::%s:\n' \
   "${AUDIT_FINGERPRINT:-9DC858229FC7DD38854AE2D88D81803C0EBFCD88}"
 }
 docker() {
  printf 'docker %s\n' "$*" >> "$log"
  case $1 in
   version) [[ ${AUDIT_DOCKER_READ_FAIL:-0} != 1 ]] || return 1
            printf '%s\n' "${AUDIT_VERSION:-28.0.0}";;
   ps) return 0;;
   inspect) printf 'true\n';;
   context) case $2 in show) printf 'default\n';; inspect) printf 'unix:///var/run/docker.sock\n';; esac;;
   *) return 0;;
  esac
 }
 swapon() {
  printf 'swapon %s\n' "$*" >> "$log"
  [[ ${AUDIT_SWAP_READ_FAIL:-0} != 1 && ! -e $auditroot/swap-read-fail ]] || return 1
  [[ ! -e $auditroot/swap-active ]] || printf '%s\n' "$TOOLBOX_SWAP_ROOT/swapfile_toolbox"
  return 0
 }
 swapoff() { printf 'swapoff %s\n' "$*" >> "$log"; rm -f "$auditroot/swap-active"; }
}
audit_case() (
 set -e
 audit_setup
 trap 'rc=$?; if (( rc != 0 )); then [[ ! -f $auditroot/out ]] || cat "$auditroot/out" >&2; fi; rm -rf "$auditroot"' EXIT
 case $1 in
  S1)
   AUDIT_TABS=1
   _toolbox_system_netopt_apply <<< $'YES\nYES' > "$auditroot/out" 2>&1
   grep -q '网络参数已应用' "$auditroot/out";;
  S2)
   AUDIT_STDOUT=1
   _toolbox_system_netopt_apply <<< $'YES\nYES' > "$auditroot/out" 2>&1
   if grep -q 'syntax error.*arithmetic' "$auditroot/out"; then
    printf 'S2 stdout used as arithmetic flag\n' >&2; exit 1
   fi
   rm -f "$TOOLBOX_SYSTEM_SYSCTL_DIR/99-terry-toolbox.conf" "$TOOLBOX_SYSTEM_STATE/net-opt.previous"
   sysctl -w net.core.somaxconn=128
   AUDIT_DRIFT_KEY=net.core.somaxconn
   if _toolbox_system_netopt_apply <<< $'YES\nYES' > "$auditroot/out" 2>&1; then
    printf 'S2 false success with stdout/runtime mismatch\n' >&2; exit 1
   fi
   grep -q '回读不一致：net.core.somaxconn' "$auditroot/out"
   ! grep -q '网络参数已应用' "$auditroot/out";;
  S3)
   _toolbox_system_netopt_apply <<< $'YES\nYES' > "$auditroot/out" 2>&1
   before=$(<"$TOOLBOX_SYSTEM_STATE/net-opt.previous")
   sysctl -w net.ipv4.tcp_congestion_control=cubic
   : > "$log"
   if _toolbox_system_netopt_apply </dev/null > "$auditroot/out" 2>&1; then
    printf 'S3 same file/runtime drift false success\n' >&2; exit 1
   fi
   [[ $(sysctl -n net.ipv4.tcp_congestion_control) == cubic ]]
   [[ $(<"$log") != *'sysctl -p'* ]]
   _toolbox_system_netopt_apply <<< $'YES\nYES' > "$auditroot/out" 2>&1
   [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]]
   [[ $(<"$TOOLBOX_SYSTEM_STATE/net-opt.previous") == "$before" ]]
   _toolbox_system_netopt_apply </dev/null > "$auditroot/out" 2>&1
   AUDIT_APPLY_FAIL=1
   sysctl -w net.ipv4.tcp_congestion_control=cubic
   if _toolbox_system_netopt_apply <<< $'YES\nYES' > "$auditroot/out" 2>&1; then exit 1; fi
   [[ $(<"$TOOLBOX_SYSTEM_STATE/net-opt.previous") == "$before" ]]
   [[ -e $TOOLBOX_SYSTEM_SYSCTL_DIR/99-terry-toolbox.conf ]];;
  S4)
   for id in B7 B15; do
    if [[ $id == B7 ]]; then names=("$TOOLBOX_SYSTEM_ETC/traffic.conf" "$TOOLBOX_SYSTEM_BIN_DIR/terry-toolbox-traffic-check" \
      "$TOOLBOX_SYSTEM_UNIT_DIR/terry-toolbox-traffic.service" "$TOOLBOX_SYSTEM_UNIT_DIR/terry-toolbox-traffic.timer")
     input=$'2\nYES\nYES'
    else names=("$TOOLBOX_SYSTEM_ETC/telegram.conf" "$TOOLBOX_SYSTEM_BIN_DIR/terry-toolbox-tg-report" \
      "$TOOLBOX_SYSTEM_UNIT_DIR/terry-toolbox-tg.service" "$TOOLBOX_SYSTEM_UNIT_DIR/terry-toolbox-tg.timer")
     input=$'123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-1001234567890\nYES\nYES'
    fi
    for target in "${names[@]}"; do
     printf 'FOREIGN %s\n' "$target" > "$target"; before=$(<"$target"); : > "$log"
     if toolbox_system "$id" <<< "$input" > "$auditroot/out" 2>&1; then
      printf 'S4 %s foreign file accepted: %s\n' "$id" "$target" >&2; exit 1
     fi
     [[ $(<"$target") == "$before" && ! -s $log ]]
     rm -f "$target"
     ln -s "$auditroot/missing-foreign" "$target"
     if toolbox_system "$id" <<< "$input" > "$auditroot/out" 2>&1; then exit 1; fi
     [[ -L $target ]]; rm -f "$target"
    done
   done;;
  S5)
   f="$TOOLBOX_SWAP_ROOT/swapfile_toolbox"; u="$TOOLBOX_SYSTEM_UNIT_DIR/swapfile_toolbox.swap"
   printf 'swap\n' > "$f"; printf '# terry-toolbox B6 swap unit\nWhat=%s\n' "$f" > "$u"
   printf 'PHASE=file\nPATH=%s\nUNIT=%s\nINODE=%s\n' "$f" "$u" "$(stat -c '%d:%i' "$f")" > "$TOOLBOX_SYSTEM_STATE/swap.txn"
   ino=$(stat -c '%d:%i' "$f"); AUDIT_SWAP_READ_FAIL=1
   rc=0; _toolbox_system_swap_member "$f" || rc=$?
   [[ $rc == 2 ]] || { printf 'S5 unreadable membership not tri-state: rc=%s\n' "$rc" >&2; exit 1; }
   if _toolbox_system_swap_rollback "$f" "$u" "$ino" > "$auditroot/out" 2>&1; then exit 1; fi
   [[ -e $f && -e $u && -e $TOOLBOX_SYSTEM_STATE/swap.txn ]]
   unset AUDIT_SWAP_READ_FAIL
   touch "$auditroot/swap-active"; AUDIT_SWAP_READ_AFTER_STOP=1
   if _toolbox_system_swap_rollback "$f" "$u" "$ino" > "$auditroot/out" 2>&1; then exit 1; fi
   [[ -e $f && -e $u && -e $TOOLBOX_SYSTEM_STATE/swap.txn ]];;
  S6)
   _toolbox_system_docker <<< $'YES\nYES' > "$auditroot/out" 2>&1
   [[ $(<"$log") == *'docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'* ]]
   [[ $(<"$log") != *'install -y docker.io'* ]]
   [[ $(<"$log") == *'docker version --format {{.Server.Version}}'* ]]
   key="$TOOLBOX_DOCKER_APT_ROOT/keyrings/terry-toolbox-docker.asc"
   src="$TOOLBOX_DOCKER_APT_ROOT/sources.list.d/terry-toolbox-docker.sources"
   [[ -f $key && -f $src ]]
   [[ $(<"$src") == *'URIs: https://download.docker.com/linux/debian'* && $(<"$src") == *"Signed-By: $key"* ]]
   # Repository refresh must occur again AFTER publishing the verified key/source.
   [[ $(grep -c 'update$' "$log") == 2 ]]
   [[ $(<"$log") == *'Dir::Etc::sourceparts=-'* && $(<"$log") == *'Dir::State::lists='* ]]
   [[ $(<"$log") == *'download docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'* ]]
   [[ $(<"$log") == *'apt-get install -y --no-upgrade --no-install-recommends /'*'/debs/docker-ce.deb'* ]]
   [[ $(<"$log") == *'apt-get install -y --no-upgrade ca-certificates curl gnupg'* ]]
   for flag in low readfail badkey download update packages; do
    rm -f "$docker_marker" "$key" "$src"; : > "$log"
    unset AUDIT_VERSION AUDIT_DOCKER_READ_FAIL AUDIT_FINGERPRINT AUDIT_DOWNLOAD_FAIL AUDIT_APT_FAIL
    case $flag in low) AUDIT_VERSION=26.1.5;; readfail) AUDIT_DOCKER_READ_FAIL=1;;
     badkey) AUDIT_FINGERPRINT=DEADBEEF;; download) AUDIT_DOWNLOAD_FAIL=1;; update) AUDIT_APT_FAIL=update;; packages) AUDIT_APT_FAIL=download;; esac
    if _toolbox_system_docker <<< $'YES\nYES' > "$auditroot/out" 2>&1; then
     printf 'S6 unsafe success: %s\n' "$flag" >&2; exit 1
    fi
    ! grep -q 'Docker Engine 已安装' "$auditroot/out"
   done
   unset AUDIT_APT_FAIL
   rm -f "$docker_marker" "$key" "$src"
   for flag in candidate policy missing-deb bad-arch unreadable-deb; do
    unset AUDIT_CANDIDATE AUDIT_POLICY_FAIL AUDIT_DEB_MISSING AUDIT_DEB_ARCH AUDIT_DEB_READ_FAIL
    case $flag in candidate) AUDIT_CANDIDATE='5:99.0.0-foreign';; policy) AUDIT_POLICY_FAIL=1;;
     missing-deb) AUDIT_DEB_MISSING=docker-ce;; bad-arch) AUDIT_DEB_ARCH=arm64;; unreadable-deb) AUDIT_DEB_READ_FAIL=1;; esac
    : > "$log"
    if _toolbox_system_docker <<< $'YES\nYES' > "$auditroot/out" 2>&1; then
     printf 'S6 unsafe provenance success: %s\n' "$flag" >&2; exit 1
    fi
    [[ ! -e $docker_marker && $(<"$log") != *'apt-get install -y --no-upgrade --no-install-recommends /'* ]]
    rm -f "$key" "$src"
   done
   unset AUDIT_CANDIDATE AUDIT_POLICY_FAIL AUDIT_DEB_MISSING AUDIT_DEB_ARCH AUDIT_DEB_READ_FAIL
   printf 'FOREIGN\n' > "$src"; : > "$log"
   if _toolbox_system_docker <<< $'YES\nYES' > "$auditroot/out" 2>&1; then exit 1; fi
   [[ $(<"$src") == FOREIGN && ! -s $log ]]
   rm -f "$src"; : > "$log"
   apt-get() {
    printf 'apt-get %s\n' "$*" >> "$log"
    if [[ ${*: -1} == update && -e $src ]]; then return 9; fi
    return 0
   }
   if _toolbox_system_docker <<< $'YES\nYES' > "$auditroot/out" 2>&1; then exit 1; fi
   [[ ! -e $key && ! -e $src && $(<"$log") != *'install -y --no-upgrade docker-ce '* ]]
   # Refuse existing conflicting packages and data; never uninstall as a shortcut.
   AUDIT_INSTALLED=containerd; : > "$log"
   if _toolbox_system_docker <<< $'YES\nYES' > "$auditroot/out" 2>&1; then exit 1; fi
   [[ ! -s $log ]]; unset AUDIT_INSTALLED
   mkdir -p "$TOOLBOX_DOCKER_DATA_ROOT/docker"; : > "$log"
   if _toolbox_system_docker <<< $'YES\nYES' > "$auditroot/out" 2>&1; then exit 1; fi
   [[ ! -s $log ]];;
  DOCKER_STABLE)
   # B1 and apps must agree: prereleases are not stable Engine >=28.
   touch "$docker_marker"
   for version in 28.0.0-rc.1 29.0.0-beta.2 28.0.0-dev 27.9.9 unknown; do
    AUDIT_VERSION=$version
    if _toolbox_system_docker_verify > "$auditroot/out" 2>&1; then
     printf 'B1 falsely accepted unstable/unsupported Engine: %s\n' "$version" >&2; exit 1
    fi
    ! grep -q 'Docker Engine 已安装' "$auditroot/out"
   done
   for version in 28.0.0 29.1.2+vendor.1; do
    AUDIT_VERSION=$version
    _toolbox_system_docker_verify > "$auditroot/out" 2>&1
    grep -q 'Docker Engine 已安装' "$auditroot/out"
   done;;
  S7)
   AUDIT_INSTALLED='curl nano'
   _toolbox_system_deps <<< $'YES\nYES' > "$auditroot/out" 2>&1
   [[ $(<"$log") == $'apt-get update\napt-get install -y --no-upgrade socat wget sudo iptables' ]] \
    || { printf 'S7 missing-only/update mismatch: %s\n' "$(<"$log")" >&2; exit 1; }
   : > "$log"; AUDIT_APT_FAIL=update
   if _toolbox_system_deps <<< $'YES\nYES' > "$auditroot/out" 2>&1; then exit 1; fi
   [[ $(<"$log") == 'apt-get update' ]]
   unset AUDIT_APT_FAIL; : > "$log"; AUDIT_INSTALLED='curl socat wget sudo nano iptables'
   _toolbox_system_deps </dev/null > "$auditroot/out" 2>&1
   [[ ! -s $log ]]
   # Test the real status parser rather than substituting the entire implementation.
   eval "$package_status_impl"
   dpkg-query() { printf '%s' "${AUDIT_PACKAGE_STATUS:-install ok installed}"; return "${AUDIT_PACKAGE_RC:-0}"; }
   _toolbox_system_package_installed curl
   AUDIT_PACKAGE_STATUS='deinstall ok config-files'; rc=0
   _toolbox_system_package_installed curl || rc=$?; [[ $rc == 1 ]]
   AUDIT_PACKAGE_RC=2; rc=0
   _toolbox_system_package_installed curl || rc=$?; [[ $rc == 2 ]]
   if _toolbox_system_deps <<< $'YES\nYES' > "$auditroot/out" 2>&1; then exit 1; fi
   [[ ! -s $log ]];;
  SYSCTL_ROLLBACK)
   _toolbox_system_netopt_apply <<< $'YES\nYES' > "$auditroot/out" 2>&1
   state="$TOOLBOX_SYSTEM_STATE/net-opt.previous"; file="$TOOLBOX_SYSTEM_SYSCTL_DIR/99-terry-toolbox.conf"
   # A successful sysctl -w can still leave a different running value.
   AUDIT_WRITE_IGNORE=net.ipv4.tcp_congestion_control
   if _toolbox_system_netopt_rollback <<< $'YES\nYES' > "$auditroot/out" 2>&1; then
    printf 'rollback falsely succeeded without readback\n' >&2; exit 1
   fi
   [[ -f $state ]]; unset AUDIT_WRITE_IGNORE
   _toolbox_system_netopt_rollback <<< $'YES\nYES' > "$auditroot/out" 2>&1
   [[ ! -e $state ]]
   printf 'FOREIGN\nnet.core.somaxconn=1\n' > "$state"; : > "$log"
   if _toolbox_system_netopt_rollback <<< $'YES\nYES' > "$auditroot/out" 2>&1; then exit 1; fi
   [[ -f $state && ! -s $log ]]
   rm -f "$state"; ln -s "$auditvals" "$state"
   if _toolbox_system_netopt_rollback <<< $'YES\nYES' > "$auditroot/out" 2>&1; then exit 1; fi
   [[ -L $state && ! -s $log ]]
   rm -f "$state"
   _toolbox_system_netopt_apply <<< $'YES\nYES' > "$auditroot/out" 2>&1
   # Foreign replacement during confirmation must not be overwritten/deleted.
   _toolbox_system_confirm() { printf 'FOREIGN\n' > "$file"; return 0; }
   : > "$log"
   if _toolbox_system_netopt_rollback > "$auditroot/out" 2>&1; then exit 1; fi
   [[ $(<"$file") == FOREIGN && ! -s $log ]];;
  S4_TXN)
   for id in B7 B15; do
    if [[ $id == B7 ]]; then
     timer=$_TOOLBOX_TRAFFIC_TIMER; service=$_TOOLBOX_TRAFFIC_SERVICE; marker=$_TOOLBOX_SYS_MARK_B7
     names=("$TOOLBOX_SYSTEM_ETC/traffic.conf" "$TOOLBOX_SYSTEM_BIN_DIR/$_TOOLBOX_TRAFFIC_CHECK" "$TOOLBOX_SYSTEM_UNIT_DIR/$service" "$TOOLBOX_SYSTEM_UNIT_DIR/$timer")
    else
     timer=$_TOOLBOX_TG_TIMER; service=$_TOOLBOX_TG_SERVICE; marker=$_TOOLBOX_SYS_MARK_B15
     names=("$TOOLBOX_SYSTEM_ETC/telegram.conf" "$TOOLBOX_SYSTEM_BIN_DIR/$_TOOLBOX_TG_REPORT" "$TOOLBOX_SYSTEM_UNIT_DIR/$service" "$TOOLBOX_SYSTEM_UNIT_DIR/$timer")
    fi
    # Exercise the real shared transaction directly, including all four backups.
    txn_dir=''; txn_marker=$marker; txn_timer=$timer; txn_service=$service; txn_active=0; txn_enabled=0
    txn_paths=("${names[@]}"); txn_before=(); txn_hash=(); txn_written=(); txn_written_hash=()
    for target in "${names[@]}"; do printf '%s\nOLD %s\n' "$marker" "$target" > "$target"; done
    touch "$auditroot/active-$timer" "$auditroot/enabled-$timer" "$auditroot/active-$service"
    _toolbox_system_timer_begin
    for i in 0 1 2 3; do printf '%s\nNEW\n' "$marker" > "$txn_dir/new.$i"; done
    _toolbox_system_timer_commit
    AUDIT_SERVICE_STOP_FAIL=1
    if _toolbox_system_timer_cleanup > "$auditroot/out" 2>&1; then
     printf 'S4 cleanup deleted files while service stop failed\n' >&2; exit 1
    fi
    for target in "${names[@]}"; do [[ $(<"$target") == *NEW* ]]; done
    [[ -d $txn_dir ]]; unset AUDIT_SERVICE_STOP_FAIL
    # Even an in-place edit to the last target must block ALL earlier deletes.
    printf '%s\nFOREIGN EDIT\n' "$marker" > "${names[3]}"
    if _toolbox_system_timer_cleanup > "$auditroot/out" 2>&1; then exit 1; fi
    [[ $(<"${names[0]}") == *NEW* && $(<"${names[3]}") == *'FOREIGN EDIT'* && -d $txn_dir ]]
    rm -rf "$txn_dir"; rm -f "${names[@]}"
    AUDIT_FOREIGN_UNIT="$service"; : > "$log"
    if _toolbox_system_timer_preflight "$marker" "${names[@]}" > "$auditroot/out" 2>&1; then
     printf 'S4 foreign loaded service accepted\n' >&2; exit 1
    fi
    unset AUDIT_FOREIGN_UNIT
    # Successful rollback restores ALL old artifacts, permissions and timer state.
    txn_dir=''; txn_active=0; txn_enabled=0; txn_before=(); txn_hash=(); txn_written=(); txn_written_hash=()
    for target in "${names[@]}"; do printf '%s\nOLD %s\n' "$marker" "$target" > "$target"; done
    chmod 0600 "${names[0]}"; chmod 0755 "${names[1]}"
    touch "$auditroot/active-$timer" "$auditroot/enabled-$timer"
    _toolbox_system_timer_begin
    for i in 0 1 2 3; do printf '%s\nNEW\n' "$marker" > "$txn_dir/new.$i"; done
    _toolbox_system_timer_commit; _toolbox_system_timer_cleanup
    for target in "${names[@]}"; do [[ $(<"$target") == *'OLD '* ]]; done
    [[ $(stat -c %a "${names[0]}") == 600 && $(stat -c %a "${names[1]}") == 755 ]]
    [[ ! -e $txn_dir && -e $auditroot/active-$timer ]]; rm -f "${names[@]}"
    # Unknown prior state cannot be silently recorded as inactive/disabled.
    txn_dir=''; txn_before=(); txn_hash=(); txn_written=(); txn_written_hash=()
    AUDIT_STATE_READ_FAIL=1
    if _toolbox_system_timer_begin > "$auditroot/out" 2>&1; then
     printf 'S4 unreadable prior timer state accepted\n' >&2; exit 1
    fi
    unset AUDIT_STATE_READ_FAIL
    _toolbox_system_timer_cleanup
   done;;
  S5_OWNERSHIP)
   f="$TOOLBOX_SWAP_ROOT/swapfile_toolbox"; u="$TOOLBOX_SYSTEM_UNIT_DIR/swapfile_toolbox.swap"
   j="$TOOLBOX_SYSTEM_STATE/swap.txn"
   printf 'swap\n' > "$f"; printf 'FOREIGN\n' > "$u"
   ino=$(stat -c '%d:%i' "$f")
   printf 'PHASE=file\nPATH=%s\nUNIT=%s\nINODE=%s\n' "$f" "$u" "$ino" > "$j"
   touch "$auditroot/swap-active"; : > "$log"
   if _toolbox_system_swap_rollback "$f" "$u" "$ino" > "$auditroot/out" 2>&1; then
    printf 'S5 rollback deleted foreign unit\n' >&2; exit 1
   fi
   [[ $(<"$u") == FOREIGN && -e $f && -e $j && -e $auditroot/swap-active ]]
   [[ $(<"$log") != *'systemctl disable'* && $(<"$log") != *swapoff* ]]
   # A journal cannot authorize deletion outside the configured swap paths.
   printf 'FOREIGN\n' > "$auditroot/victim"
   printf 'PHASE=file\nPATH=%s\nUNIT=%s\nINODE=%s\n' "$auditroot/victim" "$u" "$(stat -c '%d:%i' "$auditroot/victim")" > "$j"
   if _toolbox_system_swap_recover > "$auditroot/out" 2>&1; then exit 1; fi
   [[ -e $auditroot/victim && -e $j ]];;
  CONDITIONAL)
   # Match parent menu: function || handler disables errexit even inside (set -e).
   run_service_action() { ( set -e; "$@" ); }
   for writer in _toolbox_system_write_traffic_check _toolbox_system_write_tg_report; do
    failed=0
    (
     # Real partial write then I/O failure: chmod can succeed, but writer must fail.
     cat() { command cat "$@"; return 1; }
     run_service_action "$writer" "$auditroot/partial" > "$auditroot/out" 2>&1
    ) || failed=1
    [[ $failed == 1 ]] || { printf 'conditional writer swallowed I/O failure: %s\n' "$writer" >&2; exit 1; }
   done
   AUDIT_APT_FAIL=update; failed=0
   run_service_action _toolbox_system_deps <<< $'YES\nYES' > "$auditroot/out" 2>&1 || failed=1
   [[ $failed == 1 && $(<"$log") == 'apt-get update' ]]
   unset AUDIT_APT_FAIL; AUDIT_STDOUT=1; AUDIT_DRIFT_KEY=net.core.somaxconn; failed=0
   run_service_action _toolbox_system_netopt_apply <<< $'YES\nYES' > "$auditroot/out" 2>&1 || failed=1
   [[ $failed == 1 && -e $TOOLBOX_SYSTEM_STATE/net-opt.previous ]]
   unset AUDIT_DRIFT_KEY
   (
    _toolbox_system_put() { command cat >/dev/null; return 1; }
    failed=0
    run_service_action _toolbox_system_netopt_apply <<< $'YES\nYES' > "$auditroot/out" 2>&1 || failed=1
    [[ $failed == 1 ]] || exit 1
   )
   : > "$log"; AUDIT_APT_FAIL=update; failed=0
   run_service_action _toolbox_system_docker <<< $'YES\nYES' > "$auditroot/out" 2>&1 || failed=1
   [[ $failed == 1 && $(<"$log") == 'apt-get update' ]];;
  WEBTOP)
   touch "$docker_marker"; TEST_OS=alpine
   _toolbox_system_alpine_webtop <<< $'YES\nYES' > "$auditroot/out" 2>&1
   [[ -d $TOOLBOX_WEBTOP_ROOT && $(<"$log") == *"-v $TOOLBOX_WEBTOP_ROOT:/config"* ]];;
  *) printf 'unknown audit case: %s\n' "$1" >&2; exit 2;;
 esac
 printf 'audit %s passed\n' "$1"
)
if [[ -n ${SYSTEM_AUDIT_CASE:-} ]]; then
 if [[ $SYSTEM_AUDIT_CASE == ALL ]]; then
  for audit in S1 S2 S3 S4 S5 S6 S7 DOCKER_STABLE SYSCTL_ROLLBACK S4_TXN S5_OWNERSHIP CONDITIONAL WEBTOP; do audit_case "$audit"; done
 else audit_case "$SYSTEM_AUDIT_CASE"; fi
 exit 0
fi

for audit in S1 S2 S3 S4 S5 S6 S7 DOCKER_STABLE SYSCTL_ROLLBACK S4_TXN S5_OWNERSHIP CONDITIONAL WEBTOP; do audit_case "$audit"; done
: > "$log"; rm -f "$docker_marker"
# Cancellation and EOF are fail-closed.
if toolbox_system MAIN_DEPS </dev/null >/dev/null 2>&1; then exit 1; fi
[ ! -s "$log" ]
printf 'YES\nYES\n' | toolbox_system MAIN_DEPS >/dev/null
[ "$(<"$log")" = $'apt-get update\napt-get install -y --no-upgrade curl socat wget sudo nano iptables' ]
: > "$log"
printf 'YES\nNO\n' | toolbox_system MAIN_REBOOT >/dev/null 2>&1 && exit 1
[ ! -s "$log" ]
printf 'YES\nYES\n' | toolbox_system MAIN_REBOOT >/dev/null
[ "$(<"$log")" = reboot ]
: > "$log"
# A pending/unknown M3 plan must gate the reboot; no reinstall module keeps the old path.
toolbox_reinstall() { case $1 in status) printf 'M3 phase=prepared target=debian 13 disk=/dev/vda commit=abc\n';; esac; }
printf 'YES\nYES\n' | toolbox_system MAIN_REBOOT >/dev/null 2>&1 && exit 1
[ ! -s "$log" ]
printf 'YES\nYES\n/dev/vda\n' | toolbox_system MAIN_REBOOT >/dev/null
[ "$(<"$log")" = reboot ]
: > "$log"
toolbox_reinstall() { printf 'blocking: unknown plan\n'; return 1; }
printf 'YES\nYES\nREBOOT\n' | toolbox_system MAIN_REBOOT >/dev/null 2>&1 && exit 1
[ ! -s "$log" ]
: > "$log"
unset -f toolbox_reinstall
printf 'YES\nYES\n' | toolbox_system B8 >/dev/null
[ "$(<"$log")" = 'passwd root' ]
: > "$log"
printf 'YES\nYES\n' | toolbox_system MAIN_BBR >/dev/null
[ "$(<"$log")" = 'sysctl -w net.ipv4.tcp_congestion_control=bbr' ]
: > "$log"
# Installation/version/official repository are covered by the audit slices below.
MOCK_DOCKER_INSTALLED=1
if printf 'YES\nYES\n' | toolbox_system B1 >/dev/null 2>&1; then exit 1; fi
[ ! -s "$log" ]
touch "$docker_marker"
unset MOCK_DOCKER_INSTALLED
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
# EOF 取消：只打印预览（固定提交与摘要前缀来自代码里的常量），未下载未执行。
[[ $out == *'a92fca6c0067df29ddd03fdc2fee6f3000f64545'* && $out == *'4e1b25894cad'* && $out == *'不匹配即中止'* ]]
if printf 'YES\nYES\n' | toolbox_system 2 >/dev/null 2>&1; then exit 1; fi
# 数字编号等价；此时 MOCK_DOWNLOAD 尚未设置，curl 桩失败即止，但已用真实固定地址请求。
[[ $(<"$log") == *'raw.githubusercontent.com/LloydAsp/NodeQuality/a92fca6c0067df29ddd03fdc2fee6f3000f64545/NodeQuality.sh'* ]]
: > "$log"
TEST_OS=alpine; export TEST_OS
printf 'YES\nYES\n' | toolbox_system MAIN_DEPS >/dev/null
# This fixture reports all Alpine dependency commands present (including ss).
[ ! -s "$log" ]
unset TEST_OS
: > "$log"
if printf 'YES\nYES\n' | MOCK_FAIL=1 toolbox_system MAIN_DEPS >/dev/null 2>&1; then exit 1; fi
: > "$log"
for id in MAIN_REINSTALL B2 B4 B5 B10 B99; do
 if toolbox_system "$id" </dev/null >/dev/null 2>&1; then printf 'unexpected success: %s\n' "$id" >&2; exit 1; fi
done
[ ! -s "$log" ]
# ---------------------------------------------------------------- B6 swap 事务
# 全部隔离：swap 根目录、状态目录、单元目录都在临时目录里，swapon / systemctl /
# findmnt / df / dd 都是 shell 桩，不碰真实 swap、systemd 或磁盘。
# 每个用例先在锁内预检、确认、锁内重新校验，再落盘；失败路径必须自动回滚。
swap_root=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-swap-test.XXXXXX")
swap_state=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-swap-state.XXXXXX")
swap_units="$swap_root/etc/systemd/system"
swap_unit="$swap_units/swapfile_toolbox.swap"
swap_file="$swap_root/swapfile_toolbox"
export TOOLBOX_SYSTEM_STATE="$swap_state" TOOLBOX_SYSTEM_UNIT_DIR="$swap_units"
export TOOLBOX_SYSTEMD_RUN="$swap_root/run/systemd/system"
export TOOLBOX_SWAP_ROOT="$swap_root" TOOLBOX_SWAP_SIZE_MB=256
trap 'rm -f "$log" "$docker_marker"; rm -rf "$swap_root" "$swap_state"; rm -rf "$safetyroot"' EXIT

# 只读边界桩。MOCK_* 只在子 shell 内生效，不泄漏到后面的用例。
findmnt() { printf '%s\n' "${MOCK_FSTYPE:-ext4}"; }
df() {
 if [[ ${MOCK_DF_FAIL:-0} == 1 ]]; then return 1; fi
 printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n'
 printf 'test 9000000 0 %s 0 /\n' "${MOCK_AVAIL_KB:-9000000}"
}
dd() {
 printf 'dd\n' >> "$log"
 local count=0 a
 for a in "$@"; do case $a in count=*) count=${a#count=};; esac; done
 case ${MOCK_DD:-ok} in
  fail) return 1;;
  race) rm -f "$swap_file"; ln -s "$swap_root/victim" "$swap_file"; truncate -s "$((count * 1048576))" "$swap_file"; return 0;;
 esac
 : > "$swap_file"
 truncate -s "$((count * 1048576))" "$swap_file"
 [[ ${MOCK_DD:-ok} != term ]] || kill -TERM "$BASHPID"
 return 0
}
mkswap() { printf 'mkswap\n' >> "$log"; [[ ${MOCK_MKSWAP:-ok} != fail ]]; }
swapon() {
 printf 'swapon %s\n' "$*" >> "$log"
 case ${1-} in
  --show=NAME)
   [[ ${MOCK_SWAP_FAIL:-0} != 1 ]] || return 1
   [[ ! -e $swap_root/other-active ]] || printf '/other-swap\n'
   [[ ! -e $swap_root/active ]] || printf '%s\n' "$swap_file"
   return 0;;
 esac
 : > "$swap_root/active"
 [[ ${MOCK_SWAPON_FAIL:-0} != 1 ]]
}
swapoff() {
 printf 'swapoff %s\n' "$*" >> "$log"
 [[ ${MOCK_SWAPOFF_STUCK:-0} != 1 ]] || return 1
 rm -f "$swap_root/active"
}
systemctl() {
 printf 'systemctl %s\n' "$*" >> "$log"
 local unit=${*: -1}
 case $* in
  'show -p FragmentPath'*) [[ ! -e $swap_root/fragment ]] || printf '%s\n' "$(<"$swap_root/fragment")";;
  'show -p DropInPaths'*) [[ ! -e $swap_root/dropinpaths ]] || printf '%s\n' "$(<"$swap_root/dropinpaths")";;
  'show -p LoadState'*) [[ -e $swap_unit ]] && printf 'loaded\n' || printf 'not-found\n';;
  'show -p ActiveState'*)
   # systemd stop can be quiet while the kernel still holds swap (swapoff-stuck test).
   [[ -e $swap_state/unit-$unit ]] && printf 'active\n' || printf 'inactive\n';;
  'show -p Job'*) printf '0\n';;
  'daemon-reload') [[ ${MOCK_RELOAD_FAIL:-0} != 1 ]];;
  'enable --now '*)
   [[ ${MOCK_ENABLE_FAIL:-0} != 1 ]] || return 1
   : > "$swap_root/active"
   [[ ${MOCK_NO_ACTIVE:-0} != 1 ]] && : > "$swap_state/unit-$unit"
   return 0;;
  'disable --now '*)
   rm -f "$swap_state/unit-$unit"
   [[ ${MOCK_SWAPOFF_STUCK:-0} == 1 ]] || rm -f "$swap_root/active";;
  'is-active --quiet '*) [[ ${MOCK_ACTIVE_FAIL:-0} != 1 && -e $swap_state/unit-$unit ]];;
 esac
}
b6_reset() {
 rm -rf "$swap_root" "$swap_state"
 mkdir -p "$swap_units" "$swap_root/etc" "$TOOLBOX_SYSTEMD_RUN" "$swap_state"
 : > "$swap_root/etc/fstab"
 printf 'preserve\n' > "$swap_root/victim"
 out="$swap_root/output"; : > "$out"; : > "$log"
 unset MOCK_FSTYPE MOCK_AVAIL_KB MOCK_DF_FAIL MOCK_DD MOCK_MKSWAP MOCK_SWAP_FAIL \
  MOCK_SWAPON_FAIL MOCK_SWAPOFF_STUCK MOCK_RELOAD_FAIL MOCK_ENABLE_FAIL MOCK_NO_ACTIVE MOCK_ACTIVE_FAIL
}
b6() {
 local id=${2:-B6}
 # 子 shell 里先丢掉外层测试的 EXIT 清理，否则每次调用结束都会把夹具删掉。
 ( trap - EXIT; toolbox_system "$id" <<< "$1" > "$out" 2>&1 )
}
# 依赖顺序：后面的关键字必须在日志里出现在前面关键字之后。
b6_order() {
 local pos=0 tok line idx found
 for tok in "$@"; do
  idx=0; found=0
  while IFS= read -r line; do
   idx=$((idx + 1))
   (( idx > pos )) || continue
   case $line in *"$tok"*) pos=$idx; found=1; break;; esac
  done < "$log"
  (( found == 1 )) || { printf 'B6 顺序不对，缺少：%s\n' "$tok" >&2; return 1; }
 done
}
b6_no_write() { # $1=unit：只允许拒绝前就已存在的单元继续存在
 ! grep -qx 'dd' "$log" || { printf 'B6 在拒绝前已创建文件\n' >&2; return 1; }
 [[ ! -e $swap_state/swap.txn ]] || { printf 'B6 留下事务日志\n' >&2; return 1; }
 [[ ${1-} == unit || ! -e $swap_unit ]] || { printf 'B6 留下了单元文件\n' >&2; return 1; }
}
b6_refuse() { # $1=说明 $2=期望信息 $3=前置状态
 b6_reset
 eval "$3"
 pre_unit=0; [[ -e $swap_unit ]] && pre_unit=unit
 if b6 $'YES\nYES'; then printf 'B6: %s 未拒绝\n' "$1" >&2; exit 1; fi
 b6_no_write "$pre_unit"
 [[ $(<"$out") == *"$2"* ]] || { printf 'B6: %s 提示不对\n' "$1" >&2; cat "$out" >&2; exit 1; }
 _toolbox_system_root() { return 0; } # 前置状态可能替换过，用例结束后恢复
}

# 正常创建：外来 swap 并存也应成功；顺序、单元内容、权限、日志清理都要对。
b6_reset
: > "$swap_root/other-active"
b6 $'YES\nYES' || { printf 'B6 正常路径失败\n' >&2; cat "$out" >&2; exit 1; }
[[ -f $swap_file && ! -L $swap_file ]]
[[ $(stat -c '%a' -- "$swap_file") == 600 ]]
[[ $(<"$swap_unit") == *"What=$swap_file"* ]]
[[ $(head -n 1 "$swap_unit") == '# terry-toolbox B6 swap unit' ]]
[[ $(stat -c '%a' -- "$swap_unit") == 644 ]]
[[ -e $swap_state/unit-swapfile_toolbox.swap ]]
[[ -e $swap_state/swap.lock && ! -e $swap_state/swap.txn ]]
[[ ! -s $swap_root/etc/fstab ]]
b6_order dd mkswap 'enable --now' 'is-active --quiet' 'swapon --show=NAME'
[[ $(<"$out") == *'swap 已启用'* ]]
# Conditional parent context still fails closed on dd/enable/verification failures.
for failure in dd enable verify; do
 b6_reset
 case $failure in dd) MOCK_DD=fail;; enable) MOCK_ENABLE_FAIL=1;; verify) MOCK_ACTIVE_FAIL=1;; esac
 failed=0
 ( set -e; b6 $'YES\nYES' ) || failed=1
 [[ $failed == 1 && ! -e $swap_file && ! -e $swap_unit && ! -e $swap_state/swap.txn ]]
done
b6_reset
b6 $'YES\nYES'
# 已启用后再跑：幂等，不重写文件与单元。
unit_before=$(<"$swap_unit")
: > "$log"
b6 $'YES\nYES' || { printf 'B6 幂等路径失败\n' >&2; cat "$out" >&2; exit 1; }
[[ $(<"$out") == *'未修改任何配置'* ]]
! grep -qx 'dd' "$log"
! grep -qx 'mkswap' "$log"
[[ $(<"$swap_unit") == "$unit_before" ]]
# 单元在、文件在、但当前未启用：走恢复启用，不重建文件。
b6_reset
: > "$swap_file"
printf '# terry-toolbox B6 swap unit\n[Swap]\nWhat=%s\n' "$swap_file" > "$swap_unit"
b6 $'YES\nYES' || { printf 'B6 残留恢复失败\n' >&2; cat "$out" >&2; exit 1; }
! grep -qx 'dd' "$log"
! grep -qx 'mkswap' "$log"
[[ -e $swap_root/active && -e $swap_state/unit-swapfile_toolbox.swap ]]
[[ ! -e $swap_state/swap.txn ]]
# 成功路径要把调用者原有的 trap 原样恢复，不能静默丢掉。
b6_reset
if ( trap - EXIT; trap ':' INT TERM EXIT
     before=$(trap -p INT TERM EXIT)
     toolbox_system B6 <<< $'YES\nYES' > "$out" 2>&1 || exit 1
     [[ $(trap -p INT TERM EXIT) == "$before" ]] || exit 1
   ); then :; else printf 'B6 未恢复原有 trap\n' >&2; exit 1; fi
# 进程在 dd 期间收到 SIGTERM：回滚文件、单元、日志，退出码非 0。
b6_reset
MOCK_DD=term
b6 $'YES\nYES' && { printf 'B6 中断后仍报成功\n' >&2; exit 1; }
[[ $(<"$out") == *'回滚'* ]]
[[ ! -e $swap_file && ! -e $swap_unit && ! -e $swap_state/swap.txn ]]
[[ ! -e $swap_root/active ]]
MOCK_DD=ok
# swapoff 不成功：单元必须留着，事务日志也留着，供下次重试。
b6_reset
MOCK_ACTIVE_FAIL=1 MOCK_SWAPOFF_STUCK=1
b6 $'YES\nYES' && { printf 'B6 验证失败未回滚\n' >&2; exit 1; }
[[ $(<"$out") == *'单元保留'* ]]
[[ -e $swap_unit && -e $swap_state/swap.txn && -e $swap_file ]]
[[ -e $swap_root/active ]]
grep -q '^swapoff ' "$log" || { printf 'B6 未尝试 swapoff\n' >&2; exit 1; }
# 路径在 dd 期间被换成符号链接：归属未知，留链接与事务供人工处理。
b6_reset
MOCK_DD=race
b6 $'YES\nYES' && { printf 'B6 路径替换未拒绝\n' >&2; exit 1; }
[[ $(<"$out") == *'不是普通文件'* ]]
[[ -e $swap_root/victim && -L $swap_file && -e $swap_state/swap.txn ]]
! grep -qx 'mkswap' "$log"
MOCK_DD=ok
# 上个进程被 SIGKILL 留下的日志：下次先按日志回滚残留，再重新预检。
b6_reset
: > "$swap_file"
printf '# terry-toolbox B6 swap unit\n[Swap]\nWhat=%s\n' "$swap_file" > "$swap_unit"
printf 'PHASE=file\nPATH=%s\nUNIT=%s\nINODE=%s\n' "$swap_file" "$swap_unit" \
 "$(stat -c '%d:%i' -- "$swap_file")" > "$swap_state/swap.txn"
b6 $'NO\nNO' && { printf 'B6 取消却报成功\n' >&2; exit 1; }
[[ $(<"$out") == *'上次未完成'* ]]
[[ ! -e $swap_file && ! -e $swap_unit && ! -e $swap_state/swap.txn ]]
! grep -qx 'dd' "$log"
# 各项拒绝都必须发生在写入之前。
b6_refuse '同名文件且未启用' '无法断言归属' ': > "$swap_file"'
b6_refuse '同名文件是活动 swap' '没有本工具的单元' ': > "$swap_file"; : > "$swap_root/active"'
b6_refuse '文件是符号链接' '符号链接' 'ln -s "$swap_root/victim" "$swap_file"'
b6_refuse '单元是别人的' '不是本工具生成的' 'printf "[Swap]\nWhat=/x\n" > "$swap_unit"'
b6_refuse '单元在但文件缺失' '文件缺失' \
 'printf "# terry-toolbox B6 swap unit\n[Swap]\nWhat=$swap_file\n" > "$swap_unit"'
b6_refuse '单元 What 不符' 'What= 不是' \
 ': > "$swap_file"; printf "# terry-toolbox B6 swap unit\n[Swap]\nWhat=/elsewhere\n" > "$swap_unit"'
b6_refuse '已加载单元来自别处' '同名单元来自' 'printf "/usr/lib/systemd/system/x\n" > "$swap_root/fragment"'
b6_refuse '生效 drop-in' 'drop-in' 'printf "/run/x.conf\n" > "$swap_root/dropinpaths"'
b6_refuse '单元目录里有 drop-in' 'drop-in' \
 'mkdir -p "$swap_unit.d"; printf "[Swap]\nWhat=/x\n" > "$swap_unit.d/override.conf"'
b6_refuse '文件系统不支持' '未验证' 'MOCK_FSTYPE=overlay'
b6_refuse '空间不足' '可用空间不足' 'MOCK_AVAIL_KB=1024'
b6_refuse 'swapon 读不出来' 'swapon 读取失败' 'MOCK_SWAP_FAIL=1'
b6_refuse '非 root' '需要 root' '_toolbox_system_root() { _toolbox_system_error "此操作需要 root。"; return 1; }'
# 确认为 NO：什么都不写，锁要放开（进程结束后锁自然释放）。
b6_reset
b6 $'YES\nNO' && { printf 'B6 取消却报成功\n' >&2; exit 1; }
b6_no_write
# 并发：别的进程持锁时直接拒绝，不做任何探测后的写入。
b6_reset
exec 8> "$swap_state/swap.lock"
flock -n 8
b6 $'YES\nYES' && { printf 'B6 锁被占用仍继续\n' >&2; exit 1; }
[[ $(<"$out") == *'锁被占用'* ]]
b6_no_write
flock -u 8
exec 8>&-
# 确认期间状态被改变：锁内复检发现判定变化，写入前中止。
b6_reset
if ( trap - EXIT
     _toolbox_system_confirm() { : > "$swap_file"; return 0; }
     toolbox_system B6 </dev/null > "$out" 2>&1 ); then
 printf 'B6 确认期间变化未拦截\n' >&2; exit 1; fi
[[ $(<"$out") == *'状态已变化'* ]]
! grep -qx 'dd' "$log"
[[ ! -e $swap_state/swap.txn && ! -e $swap_unit ]]
# 裸编号别名等价。
b6_reset
b6 $'YES\nYES' 6 || { printf 'B6 数字别名失败\n' >&2; exit 1; }
[[ -e $swap_file && -e $swap_unit ]]


# ---------------------------------------------------------------- 新增系统工具
# 全部使用隔离目录与命令桩：不读写真实 /etc、/var/lib、systemd 单元。
mockroot=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-sys-test.XXXXXX")
trap 'rm -f "$log" "$docker_marker"; rm -rf "$swap_root" "$swap_state" "$mockroot"; rm -rf "$safetyroot"' EXIT
export TOOLBOX_SYSTEM_ETC="$mockroot/etc/terry-toolbox"
export TOOLBOX_SYSTEM_STATE="$mockroot/var/lib/terry-toolbox"
export TOOLBOX_SYSTEM_UNIT_DIR="$mockroot/etc/systemd/system"
export TOOLBOX_SYSTEM_BIN_DIR="$mockroot/usr/local/bin"
export TOOLBOX_SYSTEM_SYSCTL_DIR="$mockroot/etc/sysctl.d"
export TOOLBOX_SYSTEMD_RUN="$mockroot/run/systemd/system"
export MOCK_ROOT="$mockroot"
export TOOLBOX_WEBTOP_ROOT="$mockroot/webtop"
# 这两个开关要传给安装出来的脚本子进程，必须导出。
export MOCK_TG_FAIL=0 MOCK_VNSTAT_NEVER=0
mkdir -p "$TOOLBOX_SYSTEM_ETC" "$TOOLBOX_SYSTEM_STATE" "$TOOLBOX_SYSTEM_UNIT_DIR" \
 "$TOOLBOX_SYSTEM_BIN_DIR" "$TOOLBOX_SYSTEM_SYSCTL_DIR" "$TOOLBOX_SYSTEMD_RUN" \
 "$mockroot/bin" "$mockroot/docker-containers"
stub=$mockroot/bin
stublog=$mockroot/child.log
export STUBLOG="$stublog"
export PATH="$stub:$PATH"
: > "$stublog"
# 子进程（安装出来的脚本）无法继承 shell 函数，因此走 PATH 桩。
cat > "$stub/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUBLOG"
[[ ${MOCK_TG_FAIL:-0} != 1 ]] || exit 22
# 与真实 curl 一样，响应体进 -o 指定的文件；这里不必实现，只解析出来。
out=/dev/stdout
while (( $# )); do case $1 in -o) out=$2; shift 2;; *) shift;; esac; done
body='{"ok":true}'
[[ ${MOCK_TG_API_FAIL:-0} != 1 ]] || body='{"ok":false}'
case $out in /dev/null) ;; /dev/stdout) printf '%s\n' "$body";; *) printf '%s\n' "$body" > "$out";; esac
exit 0
STUB
cat > "$stub/vnstat" <<'STUB'
#!/usr/bin/env bash
printf 'vnstat %s\n' "$*" >> "$STUBLOG"
[[ ${MOCK_VNSTAT_NEVER:-0} != 1 ]] || exit 0
[[ -e $MOCK_ROOT/vnstat-ready ]] || exit 0
cat "$MOCK_VNSTAT_JSON"
STUB
cat > "$stub/logger" <<'STUB'
#!/usr/bin/env bash
printf 'logger %s\n' "$*" >> "$STUBLOG"
STUB
cat > "$stub/hostname" <<'STUB'
#!/usr/bin/env bash
printf 'testhost\n'
STUB
chmod 0755 "$stub/curl" "$stub/vnstat" "$stub/logger" "$stub/hostname"
ln -s "$(command -v jq)" "$stub/jq"
export MOCK_VNSTAT_JSON="$mockroot/vnstat.json"
now_y=$(date +%Y); now_m=$((10#$(date +%m))); now_d=$((10#$(date +%d)))
cat > "$MOCK_VNSTAT_JSON" <<JSON
{"vnstatversion":"2.12","jsonversion":"2","interfaces":[
{"name":"lo","traffic":{"month":[{"date":{"year":$now_y,"month":$now_m},"rx":999999999,"tx":0}]}},
{"name":"eth0","traffic":{
 "day":[{"date":{"year":$now_y,"month":$now_m,"day":$now_d},"rx":536870912,"tx":536870912}],
 "month":[{"date":{"year":$now_y,"month":$now_m},"rx":2147483648,"tx":1073741824}]}}]}
JSON
# 3 GiB 本月（lo 不计入）；2 GiB 阈值应触发告警。
tgconf="$TOOLBOX_SYSTEM_ETC/telegram.conf"
systemctl() {
 printf 'systemctl %s\n' "$*" >> "$log"
 local unit=${*: -1}
 case $* in
  'enable --now '*) touch "$mockroot/active-$unit"; return 0;;
  'disable --now '*) rm -f "$mockroot/active-$unit"; return 0;;
  'stop '*) rm -f "$mockroot/active-$unit"; return 0;;
  'show -p ActiveState'*) if [[ -e $mockroot/active-$unit ]]; then printf 'active\n'; else printf 'inactive\n'; fi;;
  'show -p UnitFileState'*) if [[ -e $mockroot/active-$unit ]]; then printf 'enabled\n'; else printf 'disabled\n'; fi;;
  'is-active --quiet '*) [[ -e $mockroot/active-$unit ]];;
  *) return 0;;
 esac
}

# --- B7 流量统计：前置条件全部在写盘前失败
: > "$log"
mv "$TOOLBOX_SYSTEMD_RUN" "$mockroot/run/no-systemd"
if printf '2\n' | toolbox_system B7 >/dev/null 2>&1; then printf 'B7: 无 systemd 未拒绝\n' >&2; exit 1; fi
mkdir "$TOOLBOX_SYSTEMD_RUN"
[ ! -s "$log" ]
if toolbox_system B7 </dev/null >/dev/null 2>&1; then printf 'B7: EOF 未拒绝\n' >&2; exit 1; fi
if printf 'abc\n' | toolbox_system B7 >/dev/null 2>&1; then printf 'B7: 非法阈值未拒绝\n' >&2; exit 1; fi
conf="$TOOLBOX_SYSTEM_ETC/traffic.conf"
printf 'no marker\n' > "$conf"
: > "$log"
if printf '2\nYES\nYES\n' | toolbox_system B7 >/dev/null 2>&1; then printf 'B7: 外来配置未拒绝\n' >&2; exit 1; fi
[ ! -s "$log" ]
rm -f "$conf"
if printf '2\nYES\nNO\n' | toolbox_system B7 >/dev/null 2>&1; then printf 'B7: 二次确认未生效\n' >&2; exit 1; fi
! grep -v '^systemctl show ' "$log"

# --- B7 安装失败：包装不上时不留配置
: > "$log"
if printf '2\nYES\nYES\n' | MOCK_FAIL=1 toolbox_system B7 >/dev/null 2>&1; then printf 'B7: 安装失败未拒绝\n' >&2; exit 1; fi
[ ! -e "$TOOLBOX_SYSTEM_ETC/traffic.conf" ]

# --- B7 成功路径
: > "$log"; : > "$stublog"; touch "$mockroot/vnstat-ready"
printf '2\nYES\nYES\n' | toolbox_system B7 > "$mockroot/out" 2>&1
[[ $(<"$log") == *'apt-get install -y vnstat jq'* ]]
[[ $(<"$log") == *'systemctl enable --now terry-toolbox-traffic.timer'* ]]
[[ $(<"$conf") == *'# terry-toolbox B7 traffic config'* && $(<"$conf") == *'LIMIT_GIB=2'* ]]
[[ $(stat -c %a "$conf") == 600 ]]
[ -x "$TOOLBOX_SYSTEM_BIN_DIR/terry-toolbox-traffic-check" ]
[ -e "$TOOLBOX_SYSTEM_UNIT_DIR/terry-toolbox-traffic.timer" ]
[ -e "$TOOLBOX_SYSTEM_UNIT_DIR/terry-toolbox-traffic.service" ]
[[ $(<"$TOOLBOX_SYSTEM_UNIT_DIR/terry-toolbox-traffic.timer") == *'OnCalendar=hourly'* ]]
check="$TOOLBOX_SYSTEM_BIN_DIR/terry-toolbox-traffic-check"
# 未配置 Telegram：只写日志，退出仍为 0。
TOOLBOX_TRAFFIC_CONF="$conf" TOOLBOX_TRAFFIC_STATE="$TOOLBOX_SYSTEM_STATE" \
 TOOLBOX_TG_CONF="$mockroot/absent" "$check"
[[ $(<"$stublog") == *'logger -t terry-toolbox-traffic'* && $(<"$stublog") != *sendMessage* ]]
# 配置 Telegram 后超额应发送，且同日只发一次。
printf 'TOKEN=%s\nCHAT_ID=%s\n' '123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' '-1001234567890' > "$tgconf"
marker="$TOOLBOX_SYSTEM_STATE/traffic-$(date +%Y%m).state"
rm -f "$marker"; : > "$stublog"
TOOLBOX_TRAFFIC_CONF="$conf" TOOLBOX_TRAFFIC_STATE="$TOOLBOX_SYSTEM_STATE" \
 TOOLBOX_TG_CONF="$tgconf" "$check" || { cat "$stublog" >&2; exit 1; }
[[ $(<"$stublog") == *sendMessage* && $(<"$stublog") == *'3.00 GiB'* && $(<"$stublog") == *'2 GiB'* ]]
[ -s "$marker" ]
sends=$(grep -c sendMessage "$stublog" || true)
TOOLBOX_TRAFFIC_CONF="$conf" TOOLBOX_TRAFFIC_STATE="$TOOLBOX_SYSTEM_STATE" \
 TOOLBOX_TG_CONF="$tgconf" "$check"
[ "$(grep -c sendMessage "$stublog" || true)" = "$sends" ]
# 换一天可再次告警。
printf '2000-01-01\n' > "$marker"
TOOLBOX_TRAFFIC_CONF="$conf" TOOLBOX_TRAFFIC_STATE="$TOOLBOX_SYSTEM_STATE" \
 TOOLBOX_TG_CONF="$tgconf" "$check"
[ "$(grep -c sendMessage "$stublog" || true)" -gt "$sends" ]
# Failed transport/API response must not consume today's alert; next run retries.
for failure in transport api; do
 rm -f "$marker"; : > "$stublog"
 export MOCK_TG_FAIL=0 MOCK_TG_API_FAIL=0
 if [[ $failure == transport ]]; then MOCK_TG_FAIL=1; else MOCK_TG_API_FAIL=1; fi
 if TOOLBOX_TRAFFIC_CONF="$conf" TOOLBOX_TRAFFIC_STATE="$TOOLBOX_SYSTEM_STATE" TOOLBOX_TG_CONF="$tgconf" "$check"; then
  printf 'B7 alert failure incorrectly succeeded: %s\n' "$failure" >&2; exit 1
 fi
 [[ ! -e $marker ]]
 export MOCK_TG_FAIL=0 MOCK_TG_API_FAIL=0
 TOOLBOX_TRAFFIC_CONF="$conf" TOOLBOX_TRAFFIC_STATE="$TOOLBOX_SYSTEM_STATE" TOOLBOX_TG_CONF="$tgconf" "$check"
 [[ -s $marker && $(grep -c sendMessage "$stublog") == 2 ]]
done
# 阈值提高到 10 GiB 后不再告警。
printf '%s\nLIMIT_GIB=10\n' '# terry-toolbox B7 traffic config' > "$conf"
rm -f "$marker"; : > "$stublog"
TOOLBOX_TRAFFIC_CONF="$conf" TOOLBOX_TRAFFIC_STATE="$TOOLBOX_SYSTEM_STATE" \
 TOOLBOX_TG_CONF="$tgconf" "$check"
[[ $(<"$stublog") != *sendMessage* ]]
[[ ! -e $marker ]]

# --- B7 重设失败：数据库不就绪时恢复旧阈值，而不是留下“没有配置”
printf '5\nYES\nYES\n' | toolbox_system B7 > "$mockroot/out" 2>&1 || { echo RESETFAIL >&2; cat "$mockroot/out" >&2; exit 1; }
[[ $(<"$conf") == *'LIMIT_GIB=5'* ]]
: > "$log"
rm -f "$mockroot/vnstat-ready"
if printf '7\nYES\nYES\n' | MOCK_VNSTAT_NEVER=1 toolbox_system B7 > "$mockroot/out" 2>&1; then
 printf 'B7: vnstat 未就绪未拒绝\n' >&2; exit 1
fi
[[ $(<"$mockroot/out") == *'未产生可用统计'* ]]
# 恢复的是本次运行之前的阈值（5），不是失败写入的 7。
[[ $(<"$conf") == *'LIMIT_GIB=5'* ]]
[[ $(<"$log") != *'systemctl disable --now terry-toolbox-traffic.timer'* ]]
[[ -e $mockroot/active-terry-toolbox-traffic.timer ]]
[[ -x $TOOLBOX_SYSTEM_BIN_DIR/terry-toolbox-traffic-check && -e $TOOLBOX_SYSTEM_UNIT_DIR/terry-toolbox-traffic.service ]]
# 恢复运行不残留 .bak 文件。
ls "$TOOLBOX_SYSTEM_ETC"/traffic.conf.bak.* >/dev/null 2>&1 && { printf 'B7: 残留备份\n' >&2; exit 1; }
touch "$mockroot/vnstat-ready"

# --- B15 TG 通知
# B7 用同一个路径放测试凭据（无 B15 标记），先清掉。
rm -f "$tgconf"
: > "$log"
if printf '123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-1001234567890\nYES\nYES\n' \
 | MOCK_NO_VNSTAT=1 toolbox_system B15 >/dev/null 2>&1; then printf 'B15: 缺 vnstat 未拒绝\n' >&2; exit 1; fi
if toolbox_system B15 </dev/null >/dev/null 2>&1; then printf 'B15: EOF 未拒绝\n' >&2; exit 1; fi
if printf 'bad\n' | toolbox_system B15 >/dev/null 2>&1; then printf 'B15: 非法 token 未拒绝\n' >&2; exit 1; fi
if printf '123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nbad chat!\n' | toolbox_system B15 >/dev/null 2>&1; then
 printf 'B15: 非法 chat 未拒绝\n' >&2; exit 1; fi
# 发送失败必须回滚全部写入，且不启用定时器。
: > "$log"; : > "$stublog"
if printf '123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-1001234567890\nYES\nYES\n' \
 | MOCK_TG_FAIL=1 toolbox_system B15 >/dev/null 2>&1; then printf 'B15: 发送失败未拒绝\n' >&2; exit 1; fi
[ ! -e "$tgconf" ]
[ ! -e "$TOOLBOX_SYSTEM_BIN_DIR/terry-toolbox-tg-report" ]
[ ! -e "$TOOLBOX_SYSTEM_UNIT_DIR/terry-toolbox-tg.timer" ]
[[ $(<"$log") != *'enable --now terry-toolbox-tg.timer'* ]]
# 成功路径：凭据 600、真实发送测试消息、token 不回显到输出。
: > "$log"; : > "$stublog"
token='123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
printf '%s\n-1001234567890\nYES\nYES\n' "$token" | toolbox_system B15 > "$mockroot/out" 2>&1
if [[ $(<"$mockroot/out") == *"$token"* ]]; then echo TOKENLEAK >&2; grep -n -F "$token" "$mockroot/out" >&2; fi
# bash -x 会把函数参数（含 token）写进 stderr，故仅在非 -x 下断言不回显。
case $- in *x*) ;; *) [[ $(<"$mockroot/out") != *"$token"* ]] || { printf 'B15: token 回显到输出\n' >&2; exit 1; };; esac
[[ $(<"$tgconf") == *"TOKEN=$token"* && $(<"$tgconf") == *'CHAT_ID=-1001234567890'* ]]
[[ $(<"$tgconf") == *'# terry-toolbox B15 telegram config'* ]]
[[ $(stat -c %a "$tgconf") == 600 ]]
[ -x "$TOOLBOX_SYSTEM_BIN_DIR/terry-toolbox-tg-report" ]
[[ $(<"$stublog") == *sendMessage* ]]
[[ $(<"$log") == *'enable --now terry-toolbox-tg.timer'* ]]
[[ $(<"$TOOLBOX_SYSTEM_UNIT_DIR/terry-toolbox-tg.timer") == *'09:17'* ]]
# 日报正文包含今日与本月，且真的发出去。
: > "$stublog"
"$TOOLBOX_SYSTEM_BIN_DIR/terry-toolbox-tg-report"
[[ $(<"$stublog") == *sendMessage* && $(<"$stublog") == *'1.00 GiB'* && $(<"$stublog") == *'3.00 GiB'* ]]
# 重配失败：恢复旧凭据，不让已工作的通知失效。
printf '%s\n-1001234567890\nYES\nYES\n' '987654321:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB' \
 | MOCK_TG_FAIL=1 toolbox_system B15 >/dev/null 2>&1 && { printf 'B15: 重配失败未报错\n' >&2; exit 1; }
[[ $(<"$tgconf") == *"TOKEN=$token"* ]]
# HTTP success with API rejection is not a successful test notification.
export MOCK_TG_API_FAIL=1
api_token="987654321:$(printf '%035d' 0)"
if printf '%s\n-1001234567890\nYES\nYES\n' "$api_token" | toolbox_system B15 >/dev/null 2>&1; then
 printf 'B15 accepted ok=false API response\n' >&2; exit 1
fi
[[ $(<"$tgconf") == *"TOKEN=$token"* ]]
export MOCK_TG_API_FAIL=0
# 外来配置拒绝覆盖。
printf 'no marker\n' > "$tgconf"
: > "$log"
if printf '123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-1001234567890\nYES\nYES\n' \
 | toolbox_system B15 >/dev/null 2>&1; then printf 'B15: 外来配置未拒绝\n' >&2; exit 1; fi

# --- B16 网络优化
sysctl_values=$mockroot/sysctl.values
printf '%s\t%s\n' \
 net.ipv4.tcp_available_congestion_control 'cubic bbr' \
 net.ipv4.tcp_congestion_control cubic \
 net.core.default_qdisc pfifo_fast \
 net.core.somaxconn 4096 \
 net.ipv4.tcp_max_syn_backlog 1024 \
 net.ipv4.tcp_fastopen 1 \
 net.ipv4.tcp_slow_start_after_idle 1 \
 net.ipv4.tcp_mtu_probing 0 \
 net.ipv4.ip_local_port_range '32768 60999' \
 net.core.rmem_max 212992 \
 net.core.wmem_max 212992 > "$sysctl_values"
sysctl() {
 printf 'sysctl %s\n' "$*" >> "$log"
 case $1 in
  -n) awk -F'\t' -v k="$2" '$1==k{print $2; f=1} END{exit !f}' "$sysctl_values";;
  -w) local k=${2%%=*} v=${2#*=}
      [[ ${MOCK_SYSCTL_W_FAIL:-} != *"$k"* ]] || return 1
      awk -F'\t' -v k="$k" '$1!=k' "$sysctl_values" > "$sysctl_values.t"
      printf '%s\t%s\n' "$k" "$v" >> "$sysctl_values.t"; mv "$sysctl_values.t" "$sysctl_values";;
  -p) [[ ${MOCK_SYSCTL_P_FAIL:-0} != 1 ]] || return 1
      sed -n 's/^\([a-z0-9._]*\)[[:space:]]*=[[:space:]]*\(.*\)$/\1\t\2/p' "$2" |
      while IFS=$'\t' read -r k v; do sysctl -w "$k=$v" >/dev/null; done;;
  *) return 1;;
 esac
}
sysctl_values_get() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$sysctl_values"; }
# 把“内核当前值”重置回初始值，避免上一个用例的写入影响本用例。
reset_sysctl() {
 printf '%s\t%s\n' \
  net.ipv4.tcp_available_congestion_control 'cubic bbr' net.ipv4.tcp_congestion_control cubic \
  net.core.default_qdisc pfifo_fast net.core.somaxconn 4096 net.ipv4.tcp_max_syn_backlog 1024 \
  net.ipv4.tcp_fastopen 1 net.ipv4.tcp_slow_start_after_idle 1 net.ipv4.tcp_mtu_probing 0 \
  net.ipv4.ip_local_port_range '32768 60999' net.core.rmem_max 212992 net.core.wmem_max 212992 \
  > "$sysctl_values"
}
dropin="$TOOLBOX_SYSTEM_SYSCTL_DIR/99-terry-toolbox.conf"
: > "$log"
# 无 BBR 内核：拒绝且不写文件。
awk -F'\t' -v OFS='\t' '{if ($1=="net.ipv4.tcp_available_congestion_control") $2="cubic"; print}' "$sysctl_values" > "$sysctl_values.t"
mv "$sysctl_values.t" "$sysctl_values"
if printf '1\nYES\nYES\n' | toolbox_system B16 >/dev/null 2>&1; then printf 'B16: 无 BBR 未拒绝\n' >&2; exit 1; fi
[ ! -e "$dropin" ]
awk -F'\t' -v OFS='\t' '{if ($1=="net.ipv4.tcp_available_congestion_control") $2="cubic bbr"; print}' "$sysctl_values" > "$sysctl_values.t"
mv "$sysctl_values.t" "$sysctl_values"
# 外来同名 drop-in 不改。
printf 'net.core.somaxconn = 1\n' > "$dropin"
if printf '1\nYES\nYES\n' | toolbox_system B16 >/dev/null 2>&1; then printf 'B16: 外来 drop-in 未拒绝\n' >&2; exit 1; fi
[[ $(<"$dropin") == 'net.core.somaxconn = 1' ]]
rm -f "$dropin"
# 取消不写。
if printf '1\nYES\nNO\n' | toolbox_system B16 >/dev/null 2>&1; then printf 'B16: 取消未生效\n' >&2; exit 1; fi
[ ! -e "$dropin" ]
# 成功应用：值写入运行期与持久文件，旧值备份。
: > "$log"
printf '1\nYES\nYES\n' | toolbox_system B16 > "$mockroot/out" 2>&1
[ -e "$dropin" ]
[[ $(<"$dropin") == *'# Managed by terry-toolbox (B16)'* && $(<"$dropin") == *'net.ipv4.tcp_congestion_control = bbr'* ]]
[ "$(sysctl_values_get net.ipv4.tcp_congestion_control)" = bbr ]
[ "$(sysctl_values_get net.core.default_qdisc)" = fq ]
[ "$(sysctl_values_get net.ipv4.ip_local_port_range)" = '10240 65000' ]
statefile="$TOOLBOX_SYSTEM_STATE/net-opt.previous"
[[ $(<"$statefile") == *'net.ipv4.tcp_congestion_control=cubic'* ]]
[[ $(stat -c %a "$statefile") == 600 ]]
# 幂等：再次应用不重复写 sysctl。
: > "$log"
printf '1\nYES\nYES\n' | toolbox_system B16 > "$mockroot/out" 2>&1
[[ $(<"$mockroot/out") == *'未修改任何配置'* ]]
[[ $(<"$log") != *'sysctl -p'* ]]

# 部分键不被内核接受时跳过，不因缺键整体失败。
rm -f "$dropin" "$statefile"
awk -F'\t' '$1!="net.core.rmem_max"' "$sysctl_values" > "$sysctl_values.t"; mv "$sysctl_values.t" "$sysctl_values"
printf '1\nYES\nYES\n' | toolbox_system B16 > "$mockroot/out" 2>&1
[[ $(<"$mockroot/out") == *'跳过（内核不支持）：net.core.rmem_max'* ]]
[[ $(<"$dropin") != *rmem_max* ]]
# sysctl -p 失败：删 drop-in 并恢复旧值。
rm -f "$dropin" "$statefile"; reset_sysctl
if printf '1\nYES\nYES\n' | MOCK_SYSCTL_P_FAIL=1 toolbox_system B16 > "$mockroot/out" 2>&1; then
 printf 'B16: sysctl 应用失败未报错\n' >&2; exit 1; fi
[ ! -e "$dropin" ]
[ ! -e "$statefile" ]
[ "$(sysctl_values_get net.ipv4.tcp_congestion_control)" = cubic ]
# 回滚：删除 drop-in、恢复旧值、删除备份。
reset_sysctl
printf '1\nYES\nYES\n' | toolbox_system B16 >/dev/null 2>&1
: > "$log"
printf '2\nYES\nYES\n' | toolbox_system B16 > "$mockroot/out" 2>&1
[ ! -e "$dropin" ]
[ ! -e "$statefile" ]
[ "$(sysctl_values_get net.ipv4.tcp_congestion_control)" = cubic ]
[ "$(sysctl_values_get net.ipv4.ip_local_port_range)" = '32768 60999' ]
# 恢复失败时保留回滚记录，便于修正后重试。
reset_sysctl; rm -f "$dropin" "$statefile"
printf '1\nYES\nYES\n' | toolbox_system B16 >/dev/null 2>&1
if printf '2\nYES\nYES\n' | MOCK_SYSCTL_W_FAIL=net.ipv4.tcp_fastopen toolbox_system B16 > "$mockroot/out" 2>&1; then
 printf 'B16: 恢复失败未报错\n' >&2; exit 1; fi
[[ $(<"$mockroot/out") == *'回滚记录保留'* ]]
[ -e "$statefile" ]
[ ! -e "$dropin" ]
printf '2\nYES\nYES\n' | toolbox_system B16 >/dev/null 2>&1
[ ! -e "$statefile" ]
# 无备份时回滚拒绝。
if printf '2\nYES\nYES\n' | toolbox_system B16 >/dev/null 2>&1; then printf 'B16: 无备份回滚未拒绝\n' >&2; exit 1; fi

# --- B11 1Panel
export B11LOG="$mockroot/1panel.log"
cat > "$mockroot/1p.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ran %s base=%s mode=%s\n' "$PWD" "${PANEL_BASE_DIR:-}" "${INSTALL_MODE:-}" >> "$B11LOG"
touch "$MOCK_ROOT/1pctl-installed"
STUB
chmod 0755 "$mockroot/1p.sh"
export MOCK_DOWNLOAD="$mockroot/1p.sh"
export TOOLBOX_1PANEL_URL='https://example.invalid/quick_start.sh'
export TOOLBOX_1PANEL_SHA256
TOOLBOX_1PANEL_SHA256=$(sha256sum "$mockroot/1p.sh" | cut -d' ' -f1)
# 摘要不匹配：不执行脚本。
: > "$log"
if printf 'YES\nYES\n' | TOOLBOX_1PANEL_SHA256=deadbeef toolbox_system B11 > "$mockroot/out" 2>&1; then
 printf 'B11: 摘要不匹配未拒绝\n' >&2; exit 1; fi
[[ $(<"$mockroot/out") == *'SHA-256 不匹配'* ]]
[ ! -e "$B11LOG" ]
# 取消不下载执行。
if printf 'YES\nNO\n' | toolbox_system B11 >/dev/null 2>&1; then printf 'B11: 取消未生效\n' >&2; exit 1; fi
[ ! -e "$B11LOG" ]
# 成功路径：校验后执行，环境变量与摘要均被使用。
printf 'YES\nYES\n' | toolbox_system B11 > "$mockroot/out" 2>&1
[[ $(<"$B11LOG") == *'base=/opt/1panel mode=stable'* ]]
[[ $(<"$mockroot/out") == *'已安装'* ]]
[[ $(<"$log") == *'example.invalid'* ]]
rm -f "$B11LOG"
# 已存在则拒绝，且不下载。
: > "$log"
if printf 'YES\nYES\n' | toolbox_system B11 >/dev/null 2>&1; then printf 'B11: 已安装未拒绝\n' >&2; exit 1; fi
[ ! -s "$log" ]

# --- B2 NodeQuality：固定摘要 + 预览确认 + 临时目录执行
export B2LOG="$mockroot/nq.log"
cat > "$mockroot/nq.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ran cwd=%s\n' "$PWD" >> "$B2LOG"
if [[ ${MOCK_NQ_LEFTOVER:-0} == 1 ]]; then mkdir -p .nodequality_x/BenchOs; : > .nodequality_x/error.log; fi
exit "${MOCK_NQ_RC:-1}"
STUB
chmod 0755 "$mockroot/nq.sh"
export MOCK_DOWNLOAD="$mockroot/nq.sh"
export TOOLBOX_NODEQUALITY_URL='https://example.invalid/NodeQuality.sh'
export TOOLBOX_NODEQUALITY_SHA256
TOOLBOX_NODEQUALITY_SHA256=$(sha256sum "$mockroot/nq.sh" | cut -d' ' -f1)
# 取消（EOF 与第二问 NO）都不下载、不执行。
if toolbox_system B2 </dev/null >/dev/null 2>&1; then printf 'B2: EOF 未取消\n' >&2; exit 1; fi
[ ! -s "$log" ] && [ ! -e "$B2LOG" ]
if printf 'YES\nNO\n' | toolbox_system B2 >/dev/null 2>&1; then printf 'B2: 取消未生效\n' >&2; exit 1; fi
[ ! -s "$log" ] && [ ! -e "$B2LOG" ]
# 缺少 mount 时在下载前就拒绝。
if printf 'YES\nYES\n' | MOCK_MISSING=mount toolbox_system B2 >/dev/null 2>&1; then
 printf 'B2: 缺 mount 未拒绝\n' >&2; exit 1; fi
[ ! -s "$log" ] && [ ! -e "$B2LOG" ]
# 下载失败：fail closed，不执行。
if printf 'YES\nYES\n' | MOCK_CURL_FAIL=1 toolbox_system B2 >/dev/null 2>&1; then
 printf 'B2: 下载失败未拒绝\n' >&2; exit 1; fi
[ ! -e "$B2LOG" ]
: > "$log"
# 摘要不匹配：不执行，且保留下载文件供审阅。
if printf 'YES\nYES\n' | TOOLBOX_NODEQUALITY_SHA256=deadbeef toolbox_system B2 > "$mockroot/out" 2>&1; then
 printf 'B2: 摘要不匹配未拒绝\n' >&2; exit 1; fi
[[ $(<"$mockroot/out") == *'SHA-256 不匹配'* ]]
[[ $(<"$mockroot/out") == *'保留'* ]]
[ ! -e "$B2LOG" ]
kept=$(sed -n 's/^.*供人工审阅：//p' "$mockroot/out")
tmpdir=$(dirname "$kept")
[ -f "$tmpdir/NodeQuality.sh" ]
: > "$log"
# 成功路径：使用覆盖地址下载，校验后在新临时目录内以相对路径执行；上游 exit 1 属正常。
printf 'YES\nYES\n' | toolbox_system B2 > "$mockroot/out" 2>&1
run_cwd=$(sed -n 's/^ran cwd=//p' "$B2LOG")
[ -n "$run_cwd" ]
[[ $run_cwd == "${TMPDIR:-/tmp}"/* ]]
[[ $(<"$log") == *'example.invalid/NodeQuality.sh'* ]]
! grep -q '异常退出' "$mockroot/out"
[[ $(<"$mockroot/out") == *'临时目录已删除'* ]]
[ ! -e "$run_cwd" ]
# 上游非 0/1 的退出码要报错，但仍清理临时目录。
: > "$B2LOG"; : > "$log"
if printf 'YES\nYES\n' | MOCK_NQ_RC=2 toolbox_system B2 > "$mockroot/out" 2>&1; then
 printf 'B2: 异常退出码未报错\n' >&2; exit 1; fi
[[ $(<"$mockroot/out") == *'异常退出（2）'* ]]
[ ! -e "$(sed -n 's/^ran cwd=//p' "$B2LOG")" ]
# 工作目录残留（挂载没卸干净）：报错并保留临时目录。
: > "$B2LOG"; : > "$log"
if printf 'YES\nYES\n' | MOCK_NQ_LEFTOVER=1 toolbox_system B2 > "$mockroot/out" 2>&1; then
 printf 'B2: 残留未报错\n' >&2; exit 1; fi
[[ $(<"$mockroot/out") == *'挂载残留'* ]]
left=$(sed -n 's/^.*临时目录保留在 //p' "$mockroot/out" | sed 's/（.*$//')
[ -d "$left/.nodequality_x" ]
rm -rf -- "$left"
unset TOOLBOX_NODEQUALITY_URL TOOLBOX_NODEQUALITY_SHA256 MOCK_DOWNLOAD

# --- B19 Alpine 工具：非 Alpine 一律拒绝
: > "$log"
if printf '1\nYES\nYES\n' | toolbox_system B19 >/dev/null 2>&1; then printf 'B19: Debian 未拒绝\n' >&2; exit 1; fi
[ ! -s "$log" ]
TEST_OS=alpine; export TEST_OS
# This suite sources only system.sh; every swap action must refuse a missing module.
# Real module behavior is covered by alpine-swap-test.sh and dispatch-test.sh.
for choice in 4 5 6; do
 : > "$log"
 if printf '%s\n' "$choice" | toolbox_system B19 > "$mockroot/out" 2>&1; then
  printf 'B19: missing swap module did not refuse action %s\n' "$choice" >&2; exit 1
 fi
 [[ $(<"$mockroot/out") == *'模块未加载'* && $(<"$mockroot/out") == *'未改动'* ]]
 [ ! -s "$log" ]
done
if printf '9\n' | toolbox_system B19 >/dev/null 2>&1; then printf 'B19: 非法选项未拒绝\n' >&2; exit 1; fi

# Webtop：缺 docker 与服务不健康都拒绝。
mkdir -p "$mockroot/docker-containers"
docker() {
 printf 'docker %s\n' "$*" >> "$log"
 case $1 in
  info) [[ ${MOCK_DOCKER_UP:-1} == 1 ]];;
  ps) [[ -e $mockroot/docker-containers/terry-toolbox-webtop ]] && printf 'terry-toolbox-webtop\n'; return 0;;
  pull) [[ ${MOCK_DOCKER_PULL_FAIL:-0} != 1 ]];;
  run) [[ ${MOCK_DOCKER_RUN_FAIL:-0} != 1 ]] || return 125
       touch "$mockroot/docker-containers/terry-toolbox-webtop"; printf 'cid\n';;
  inspect) [[ ${MOCK_DOCKER_RUNNING:-1} == 1 ]] && printf 'true\n';;
  *) return 0;;
 esac
}
: > "$log"
if printf '1\nYES\nYES\n' | MOCK_MISSING=docker toolbox_system B19 >/dev/null 2>&1; then
 printf 'B19: 缺 docker 未拒绝\n' >&2; exit 1; fi
[ ! -s "$log" ]
if printf '1\nYES\nYES\n' | MOCK_DOCKER_UP=0 toolbox_system B19 >/dev/null 2>&1; then
 printf 'B19: docker 未运行未拒绝\n' >&2; exit 1; fi
# 同名容器存在：不重建。
touch "$mockroot/docker-containers/terry-toolbox-webtop"
printf '1\nYES\nYES\n' | toolbox_system B19 > "$mockroot/out" 2>&1 || true
[[ $(<"$mockroot/out") == *'已存在'* ]]
[[ $(<"$log") != *'docker pull'* ]]
rm -f "$mockroot/docker-containers/terry-toolbox-webtop"
# 拉取失败：不创建容器。
: > "$log"
if printf '1\nYES\nYES\n' | MOCK_DOCKER_PULL_FAIL=1 toolbox_system B19 >/dev/null 2>&1; then
 printf 'B19: 拉取失败未拒绝\n' >&2; exit 1; fi
[[ $(<"$log") != *'docker run'* ]]
# 成功：拉取 + 仅本机绑定 + 数据目录挂载 + inspect 验证。
: > "$log"
printf '1\nYES\nYES\n' | toolbox_system B19 > "$mockroot/out" 2>&1
[[ $(<"$log") == *'docker pull lscr.io/linuxserver/webtop:latest'* ]]
[[ $(<"$log") == *'-p 127.0.0.1:3000:3000'* ]]
[[ $(<"$log") == *"-v $TOOLBOX_WEBTOP_ROOT:/config"* ]]
[[ $(<"$log") == *'inspect'* ]]
[[ $(<"$mockroot/out") == *'容器已运行'* ]]
rm -f "$mockroot/docker-containers/terry-toolbox-webtop"
# 启动后未运行：保留容器但报错。
: > "$log"
if printf '1\nYES\nYES\n' | MOCK_DOCKER_RUNNING=0 toolbox_system B19 > "$mockroot/out" 2>&1; then
 printf 'B19: 容器未运行未报错\n' >&2; exit 1; fi
[[ $(<"$mockroot/out") == *'容器未运行'* ]]
rm -f "$mockroot/docker-containers/terry-toolbox-webtop"

# 端口跳跃：规则用独立状态文件模拟，-C/-A/-D 语义与真实 iptables 一致。
iptrules=$mockroot/iptables.rules
: > "$iptrules"
iptables() {
 printf 'iptables %s\n' "$*" >> "$log"
 local key='' a cmd=''
 for a in "$@"; do case $a in -C|-A|-D) cmd=$a;; *) key+="$a ";; esac; done
 case $cmd in
  -C) grep -qxF -- "$key" "$iptrules";;
  -A) [[ ${MOCK_IPT_FAIL:-0} != 1 ]] || return 1
      grep -qxF -- "$key" "$iptrules" || printf '%s\n' "$key" >> "$iptrules";;
  -D) [[ ${MOCK_IPT_FAIL:-0} != 1 ]] || return 1
      # 真实 iptables 对不存在的规则返回 1。
      grep -qxF -- "$key" "$iptrules" || return 1
      grep -vxF -- "$key" "$iptrules" > "$iptrules.t"; mv "$iptrules.t" "$iptrules";;
  *) return 1;;
 esac
}
ss() { printf 'ss %s\n' "$*" >> "$log"; printf 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:*\n'; }
rc-service() { printf 'rc-service %s\n' "$*" >> "$log"; [[ ${MOCK_RC_FAIL:-0} != 1 ]]; }
hopconf="$TOOLBOX_SYSTEM_ETC/port-hop.conf"
: > "$log"
if printf '2\n20000\n30000\n443\n' | MOCK_MISSING=iptables toolbox_system B19 >/dev/null 2>&1; then
 printf 'B19: 缺 iptables 未拒绝\n' >&2; exit 1; fi
[ ! -s "$log" ]
# 端口范围校验。
if printf '2\n30000\n20000\n443\n' | toolbox_system B19 >/dev/null 2>&1; then printf 'B19: 反向范围未拒绝\n' >&2; exit 1; fi
if printf '2\n20000\n99999\n443\n' | toolbox_system B19 >/dev/null 2>&1; then printf 'B19: 越界端口未拒绝\n' >&2; exit 1; fi
if printf '2\n20000\n22000\n443\n' | toolbox_system B19 >/dev/null 2>&1; then printf 'B19: 超大范围未拒绝\n' >&2; exit 1; fi
[ ! -s "$iptrules" ]
if printf '2\n20000\n20100\n443\nYES\nNO\n' | toolbox_system B19 >/dev/null 2>&1; then
 printf 'B19: 取消仍加规则\n' >&2; exit 1; fi
[ ! -s "$iptrules" ]
# 添加失败：不留配置。
if printf '2\n20000\n20100\n443\nYES\nYES\n' | MOCK_IPT_FAIL=1 toolbox_system B19 >/dev/null 2>&1; then
 printf 'B19: 添加失败未报错\n' >&2; exit 1; fi
[ ! -e "$hopconf" ]
# 成功：规则、配置、持久化保存。
printf '2\n20000\n20100\n443\nYES\nYES\n' | toolbox_system B19 > "$mockroot/out" 2>&1
[[ $(<"$iptrules") == *'nat PREROUTING -p udp --dport 20000:20100 -j REDIRECT --to-ports 443'* ]]
[[ $(<"$hopconf") == *'START=20000'* && $(<"$hopconf") == *'TARGET=443'* ]]
[[ $(<"$log") == *'rc-service iptables save'* ]]
[[ $(<"$mockroot/out") == *'已保存'* ]]
# 持久化保存失败必须明说，不能假称持久（规则已存在，配置重写）。
rm -f "$hopconf"; : > "$log"
printf '2\n20000\n20100\n443\nYES\nYES\n' | MOCK_RC_FAIL=1 toolbox_system B19 > "$mockroot/out" 2>&1 || true
[[ $(<"$mockroot/out") == *'重启后会丢失'* ]]
# 已应用且规则在位：幂等，不再询问、不重复加规则。
: > "$log"
printf '2\n' | toolbox_system B19 > "$mockroot/out" 2>&1
[[ $(<"$mockroot/out") == *'未修改'* ]]
[[ $(<"$log") != *'iptables -t nat -A'* ]]
# 规则已被手工删掉但配置仍在：报错且保留配置。
: > "$iptrules"
if printf '3\nYES\nYES\n' | toolbox_system B19 >/dev/null 2>&1; then printf 'B19: 规则缺失未报错\n' >&2; exit 1; fi
[ -e "$hopconf" ]
# 规则缺失时再次应用应补回规则（配置沿用，不再询问端口）。
printf '2\nYES\nYES\n' | toolbox_system B19 > "$mockroot/out" 2>&1
[[ $(<"$mockroot/out") == *'将补回'* ]]
[ -s "$iptrules" ]
# 移除外来标记的配置也拒绝。
printf 'no marker\n' > "$hopconf"
if printf '3\nYES\nYES\n' | toolbox_system B19 >/dev/null 2>&1; then printf 'B19: 外来配置被删除\n' >&2; exit 1; fi
printf '%s\nSTART=20000\nEND=20100\nTARGET=443\n' '# terry-toolbox B19 port-hop' > "$hopconf"
# 移除成功：规则和配置一起删除，并同步保存。
[ -s "$iptrules" ]
printf '3\nYES\nYES\n' | toolbox_system B19 > "$mockroot/out" 2>&1
[ ! -s "$iptrules" ]
[ ! -e "$hopconf" ]
[[ $(<"$mockroot/out") == *'已删除'* ]]
# 无配置时移除拒绝。
if printf '3\nYES\nYES\n' | toolbox_system B19 >/dev/null 2>&1; then printf 'B19: 无配置移除未拒绝\n' >&2; exit 1; fi
unset TEST_OS
printf 'system tests passed\n'
