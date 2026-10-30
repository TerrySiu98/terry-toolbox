#!/usr/bin/env bash
# Real-bytes check: fetch the pinned upstream file for real, but do not run it.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/modules/system.sh"
_toolbox_system_root() { return 0; }
_toolbox_system_confirm() { return 0; }
log=$(mktemp)
trap 'rm -f "$log"' EXIT
bash() { printf 'exec %s cwd=%s\n' "$*" "$PWD" >> "$log"; return 1; }
tmp=$(mktemp -d)
out=$( tool 2>/dev/null; true )
printf 'YES\nYES\n' | TMPDIR="$tmp" toolbox_system B2 > "$tmp.out" 2>&1
rc=$?
echo "rc=$rc"
grep -E '固定提交|校验|校验通过|不匹配' "$tmp.out"
echo "exec: $(cat "$log")"
echo "leftovers: $(ls -A "$tmp")"
rm -rf "$tmp" "$tmp.out"
