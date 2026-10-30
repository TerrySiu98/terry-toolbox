#!/usr/bin/env bash
# Terry 工具箱：进入菜单不安装、不修改系统。
set -u
TOOLBOX_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOOLBOX_VERSION='0.1.0-dev'

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
      if [[ ! -t 0 && -t 2 || -r /dev/tty ]]; then exec sudo -E bash "$_tb_tmp" "$@" </dev/tty; fi
      exec sudo -E bash "$_tb_tmp" "$@"
      ;;
    *) exec sudo -E bash "${BASH_SOURCE[0]}" "$@" ;;
  esac
fi

show_list() {
  printf '%s\n' 'A1 A2 A3 A4 A5' 'B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 B11 B12 B13 B14 B15 B16 B17 B18 B19 B20 B21 B22 B23 B24 B25 B26 B27 B28 B29 B30 B31'
}
show_help() {
  printf 'Terry 工具箱 %s\n用法: bash toolbox.sh [--help|--list]\n--list 列出菜单编号；不带参数进入交互菜单。\n' "$TOOLBOX_VERSION"
}
load_modules() {
  local f
  for f in apps network system diagnostics hy2 webssh; do
    if [[ ! -r "$TOOLBOX_DIR/modules/$f.sh" ]]; then
      printf '错误：缺少模块 %s/modules/%s.sh。请下载完整项目。\n' "$TOOLBOX_DIR" "$f" >&2
      return 1
    fi
    # shellcheck source=/dev/null
    source "$TOOLBOX_DIR/modules/$f.sh"
  done
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
  printf 'A4 Hysteria 2\n 1 安装\n 2 卸载\n 3 状态\n请输入编号：'
  IFS= read -r c || return 1
  case "$c" in
    1) toolbox_hy2 install ;;
    2) toolbox_hy2 uninstall ;;
    3) toolbox_hy2 status ;;
    *) printf '无效选项。\n' ; return 1 ;;
  esac
}
menu() {
  local choice
  printf '\nTerry 服务器工具箱 %s\n启动不安装软件、不修改系统；功能执行前请检查提示。\n' "$TOOLBOX_VERSION"
  while :; do
    printf '\n网络服务\n A1 Alpine HY2  A2 Alpine Xray  A3 TUIC  A4 HY2  A5 Xray\n系统\n M1 BBR  M2 基础依赖  M3 重装系统  M4 重启\n常用工具\n B1 Docker  B2 NodeQuality  B3 Alist  B4 哪吒  B5 X-UI\n B6 swap  B7 流量限制  B8 改密码  B9 IT-Tools  B10 WebSSH\n B11 1Panel  B12 TCP Brutal  B13 MyIP  B14 回程测试\n B15 TG 流量通知  B16 网络优化  B17 Sun-panel  B18 预留\n B19 Alpine 工具  B20 Memos  B21 Nginx Proxy Manager  B22 Halo\n B23 DNS  B24 NginxWebUI  B25 Nexterm  B26 LibreTV\n B27 Stirling PDF  B28 网页验证  B29 DDNS-GO\n B30 Vaultwarden  B31 Relay\n 0 退出\n'
    printf '\n输入 DIAG 可查看只读体检。\n请输入编号：'
    if ! IFS= read -r choice; then printf '\n'; return 0; fi
    choice=${choice^^}
    case "$choice" in
      0|Q) return 0 ;;
      M1) choice=MAIN_BBR ;;
      M2) choice=MAIN_DEPS ;;
      M3) choice=MAIN_REINSTALL ;;
      M4) choice=MAIN_REBOOT ;;
    esac
    if [[ "$choice" != B18 ]]; then
      if ! load_modules; then continue; fi
    fi
    run_action "$choice" || printf '操作未完成或已取消。\n'
  done
}
case "${1-}" in
  --help|-h) show_help ;;
  --list) show_list ;;
  '') menu ;;
  *) printf '未知参数：%s\n' "$1" >&2; show_help >&2; exit 2 ;;
esac
