#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-build-test.XXXXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
artifact="$tmp/standalone/index.html"
mkdir -p -- "$(dirname -- "$artifact")"
bash "$root/scripts/build.sh" "$artifact"
[[ -x $artifact ]] || fail 'artifact is not executable'
bash -n "$artifact"
[[ $(bash "$artifact" --list) == "$(bash "$root/toolbox.sh" --list)" ]] || fail 'list differs from source'
[[ $(bash "$artifact" --help) == "$(bash "$root/toolbox.sh" --help)" ]] || fail 'help differs from source'
[[ $("$artifact" --list) == "$(bash "$root/toolbox.sh" --list)" ]] || fail 'direct execution'
bash -s -- --list < "$artifact" > "$tmp/stdin-list" 2> "$tmp/stdin-error"
[[ $(<"$tmp/stdin-list") == "$(bash "$root/toolbox.sh" --list)" && ! -s $tmp/stdin-error ]] || fail 'stdin execution'
if bash "$artifact" --unknown >"$tmp/out" 2>&1; then fail 'accepted unknown option'; fi
out=$(printf '0\n' | bash "$artifact")
[[ $out == *'请选择要执行的操作'* ]] || fail 'menu exit'
# 每个动作单独一次运行：B2/A5 可能各自读 stdin，混在一起会互相吃掉输入。
out=$(printf 'DIAG\n0\n' | HOME="$tmp" bash "$artifact" 2>&1)
[[ $out == *'=== 系统 ==='* ]] || fail 'diagnostics dispatch'
out=$(printf 'B18\n0\n' | HOME="$tmp" bash "$artifact" 2>&1)
[[ $out == *'预留，暂未实现'* ]] || fail 'reserved B18'
# A5 已启用，但此环境缺依赖会先退出，没有固定文案；只要求菜单不中断。
out=$(printf 'A5\n0\n' | HOME="$tmp" bash "$artifact" 2>&1)
[[ $out == *'A5 Xray'* && $out == *'返回上一层'* ]] || fail 'network management dispatch'
out=$(printf 'B2\nNO\n0\n' | HOME="$tmp" bash "$artifact" 2>&1)
[[ $out == *'NodeQuality：官方综合测试'* ]] || fail 'system dispatch'
# App dispatch needs a Docker stub: B28 prints its image and note, then the trailing "0"
# is an invalid port, which aborts before any data directory is created.
mkdir -p "$tmp/stub"
printf '%s\n' '#!/bin/sh' 'case "$1 $2" in' \
    'context\ show) echo default ;;' \
    'context\ inspect) echo unix:///var/run/docker.sock ;;' \
    'version\ --format) echo 28.0.0 ;;' \
    'container\ ls) : ;;' \
    'info\ *) : ;;' \
    '*) exit 0 ;;' 'esac' > "$tmp/stub/docker"
chmod +x "$tmp/stub/docker"
out=$(printf 'B28\n0\n' | HOME="$tmp" PATH="$tmp/stub:$PATH" bash "$artifact" 2>&1)
[[ $out == *'B28 mfa-start'* ]] || fail 'app dispatch'
[[ $out == *'lovele/mfa-start@sha256:'* ]] || fail 'app image'
[[ $out == *'admin/admin1234'* ]] || fail 'app credential note'
[[ ! -e $tmp/.local ]] || fail 'unexpected app state'
# Build from isolated fixtures: source bytes are copied, never executed during build.
fixture="$tmp/source with spaces"
mkdir -p "$fixture/modules" "$fixture/scripts"
cp "$root/toolbox.sh" "$fixture/toolbox.sh"
cp "$root"/modules/*.sh "$fixture/modules/"
cp "$root/scripts/build.sh" "$fixture/scripts/build.sh"
printf '\nprintf "executed" > "%s"\n' "$tmp/executed" >> "$fixture/modules/apps.sh"
bash "$fixture/scripts/build.sh" "$tmp/\$(touch injected).html"
[[ ! -e $tmp/executed && ! -e injected ]] || fail 'source or filename executed during build'
# Never clobber an existing output or publish invalid or incomplete bundles.
printf 'keep\n' > "$tmp/existing"
if bash "$fixture/scripts/build.sh" "$tmp/existing" >/dev/null 2>&1; then fail 'clobbered existing output'; fi
[[ $(<"$tmp/existing") == keep ]] || fail 'existing output changed'
printf '\nif\n' >> "$fixture/modules/network.sh"
if bash "$fixture/scripts/build.sh" "$tmp/invalid" >/dev/null 2>&1; then fail 'accepted syntax error'; fi
[[ ! -e $tmp/invalid ]] || fail 'published invalid artifact'
cp "$root/modules/network.sh" "$fixture/modules/network.sh"
rm "$fixture/modules/system.sh"
if bash "$fixture/scripts/build.sh" "$tmp/missing" >/dev/null 2>&1; then fail 'accepted missing module'; fi
[[ ! -e $tmp/missing ]] || fail 'published incomplete artifact'
cp "$root/modules/system.sh" "$fixture/modules/system.sh"
# A loader edit must require an explicit build-script review.
python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); s=p.read_text(); p.write_text(s.replace("  local f\n", "  local f # changed\n", 1))' "$fixture/toolbox.sh"
if bash "$fixture/scripts/build.sh" "$tmp/changed" >/dev/null 2>&1; then fail 'accepted changed loader'; fi
[[ ! -e $tmp/changed ]] || fail 'published changed loader'
printf 'build tests passed\n'
