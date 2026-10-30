#!/usr/bin/env bash
# Isolated regression: commands are mocks; no host services or deployment touched.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-webssh.XXXXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export LOG="$test_dir/commands.log"
: > "$LOG"
docker() { printf 'docker %s\n' "$*" >> "$LOG"; return 1; }
curl() { printf 'curl %s\n' "$*" >> "$LOG"; return 1; }
wget() { printf 'wget %s\n' "$*" >> "$LOG"; return 1; }
source "$script_dir/../modules/webssh.sh"
[[ ! -s $LOG ]] || { printf 'source executed commands\n' >&2; exit 1; }
if output=$(toolbox_webssh <<< $'\ny' 2>&1); then
    printf 'WebSSH must fail closed without a verified official image\n' >&2; exit 1
fi
[[ $output == *'官方'* && $output == *'镜像'* && $output == *'认证'* ]] || {
    printf 'Missing clear official-image and authentication explanation\n' >&2; exit 1;
}
[[ ! -s $LOG ]] || { printf 'Unexpected external operation\n' >&2; exit 1; }
printf 'WebSSH fail-closed tests passed.\n'
