#!/usr/bin/env bash
# Build the publishable single file into docs/ for GitHub Pages.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/docs/index.html
mkdir -p -- "$root/docs"
rm -f -- "$out"
bash "$root/scripts/build.sh" "$out"
printf 'sha256  %s\n' "$(sha256sum "$out" | cut -d' ' -f1)"
printf 'bytes   %s\n' "$(stat -c %s "$out")"
