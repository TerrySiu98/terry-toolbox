#!/usr/bin/env bash
# Self-signed onboarding; all mutations use the isolated HY2 fixture.
set -euo pipefail
TOOLBOX_HY2_FIXTURE_ONLY=1 source "$(dirname -- "${BASH_SOURCE[0]}")/hy2-test.sh"

# Missing process-control capability must reject before prompts or mutations.
(
    hy2_require_pidfd() { printf 'fixture-pidfd-unavailable\n' >&2; return 1; }
    rc=0
    toolbox_hy2 install-self 192.0.2.10 www.cloudflare.com 18443 <<< $'YES\nYES' >"$work/pidfd-gate.out" 2>&1 || rc=$?
    [[ $rc != 0 ]] || fail 'pidfd preflight missing: install proceeded'
    assert_clean 'pidfd unavailable before mutation'
    [[ ! -e $(hy2_lock) && ! -s $SD/stub.log && ! -s $SD/systemctl.log ]] || fail 'pidfd failure crossed mutation boundary'
    grep -q 'fixture-pidfd-unavailable' "$work/pidfd-gate.out" || fail 'pidfd gate not reached'
    ! grep -q '输入 YES' "$work/pidfd-gate.out" || fail 'pidfd refusal happened after confirmation'
)
hy2_require_pidfd || fail 'native pidfd positive control'
cat > "$work/pidfd-inject.py" <<'PY_PIDFD_INJECT'
import errno, os, signal, sys
code = sys.stdin.read()
case = os.environ['PIDFD_CASE']
if case == 'missing-open': delattr(os, 'pidfd_open')
elif case == 'missing-send': delattr(signal, 'pidfd_send_signal')
else:
    def unavailable(*args, **kwargs): raise OSError(errno.ENOSYS, 'fixture pidfd unavailable')
    os.pidfd_open = unavailable
exec(compile(code, '<pidfd-preflight>', 'exec'))
PY_PIDFD_INJECT
for PIDFD_CASE in missing-open missing-send enosys; do
    export PIDFD_CASE
    (
        python3() { command python3 "$work/pidfd-inject.py" "$@"; }
        hy2_require_pidfd >"$work/pidfd-negative.out" 2>&1 && fail 'unsupported pidfd accepted'
        grep -q 'pidfd' "$work/pidfd-negative.out" || fail 'pidfd rejection reason missing'
    )
done
unset PIDFD_CASE
hy2_require_pidfd || fail 'native pidfd recovery control'
printf 'PASS: pidfd capability checked before prompts/writes; API/ENOSYS controls\n'

# A real loopback child (not a mocked kill) must be gone before rollback deletes
# its executable/config. Keep measurements in runner stdout before fixture cleanup.
cp -- "$TOOLBOX_HY2_BIN_SRC" "$work/original-hysteria"
cat > "$work/signal-child.py" <<'PY_CHILD'
import json, os, pathlib, signal, socket, sys, time
parent, sd, kind, sig, phase = int(sys.argv[1]), pathlib.Path(sys.argv[2]), *sys.argv[3:]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('127.0.0.1', 0))
s.settimeout(15)
identity = pathlib.Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()[19]
(sd/'child.json').write_text(json.dumps(dict(pid=os.getpid(), start=identity, port=s.getsockname()[1])))
if kind in ('signal', 'signal-stopfail', 'repeated'):
    os.kill(parent, getattr(signal, 'SIG'+sig))
elif kind != 'window':
    print('server up and running' if phase == 'server' else 'connected to server', flush=True)
try:
    while True:
        data, peer = s.recvfrom(128)
        s.sendto(b'fixture-reply', peer)
except socket.timeout:
    pass
PY_CHILD
cat > "$TOOLBOX_HY2_BIN_SRC" <<'SIGNAL_BIN'
#!/usr/bin/env bash
if [[ $1 != "$CHILD_PHASE" || ( $1 == client && $3 != */good.yaml ) ]]; then
    exec "$TOOLBOX_TEST_WORK/original-hysteria" "$@"
fi
exec python3 "$TOOLBOX_TEST_WORK/signal-child.py" "$PPID" "$SD" "$CHILD_KIND" "$CHILD_SIGNAL" "$CHILD_PHASE"
SIGNAL_BIN
chmod 0755 "$TOOLBOX_HY2_BIN_SRC"
TOOLBOX_HY2_SHA256=$(sha256sum "$TOOLBOX_HY2_BIN_SRC" | cut -d' ' -f1)
child_failures=0
for CHILD_PHASE in server client; do
    for child_case in signal:TERM signal:INT signal:HUP normal:NONE stopfail:NONE signal-stopfail:TERM repeated:TERM window:TERM; do
        reset
        rm -f "$SD/child.json" "$SD/child-stop-failure"
        export MOCK_PORT=18443 CHILD_PHASE CHILD_KIND=${child_case%:*} CHILD_SIGNAL=${child_case#*:}
        child_rc=0
        (
            if [[ $CHILD_KIND == stopfail || $CHILD_KIND == signal-stopfail || $CHILD_KIND == repeated ]]; then
                eval "$(declare -f hy2_child_terminate | sed '1s/hy2_child_terminate/hy2_original_terminate/')"
                hy2_child_terminate() {
                    if [[ -s $SD/child.json ]]; then
                        if [[ $CHILD_KIND == repeated ]]; then
                            # Signals during cleanup must not re-enter rollback.
                            kill -TERM "$BASHPID"; kill -INT "$BASHPID"; kill -HUP "$BASHPID"
                        else
                            printf reached >> "$SD/child-stop-failure"; return 1
                        fi
                    fi
                    hy2_original_terminate "$@"
                }
            elif [[ $CHILD_KIND == window ]]; then
                # Deterministic signal between '&' and PID registration. No new
                # async job is launched here, so the original $! is preserved.
                if declare -F hy2_child_start >/dev/null; then
                    definition=$(declare -f hy2_child_start)
                    gap='if [[ $2 == "$CHILD_PHASE" ]]; then for ((gap_i=0; gap_i<200; gap_i++)); do [[ -s $SD/child.json ]] && break; command sleep 0.01; done; kill -TERM "$BASHPID"; fi; hy2_child_pid=$!'
                    # Bash 5.2 otherwise expands '&' inside the replacement.
                    shopt -u patsub_replacement 2>/dev/null || true
                    [[ $definition == *'hy2_child_pid=$!'* ]] || fail 'launch injection anchor missing'
                    eval "${definition/hy2_child_pid=\$!/$gap}"
                else
                    exit 92
                fi
            fi
            toolbox_hy2 install-self 192.0.2.10 www.cloudflare.com 18443 <<< $'YES\nYES'
        ) >"$work/child-install.out" 2>&1 || child_rc=$?
        python3 - "$SD" "$TOOLBOX_HY2_ETC" "$(hy2_bin)" "$(hy2_unit)" "$child_rc" "$work/child-install.out" <<'PY_RESULT' || child_failures=$((child_failures+1))
import json, os, pathlib, select, signal, socket, sys
sd, etc, binary, unit = map(pathlib.Path, sys.argv[1:5])
kind, sig, phase = (os.environ[k] for k in ('CHILD_KIND','CHILD_SIGNAL','CHILD_PHASE'))
r = dict(phase=phase, kind=kind, signal=sig, install_rc=int(sys.argv[5]),
         bin_exists=binary.exists(), unit_exists=unit.exists(), config_exists=(etc/'config.yaml').exists(),
         stop_failure_reached=(sd/'child-stop-failure').exists(), udp_reply_after_exit=False, child_alive=False)
fd = None
if (sd/'child.json').exists():
    child = json.loads((sd/'child.json').read_text())
    r['child_pid'] = child['pid']
    try:
        fd = os.pidfd_open(child['pid'])
        stat = pathlib.Path('/proc/%s/stat'%child['pid']).read_text().rsplit(')',1)[1].split()
        if stat[19] != child['start']:
            os.close(fd); fd = None
        else:
            poll = select.poll(); poll.register(fd, select.POLLIN)
            r['child_alive'] = not bool(poll.poll(0))
    except ProcessLookupError:
        pass
    except FileNotFoundError:
        pass
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        s.settimeout(0.2)
        s.sendto(b'fixture-probe',('127.0.0.1',child['port']))
        try: r['udp_reply_after_exit'] = s.recv(128) == b'fixture-reply'
        except (TimeoutError,ConnectionRefusedError): pass
print('CHILD_RESULT '+json.dumps(r, sort_keys=True), flush=True)
# Clean only this fixture's exact process AFTER observing the product result.
if fd is not None:
    try: signal.pidfd_send_signal(fd,signal.SIGKILL)
    except ProcessLookupError: pass
    poll = select.poll(); poll.register(fd,select.POLLIN)
    assert poll.poll(2000), 'fixture cleanup could not stop child'
    os.close(fd)
files = (r['bin_exists'],r['unit_exists'],r['config_exists'])
assert 'child_pid' in r, 'fixture child was not launched'
if kind in ('signal','window','repeated'):
    assert r['install_rc'] == (130 if sig == 'INT' else 143), r
    assert not r['child_alive'] and not r['udp_reply_after_exit'], 'signal rollback left a live child'
    assert not any(files), 'stopped signal rollback retained server files'
elif kind in ('stopfail','signal-stopfail'):
    assert r['stop_failure_reached'], 'stop-failure injection was not reached'
    if kind == 'signal-stopfail': assert r['install_rc'] == 143, r
    assert r['install_rc'] != 0 and all(files), 'failed stop must fail and preserve all server files'
    assert r['child_alive'] and r['udp_reply_after_exit'], 'stop-failure control did not retain the real child'
    assert '保留' in pathlib.Path(sys.argv[6]).read_text(), 'retention reason not reported'
else:
    assert r['install_rc'] == 0 and all(files), 'normal install control failed'
    assert not r['child_alive'] and not r['udp_reply_after_exit'], 'normal completion left a live child'
PY_RESULT
    done
done
cp -- "$work/original-hysteria" "$TOOLBOX_HY2_BIN_SRC"
TOOLBOX_HY2_SHA256=$(sha256sum "$TOOLBOX_HY2_BIN_SRC" | cut -d' ' -f1)
reset
[[ $child_failures == 0 ]] || fail 'live smoke/probe signal and stop controls'
printf 'PASS: live smoke/probe signals, launch windows, normal and failed-stop controls\n'

out=$(toolbox_hy2 install <<< 0 2>&1) && fail 'cancel accepted as install'
[[ $out == *'1 自动生成自签'* && $out == *'2 已有证书'* && $out == *'0 取消'* ]] || fail 'certificate choice missing before path prompts'
assert_clean 'self mode cancel'
[[ ! -s $SD/systemctl.log && ! -s $SD/stub.log ]] || fail 'cancel crossed service boundary'
printf 'PASS: certificate choice and cancellation
'

# Negative probe setup failure must not masquerade as a pin rejection.
(
    eval "$(declare -f hy2_probe | sed '1s/hy2_probe/hy2_original_probe/')"
    hy2_probe() { [[ ${6:-} != badpin ]] || return 1; hy2_original_probe "$@"; }
    export MOCK_PORT=18443
    toolbox_hy2 install-self 192.0.2.10 www.cloudflare.com 18443 <<< $'YES\nYES' >"$work/probe-boundary.out" 2>&1 \
        && fail 'pin probe not executed but installation reported verified'
    assert_clean 'pin probe setup failure'
)
printf 'PASS: pin probe must really execute\n'
reset

# Cancellation at every input/confirmation (including partial YES at EOF)
# must not generate a key, download, create a service or long-lived file.
(
    hy2_generate_self() { printf called >> "$work/generated"; return 91; }
    for input in '' '1' $'1\n' $'1\n\n' $'1\n\n192.0.2.10\n' \
        $'1\n\n192.0.2.10\n\n' $'1\n\n192.0.2.10\n\nn\n' \
        $'1\n\n192.0.2.10\n\nYES\n' $'1\n\n192.0.2.10\n\nYES\nn\n' \
        $'1\n\n192.0.2.10\n\nYES\nYES'; do
        printf '%s' "$input" | toolbox_hy2 install >"$work/cancel.out" 2>&1 && fail 'incomplete input accepted'
        assert_clean 'incomplete input'
        [[ ! -e $work/generated && ! -e $(hy2_lock) && ! -s $SD/stub.log && ! -s $SD/curl.log ]] || fail 'cancel generated credentials or mutated resources'
    done
)
printf 'PASS: cancellation/EOF before all mutations\n'

# Address validation and separate endpoint; do not infer one from certificate SNI.
for bad in '' 'https://example.com' 'example.com:443' '[2001:db8::1]' '::gg' '127.00.0.1' \
    '1.2.3.999' 'example.com/path' 'a b.com' 'x;echo.bad' 'fe80::1%eth0'; do
    hy2_valid_endpoint "$bad" && fail 'bad endpoint accepted'
done
for good in 192.0.2.10 2001:db8::1 ::1 edge.example.com; do
    hy2_valid_endpoint "$good" || fail 'valid endpoint refused'
done
for input in $'1\n\n\n\nYES\nYES\n' $'1\nbad_sni\n192.0.2.10\n\nYES\nYES\n'; do
    toolbox_hy2 install <<< "$input" >"$work/invalid.out" 2>&1 && fail 'invalid wizard values accepted'
    assert_clean 'invalid wizard values'
done
printf 'PASS: independent endpoint and strict address validation\n'

# Three real certificate/export rounds; service boundary remains mocked.
for endpoint in 192.0.2.10 2001:db8::1 edge.example.com; do
    reset; export MOCK_PORT=18443
    out=$(printf '1\n\n%s\n18443\nYES\nYES\n' "$endpoint" | toolbox_hy2 install 2>&1) \
        || { printf '%s\n' "$out" >&2; fail 'self-signed wizard failed'; }
    [[ $out == *'不是 Apple/Cloudflare'* && $out == *'365 天'* && $out == *'不自动续期'* ]] || fail 'certificate provenance/expiry not disclosed'
    [[ $out != *'hysteria2://'* ]] || fail 'share link leaked'
    printf '%s' "$out" >"$work/report.out"
    python3 - "$(hy2_etc)" "$endpoint" "$work/report.out" <<'PY_VERIFY'
import pathlib,sys,re,subprocess,yaml,urllib.parse
from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
p=pathlib.Path(sys.argv[1]); endpoint=sys.argv[2]
c=x509.load_pem_x509_certificate((p/'cert.pem').read_bytes())
assert isinstance(c.public_key(),ec.EllipticCurvePublicKey)
assert c.public_key().curve.name == 'secp256r1'
assert c.signature_hash_algorithm.name == 'sha256'
assert c.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)==['www.cloudflare.com']
assert (c.not_valid_after_utc-c.not_valid_before_utc).total_seconds()==365*86400
pin=c.fingerprint(hashes.SHA256()).hex()
fp=subprocess.check_output(['openssl','x509','-in',str(p/'cert.pem'),'-noout','-fingerprint','-sha256'],text=True).strip().split('=')[1]
assert re.fullmatch(r'(?:[0-9A-F]{2}:){31}[0-9A-F]{2}',fp) and fp.replace(':','').lower()==pin
server=yaml.safe_load((p/'config.yaml').read_text()); pw=server['auth']['password']
assert re.fullmatch('[a-zA-Z0-9]{32}',pw) and pw not in pathlib.Path(sys.argv[3]).read_text()
for name in ('cert.pem','key.pem','config.yaml','meta','hysteria2.txt','client.yaml','mihomo.yaml'):
    assert (p/name).stat().st_mode & 0o777 == 0o600
u=urllib.parse.urlsplit((p/'hysteria2.txt').read_text().strip()); q=urllib.parse.parse_qs(u.query)
assert u.hostname==endpoint and u.port==18443 and u.username==pw
assert q=={'sni':['www.cloudflare.com'],'insecure':['1'],'pinSHA256':[pin]}
addr='['+endpoint+']' if ':' in endpoint else endpoint
cfg=yaml.safe_load((p/'client.yaml').read_text())
assert cfg['server']==addr+':18443' and cfg['auth']==pw
assert cfg['tls']=={'sni':'www.cloudflare.com','insecure':True,'pinSHA256':pin}
m=yaml.safe_load((p/'mihomo.yaml').read_text()); proxy=m['proxies'][0]
assert proxy['server']==endpoint and proxy['port']==18443 and proxy['password']==pw
assert proxy['sni']=='www.cloudflare.com' and proxy['fingerprint']==pin and proxy['skip-cert-verify'] is False
assert m['allow-lan'] is False and m['rules']==['MATCH,PROXY']
assert (p/'meta').read_text().strip().split('|')==['www.cloudflare.com','18443','1','2.13.0']
PY_VERIFY
    grep -q 'no certificate matches the pinned hash' "$(hy2_client_dir)/badpin.log" || fail 'pin rejection not observed'
    grep -q 'badpin.yaml' "$SD/stub.log" || fail 'pin client not run'
    [[ $(sed -n 's/^  pinSHA256: //p' "$(hy2_client_dir)/good.yaml") != $(sed -n 's/^  pinSHA256: //p' "$(hy2_client_dir)/badpin.yaml") ]] || fail 'negative pin unchanged'
    toolbox_hy2 uninstall <<< YES >/dev/null 2>&1 || fail 'self uninstall failed'
    [[ ! -e $(hy2_etc) && ! -e $(hy2_client_dir) ]] || fail 'self uninstall left exports or probes'
    printf 'PASS: self certificate, exports and uninstall (%s)\n' "$endpoint"
done
reset

# Explicit self CLI, custom SNI, first/second confirmations and encrypted key refusal.
export MOCK_PORT=18443
out=$(toolbox_hy2 install-self 192.0.2.11 cert.example.com 18443 <<< $'yes\nYeS' 2>&1) || fail 'explicit self CLI failed'
openssl x509 -in "$(hy2_etc)/cert.pem" -noout -checkhost cert.example.com | grep -q 'does match' || fail 'custom SAN ignored'
toolbox_hy2 uninstall <<< YES >/dev/null 2>&1 || fail 'explicit self uninstall failed'
reset
openssl pkey -in "$work/good.key" -aes-256-cbc -passout pass:fixture-only -out "$work/encrypted.key" >/dev/null 2>&1
out=$(toolbox_hy2 install "$work/good.crt" "$work/encrypted.key" "$GOOD_H" 18443 <<< YES 2>&1) && fail 'encrypted key accepted'
[[ $out == *'仅接受无口令'* ]] || fail 'encrypted key rejection unclear'
assert_clean 'encrypted key'
printf 'PASS: explicit self/custom SNI and encrypted key refusal\n'

# Every post-confirmation failure cleans staged key/cert and owned exports.
for failure in generate download smoke export publish probe-pin; do
    reset
    (
        export MOCK_PORT=18443
        case $failure in
            generate) hy2_generate_self() { touch "$1/self.key"; return 1; };;
            download) hy2_fetch() { return 1; };;
            smoke) hy2_smoke() { return 1; };;
            export) hy2_export_clients() { printf partial > "$1/client.yaml"; return 1; };;
            publish)
                eval "$(declare -f hy2_place | sed '1s/hy2_place/hy2_original_place/')"
                hy2_place() { [[ $3 != */mihomo.yaml ]] || return 1; hy2_original_place "$@"; };;
            probe-pin) touch "$SD/accept_pin_any";;
        esac
        toolbox_hy2 install-self 192.0.2.10 www.cloudflare.com 18443 <<< $'YES\nYES' >"$work/failure.out" 2>&1 && fail 'injected failure ignored'
        assert_clean 'self failure rollback'
        [[ ! -e $SD/active && ! -e $(hy2_client_dir) ]] || fail 'failure retained own running service/probe'
        [[ -z $(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'tmp.*' -print) ]] || fail 'staging credentials leaked'
    )
    rm -f "$SD/accept_pin_any"
    printf 'PASS: self rollback (%s)\n' "$failure"
done
reset
# Invalid fingerprint output cannot be exported, even when openssl exits zero.
(
    openssl() { printf 'sha256 Fingerprint=not-a-fingerprint\n'; }
    hy2_pin "$work/good.crt" >/dev/null 2>&1 && fail 'malformed openssl fingerprint accepted'
    :
)
# A source certificate changed after consent is not the certificate trusted.
(
    eval "$(declare -f hy2_fetch | sed '1s/hy2_fetch/hy2_original_fetch/')"
    hy2_fetch() { cp "$work/other.crt" "$work/race.crt"; hy2_original_fetch "$@"; }
    cp "$work/good.crt" "$work/race.crt"
    export MOCK_PORT=18443
    toolbox_hy2 install "$work/race.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >"$work/race.out" 2>&1 && fail 'changed source cert accepted'
    assert_clean 'changed certificate'
)
reset
# Self mode must not bypass explicit trust policy inherited by a caller.
TOOLBOX_HY2_CAFILE="$work/good.crt" toolbox_hy2 install-self 192.0.2.10 www.cloudflare.com 18443 <<< $'YES\nYES' >/dev/null 2>&1 && fail 'self mode ignored explicit CA'
assert_clean 'explicit CA on self mode'
printf 'PASS: pin format, copy race and explicit CA rejection\n'

# SIGTERM after generation and after publication must remove owned material.
for phase in generated published; do
    reset
    (
        export MOCK_PORT=18443
        if [[ $phase == generated ]]; then
            eval "$(declare -f hy2_generate_self | sed '1s/hy2_generate_self/hy2_original_generate/')"
            hy2_generate_self() { hy2_original_generate "$@" || return; kill -TERM "$BASHPID"; }
        else
            hy2_smoke() { kill -TERM "$BASHPID"; }
        fi
        rc=0
        toolbox_hy2 install-self 192.0.2.10 www.cloudflare.com 18443 <<< $'YES\nYES' >"$work/signal.out" 2>&1 || rc=$?
        [[ $rc == 143 ]] || fail 'SIGTERM result not propagated'
        assert_clean 'SIGTERM'
        [[ -z $(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'tmp.*' -print) ]] || fail 'SIGTERM staging leaked'
    )
    printf 'PASS: signal cleanup (%s)\n' "$phase"
done
reset

# Inherited xtrace must not turn a file-only credential flow into plaintext logs.
(
    export MOCK_PORT=18443
    set -x
    toolbox_hy2 install-self 192.0.2.10 www.cloudflare.com 18443 <<< $'YES\nYES'
) >"$work/trace.out" 2>&1 || fail 'trace install failed'
python3 - "$(hy2_etc)/config.yaml" "$work/trace.out" <<'PY_TRACE'
import pathlib,sys,yaml
pw=yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())['auth']['password']
assert pw not in pathlib.Path(sys.argv[2]).read_text(), 'generated password leaked through xtrace'
PY_TRACE
toolbox_hy2 uninstall <<< YES >/dev/null 2>&1 || fail 'trace uninstall failed'
reset
printf 'PASS: xtrace credential suppression\n'
printf 'All hy2 self-cert tests passed.\n'
