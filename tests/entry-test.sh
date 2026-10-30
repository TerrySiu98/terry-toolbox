#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
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
