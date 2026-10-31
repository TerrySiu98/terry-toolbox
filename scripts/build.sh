#!/usr/bin/env bash
# Build a standalone Pages-compatible shell file without running the sources.
# Usage: bash scripts/build.sh [output-path] (default: dist/index.html).
# Existing outputs are never replaced; remove/move an old artifact explicitly.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if (( $# > 1 )); then printf 'Usage: bash scripts/build.sh [output-path]\n' >&2; exit 2; fi
output=${1:-"$root/dist/index.html"}
[[ -n $output && $output != */ ]] || { printf 'Invalid output path\n' >&2; exit 2; }
output_dir=$(dirname -- "$output")
output_name=$(basename -- "$output")
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
output=$output_dir/$output_name
[[ ! -e $output && ! -L $output ]] || { printf 'Output already exists: %s\n' "$output" >&2; exit 1; }
modules=(entry dependencies apps network system diagnostics hy2 webssh vmess alpine-swap docker-ipv6 webssh-containers tls-acme reinstall-provenance reinstall)
for file in "$root/toolbox.sh" "${modules[@]/#/$root/modules/}"; do
  # Module names get their extension below; the entrypoint already has one.
  [[ $file == "$root/toolbox.sh" ]] || file+=.sh
  [[ -f $file && -r $file ]] || { printf 'Missing source: %s\n' "$file" >&2; exit 1; }
  bash -n "$file"
done
# Fail closed if the loader changes: don't silently delete unfamiliar code.
expected=$(printf '%s\n' \
  'load_modules() {' \
  '  [[ ${TOOLBOX_MODULES_LOADED:-0} == 1 ]] && return 0' \
  '  local f' \
  '  for f in dependencies apps network system diagnostics hy2 webssh vmess alpine-swap docker-ipv6 webssh-containers tls-acme reinstall-provenance reinstall; do' \
  '    if [[ ! -r "$TOOLBOX_DIR/modules/$f.sh" ]]; then' \
  '      printf '\''错误：缺少模块 %s/modules/%s.sh。请下载完整项目。\n'\'' "$TOOLBOX_DIR" "$f" >&2' \
  '      return 1' \
  '    fi' \
  '    # shellcheck source=/dev/null' \
  '    source "$TOOLBOX_DIR/modules/$f.sh"' \
  '  done' \
  '  TOOLBOX_MODULES_LOADED=1' \
  '}')
tmp=$(mktemp "$output_dir/.toolbox-build.XXXXXXXX")
trap 'rm -f -- "$tmp"' EXIT
found=0
{
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == 'load_modules() {' ]]; then
      ((found+=1))
      loader=$line
      closed=0
      while IFS= read -r line || [[ -n $line ]]; do
        loader+=$'\n'$line
        if [[ $line == '}' ]]; then closed=1; break; fi
      done
      if (( ! closed )) || [[ $loader != "$expected" ]]; then
        printf 'Unexpected load_modules definition; review build script.\n' >&2; exit 1
      fi
      printf '%s\n' '# Bundled modules; load_modules is intentionally a no-op.' 'TOOLBOX_BUNDLED=1' 'load_modules() { :; }'
      for module in dependencies apps network system diagnostics hy2 webssh vmess alpine-swap docker-ipv6 webssh-containers tls-acme reinstall-provenance reinstall; do
        printf '\n# BEGIN bundled module: %s\n' "$module"
        cat -- "$root/modules/$module.sh"
        printf '\n# END bundled module: %s\n' "$module"
      done
    elif [[ $line == 'source "$TOOLBOX_DIR/modules/entry.sh"' ]]; then
      printf '\n# BEGIN bundled module: entry\n'
      cat -- "$root/modules/entry.sh"
      printf '\n# END bundled module: entry\n'
    elif [[ $line == 'TOOLBOX_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)' ]]; then
      # The loader no longer needs a directory, and BASH_SOURCE is unset for stdin.
      printf '%s\n' "TOOLBOX_DIR='' # No external modules in the standalone bundle."
    else
      printf '%s\n' "$line"
    fi
  done < "$root/toolbox.sh"
} > "$tmp"
[[ $found == 1 ]] || { printf 'Expected exactly one module loader, found %s\n' "$found" >&2; exit 1; }
bash -n "$tmp"
chmod 755 "$tmp"
# Linking within the output directory is atomic and fails if the name exists.
ln -- "$tmp" "$output" || { printf 'Could not publish output without clobbering: %s\n' "$output" >&2; exit 1; }
printf 'Built %s\n' "$output"
