#!/usr/bin/env bash
# Isolated tests: these never execute a real installer or touch system settings.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-network-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$work/bin"
for cmd in curl wget apk apt apt-get systemctl rc-service rc-update sysctl; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" invoked >> "$NETWORK_TEST_MARKER"\nexit 99\n' > "$work/bin/$cmd"
    chmod +x "$work/bin/$cmd"
done
export NETWORK_TEST_MARKER="$work/invoked"
export PATH="$work/bin:$PATH"
# Source must be inert and keep the caller alive.
out=$(bash -ec 'source "$1"; printf sourced' _ "$ROOT/modules/network.sh") || fail 'source failed'
[[ $out == sourced ]] || fail 'source has output or side effects'
[[ ! -e $NETWORK_TEST_MARKER ]] || fail 'source ran a command'
source "$ROOT/modules/network.sh"
printf 'ID=alpine\n' > "$work/alpine"
printf 'ID=debian\n' > "$work/debian"
printf 'ID=ubuntu\n' > "$work/ubuntu"
printf 'ID=other\nID_LIKE="debian ubuntu"\n' > "$work/derived"
printf 'ID=unknown\n' > "$work/unknown"
[[ $(toolbox_network_detect_os "$work/alpine") == alpine ]] || fail 'Alpine detection'
[[ $(toolbox_network_detect_os "$work/debian") == debian ]] || fail 'Debian detection'
[[ $(toolbox_network_detect_os "$work/ubuntu") == ubuntu ]] || fail 'Ubuntu detection'
[[ $(toolbox_network_detect_os "$work/derived") == debian ]] || fail 'Debian derivative detection'
if toolbox_network_detect_os "$work/unknown" >/dev/null 2>&1; then fail 'unknown OS accepted'; fi
# Detection reads data only; an os-release must not be interpreted as shell code.
printf 'ID=$(touch %s)\n' "$work/pwned" > "$work/hostile"
toolbox_network_detect_os "$work/hostile" >/dev/null 2>&1 && fail 'hostile OS accepted'
[[ ! -e $work/pwned ]] || fail 'OS file executed'
for choice in A1 A2 A3 A4 A5 B12 B23 B31; do
    if printf 'yes\nYES\n' | toolbox_network "$choice" >"$work/out" 2>&1; then
        fail "$choice falsely reported success"
    fi
    [[ -s $work/out ]] || fail "$choice failed silently"
    [[ ! -e $NETWORK_TEST_MARKER ]] || fail "$choice invoked an external mutator"
done
# B23 must fail closed even when resolvectl is installed: merely detecting it
# does not prove exclusive DNS ownership or rule out split-DNS/fallback leaks.
(
    resolvectl() { printf 'called\n' >> "$work/resolvectl.calls"; return 0; }
    printf '1.1.1.1\n8.8.8.8\nYES\n' | toolbox_network B23 >"$work/dns.out" 2>&1 && fail 'B23 unexpectedly applied DNS'
    [[ $(<"$work/dns.out") == *'resolvectl'* ]] || fail 'B23 did not report detected resolver'
    [[ $(<"$work/dns.out") == *'DNS'* && $(<"$work/dns.out") == *'未修改'* ]] || fail 'B23 did not explain safe refusal'
    [[ ! -e $work/resolvectl.calls ]] || fail 'B23 called resolvectl'
)
(
    command() {
        if [[ ${1:-} == -v && ${2:-} == resolvectl ]]; then return 1; fi
        builtin command "$@"
    }
    toolbox_network B23 >"$work/dns-missing.out" 2>&1 && fail 'B23 accepted missing resolver'
    [[ $(<"$work/dns-missing.out") == *'未检测到 resolvectl'* && $(<"$work/dns-missing.out") == *'未修改'* ]] || fail 'B23 missing-resolver refusal'
    [[ ! -e $NETWORK_TEST_MARKER ]] || fail 'B23 invoked a mutator'
)
if toolbox_network BAD >"$work/out" 2>&1; then fail 'invalid choice accepted'; fi
if toolbox_network >"$work/out" 2>&1; then fail 'missing choice accepted'; fi
if toolbox_network A1 unexpected >"$work/out" 2>&1; then fail 'extra argument accepted'; fi
# A4 must remain fail-closed, even with plausible inputs and confirmation.
# Mock the formerly reachable boundaries so a regression cannot touch the host.
(
    toolbox_network_detect_os() { printf 'debian\n'; }
    toolbox_network_hy2_preflight() { printf preflight >> "$work/a4.calls"; return 0; }
    toolbox_network_hy2_apply() { printf apply >> "$work/a4.calls"; return 0; }
    printf '/tmp/cert.pem\n/tmp/key.pem\n443\nINSTALL\n' | toolbox_network A4 > "$work/a4.out" 2>&1 && fail 'disabled A4 reported success'
    [[ ! -e $work/a4.calls ]] || fail 'disabled A4 reached installation boundaries'
    [[ $(<"$work/a4.out") == *'禁用'* ]] || fail 'A4 did not explain refusal'
)
# Unsafe installer entry points must not be callable directly after sourcing.
for helper in toolbox_network_hy2_preflight toolbox_network_hy2_apply; do
    if declare -F "$helper" >/dev/null; then fail "unsafe helper remains callable: $helper"; fi
done
# All inputs and repeated attempts are inert: no external mutator or socket probe.
(
    for cmd in id uname openssl ss sleep mktemp; do
        eval "$cmd() { printf '%s\\n' '$cmd' >> \"\$NETWORK_TEST_MARKER\"; return 99; }"
    done
    # Verify the mock itself before using absence of the marker as evidence.
    ss >/dev/null 2>&1 || :
    [[ $(<"$NETWORK_TEST_MARKER") == ss ]] || fail 'socket mock not recording calls'
    rm "$NETWORK_TEST_MARKER"
    for input in '' $'/tmp/cert.pem\n/tmp/key.pem\nexample.test\n443\nINSTALL\n' 'INSTALL'; do
        printf '%s' "$input" | toolbox_network A4 > "$work/a4-refusal" 2>&1 && fail 'A4 accepted input'
        [[ $(<"$work/a4-refusal") == *'未修改系统'* && $(<"$work/a4-refusal") == *'toolbox-hy2.service'* ]] || fail 'A4 missing refusal or residual guidance'
    done
    [[ ! -e $NETWORK_TEST_MARKER ]] || fail 'A4 invoked an external boundary'
)
# Disabled A5 cannot be bypassed by calling formerly exposed install helpers.
for helper in toolbox_network_xray_preflight toolbox_network_xray_apply toolbox_network_xray_validate; do
    if declare -F "$helper" >/dev/null; then fail "unsafe A5 helper remains callable: $helper"; fi
done
# Actual menu and direct entrypoint with plausible input and hostile boundary
# mocks: repeated and concurrent attempts must never touch a boundary.
(
    for cmd in id uname curl sha256sum python3 systemctl ss sleep mkdir chmod rm; do
        eval "$cmd() { printf '%s\\n' '$cmd' >> \"\$NETWORK_TEST_MARKER\"; return 99; }"
    done
    toolbox_network_xray_apply() { printf 'apply\n' >> "$NETWORK_TEST_MARKER"; return 99; }
    toolbox_network_xray_preflight() { printf 'preflight\n' >> "$NETWORK_TEST_MARKER"; return 99; }
    ss >/dev/null 2>&1 || :
    [[ $(<"$NETWORK_TEST_MARKER") == ss ]] || fail 'A5 boundary mock not recording calls'
    command rm "$NETWORK_TEST_MARKER"
    for entry in menu direct; do
        for input in '' $'443\nexample.com\nINSTALL\n' 'INSTALL'; do
            if [[ $entry == menu ]]; then
                printf '%s' "$input" | toolbox_network A5 > "$work/a5-refusal" 2>&1 && fail 'A5 menu accepted input'
            else
                printf '%s' "$input" | toolbox_network_xray 443 example.com > "$work/a5-refusal" 2>&1 && fail 'A5 direct entry accepted input'
            fi
            [[ $(<"$work/a5-refusal") == *'禁用'* && $(<"$work/a5-refusal") == *'未修改系统'* && $(<"$work/a5-refusal") == *'terry-toolbox-xray.service'* && $(<"$work/a5-refusal") == *'回退流量'* ]] || fail 'A5 missing refusal or residual guidance'
        done
    done
    pids=()
    for n in 1 2 3 4; do
        (printf '443\nexample.com\nINSTALL\n' | toolbox_network A5 > "$work/a5-concurrent-$n" 2>&1 && exit 1; exit 0) &
        pids+=("$!")
    done
    for job in "${pids[@]}"; do wait "$job" || fail 'concurrent A5 attempt succeeded'; done
    [[ ! -e $NETWORK_TEST_MARKER ]] || fail 'disabled A5 invoked an installation boundary'
)
printf 'network tests passed\n'
