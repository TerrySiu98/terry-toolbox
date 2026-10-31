#!/usr/bin/env bash
# Source-only UI. Navigation references jht.one (jinhuaitao); independent implementation.

_tb_ui_init() {
  TB_RESET='' TB_BOLD='' TB_CYAN='' TB_BLUE='' TB_DIM='' TB_GREEN='' TB_YELLOW='' TB_RED=''
  if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
    TB_RESET=$'\033[0m' TB_BOLD=$'\033[1m' TB_CYAN=$'\033[96m' TB_BLUE=$'\033[94m'
    TB_DIM=$'\033[90m' TB_GREEN=$'\033[92m' TB_YELLOW=$'\033[93m' TB_RED=$'\033[91m'
  fi
  local columns=${COLUMNS:-80}
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then columns=$(tput cols 2>/dev/null) || columns=80; fi
  [[ $columns =~ ^[0-9]+$ ]] || columns=80
  (( columns > 78 )) && columns=78
  (( columns < 32 )) && columns=32
  TB_WIDTH=$((columns - 2))
  TB_OS='Linux' TB_OS_ID='unknown'
  local line val release=${TOOLBOX_OS_RELEASE:-/etc/os-release}
  if [[ -r $release ]]; then
    while IFS= read -r line; do
      case "$line" in
        PRETTY_NAME=*|ID=*)
          val=${line#*=}; val=${val#\"}; val=${val%\"}; val=${val#\'}; val=${val%\'}
          # OS metadata is parsed as data; strip anything that could move the cursor.
          val=${val//[^a-zA-Z0-9 ._()\/+-]/}
          case "$line" in PRETTY_NAME=*) TB_OS=$val;; ID=*) TB_OS_ID=$val;; esac
          ;;
      esac
    done < "$release"
  fi
  TB_ARCH=$(uname -m 2>/dev/null) || TB_ARCH='unknown'
  TB_TERRY_ART=(
    '██████  █████   █████   █████   ██  ██'
    '  ██    ██      ██  ██  ██  ██  ██  ██'
    '  ██    ████    █████   █████    ███  '
    '  ██    ██      ██ ██   ██ ██      ██  '
    '  ██    █████   ██  ██  ██  ██     ██  '
  )
}
_tb_display_width() {
  local LC_ALL=C
  local text=${1//$'\xef\xb8\x8f'/} i char n=0
  # Byte-based so alignment holds under LC_ALL=C or a C-locale SSH login.
  # Box drawing (U+2500 block, 3 bytes) is one column; only CJK and emoji are two.
  for ((i=0; i<${#text}; i++)); do
    char=${text:i:1}
    case "$char" in
      [$'\x80'-$'\xbf']) ;;                  # continuation byte
      [$'\xe3'-$'\xe9']) ((n+=2));;           # CJK ideograph / CJK punctuation
      [$'\xe2'])
        case ${text:i+1:1} in [$'\x98'-$'\x9f']) ((n+=2));; *) ((n+=1));; esac ;;
      [$'\xef']) ((n+=2));;                   # fullwidth forms
      [$'\xf0'-$'\xf3']) ((n+=2));;           # emoji
      [$'\xc2'-$'\xdf']) ((n+=1));;           # Latin-1 punctuation (·, …)
      *) ((n+=1));;
    esac
  done
  TB_TEXT_WIDTH=$n
}
_tb_repeat() { local n=$1 ch=$2 i; for ((i=0;i<n;i++)); do printf '%s' "$ch"; done; }
_tb_top()  { printf ' %s%s%s' "$TB_BLUE" "$1" "$TB_RESET"; _tb_repeat "$((TB_WIDTH-2))" '═'; printf '%s%s%s\n' "$TB_BLUE" "$2" "$TB_RESET"; }
_tb_sep()  { printf ' %s╠' "$TB_BLUE"; _tb_repeat "$((TB_WIDTH-2))" '═'; printf '╣%s\n' "$TB_RESET"; }
_tb_bot()  { printf ' %s╚' "$TB_BLUE"; _tb_repeat "$((TB_WIDTH-2))" '═'; printf '╝%s\n' "$TB_RESET"; }
_tb_row() {
  local text=$1 color=${2:-$TB_RESET} padding
  _tb_display_width "$text"
  padding=$((TB_WIDTH - TB_TEXT_WIDTH - 4)); (( padding < 0 )) && padding=0
  printf ' %s║%s %s%s%s' "$TB_BLUE" "$TB_RESET" "$color" "$text" "$TB_RESET"
  _tb_repeat "$padding" ' '
  printf ' %s║%s\n' "$TB_BLUE" "$TB_RESET"
}
_tb_center() {
  local text=$1 color=${2:-$TB_RESET} left right
  _tb_display_width "$text"
  left=$(( (TB_WIDTH - TB_TEXT_WIDTH - 4) / 2 )); (( left < 0 )) && left=0
  right=$(( TB_WIDTH - TB_TEXT_WIDTH - 4 - left )); (( right < 0 )) && right=0
  printf ' %s║%s ' "$TB_BLUE" "$TB_RESET"; _tb_repeat "$left" ' '
  printf '%s%s%s' "$color" "$text" "$TB_RESET"; _tb_repeat "$right" ' '
  printf ' %s║%s\n' "$TB_BLUE" "$TB_RESET"
}
_tb_pair() {
  local left=$1 right=${2:-} target=$(((TB_WIDTH - 8)/2)) padding text
  if (( TB_WIDTH < 64 )) || [[ -z $right ]]; then
    _tb_row "$left"; [[ -z $right ]] || _tb_row "$right"
  else
    _tb_display_width "$left"; padding=$((target-TB_TEXT_WIDTH)); (( padding < 1 )) && padding=1
    printf -v text '%s%*s%s' "$left" "$padding" '' "$right"
    _tb_row "$text"
  fi
}
_tb_head() { printf '\n'; _tb_top '╔' '╗'; _tb_center "$1" "$TB_BOLD$TB_BLUE"; _tb_sep; }
_tb_line() { _tb_row "$@"; }
_tb_border() { _tb_sep; }
_tb_finish() { _tb_bot; }
_tb_redraw() {
  # Replace the visible page only; never erase the operator's terminal scrollback.
  if [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb && -z ${TOOLBOX_NO_CLEAR:-} ]]; then printf '\033[H\033[2J'; fi
  return 0
}
_tb_banner() {
  printf '\n'
  _tb_top '╔' '╗'
  local art
  if (( TB_WIDTH >= 46 )); then
    _tb_center ' '
    for art in "${TB_TERRY_ART[@]}"; do _tb_center "$art" "$TB_BOLD$TB_BLUE"; done
    _tb_center ' '
    _tb_center 'T E R R Y   T O O L B O X' "$TB_BOLD$TB_CYAN"
  else
    _tb_center ' '
    _tb_center 'TERRY TOOLBOX' "$TB_BOLD$TB_CYAN"
  fi
  _tb_center '服务器工具箱 · 启动先检测依赖' "$TB_DIM"
  _tb_sep
  if (( TB_WIDTH >= 60 )); then
    _tb_center "$TB_OS   $TB_ARCH   $TOOLBOX_VERSION" "$TB_DIM"
  else
    _tb_center "$TB_ARCH   $TOOLBOX_VERSION" "$TB_DIM"
  fi
  _tb_bot
  printf '\n'
}
_tb_main_screen() {
  _tb_banner
  _tb_head '请选择要执行的操作'
  _tb_pair '🌐 1. 网络服务' '💽 4. 重装系统'
  _tb_pair '⚡ 2. 安装 BBR' '🛠️  5. 常用工具'
  _tb_pair '📦 3. 安装基础依赖' '🔄 99. 重新启动'
  _tb_pair '🩺  DIAG 只读体检' '🚪 0. 退出脚本'
  _tb_row '🔐 TLS 证书管理（本地开发）'
  _tb_bot
  if (( TB_WIDTH < 64 )); then
    printf '\n %s· 输入编号回车；A1 / B9 快捷可用%s\n' "$TB_DIM" "$TB_RESET"
    printf ' %s· 修改前会提示影响并确认%s\n\n' "$TB_DIM" "$TB_RESET"
  else
    printf '\n %s· 输入编号回车；完整编号 A1 / B9 也可直接输入%s\n' "$TB_DIM" "$TB_RESET"
    printf ' %s· 安装、修改和重启前会显示影响并二次确认%s\n\n' "$TB_DIM" "$TB_RESET"
  fi
}
_tb_network_screen() {
  _tb_head '🌐 网络服务'
  _tb_row '📡 1. Alpine 版 HY2'
  _tb_row '📡 2. Alpine 版 Xray'
  _tb_row '📡 3. TUIC 服务'
  _tb_row '📡 4. HY2 服务'
  _tb_row '📡 5. Xray 服务'
  _tb_sep
  _tb_row '↩️  0. 返回主菜单'
  _tb_bot; printf '\n'
  printf ' %sAlpine 两项仅在 Alpine + OpenRC 可用。%s\n\n' "$TB_DIM" "$TB_RESET"
}
_tb_apps_screen() {
  _tb_head '🛠️  常用工具'
  _tb_pair '🐳 1. Docker' '🧰 9. IT-Tools'
  _tb_pair '📊 2. NodeQuality' '🔐 10. WebSSH'
  _tb_pair '📁 3. Alist' '🧱 11. 1Panel'
  _tb_pair '🐱 4. 哪吒面板' '⚙️  12. TCP Brutal'
  _tb_pair '🪪 5. X-UI' '🌍 13. MyIP'
  _tb_pair '💾 6. 虚拟内存' '🛰️  14. 回程测试'
  _tb_pair '📈 7. 流量告警' '📨 15. TG 通知'
  _tb_pair '🔑 8. 修改密码' '🚀 16. 网络优化'
  _tb_sep
  _tb_pair '🧭 17. Sun-panel' '🏔️  19. Alpine 工具'
  _tb_pair '📝 20. Memos' '🔀 21. NPM'
  _tb_pair '✍️  22. Halo' '🌐 23. DNS 切换'
  _tb_pair '🧩 24. NginxWebUI' '🖥️  25. Nexterm'
  _tb_pair '📺 26. LibreTV' '📄 27. Stirling PDF'
  _tb_pair '✅ 28. 网页验证' '🧬 29. DDNS-GO'
  _tb_pair '🔒 30. 密码管理器' '🔁 31. Relay 转发'
  _tb_sep
  _tb_pair '🕳️  18. 预留' '↩️  0. 返回主菜单'
  _tb_bot; printf '\n'
}
_tb_read_choice() {
  printf ' %s🎯%s 请输入数字选择操作：' "$TB_CYAN" "$TB_RESET"
  IFS= read -r TB_CHOICE || { printf '\n'; return 1; }
  TB_CHOICE=${TB_CHOICE^^}
}
_tb_pause() {
  if [[ -t 0 && -t 1 ]]; then
    local answer
    printf '\n %s↩  操作结束，按回车返回当前菜单…%s' "$TB_DIM" "$TB_RESET"
    IFS= read -r answer || return 1
  fi
}
_tb_bye() {
  printf '\n'
  _tb_top '╔' '╗'
  _tb_center '👋  感谢使用 Terry Toolbox' "$TB_BOLD$TB_CYAN"
  _tb_center ' '
  _tb_center '期待下次见，留好备用登录方式。' "$TB_DIM"
  _tb_center ' '
  _tb_bot
  printf '\n'
}
_tb_bootstrap_has() { command -v "$1" >/dev/null 2>&1; }
_tb_bootstrap_exec() { "$@" </dev/null; }
_tb_bootstrap() {
  # Interactive startup only. --help, --list and piped runs never install anything.
  [[ -t 0 && -t 1 ]] || return 0
  local command answer missing=() packages=() package manager=''
  for command in curl wget socat sudo nano openssl tar ss; do
    _tb_bootstrap_has "$command" || missing+=("$command")
  done
  if (( ${#missing[@]} == 0 )); then
    if (( TB_WIDTH < 60 )); then
      printf ' %s✓%s 基础依赖已齐全\n' "$TB_GREEN" "$TB_RESET"
    else
      printf ' %s✓%s 基础依赖已齐全 · %s · %s\n' "$TB_GREEN" "$TB_RESET" "$TB_OS" "$TB_ARCH"
    fi
    return 0
  fi
  case "$TB_OS_ID" in
    alpine) manager=apk;;
    debian|ubuntu) manager=apt-get;;
    centos|rhel|rocky|almalinux|fedora) if _tb_bootstrap_has dnf; then manager=dnf; else manager=yum; fi;;
  esac
  printf ' %s⚠%s 系统 %s · %s\n' "$TB_YELLOW" "$TB_RESET" "$TB_OS" "$TB_ARCH"
  printf ' %s缺少%s：%s\n' "$TB_YELLOW" "$TB_RESET" "${missing[*]}"
  if [[ -z $manager ]] || ! _tb_bootstrap_has "$manager"; then
    printf ' 未找到支持的包管理器，跳过安装；各功能会自行检查依赖。\n'
    return 0
  fi
  for command in "${missing[@]}"; do
    package=$command
    if [[ $command == ss ]]; then
      case $manager in apk) package=iproute2-ss;; apt-get) package=iproute2;; dnf|yum) package=iproute;; esac
    fi
    packages+=("$package")
  done
  printf ' 将用 %s 只补缺失项（不升级系统）。按 Y 安装，其他键跳过：' "$manager"
  IFS= read -r answer || return 0
  [[ ${answer^^} == Y ]] || { printf ' %s已跳过%s，稍后可从 [3] 安装。\n' "$TB_DIM" "$TB_RESET"; return 0; }
  (( EUID == 0 )) || { printf ' %s安装依赖需要 root%s；未执行。\n' "$TB_RED" "$TB_RESET"; return 1; }
  case "$manager" in
    apt-get) _tb_bootstrap_exec apt-get update && _tb_bootstrap_exec apt-get install -y --no-upgrade -- "${packages[@]}";;
    apk) _tb_bootstrap_exec apk add --no-cache -- "${packages[@]}";;
    dnf|yum) _tb_bootstrap_exec "$manager" install -y -- "${packages[@]}";;
  esac || { printf ' %s装依赖失败%s，可检查软件源后从 [3] 重试。\n' "$TB_RED" "$TB_RESET" >&2; return 1; }
  missing=()
  for command in curl wget socat sudo nano openssl tar ss; do _tb_bootstrap_has "$command" || missing+=("$command"); done
  (( ${#missing[@]} == 0 )) || { printf ' %s仍缺少%s：%s\n' "$TB_RED" "$TB_RESET" "${missing[*]}" >&2; return 1; }
  printf ' %s✓%s 依赖检查通过。\n' "$TB_GREEN" "$TB_RESET"
}
