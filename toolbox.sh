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
      if ! curl -fsSL --proto '=https' --proto-redir '=https' https://sh.uw.cx >"$_tb_tmp"; then
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
  for f in dependencies apps network system diagnostics hy2 webssh vmess alpine-swap docker-ipv6 webssh-containers tls-acme reinstall-provenance reinstall; do
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
    A1|A2|A3|A4|A5|B12|B23|B31) toolbox_network "$key" ;;
    B3|B4|B5|B9|B13|B17|B20|B21|B22|B24|B25|B26|B27|B28|B29|B30) toolbox_app "${key#B}" ;;
    MAIN_BBR|MAIN_DEPS|MAIN_REINSTALL|MAIN_REBOOT|B1|B2|B6|B7|B8|B11|B14|B15|B16|B19) toolbox_system "$key" ;;
    B10) toolbox_webssh ;;
    TLS) _toolbox_tls_acme status ;;
    B18) printf 'B18：预留，暂未实现。\n' ; return 1 ;;
    *) printf '无效选项：%s\n' "$key" ; return 1 ;;
  esac
}
_tb_managed_key() {
  case "$1" in A[1-5]|B1|B10|B12|B16|B19|B23|B31|MAIN_REINSTALL|TLS) return 0;; *) return 1;; esac
}
_toolbox_webssh_container() {
  declare -F toolbox_webssh_container >/dev/null || { printf 'WebSSH 容器模块未加载。\n' >&2; return 1; }
  toolbox_webssh_container "$@"
}
_toolbox_tls_acme() {
  declare -F toolbox_tls_acme >/dev/null || { printf 'TLS ACME 模块未加载。\n' >&2; return 1; }
  toolbox_tls_acme "$@"
}
_tb_reinstall_target() {
  local choice
  printf '重装目标：1 Debian 13；2 Ubuntu 24.04；3 Alpine 3.24；0 取消\n选择：' >&2
  IFS= read -r choice || { printf '输入结束，已取消。\n' >&2; return 1; }
  case "$choice" in
    1) printf 'debian 13\n';;
    2) printf 'ubuntu 24.04\n';;
    3) printf 'alpine 3.24\n';;
    *) printf '已取消。\n' >&2; return 1;;
  esac
}
_tb_service_screen() {
  local title
  case "$1" in
    A1) title='A1 Alpine Hysteria 2';; A2) title='A2 Alpine Xray';;
    A3) title='A3 TUIC';; A4) title='A4 Hysteria 2';; A5) title='A5 Xray';;
    B1) title='B1 Docker';; B10) title='B10 WebSSH';; B12) title='B12 TCP Brutal';;
    MAIN_REINSTALL) title='M3 系统重装';; TLS) title='TLS 证书管理';;
    B16) title='B16 网络优化';; B19) title='B19 Alpine 工具';;
    B23) title='B23 DNS 切换';; B31) title='B31 Relay 转发';;
  esac
  _tb_head "$title"
  case "$1" in
    A5)
      _tb_row '📦 1. 安装 REALITY'; _tb_row '🗑️  2. 卸载 REALITY'; _tb_row '🩺 3. REALITY 状态'
      _tb_row '📦 4. 安装 VMess + WS'; _tb_row '🗑️  5. 卸载 VMess + WS'; _tb_row '🩺 6. VMess + WS 状态'
      _tb_row '🔄 7. VMess 开机自启'; _tb_row '⏸️  8. 关闭 VMess 自启'; _tb_row '🩺 9. VMess 自启状态'
      _tb_row '🔐 10. 更新 VMess 证书';;
    B1)
      _tb_row '📦 1. 安装 Docker'; _tb_row '🌐 2. 配置 Docker IPv6'
      _tb_row '🩺 3. IPv6 状态'; _tb_row '↩️  4. 回滚 IPv6 配置';;
    B10)
      _tb_row '📦 1. 安装 WebSSH'; _tb_row '🗑️  2. 卸载 WebSSH'; _tb_row '🩺 3. WebSSH 状态'
      _tb_row '📦 4. 安装个人版'; _tb_row '🗑️  5. 卸载个人版'; _tb_row '🩺 6. 个人版状态'
      _tb_row '📦 7. 安装 Easynode'; _tb_row '🗑️  8. 卸载 Easynode'; _tb_row '🩺 9. Easynode 状态';;
    MAIN_REINSTALL)
      _tb_row '🩺 1. 重装预检'; _tb_row '💽 2. 准备重装（毁损风险）'
      _tb_row '🩺 3. 重装计划状态'; _tb_row '↩️  4. 取消本工具重装计划'
      _tb_row '⚠️  不自动重启，不用于业务机试验';;
    TLS)
      _tb_row '🔐 1. 申请证书'; _tb_row '🩺 2. 证书状态'; _tb_row '🔄 3. 手动续期'
      _tb_row '⏰ 4. 启用自动续期'; _tb_row '⏸️  5. 关闭自动续期'; _tb_row '📤 6. 同步至 VMess';;
    B16) _tb_row '🚀 1. 应用优化参数'; _tb_row '↩️  2. 回滚到应用前';;
    B19)
      _tb_row '🖥️  1. Webtop 桌面容器'; _tb_row '🔀 2. UDP 端口跳跃'
      _tb_row '↩️  3. 移除端口跳跃'; _tb_row '💾 4. 安装 swap'
      _tb_row '🗑️  5. 卸载 swap'; _tb_row '🩺 6. swap 状态';;
    B23)
      _tb_row '🌐 1. Cloudflare DNS'; _tb_row '🌐 2. Google DNS'; _tb_row '🌐 3. Quad9 DNS'
      _tb_row '🌐 4. 阿里 DNS'; _tb_row '🌐 5. 腾讯 DNS'; _tb_row '✍️  6. 自定义 DNS'
      _tb_row '↩️  7. 恢复原状'; _tb_row '🩺 8. 查看状态';;
    *) _tb_row '📦 1. 安装'; _tb_row '🗑️  2. 卸载'; _tb_row '🩺 3. 查看状态';;
  esac
  _tb_sep; _tb_row '↩️  0. 返回上一层'; _tb_bot
  printf '\n'
}
_tb_service_choice_valid() {
  case "$1" in
    A5) [[ $2 =~ ^([1-9]|10)$ ]];;
    B1|MAIN_REINSTALL) [[ $2 =~ ^[1-4]$ ]];; B10) [[ $2 =~ ^[1-9]$ ]];;
    TLS) [[ $2 =~ ^[1-6]$ ]];;
    B16) [[ $2 =~ ^[12]$ ]];; B19) [[ $2 =~ ^[1-6]$ ]];;
    B23) [[ $2 =~ ^[1-8]$ ]];; *) [[ $2 =~ ^[1-3]$ ]];;
  esac
}
run_service_action() {
  local key=$1 choice=$2 action
  local input servers=()
  case "$key" in
    A5)
      case "$choice" in
        1) action=install;; 2) action=uninstall;; 3) action=status;;
        4) action=install-ws;; 5) action=uninstall-ws;; 6) action=status-ws;;
        7) action=enable-boot-ws;; 8) action=disable-boot-ws;; 9) action=boot-status-ws;;
        10)
          local cert keyfile
          printf '新证书完整链路径（PEM）：'
          IFS= read -r cert || { printf '输入结束，已取消。\n' >&2; return 1; }
          printf '新私钥路径（无口令 PEM）：'
          IFS= read -r keyfile || { printf '输入结束，已取消。\n' >&2; return 1; }
          [[ -n $cert && -n $keyfile ]] || { printf '路径不能为空，已取消。\n' >&2; return 1; }
          toolbox_network A5 update-cert-ws "$cert" "$keyfile"; return $?;;
      esac
      toolbox_network A5 "$action" ;;
    B1)
      case "$choice" in
        1) _toolbox_system_docker;;
        2) _toolbox_system_docker_ipv6 apply;;
        3) _toolbox_system_docker_ipv6 status;;
        4) _toolbox_system_docker_ipv6 restore;;
      esac ;;
    B10)
      case "$choice" in
        1) toolbox_webssh install;; 2) toolbox_webssh uninstall;; 3) toolbox_webssh status;;
        4) _toolbox_webssh_container personal install;; 5) _toolbox_webssh_container personal uninstall;; 6) _toolbox_webssh_container personal status;;
        7) _toolbox_webssh_container easynode install;; 8) _toolbox_webssh_container easynode uninstall;; 9) _toolbox_webssh_container easynode status;;
      esac ;;
    MAIN_REINSTALL)
      local target distro version
      case "$choice" in
        1|2)
          target=$(_tb_reinstall_target) || return 1
          read -r distro version <<< "$target"
          if [[ $choice == 1 ]]; then _toolbox_system_reinstall preflight "$distro"
          else _toolbox_system_reinstall prepare "$distro" "$version"; fi;;
        3) _toolbox_system_reinstall status;; 4) _toolbox_system_reinstall cancel;;
      esac ;;
    TLS)
      case "$choice" in
        1) action=issue;; 2) action=status;; 3) action=renew;;
        4) action=enable-renewal;; 5) action=disable-renewal;; 6) action=deploy-vmess;;
      esac
      _toolbox_tls_acme "$action" ;;
    B16)
      case "$choice" in
        1) ( set -e; _toolbox_system_netopt_apply );;
        2) ( set -e; _toolbox_system_netopt_rollback );;
      esac ;;
    B19)
      case "$choice" in
        1) ( set -e; _toolbox_system_alpine_webtop );;
        2) ( set -e; _toolbox_system_alpine_hop_apply );;
        3) ( set -e; _toolbox_system_alpine_hop_remove );;
        4) _toolbox_system_alpine_swap install;;
        5) _toolbox_system_alpine_swap uninstall;;
        6) _toolbox_system_alpine_swap status;;
      esac ;;
    B23)
      case "$choice" in
        [1-5])
          input=$(net_dns_preset "$choice") || return 1
          read -r -a servers <<< "$input"
          toolbox_network B23 install "${servers[@]}" ;;
        6)
          printf '输入 1-2 个 IPv4/IPv6 地址（空格或逗号分隔）：'
          IFS= read -r input || { printf '\n没有收到输入，已取消。\n' >&2; return 1; }
          input=${input//,/ }
          read -r -a servers <<< "$input"
          toolbox_network B23 install "${servers[@]}" ;;
        7) toolbox_network B23 restore;; 8) toolbox_network B23 status;;
      esac ;;
    *)
      case "$choice" in 1) action=install;; 2) action=uninstall;; 3) action=status;; esac
      if [[ $key == B10 ]]; then toolbox_webssh "$action"; else toolbox_network "$key" "$action"; fi ;;
  esac
}
menu() {
  local choice screen=main key booted=0 service='' parent=main notice=''
  _tb_ui_init
  while :; do
    _tb_redraw
    case "$screen" in
      main) _tb_main_screen;; network) _tb_network_screen;; apps) _tb_apps_screen;;
      service) _tb_service_screen "$service";;
    esac
    if (( booted == 0 )); then booted=1; _tb_bootstrap || true; printf '\n'; fi
    if [[ -n $notice ]]; then printf '\n %s%s%s\n\n' "$TB_YELLOW" "$notice" "$TB_RESET"; notice=''; fi
    _tb_read_choice || return 0
    choice=$TB_CHOICE
    case "$choice" in
      0|Q)
        if [[ $screen == service ]]; then screen=$parent; service=''; continue; fi
        if [[ $screen != main ]]; then screen=main; continue; fi
        _tb_bye; return 0 ;;
    esac
    if [[ $screen == service && $choice =~ ^[0-9]+$ ]]; then
      if ! _tb_service_choice_valid "$service" "$choice"; then notice='无效的选择，请按菜单编号输入。'; continue; fi
      load_modules || { notice='模块加载失败，请检查项目文件。'; continue; }
      printf '\n'
      run_service_action "$service" "$choice" || printf '\n %s操作未完成或已取消。%s\n' "$TB_YELLOW" "$TB_RESET"
      _tb_pause || return 0
      continue
    fi
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
      DIAG|TLS|MAIN_BBR|MAIN_DEPS|MAIN_REINSTALL|MAIN_REBOOT|A[1-5]|B[1-9]|B[12][0-9]|B3[01]) ;;
      *) notice='无效的选择，请按菜单编号输入。'; continue;;
    esac
    if _tb_managed_key "$key"; then
      [[ $screen == service ]] || parent=$screen
      service=$key; screen=service; continue
    fi
    if [[ "$key" != B18 ]]; then
      if ! load_modules; then continue; fi
    fi
    printf '\n'
    run_action "$key" || printf '\n %s操作未完成或已取消。%s\n' "$TB_YELLOW" "$TB_RESET"
    _tb_pause || return 0
  done
}
case "${1-}" in
  --help|-h) show_help ;;
  --list) show_list ;;
  '') menu ;;
  *) printf '未知参数：%s\n' "$1" >&2; show_help >&2; exit 2 ;;
esac
