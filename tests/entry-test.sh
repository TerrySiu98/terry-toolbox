#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
safetyroot=$(mktemp -d)
trap 'rc=$?; if [[ -s $safetyroot/packages.log ]]; then printf "FAIL: entry invoked an unmocked package command\n" >&2; cat "$safetyroot/packages.log" >&2; rc=1; fi; rm -rf -- "$safetyroot"; exit "$rc"' EXIT
mkdir "$safetyroot/bin"
: > "$safetyroot/packages.log"
for manager in sudo apt apt-get apt-cache aptitude apk dpkg dpkg-query dpkg-deb; do
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$0 $*" >> %q\n' "$safetyroot/packages.log"
    printf 'printf "UNMOCKED package boundary: %%s\\n" "$0" >&2\nexit 99\n'
  } > "$safetyroot/bin/$manager"
  chmod 0755 "$safetyroot/bin/$manager"
done
export PATH="$safetyroot/bin:$PATH"
# Entry rendering/dispatch never needs elevation; sudo must stay unreachable.
export TOOLBOX_ELEVATED=1
package_guard_probe='for manager in sudo apt apt-get apk dpkg; do [[ $(command -v "$manager") == "$1/$manager" ]] || exit 1; rc=0; "$manager" --fixture-guard-probe || rc=$?; [[ $rc == 99 ]] || exit 1; done'
bash --noprofile --norc -c "$package_guard_probe" guard "$safetyroot/bin" >/dev/null 2>&1
env -i PATH="$PATH" bash --noprofile --norc -c "$package_guard_probe" guard "$safetyroot/bin" >/dev/null 2>&1
[[ $(wc -l < "$safetyroot/packages.log") == 10 ]]
: > "$safetyroot/packages.log"
script="$root/toolbox.sh"
test -f "$script" || { printf 'FAIL: toolbox.sh missing\n'; exit 1; }
bash -n "$script"
help=$(bash "$script" --help)
[[ "$help" == *'--list'* ]] || { printf 'FAIL: --help\n'; exit 1; }
list=$(bash "$script" --list | tr '\n' ' ')
for item in A1 A2 A3 A4 A5 B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 B11 B12 B13 B14 B15 B16 B17 B18 B19 B20 B21 B22 B23 B24 B25 B26 B27 B28 B29 B30 B31; do
  [[ " $list " == *" $item "* ]] || { printf 'FAIL: missing %s\n' "$item"; exit 1; }
done
out=$(printf '0\n' | bash "$script")
[[ "$out" == *'Terry'* ]] || { printf 'FAIL: menu\n'; exit 1; }
out=$(printf 'DIAG\n0\n' | bash "$script")
[[ "$out" == *'=== 系统 ==='* ]] || { printf 'FAIL: diagnostic dispatch\n'; exit 1; }
out=$(printf 'B18\n0\n' | bash "$script")
[[ "$out" == *'预留，暂未实现'* ]] || { printf 'FAIL: reserved entry\n'; exit 1; }
printf 'entry tests passed\n'
