#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-diagnostics.XXXXXXXX")
cleanup_packages() {
    local rc=$?
    if [[ -s $test_dir/package-boundary.log ]]; then
        printf 'FAIL: unmocked package command\n' >&2
        command cat "$test_dir/package-boundary.log" >&2
        rc=1
    fi
    rm -rf -- "$test_dir"
    exit "$rc"
}
trap cleanup_packages EXIT
# Physical package guards also cover child Bash and an empty environment.
mkdir -p "$test_dir/package-deny"
: > "$test_dir/package-boundary.log"
for manager in sudo apt apt-get apt-cache aptitude apk dpkg dpkg-query dpkg-deb dnf yum rpm; do
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$0 $*" >> %q\n' "$test_dir/package-boundary.log"
        printf 'exit 99\n'
    } > "$test_dir/package-deny/$manager"
    chmod 0755 "$test_dir/package-deny/$manager"
done
export PATH="$test_dir/package-deny:$PATH"
for guard_env in inherited empty; do
    if [[ $guard_env == empty ]]; then
        env -i PATH="$PATH" bash --noprofile --norc -c 'apt-get --fixture-guard-probe' && exit 1 || [[ $? == 99 ]]
    else
        bash --noprofile --norc -c 'apt-get --fixture-guard-probe' && exit 1 || [[ $? == 99 ]]
    fi
done
[[ $(wc -l < "$test_dir/package-boundary.log") -eq 2 ]]
: > "$test_dir/package-boundary.log"
source "$root/modules/diagnostics.sh"
out=$(toolbox_diagnostics </dev/null)
for item in '系统' '运行时间' '内存' '磁盘' '网络'; do
  [[ "$out" == *"$item"* ]] || { printf 'FAIL: missing %s\n' "$item" >&2; exit 1; }
done
printf 'diagnostics tests passed\n'
