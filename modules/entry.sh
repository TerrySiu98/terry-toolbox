#!/usr/bin/env bash
# Source-only UI. Navigation references jht.one (jinhuaitao); independent implementation.

_tb_ui_init() {
  TB_RESET='' TB_BOLD='' TB_CYAN='' TB_BLUE='' TB_DIM='' TB_GREEN='' TB_YELLOW='' TB_RED=''
  if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
    TB_RESET=$'\033[0m' TB_BOLD=$'\033[1m' TB_CYAN=$'\033[96m' TB_BLUE=$'\033[94m'
    TB_DIM=$'\033[90m' TB_GREEN=$'\033[92m' TB_YELLOW=$'\033[93m' TB_RED=$'\033[91m'
  fi
  _tb_ui_size
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
_tb_ui_size() {
  local columns=${COLUMNS:-80} geometry='' measured=0
  TB_CURSOR=0
  if [[ -t 1 ]]; then
    [[ ${TERM:-dumb} == dumb ]] || TB_CURSOR=1
    if command -v stty >/dev/null 2>&1; then
      # Keep the terminal fd: command substitution itself has a pipe for stdout.
      { geometry=$(stty size <&3 2>/dev/null) || geometry=''; } 3<&1
      if [[ $geometry =~ ^[0-9]+[[:space:]]+([1-9][0-9]*)$ ]]; then
        columns=${BASH_REMATCH[1]}; measured=1
      fi
    fi
    if (( measured == 0 )) && command -v tput >/dev/null 2>&1; then
      geometry=$(tput cols 2>/dev/null) || geometry=''
      [[ -z $geometry ]] || columns=$geometry
    fi
  fi
  [[ $columns =~ ^[0-9]{1,4}$ ]] || columns=80
  columns=$((10#$columns))
  (( columns > 0 )) || columns=80
  (( columns > 78 )) && columns=78
  TB_COLUMNS=$columns
  TB_WIDTH=$((columns - 2))
  TB_PLAIN=0
  (( columns >= 20 )) || TB_PLAIN=1
  return 0
}
_tb_glyph() {
  local LC_ALL=C text=$1 offset=$2 lead=${1:$2:1} size=1
  TB_GLYPH_WIDTH=1
  # This is the menu's small character repertoire, not a Unicode wcwidth table.
  # Decode complete UTF-8 characters even when the SSH session uses LC_ALL=C.
  case "$lead" in
    [$'\xc2'-$'\xdf']) size=2;;
    [$'\xe0'-$'\xef'])
      size=3
      case "$lead" in [$'\xe3'-$'\xe9']|$'\xef') TB_GLYPH_WIDTH=2;; esac;;
    [$'\xf0'-$'\xf4']) size=4; TB_GLYPH_WIDTH=2;;
  esac
  TB_GLYPH=${text:offset:size}
  case "$TB_GLYPH" in
    '⏰'|'⚡'|'✅') TB_GLYPH_WIDTH=2;;
    $'\xef\xb8\x8f'|$'\xef\xb8\x8e') TB_GLYPH_WIDTH=0;;
  esac
  # VS16 belongs to the preceding glyph and requests its two-cell emoji form.
  # Keeping it attached also prevents a line break inside an emoji sequence.
  if [[ ${text:offset+size:3} == $'\xef\xb8\x8f' ]]; then
    TB_GLYPH+=${text:offset+size:3}; ((size+=3)); TB_GLYPH_WIDTH=2
  fi
  TB_GLYPH_BYTES=$size
}
_tb_display_width() {
  local LC_ALL=C text=$1 offset=0
  TB_TEXT_WIDTH=0
  while (( offset < ${#text} )); do
    _tb_glyph "$text" "$offset"
    (( TB_TEXT_WIDTH += TB_GLYPH_WIDTH, offset += TB_GLYPH_BYTES ))
  done
  return 0
}
_tb_wrap() {
  local LC_ALL=C text=$1 limit=$2 offset=0 line='' width=0
  # A complete CJK/emoji glyph needs two cells, even on a one-column terminal.
  (( limit >= 2 )) || limit=2
  TB_TEXT_LINES=() TB_LINE_WIDTHS=()
  while (( offset < ${#text} )); do
    _tb_glyph "$text" "$offset"
    if [[ $TB_GLYPH == $'\n' ]]; then
      TB_TEXT_LINES+=("$line"); TB_LINE_WIDTHS+=("$width"); line=''; width=0
    else
      if (( width + TB_GLYPH_WIDTH > limit )) && [[ -n $line ]]; then
        TB_TEXT_LINES+=("$line"); TB_LINE_WIDTHS+=("$width"); line=''; width=0
      fi
      line+=$TB_GLYPH; (( width += TB_GLYPH_WIDTH ))
    fi
    (( offset += TB_GLYPH_BYTES ))
  done
  TB_TEXT_LINES+=("$line"); TB_LINE_WIDTHS+=("$width")
}
_tb_repeat() { local n=$1 ch=$2 i; for ((i=0;i<n;i++)); do printf '%s' "$ch"; done; }
_tb_top() {
  (( TB_PLAIN == 0 )) || return 0
  printf ' %s%s%s' "$TB_BLUE" "$1" "$TB_RESET"
  _tb_repeat "$((TB_WIDTH-2))" '═'
  printf '%s%s%s\n' "$TB_BLUE" "$2" "$TB_RESET"
}
_tb_sep() { _tb_top '╠' '╣'; }
_tb_bot() { _tb_top '╚' '╝'; }
_tb_row_end() {
  _tb_repeat "$1" ' '
  printf ' '
  # Terminal emoji width varies. Place the border at its column independently.
  if (( TB_CURSOR )); then printf '\033[%dG' "$((TB_WIDTH+1))"; fi
  printf '%s║%s\n' "$TB_BLUE" "$TB_RESET"
}
_tb_print_rows() {
  local text=$1 color=$2 mode=$3 limit=$((TB_WIDTH-4)) i left width
  if (( TB_PLAIN )) || [[ $mode == plain ]]; then limit=$((TB_COLUMNS-1)); mode=plain; fi
  _tb_wrap "$text" "$limit"
  for ((i=0; i<${#TB_TEXT_LINES[@]}; i++)); do
    text=${TB_TEXT_LINES[i]}; width=${TB_LINE_WIDTHS[i]}; left=0
    if [[ $mode == plain ]]; then
      printf '%s%s%s\n' "$color" "$text" "$TB_RESET"
    else
      if [[ $mode == center ]]; then left=$(((limit-width)/2)); fi
      printf ' %s║%s ' "$TB_BLUE" "$TB_RESET"
      _tb_repeat "$left" ' '
      printf '%s%s%s' "$color" "$text" "$TB_RESET"
      _tb_row_end "$((limit-width-left))"
    fi
  done
}
_tb_row() { _tb_print_rows "$1" "${2:-$TB_RESET}" left; }
_tb_center() { _tb_print_rows "$1" "${2:-$TB_RESET}" center; }
_tb_plain() { _tb_print_rows "$1" "${2:-$TB_RESET}" plain; }
_tb_pair() {
  local left=$1 right=${2:-} target=$(((TB_WIDTH-8)/2)) left_width right_width text
  _tb_display_width "$left"; left_width=$TB_TEXT_WIDTH
  _tb_display_width "$right"; right_width=$TB_TEXT_WIDTH
  if (( TB_WIDTH < 64 || left_width >= target || target+right_width > TB_WIDTH-4 )) || [[ -z $right ]]; then
    _tb_row "$left"; [[ -z $right ]] || _tb_row "$right"
  elif (( TB_CURSOR )); then
    printf ' %s║%s %s' "$TB_BLUE" "$TB_RESET" "$left"
    _tb_repeat "$((target-left_width))" ' '
    printf '\033[%dG%s' "$((4+target))" "$right"
    _tb_row_end "$((TB_WIDTH-4-target-right_width))"
  else
    printf -v text '%s%*s%s' "$left" "$((target-left_width))" '' "$right"
    _tb_row "$text"
  fi
}
_tb_head() { printf '\n'; _tb_top '╔' '╗'; _tb_center "$1" "$TB_BOLD$TB_BLUE"; _tb_sep; }
_tb_line() { _tb_row "$@"; }
_tb_border() { _tb_sep; }
_tb_finish() { _tb_bot; }
_tb_redraw() {
  _tb_ui_size
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
  _tb_pair '⚡ 2. BBR 管理' '🛠️  5. 常用工具'
  _tb_pair '📦 3. 安装基础依赖' '🔄 99. 重新启动'
  _tb_pair '🩺  DIAG 只读体检' '🚪 0. 退出脚本'
  _tb_row '🔐 TLS 证书管理（本地开发）'
  _tb_bot
  if (( TB_WIDTH < 64 )); then
    printf '\n'
    _tb_plain ' · 输入编号回车；A1 / B9 快捷可用' "$TB_DIM"
    _tb_plain ' · 修改前会提示影响并确认' "$TB_DIM"
    printf '\n'
  else
    printf '\n'
    _tb_plain ' · 输入编号回车；完整编号 A1 / B9 也可直接输入' "$TB_DIM"
    _tb_plain ' · 安装、修改和重启前会显示影响并二次确认' "$TB_DIM"
    printf '\n'
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
  _tb_plain ' Alpine 两项仅在 Alpine + OpenRC 可用。' "$TB_DIM"
  printf '\n'
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
  if (( TB_COLUMNS < 8 )); then
    printf '%s>%s' "$TB_CYAN" "$TB_RESET"
  elif (( TB_COLUMNS < 32 )); then
    printf '%s选择：%s' "$TB_CYAN" "$TB_RESET"
  else
    printf ' %s🎯%s 请输入数字选择操作：' "$TB_CYAN" "$TB_RESET"
  fi
  IFS= read -r TB_CHOICE || { printf '\n'; return 1; }
  TB_CHOICE=${TB_CHOICE^^}
}
_tb_pause() {
  if [[ -t 0 && -t 1 ]]; then
    local answer
    if (( TB_COLUMNS < 40 )); then
      printf '\n'
      _tb_plain '操作结束，按回车返回当前菜单…' "$TB_DIM"
    else
      printf '\n %s↩  操作结束，按回车返回当前菜单…%s' "$TB_DIM" "$TB_RESET"
    fi
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
