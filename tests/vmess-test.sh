#!/usr/bin/env bash
# Focused lifecycle tests. systemctl/download/TLS+WS are MOCKED; no host service,
# firewall, package manager or business host is touched. Socket ownership uses a
# real task-owned native process and /proc/PID/exe, never a process-name mock.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/modules/network.sh"
source "$ROOT/modules/vmess.sh"
test_tmp=${TOOLBOX_TEST_TMPDIR:-${TMPDIR:-/root/.cache/terry-toolbox-tests}}
mkdir -p -- "$test_tmp"
T=$(mktemp -d "$test_tmp/vmess-test.XXXXXXXX")
export T
cleanup() {
    local rc=$?
    if [[ -s $T/package-boundary.log ]]; then
        printf 'FAIL: unmocked package command\n' >&2
        command cat "$T/package-boundary.log" >&2
        rc=1
    fi
    python3 - "$T" <<'PY'
import os, signal, shutil, sys
root = sys.argv[1]
# Only test processes whose live executable is still within this exact fixture.
for path, _, files in os.walk(root):
    if 'pid' not in files: continue
    try:
        pid = int(open(path + '/pid').read())
        if os.readlink(f'/proc/{pid}/exe').startswith(root + '/'):
            os.kill(pid, signal.SIGKILL)
    except (OSError, ValueError): pass
shutil.rmtree(root)
PY
    exit "$rc"
}
trap cleanup EXIT
# Physical package guards also cover child Bash and an empty environment.
mkdir -p "$T/package-deny"
: > "$T/package-boundary.log"
for manager in sudo apt apt-get apt-cache aptitude apk dpkg dpkg-query dpkg-deb dnf yum rpm; do
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$0 $*" >> %q\n' "$T/package-boundary.log"
        printf 'exit 99\n'
    } > "$T/package-deny/$manager"
    chmod 0755 "$T/package-deny/$manager"
done
export PATH="$T/package-deny:$PATH"
for guard_env in inherited empty; do
    if [[ $guard_env == empty ]]; then
        env -i PATH="$PATH" bash --noprofile --norc -c 'apt-get --fixture-guard-probe' && exit 1 || [[ $? == 99 ]]
    else
        bash --noprofile --norc -c 'apt-get --fixture-guard-probe' && exit 1 || [[ $? == 99 ]]
    fi
done
[[ $(wc -l < "$T/package-boundary.log") -eq 2 ]]
: > "$T/package-boundary.log"
fail() {
    [[ -z ${C:-} || ! -f $C/output ]] || command cat "$C/output" >&2
    printf 'FAIL: %s\n' "$*" >&2; exit 1;
}
pass() { printf 'PASS: %s\n' "$*"; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
vmess_valid_input example.com 443 /vmess || fail 'valid VMess parameters rejected'
for host in 'evil".com' $'example.com\nbad' '-example.com'; do reject vmess_valid_input "$host" 443 /vmess; done
for path in '../bad' '/bad"' $'/bad\n' '/a/../b' '/a?x=y'; do reject vmess_valid_input example.com 443 "$path"; done
for port in 0 0443 65536 '443;id'; do reject vmess_valid_input example.com "$port" /vmess; done
pass 'parameter validation'
# Fixture certificates only; actual certificate checking gets its own tests below.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=example.com -addext subjectAltName=DNS:example.com -keyout "$T/key.pem" -out "$T/cert.pem" >/dev/null 2>&1
export TOOLBOX_NET_CAFILE="$T/cert.pem" TOOLBOX_NET_CAPATH=''
# The fake archive is explicit, locally hashed and only used via the existing test
# whitelist override. Validation binary is a script, running service is native sleep.
python3 - "$T" <<'PY'
import zipfile, sys, hashlib, os
p = sys.argv[1]
with zipfile.ZipFile(p + '/fake.zip','w') as z:
    z.writestr('xray', '#!/bin/sh\n[ "$1 $2" = "run -test" ]\n')
print(hashlib.sha256(open(p + '/fake.zip','rb').read()).hexdigest(), file=open(p + '/hash','w'))
PY
TOOLBOX_A5_SHA256=$(<"$T/hash")
TOOLBOX_A5_SHA256_ARM64=$TOOLBOX_A5_SHA256
export TOOLBOX_A5_SHA256 TOOLBOX_A5_SHA256_ARM64 TOOLBOX_VM_WS_ZIP_SRC="$T/fake.zip"
# Save real functions for tests of the boundary independently from lifecycle mocks.
eval "$(declare -f vmess_tls_probe | sed '1s/vmess_tls_probe/vmess_real_tls_probe/')"
eval "$(declare -f vmess_certificate | sed '1s/vmess_certificate/vmess_real_certificate/')"
vmess_tls_probe() { printf 'tls-ws-probe\n' >> "$C/log"; [[ ${TLS_FAIL:-0} != 1 ]]; }
vmess_certificate() { printf 'certificate-check\n' >> "$C/log"; [[ ${CERT_FAIL:-0} != 1 ]]; }
# sleep only shortens the module's readiness delay, not any real daemon.
sleep() { command sleep 0.001; }
fixture() {
    C="$T/$1"; export C
    mkdir -m 700 "$C" "$C/bin" "$C/units" "$C/run" "$C/scratch"
    printf 'ID=debian\n' > "$C/os-release"
    printf 'not-found\n' > "$C/state"
    printf '0\n' > "$C/pid"
    : > "$C/log"
    export TOOLBOX_VM_WS_ETC="$C/etc" TOOLBOX_VM_WS_BIN_DIR="$C/bin" TOOLBOX_VM_WS_UNIT_DIR="$C/units"
    export TOOLBOX_VM_WS_LOCK="$C/lock" TOOLBOX_VM_WS_OS_RELEASE="$C/os-release" TOOLBOX_VM_WS_SYSTEMD_RUN="$C/run"
    export TOOLBOX_VM_WS_LISTEN=127.0.0.1 TMPDIR="$C/scratch"
    unset START_FAIL STOP_FAIL SHOW_FAIL SS_FAIL TLS_FAIL CERT_FAIL EXTRA_JOB UNKNOWN_AFTER_STOP KEEP_SOCKET WRONG_PID WRONG_PORT FOREIGN_EXE SIGNAL_START PUBLISH_FAIL IO_FAILURE RELOAD_FAIL VALIDATE_FAIL
}
# The running fixture uses a separate native executable. Tests of installation
# replace the sealed binary with a native one BEFORE hashing/publishing.
eval "$(declare -f vmess_fetch | sed '1s/vmess_fetch/vmess_real_fetch/')"
vmess_fetch() {
    printf 'fetch\n' >> "$C/log"
    vmess_real_fetch "$1" || return 1
    # Compile a small native stand-in: accepts -test, otherwise sleeps. This makes
    # /proc/exe a real ownership assertion; it is not a proxy implementation.
    if [[ ${VALIDATE_FAIL:-0} == 1 ]]; then cp "$T/native-fail" "$1/xray"; else cp "$T/native" "$1/xray"; fi
}
# Build via the host compiler, never install packages. Fail explicitly if absent.
command -v cc >/dev/null || fail 'test fixture requires cc'
printf '%s\n' '#include <string.h>' '#include <unistd.h>' '#include <stdlib.h>' 'int main(int c,char **v){if(c>2 && !strcmp(v[1],"run") && !strcmp(v[2],"-test")){if(c>4 && strstr(v[4],".terry-vmess-manage") && getenv("VMESS_MANAGEMENT_VALIDATE_FAIL"))return 1;return 0;}for(;;)pause();}' > "$T/native.c"
cc "$T/native.c" -o "$T/native"
sed 's/return 0;}for/return 1;}for/' "$T/native.c" > "$T/native-fail.c"
cc "$T/native-fail.c" -o "$T/native-fail"
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$C/log"
    local state pid sub=dead active=inactive load=loaded fragment
    state=$(<"$C/state"); pid=$(<"$C/pid"); fragment=$(vmess_unit)
    case $1 in
        show)
            [[ ${SHOW_FAIL:-0} != 1 ]] || return 1
            case $state in not-found) load=not-found; fragment='' ;; active) active=active; sub=running ;; failed) active=failed; sub=failed ;; unknown) active=deactivating; sub=stop-sigterm ;; esac
            printf 'LoadState=%s\nActiveState=%s\nSubState=%s\nMainPID=%s\nFragmentPath=%s\nDropInPaths=\nJob=%s\n' "$load" "$active" "$sub" "$pid" "$fragment" "${EXTRA_JOB:-}"
            ;;
        daemon-reload)
            [[ ${RELOAD_FAIL:-0} != 1 ]] || return 1
            if [[ -f $(vmess_unit) ]]; then
                [[ $state != not-found ]] || printf 'inactive\n' > "$C/state"
            else printf 'not-found\n' > "$C/state"; fi
            ;;
        start)
            if [[ ${SIGNAL_START:-0} == 1 ]]; then kill -TERM "$BASHPID"; return 1; fi
            if [[ ${START_FAIL:-0} == 1 ]]; then printf 'failed\n' > "$C/state"; return 1; fi
            "$(vmess_bin)" >/dev/null 2>&1 &
            printf '%s\n' "$!" > "$C/pid"
            printf 'active\n' > "$C/state"
            ;;
        stop)
            [[ ${STOP_FAIL:-0} != 1 ]] || return 1
            if [[ $pid != 0 && -e /proc/$pid/exe ]]; then kill "$pid"; wait "$pid" 2>/dev/null || true; fi
            printf '0\n' > "$C/pid"
            if [[ ${UNKNOWN_AFTER_STOP:-0} == 1 ]]; then printf 'unknown\n' > "$C/state"; else printf 'inactive\n' > "$C/state"; fi
            ;;
        *) fail "forbidden systemctl verb $1" ;;
    esac
}
ss() {
    [[ $* == -ltnpH ]] || fail 'ss must request TCP+PIDs'
    [[ ${SS_FAIL:-0} != 1 ]] || return 1
    local pid state
    pid=$(<"$C/pid"); state=$(<"$C/state")
    if [[ $state == active || ${KEEP_SOCKET:-0} == 1 ]]; then
        printf 'LISTEN 0 128 127.0.0.1:%s 0.0.0.0:* users:(("irrelevant-name",pid=%s,fd=3))\n' "${WRONG_PORT:-24443}" "${WRONG_PID:-$pid}"
    fi
}
install_yes() { toolbox_vmess install "$T/cert.pem" "$T/key.pem" example.com 24443 /vmess <<< $'yEs\nYes' > "$C/output" 2>&1; }
uninstall_yes() { toolbox_vmess uninstall <<< $'YES\nyes' > "$C/uninstall-output" 2>&1; }
empty_targets() { [[ ! -e $(vmess_etc) && ! -e $(vmess_bin) && ! -e $(vmess_unit) && ! -e $(vmess_lock) ]] || fail 'unexpected target retained'; }
no_mutation() { ! grep -Eq 'fetch|systemctl (start|stop|daemon-reload)' "$C/log" || fail 'prerequisite/cancel touched privileged boundary'; }
# Reuse the actual isolated boundary fixtures in management regressions.
if [[ ${VMESS_FIXTURE_ONLY:-0} == 1 ]]; then return 0; fi
for input in '' $'\n' 'no' 'YES' $'YES\nno'; do
    fixture "cancel-${input//[^a-zA-Z]/x}"
    reject toolbox_vmess install "$T/cert.pem" "$T/key.pem" example.com 24443 /vmess <<< "$input" > "$C/output" 2>&1
    empty_targets; no_mutation
done
pass 'empty/EOF/unrelated/second confirmation cancel'
fixture prerequisites
CERT_FAIL=1; reject install_yes; empty_targets; no_mutation
unset CERT_FAIL
printf 'ID=ubuntu\n' > "$C/os-release"; reject install_yes; empty_targets; no_mutation
printf 'ID=debian\n' > "$C/os-release"
rm -d "$C/run"; reject install_yes; empty_targets; no_mutation
pass 'explicit prerequisite failure under conditional caller'
source "$ROOT/modules/dependencies.sh"
fixture missing-command
command() { if [[ $* == '-v python3' ]]; then return 1; fi; builtin command "$@"; }
(
    _toolbox_deps_os() { printf 'debian\n'; }
    _toolbox_deps_confirm() { printf 'fixture: dependency installation declined\n' >&2; return 1; }
    reject install_yes
)
empty_targets; no_mutation
unset -f command
pass 'missing mandatory command under conditional caller'
for conflict in etc binary unit symlink dropin loaded lock port ss-error show-error; do
    fixture "conflict-$conflict"
    case $conflict in
        etc) mkdir "$(vmess_etc)" ;; binary) : > "$(vmess_bin)" ;; unit) : > "$(vmess_unit)" ;;
        symlink) ln -s "$C/missing" "$(vmess_etc)" ;; dropin) mkdir "$(vmess_unit).d" ;;
        loaded) printf 'inactive\n' > "$C/state" ;; lock) mkdir "$(vmess_lock)" ;;
        port) KEEP_SOCKET=1 ;; ss-error) SS_FAIL=1 ;; show-error) SHOW_FAIL=1 ;;
    esac
    reject install_yes; no_mutation
done
pass 'target/symlink/drop-in/loaded-unit/lock/listener/unknown conflicts'
fixture changed-parent
vmess_confirm() { mv "$C/bin" "$C/old-bin"; ln -s "$C/old-bin" "$C/bin"; }
reject install_yes; no_mutation
source "$ROOT/modules/vmess.sh"
# Restore test-only mocks after resourcing.
vmess_tls_probe() { printf 'tls-ws-probe\n' >> "$C/log"; [[ ${TLS_FAIL:-0} != 1 ]]; }
vmess_certificate() { printf 'certificate-check\n' >> "$C/log"; [[ ${CERT_FAIL:-0} != 1 ]]; }
vmess_fetch() { printf 'fetch\n' >> "$C/log"; vmess_real_fetch "$1" || return 1; if [[ ${VALIDATE_FAIL:-0} == 1 ]]; then cp "$T/native-fail" "$1/xray"; else cp "$T/native" "$1/xray"; fi; }
pass 'parent switched to symlink during confirmation'
fixture incorrect-hash
original_hash=$TOOLBOX_A5_SHA256
TOOLBOX_A5_SHA256=$(printf '0%.0s' {1..64}); TOOLBOX_A5_SHA256_ARM64=$TOOLBOX_A5_SHA256
reject install_yes; empty_targets
TOOLBOX_A5_SHA256=$original_hash; TOOLBOX_A5_SHA256_ARM64=$original_hash
pass 'incorrect archive hash rejected before publication'
fixture happy
install_yes || { read -r _ < "$C/output" || true; fail "install failed, log $C/output"; }
# No UUID or vmess:// credential appears in terminal output.
python3 - "$C" <<'PY'
import json, os, sys, stat, base64
p=sys.argv[1]; cfg=json.load(open(p+'/etc/config.json')); cli=json.load(open(p+'/etc/client.json'))
u=cfg['inbounds'][0]['settings']['clients'][0]['id']
assert u not in open(p+'/output').read()
assert 'vmess://' not in open(p+'/output').read()
assert cli['outbounds'][0]['streamSettings']['tlsSettings']['allowInsecure'] is False
assert cfg['outbounds'] == [{'protocol':'freedom','tag':'direct'}], 'must not allow private targets for tests'
for name in ('config.json','client.json','key.pem','cert.pem','vmess.txt','manifest.json','manifest.sha256'):
    assert stat.S_IMODE(os.stat(p+'/etc/'+name).st_mode)==0o600
share=json.loads(base64.b64decode(open(p+'/etc/vmess.txt').read().strip()[8:]))
assert share['id']==u and share['tls']=='tls' and share['net']=='ws'
PY
reject install_yes # existing installation is not "reuse" authorization
if ! toolbox_vmess status > "$C/status-output" 2>&1; then fail 'status failed'; fi
WRONG_PORT=24444; reject toolbox_vmess status > "$C/status-output" 2>&1; unset WRONG_PORT
WRONG_PID=2147483647; reject toolbox_vmess status > "$C/status-output" 2>&1; unset WRONG_PID
SS_FAIL=1; reject toolbox_vmess status > "$C/status-output" 2>&1; unset SS_FAIL
EXTRA_JOB=123; reject toolbox_vmess status > "$C/status-output" 2>&1; unset EXTRA_JOB
reject toolbox_vmess uninstall <<< '' > "$C/uninstall-output" 2>&1
[[ -f $(vmess_bin) ]] || fail 'uninstall cancel removed binary'
: > "$C/log"
reject toolbox_vmess uninstall <<< $'YES\n' > "$C/uninstall-output" 2>&1
[[ -f $(vmess_bin) && -f $(vmess_unit) ]] || fail 'second uninstall cancel removed files'
! grep -q 'systemctl stop' "$C/log" || fail 'second uninstall cancel stopped service'
vmess_fs verify --complete >/dev/null || fail 'second uninstall cancel changed ownership state'
no_mutation
[[ $(<"$C/state") == active && $(<"$C/pid") != 0 ]] || fail 'second uninstall cancel changed service state'
uninstall_yes || fail 'uninstall failed'
empty_targets
reject toolbox_vmess status > "$C/status-output" 2>&1
pass 'install/status/uninstall and PID/exact TCP port/unknown status gates'
for fault in stop unknown job socket ss preunknown foreignpid; do
    fixture "stop-$fault"; install_yes || fail "setup for $fault"
    case $fault in stop) STOP_FAIL=1 ;; unknown) UNKNOWN_AFTER_STOP=1 ;; job) EXTRA_JOB=42 ;; socket) KEEP_SOCKET=1 ;; ss) SS_FAIL=1 ;;
        preunknown) printf 'unknown\n' > "$C/state" ;;
        foreignpid) cp "$C/pid" "$C/owned-pid"; printf '%s\n' "$BASHPID" > "$C/pid" ;; esac
    reject uninstall_yes
    [[ -f $(vmess_bin) && -f $(vmess_unit) && -f $(vmess_etc)/manifest.json ]] || fail 'unconfirmed stop removed files'
    if [[ $fault == foreignpid ]]; then mv "$C/owned-pid" "$C/pid"; fi
done
pass 'failed/unknown/pending/lingering-listener/ss-failed stops retain all resources'
for kind in config inode extra ledger; do
    fixture "changed-$kind"; install_yes || fail "setup for $kind"
    case $kind in
        config) printf '\n' >> "$(vmess_etc)/config.json" ;;
        inode) cp "$(vmess_unit)" "$C/replacement"; mv "$C/replacement" "$(vmess_unit)" ;;
        extra) : > "$(vmess_etc)/user-file" ;;
        ledger) printf '\n' >> "$(vmess_etc)/manifest.json" ;;
    esac
    reject uninstall_yes
    [[ -f $(vmess_bin) ]] || fail 'modified resources were deleted'
    ! grep -q 'systemctl stop' "$C/log" || fail 'changed/unknown ownership must not stop'
done
pass 'content/inode/extra directory/manifest changes are retained without stop'
fixture start-fail
START_FAIL=1; reject install_yes
empty_targets
pass 'failed start explicitly stops and safely rolls back'
fixture start-stop-fail
START_FAIL=1 STOP_FAIL=1; reject install_yes
[[ -f $(vmess_unit) && -f $(vmess_bin) ]] || fail 'stop failure did not preserve failed install'
pass 'failed start plus failed stop retains resources'
fixture validate-fail
VALIDATE_FAIL=1; reject install_yes
empty_targets
pass 'Xray config validation failure rolls back without starting'
fixture reload-fail
RELOAD_FAIL=1; reject install_yes
empty_targets
pass 'daemon-reload failure rolls back without starting'
# The unpublished-to-systemd rollback path requires an explicitly stopped state;
# LoadState=not-found alone cannot prove that an in-flight service is inactive.
(
    systemctl() {
        printf 'LoadState=not-found\nActiveState=%s\nSubState=%s\nMainPID=0\nFragmentPath=\nDropInPaths=\nJob=%s\n' "$gate_active" "$gate_sub" "$gate_job"
    }
    ss() { :; }
    for gate_pair in deactivating:stop-sigterm activating:start active:running unknown:unknown; do
        gate_active=${gate_pair%%:*}; gate_sub=${gate_pair#*:}; gate_job=''
        reject vmess_stop_gate 24443 1
    done
    gate_active=inactive; gate_sub=dead; gate_job=42
    reject vmess_stop_gate 24443 1
    gate_job=''
    vmess_stop_gate 24443 1 || fail 'explicit inactive/dead not-found state rejected'
)
pass 'not-found rollback rejects ambiguous states and pending jobs'
fixture bad-arch
uname() { printf 'riscv64\n'; }
reject install_yes
unset -f uname
[[ $(<"$C/output") == *'不支持的 CPU 架构'* ]] || fail 'unsupported architecture reason missing'
empty_targets; no_mutation
pass 'unsupported architecture is refused before confirmation with a reason'
fixture bad-cert-path
reject toolbox_vmess install "$T/cert with space.pem" "$T/key.pem" example.com 24443 /vmess <<< $'YES\nYES' > "$C/output" 2>&1
[[ $(<"$C/output") == *'不含空格'* ]] || fail 'unsafe certificate path reason missing'
empty_targets; no_mutation
pass 'unsafe certificate path is refused with a reason'
fixture tls-fail
TLS_FAIL=1; reject install_yes
empty_targets
pass 'TLS/WS verification failure is not successful installation'
fixture signal
SIGNAL_START=1; reject install_yes
empty_targets
pass 'real SIGTERM follows the same stop/ownership rollback gates'
# IO faults are injected at Python os.write/os.fsync, below the real fs ledger.
# These tests do not mock the filesystem ownership/publish/remove implementation.
mkdir -m 700 "$T/inject"
printf '%s\n' 'import os' 'old=os.fsync' 'def broken(fd):' '    p=os.readlink("/proc/self/fd/"+str(fd))' '    if "/etc/.terry-vmess-" in p and not os.path.exists(os.environ["C"]+"/injected"):' '        open(os.environ["C"]+"/injected","w").close()' '        raise OSError("injected fsync I/O failure")' '    return old(fd)' 'os.fsync=broken' > "$T/inject/sitecustomize.py"
fixture publish-io
PYTHONPATH="$T/inject" reject install_yes
empty_targets
pass 'partial fsync publication failure cleans only exclusively owned resources'
fixture rollback-no-claim
install_yes || fail 'setup valid independent installation'
mkdir -m 700 "$C/unclaimed"
# shellcheck disable=SC2034 # vmess_rollback in the sourced module reads this caller state.
vmess_stage="$C/unclaimed"
reject vmess_rollback > "$C/rollback-output" 2>&1
[[ -f $(vmess_bin) ]] || fail 'rollback adopted unrelated existing install'
! grep -q 'systemctl stop' "$C/log" || fail 'unclaimed rollback stopped service'
unset vmess_stage
pass 'rollback cannot adopt an existing valid installation without its per-attempt claim'
fixture signal-stop-fail
SIGNAL_START=1 STOP_FAIL=1; reject install_yes
[[ -f $(vmess_unit) && -f $(vmess_bin) ]] || fail 'signal rollback ignored failed stop'
pass 'SIGTERM plus failed stop preserves resources'
# Test a race at the atomic no-clobber commit, not merely the preflight check.
printf '%s\n' 'import os' 'old=os.link' 'def swapped(src,dst,*args,**kwargs):' '    if dst=="key.pem":' '        os.symlink(os.environ["C"]+"/sentinel",dst,dir_fd=kwargs["dst_dir_fd"])' '    return old(src,dst,*args,**kwargs)' 'os.link=swapped' > "$T/inject/sitecustomize.py"
fixture publish-symlink
printf 'untouched\n' > "$C/sentinel"
PYTHONPATH="$T/inject" reject install_yes
[[ $(<"$C/sentinel") == untouched && -L $(vmess_etc)/key.pem ]] || fail 'atomic publish overwrote/followed raced symlink'
! grep -q 'systemctl start' "$C/log" || fail 'started after no-clobber failure'
pass 'atomic publication refuses a symlink raced into place'
# Persistent ledger failure must retain evidence rather than guess ownership.
printf '%s\n' 'import os' 'old=os.write' 'def broken(fd,data):' '    p=os.readlink("/proc/self/fd/"+str(fd))' '    if p.endswith("/manifest.json"): raise OSError("injected manifest write error")' '    return old(fd,data)' 'oldfd=os.fdopen' 'def badfd(fd,*args,**kwargs):' '    p=os.readlink("/proc/self/fd/"+str(fd))' '    if p.endswith("/manifest.json"): raise OSError("injected manifest I/O error")' '    return oldfd(fd,*args,**kwargs)' 'os.write=broken' 'os.fdopen=badfd' > "$T/inject/sitecustomize.py"
fixture ledger-io
PYTHONPATH="$T/inject" reject install_yes
[[ -f $(vmess_bin) && -f $(vmess_unit) ]] || fail 'unsealed ledger resources must be retained'
! grep -q 'systemctl start' "$C/log" || fail 'started with unsealed ledger'
pass 'unsealed ledger I/O failure retains resources and does not start'
fixture malformed-ss
ss() { printf 'not a TCP socket table\n'; }
reject install_yes; empty_targets; no_mutation
pass 'malformed socket reads are unknown, not free'
# Restore the previous safe fixture socket reader for the final identity test.
ss() {
    local pid; pid=$(<"$C/pid")
    printf 'LISTEN 0 128 127.0.0.1:24443 0.0.0.0:* users:(("irrelevant-name",pid=%s,fd=3))\n' "$pid"
}
fixture proc-identity
"$T/native" >/dev/null 2>&1 &
NATIVE_PID=$!
printf '%s\n' "$NATIVE_PID" > "$C/pid"; printf 'active\n' > "$C/state"
reject vmess_socket_owned 24443 "$NATIVE_PID" 127.0.0.1 /bin/sh
vmess_socket_owned 24443 "$NATIVE_PID" 127.0.0.1 "$T/native" || fail 'real PID/executable ownership should pass'
kill "$NATIVE_PID"; wait "$NATIVE_PID" 2>/dev/null || true
pass 'native executable identity required, not process name'
fixture real-cert
vmess_real_certificate "$T/cert.pem" "$T/key.pem" example.com || fail 'valid trusted certificate'
reject vmess_real_certificate "$T/cert.pem" "$T/key.pem" other.example.com >/dev/null 2>&1
TOOLBOX_NET_CAFILE="$C/nonexistent" reject vmess_real_certificate "$T/cert.pem" "$T/key.pem" example.com >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$C/wrong-key.pem" >/dev/null 2>&1
reject vmess_real_certificate "$T/cert.pem" "$C/wrong-key.pem" example.com >/dev/null 2>&1
pass 'real cert trust/hostname/key-pair checks (local fixture CA only)'
# Certificate validity, key encryption and a real intermediate chain.
python3 "$ROOT/tests/certificate-fixture.py" "$C/expired.pem" "$C/expired.key" 20200101000000Z 20200102000000Z
TOOLBOX_NET_CAFILE="$C/expired.pem" reject vmess_real_certificate "$C/expired.pem" "$C/expired.key" example.com >/dev/null 2>&1
python3 "$ROOT/tests/certificate-fixture.py" "$C/future.pem" "$C/future.key" 20990101000000Z 20990102000000Z
TOOLBOX_NET_CAFILE="$C/future.pem" reject vmess_real_certificate "$C/future.pem" "$C/future.key" example.com >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -aes-256-cbc -pass pass:secret -out "$C/enc.key" >/dev/null 2>&1
reject vmess_real_certificate "$T/cert.pem" "$C/enc.key" example.com >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$C/ca.key" >/dev/null 2>&1
openssl req -x509 -new -key "$C/ca.key" -days 2 -subj /CN=TestRoot -out "$C/ca.pem" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$C/int.key" >/dev/null 2>&1
openssl req -new -key "$C/int.key" -subj /CN=TestIntermediate -out "$C/int.csr" >/dev/null 2>&1
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$C/int.ext"
openssl x509 -req -in "$C/int.csr" -CA "$C/ca.pem" -CAkey "$C/ca.key" -CAcreateserial -days 2 -extfile "$C/int.ext" -out "$C/int.pem" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$C/leaf.key" >/dev/null 2>&1
openssl req -new -key "$C/leaf.key" -subj /CN=example.com -out "$C/leaf.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:example.com\nbasicConstraints=CA:FALSE\n' > "$C/leaf.ext"
openssl x509 -req -in "$C/leaf.csr" -CA "$C/int.pem" -CAkey "$C/int.key" -CAcreateserial -days 2 -extfile "$C/leaf.ext" -out "$C/leaf.pem" >/dev/null 2>&1
command cat "$C/leaf.pem" "$C/int.pem" > "$C/chain.pem"
reject vmess_real_certificate "$C/chain.pem" "$C/leaf.key" example.com >/dev/null 2>&1
TOOLBOX_NET_CAFILE="$C/ca.pem" vmess_real_certificate "$C/chain.pem" "$C/leaf.key" example.com || fail 'valid intermediate chain rejected'
pass 'expired, not-yet-valid and encrypted certificate inputs rejected; complete chain with trust anchor accepted'
printf 'VMess focused suite complete. Lifecycle/transport mocked; protocol acceptance is separate.\n'
