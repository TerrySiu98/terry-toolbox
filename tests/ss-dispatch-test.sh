#!/usr/bin/env bash
# Shadowsocks has separate Alpine and systemd paths; menu tests never mutate a host.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/scratch-root.sh"
toolbox_test_scratch
work=$(mktemp -d "${TMPDIR}/ss-dispatch.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/guard"
for cmd in sudo apt apt-get apk dnf yum systemctl rc-service rc-update curl wget; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$0 $*" >> "$SS_MENU_FORBIDDEN"\nexit 99\n' > "$work/guard/$cmd"
  chmod 755 "$work/guard/$cmd"
done
export PATH="$work/guard:$PATH" SS_MENU_FORBIDDEN="$work/forbidden" TOOLBOX_ELEVATED=1
export NO_COLOR=1 TERM=dumb COLUMNS=40
source "$root/toolbox.sh" --help >/dev/null
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
list=$(show_list | tr '
' ' ')
for key in A6 A7; do
  [[ " $list " == *" $key "* ]] || fail "$key missing from list"
  _tb_managed_key "$key" || fail "$key has no management page"
  for choice in 1 2 3; do _tb_service_choice_valid "$key" "$choice" || fail "$key $choice invalid"; done
  if _tb_service_choice_valid "$key" 4; then fail "$key accepts undocumented action"; fi
done
_tb_ui_init
screen=$(_tb_network_screen)
[[ $screen == *'6. Alpine 版 SS'* && $screen == *'7. SS 服务'* ]] || fail 'separate menu entries missing'
for key in A6 A7; do
  screen=$(_tb_service_screen "$key")
  [[ $screen == *"$key"* && $screen == *'Shadowsocks'* && $screen == *'返回上一层'* ]] || fail "$key page missing"
done
# Real network dispatch with only its external implementation boundary replaced.
source "$root/modules/network.sh"
toolbox_shadowsocks() { printf 'SS_BACKEND:%s\n' "$*"; }
for row in 'A6 alpine' 'A7 systemd'; do
  read -r key backend <<< "$row"
  for action in install uninstall status; do
    out=$(toolbox_network "$key" "$action")
    [[ $out == "SS_BACKEND:$backend $action" ]] || fail "$key $action routed incorrectly: $out"
  done
done
unset -f toolbox_shadowsocks
if toolbox_network A6 status >"$work/missing.out" 2>"$work/missing.err"; then fail 'missing SS module accepted'; fi
[[ $(<"$work/missing.err") == *'未加载'* ]] || fail 'missing module has no reason'
# Navigate both numeric and full keys without loading installers or bootstrap packages.
load_modules() { :; }
_tb_bootstrap() { :; }
_tb_pause() { IFS= read -r _pause; }
toolbox_network() { printf 'SS_MENU:%s\n' "$*"; }
for key in A6 A7; do
  for choice in 1 2 3; do
    out=$(menu <<< $'1\n'"${key#A}"$'\n'"$choice"$'\n\n0\n0\n0\n')
    case "$choice" in 1) action=install;; 2) action=uninstall;; 3) action=status;; esac
    [[ $out == *"SS_MENU:$key $action"* ]] || fail "$key numeric action missing"
    [[ $out != *'无效的选择'* && $out != *'操作未完成或已取消'* ]] || fail "$key numeric navigation failed"
  done
  out=$(menu <<< "$key"$'\n0\n0\n')
  [[ $out == *"$key"* && $out == *'Shadowsocks'* && $out != *'SS_MENU:'* ]] || fail "$key return invoked an action"
done
[[ ! -e $SS_MENU_FORBIDDEN ]] || fail 'host command called'
printf 'PASS: separate A6/A7 navigation, actions, backends and fail-closed module\n'
