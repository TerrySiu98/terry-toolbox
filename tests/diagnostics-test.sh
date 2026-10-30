#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/modules/diagnostics.sh"
out=$(toolbox_diagnostics)
for item in '系统' '运行时间' '内存' '磁盘' '网络'; do
  [[ "$out" == *"$item"* ]] || { printf 'FAIL: missing %s\n' "$item" >&2; exit 1; }
done
printf 'diagnostics tests passed\n'
