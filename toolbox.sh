#!/usr/bin/env bash
# Terry 工具箱：启动检测依赖；确认后才安装，不自动升级系统。
set -u
TOOLBOX_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOOLBOX_VERSION='0.2.0-dev'

# 非 root 时自动提权，便于一条命令 `bash <(curl -fsSL sh.uw.cx)` 直接可用。
if (( EUID != 0 )) && [[ -z ${TOOLBOX_ELEVATED:-} ]]; then
  command -v sudo >/dev/null 2>&1 || {
    printf '需要 root 权限：请用 root 运行，或先安装 sudo。\n' >&2
    exit 1
  }
  export TOOLBOX_ELEVATED=1
  case ${BASH_SOURCE[0]:-} in
    /dev/fd/*|/dev/stdin|/proc/self/fd/*|bash|'')
      # 流式执行时脚本本身在已关闭/被读空的 fd 上，重新取一份完整副本再提权。
      command -v curl >/dev/null 2>&1 || { printf '需要 curl 才能自动提权。\n' >&2; exit 1; }
      _tb_tmp=$(mktemp "${TMPDIR:-/tmp}/toolbox.XXXXXXXX") || exit 1
      if ! curl -fsSL --proto '=https,http' sh.uw.cx >"$_tb_tmp"; then
        printf '下载脚本失败（sh.uw.cx）。\n' >&2
        exit 1
      fi
      # 管道执行时 stdin 不是终端，菜单会读不到；能拿到终端就切回去。
      if [[ -t 0 ]]; then
        exec sudo -E bash "$_tb_tmp" "$@"
      elif { : </dev/tty; } 2>/dev/null; then
        exec sudo -E bash "$_tb_tmp" "$@" </dev/tty
      else
        exec sudo -E bash "$_tb_tmp" "$@"
      fi
      ;;
    *) exec sudo -E bash "${BASH_SOURCE[0]}" "$@" ;;
  esac
fi

# shellcheck source=modules/entry.sh
source "$TOOLBOX_DIR/modules/entry.sh"

show_list() {
  printf '%s\n' 'A1 A2 A3 A4 A5' 'B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 B11 B12 B13 B14 B15 B16 B17 B18 B19 B20 B21 B22 B23 B24 B25 B26 B27 B28 B29 B30 B31'
}
show_help() {
  printf 'Terry 工具箱 %s\n用法: bash toolbox.sh [--help|--list]\n--list 列出菜单编号；不带参数进入交互菜单。\n' "$TOOLBOX_VERSION"
}
load_modules() {
  [[ ${TOOLBOX_MODULES_LOADED:-0} == 1 ]] && return 0
  local f
  for f in apps network system diagnostics hy2 webssh; do
    if [[ ! -r "$TOOLBOX_DIR/modules/$f.sh" ]]; then
      printf '错误：缺少模块 %s/modules/%s.sh。请下载完整项目。\n' "$TOOLBOX_DIR" "$f" >&2
      return 1
    fi
    # shellcheck source=/dev/null
    source "$TOOLBOX_DIR/modules/$f.sh"
  done
  TOOLBOX_MODULES_LOADED=1
}
run_action() {
  local key=$1
  case "$key" in
    DIAG) toolbox_diagnostics ;;
    A4) a4_menu ;;
    A1|A2|A3|A5|B12|B23|B31) toolbox_network "$key" ;;
    B3|B4|B5|B9|B13|B17|B20|B21|B22|B24|B25|B26|B27|B28|B29|B30) toolbox_app "${key#B}" ;;
    MAIN_BBR|MAIN_DEPS|MAIN_REINSTALL|MAIN_REBOOT|B1|B2|B6|B7|B8|B11|B14|B15|B16|B19) toolbox_system "$key" ;;
    B10) toolbox_webssh ;;
    B18) printf 'B18：预留，暂未实现。\n' ; return 1 ;;
    *) printf '无效选项：%s\n' "$key" ; return 1 ;;
  esac
}
a4_menu() {
  local c
  printf '\n'; _tb_heading 'A4 Hysteria 2'
  _tb_line '[1] 安装'; _tb_line '[2] 卸载'; _tb_line '[3] 状态'; _tb_line '[0] 返回'; _tb_finish
  printf '\n请输入编号：'
  IFS= read -r c || return 1
  case "$c" in
    0) return 0 ;;
    1) toolbox_hy2 install ;;
    2) toolbox_hy2 uninstall ;;
    3) toolbox_hy2 status ;;
    *) printf '无效选项。\n' ; return 1 ;;
  esac
}
menu() {
  local choice screen=main key
  _tb_ui_init
  _tb_banner
  _tb_bootstrap || true
  while :; do
    TB_SKIP_BANNER=1
    case "$screen" in main) _tb_main_screen;; network) _tb_network_screen;; apps) _tb_apps_screen;; esac
    _tb_read_choice || return 0
    choice=$TB_CHOICE
    case "$choice" in
      0|Q)
        if [[ $screen != main ]]; then screen=main; continue; fi
        _tb_bye; return 0 ;;
    esac
    key=$choice
    if [[ $screen == main ]]; then
      case "$choice" in
        1) screen=network; continue;;
        5) screen=apps; continue;;
        2|M1) key=MAIN_BBR;;
        3|M2) key=MAIN_DEPS;;
        4|DD|M3) key=MAIN_REINSTALL;;
        99|M4) key=MAIN_REBOOT;;
      esac
    elif [[ $screen == network && $choice =~ ^[1-5]$ ]]; then
      key=A$choice
    elif [[ $screen == apps && $choice =~ ^([1-9]|[12][0-9]|3[01])$ ]]; then
      key=B$choice
    fi
    case "$key" in
      DIAG|MAIN_BBR|MAIN_DEPS|MAIN_REINSTALL|MAIN_REBOOT|A[1-5]|B[1-9]|B[12][0-9]|B3[01]) ;;
      *) printf '\n %s无效的选择，请按菜单编号输入。%s\n' "$TB_YELLOW" "$TB_RESET"; continue;;
    esac
    if [[ "$key" != B18 ]]; then
      if ! load_modules; then continue; fi
    fi
    printf '\n'
    run_action "$key" || printf '\n %s操作未完成或已取消。%s\n' "$TB_YELLOW" "$TB_RESET"
    _tb_pause || return 0
    TB_SKIP_BANNER=0
  done
}
case "${1-}" in
  --help|-h) show_help ;;
  --list) show_list ;;
  '') menu ;;
  *) printf '未知参数：%s\n' "$1" >&2; show_help >&2; exit 2 ;;
esac
