#!/usr/bin/env bash
# Offline A5 target checks. Only certificate creation/parsing uses real OpenSSL;
# TLS, timeout, trust-store results, package managers and services are fixtures.
# Run on the project development server, never as a host acceptance test.
# TOOLBOX_NETWORK_SOURCE may select modules/network.sh or a built toolbox script.
# shellcheck disable=SC2016,SC1090
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/scratch-root.sh"
toolbox_test_scratch
scratch_base=$TMPDIR
work=$(mktemp -d "$scratch_base/network-a5-target.XXXXXXXX")
printf 'toolbox-network-a5-target-fixture\n' > "$work/.fixture"
guard_log=$work/forbidden
: > "$guard_log"
cleanup() {
    local cleanup_rc=$?
    trap - EXIT
    if [[ -s $guard_log ]]; then
        printf 'FAIL: an unmocked host command was attempted\n' >&2
        /bin/cat "$guard_log" >&2
        cleanup_rc=1
    fi
    if [[ $work == "$scratch_base"/network-a5-target.* && -d $work && ! -L $work && -O $work && -f $work/.fixture ]] &&
       [[ $(<"$work/.fixture") == toolbox-network-a5-target-fixture ]]; then
        /bin/rm -rf -- "$work"
    else
        printf 'FAIL: fixture ownership changed; retained %s\n' "$work" >&2
        cleanup_rc=1
    fi
    exit "$cleanup_rc"
}
trap cleanup EXIT
mkdir -p "$work/bin" "$work/state" "$work/tmp"
export TMPDIR=$work/tmp A5_TARGET_STATE=$work/state A5_TARGET_FORBIDDEN=$guard_log
export PATH="$work/bin:/usr/bin:/bin" LC_ALL=C OPENSSL_CONF=/dev/null
# The existing source --help convention loads bundles without entering a menu.
# Its existing elevation marker prevents a non-root test from invoking sudo.
export TOOLBOX_ELEVATED=1 TOOLBOX_OS_RELEASE=$work/os-release
printf 'ID=debian\n' > "$TOOLBOX_OS_RELEASE"

guard_commands=(sudo doas apt apt-get apt-cache aptitude apk dpkg dpkg-query dnf yum
    systemctl service rc-service rc-update reboot shutdown mount umount
    sysctl modprobe insmod rmmod depmod ip iptables ip6tables nft
    curl wget ssh scp nc ncat netcat socat docker podman install)
for command_name in "${guard_commands[@]}"; do
    {
        printf '#!/bin/bash\n'
        printf 'printf "%%s\\n" "$0 $*" >> %q\n' "$guard_log"
        printf 'printf "UNMOCKED host boundary: %%s\\n" "$0" >&2\nexit 99\n'
    } > "$work/bin/$command_name"
    chmod 0755 "$work/bin/$command_name"
done

cat > "$work/bin/timeout" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ $# != 11 || $1 != 20 || $2 != openssl ]]; then
    printf 'unexpected timeout arguments: %s\n' "$*" >> "$A5_TARGET_FORBIDDEN"
    exit 99
fi
printf 'timeout\n' >> "$A5_TARGET_STATE/probe.trace"
shift
probe_rc=0
"$@" || probe_rc=$?
forced_rc=$(<"$A5_TARGET_STATE/timeout.rc")
[[ $forced_rc == inherit ]] || probe_rc=$forced_rc
exit "$probe_rc"
STUB

cat > "$work/bin/openssl" <<'STUB'
#!/bin/bash
set -euo pipefail
deny() {
    printf 'unexpected openssl invocation: %s\n' "$*" >> "$A5_TARGET_FORBIDDEN"
    exit 99
}
case ${1:-} in
    s_client)
        [[ $# == 9 && $2 == -connect && $3 == dest.example.test:443 &&
           $4 == -servername && $5 == dest.example.test && $6 == -tls1_3 &&
           $7 == -alpn && $8 == h2 && $9 == -showcerts ]] || deny "$@"
        input=''
        if IFS= read -r input || [[ -n $input ]]; then
            deny 's_client received unexpected input'
        fi
        printf 's_client\n' >> "$A5_TARGET_STATE/probe.trace"
        /bin/cat "$A5_TARGET_STATE/raw"
        exit "$(<"$A5_TARGET_STATE/openssl.rc")"
        ;;
    x509)
        [[ $# == 6 && $2 == -in && $3 == "$TMPDIR/"* &&
           $4 == -noout && $5 == -checkhost && $6 == dest.example.test ]] || deny "$@"
        # Parsing and hostname matching stay real; this cannot open a socket.
        exec /usr/bin/openssl "$@"
        ;;
    verify)
        [[ ( $# == 4 || $# == 6 ) && $2 == -CAfile &&
           $3 == /etc/ssl/certs/ca-certificates.crt && ${!#} == "$TMPDIR/"* ]] || deny "$@"
        if [[ $# == 6 ]]; then
            [[ $4 == -untrusted && $5 == "$TMPDIR/"* ]] || deny "$@"
        fi
        # Host trust policy is outside this parser regression, so its result is
        # deterministic even though the fixture certificates are self-signed.
        exit 0
        ;;
    *) deny "$@" ;;
esac
STUB
chmod 0755 "$work/bin/timeout" "$work/bin/openssl"
hash -r

for cert_name in good wrong; do
    cert_host=dest.example.test
    [[ $cert_name == good ]] || cert_host=other.example.test
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
        -keyout "$work/$cert_name.key" -out "$work/$cert_name.crt" \
        -subj "/CN=$cert_host" -addext "subjectAltName=DNS:$cert_host" \
        > "$work/certificate.out" 2>&1 || {
            /bin/cat "$work/certificate.out" >&2
            printf 'FAIL: unable to create offline fixture certificate\n' >&2
            exit 1
        }
done

source "${TOOLBOX_NETWORK_SOURCE:-$ROOT/modules/network.sh}" --help > "$work/source.out" 2> "$work/source.err"
declare -F net_a5_check_target >/dev/null
[[ ! -s $guard_log ]]
pass_count=0
case_name='source'
fail() {
    printf 'FAIL [%s]: %s\n' "$case_name" "$*" >&2
    [[ ! -f $work/state/result ]] || /bin/cat "$work/state/result" >&2
    exit 1
}

# Each case exercises the actual probe plus its temp-file cleanup. The timeout
# mock runs only our s_client mock, then emulates timeout's own exit status.
run_case() { # label pass|reject protocol alpn good|wrong|missing|invalid [openssl rc] [timeout rc] [error]
    local expected=$2 protocol=$3 alpn=$4 cert_kind=$5 result_rc=0
    case_name=$1
    printf '%s\n' "${6:-0}" > "$work/state/openssl.rc"
    printf '%s\n' "${7:-inherit}" > "$work/state/timeout.rc"
    : > "$work/state/probe.trace"
    {
        printf 'CONNECTED(00000003)\n---\nCertificate chain\n'
        case $cert_kind in
            good|wrong) /bin/cat "$work/$cert_kind.crt" ;;
            missing) : ;;
            invalid) printf '%s\n' '-----BEGIN CERTIFICATE-----' 'invalid-base64' '-----END CERTIFICATE-----' ;;
            *) fail 'invalid certificate fixture mode' ;;
        esac
        printf '%s\n' '---' 'SSL handshake has read 3000 bytes and written 300 bytes' 'Verification: OK' '---'
        [[ -z $protocol ]] || printf '%s\n' "$protocol"
        [[ -z $alpn ]] || printf '%s\n' "$alpn"
        printf 'Verify return code: 0 (ok)\n'
        [[ -z ${8:-} ]] || printf '%s\n' "$8"
    } > "$work/state/raw"
    net_a5_check_target dest.example.test 443 dest.example.test > "$work/state/result" 2>&1 || result_rc=$?
    if [[ $expected == pass ]]; then
        [[ $result_rc == 0 ]] || fail 'valid TLS 1.3/h2/hostname result rejected'
    else
        [[ $result_rc != 0 ]] || fail 'invalid or failed probe accepted'
        [[ -s $work/state/result ]] || fail 'rejection omitted its diagnostic'
    fi
    [[ $(<"$work/state/probe.trace") == $'timeout\ns_client' ]] || fail 'probe skipped its timeout or ran more than once'
    [[ ! -s $guard_log ]] || fail 'attempted an unmocked host command'
    local leftovers
    shopt -s nullglob dotglob
    leftovers=("$TMPDIR"/*)
    (( ${#leftovers[@]} == 0 )) || fail 'probe leaked temporary files'
    pass_count=$((pass_count + 1))
    printf 'PASS: %s\n' "$case_name"
}

tls13='New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384'
session13='    Protocol  : TLSv1.3'
h2='ALPN protocol: h2'
run_case 'OpenSSL 1.1.1 TLS 1.3 without session ticket' pass "$tls13" "$h2" good
run_case 'reused TLS 1.3 without session details' pass 'Reused, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384' "$h2" good
run_case 'compact Protocol output' pass 'Protocol: TLSv1.3' "$h2" good
run_case 'session Protocol output only' pass "$session13" "$h2" good
run_case 'combined summary and session output' pass "$tls13"$'\n'"$session13" "$h2" good
run_case 'surrounding protocol whitespace' pass $' \tNew, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384 \t' "$h2" good
run_case 'AES 128 TLS 1.3 cipher' pass 'New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256' "$h2" good
run_case 'ChaCha20 TLS 1.3 cipher' pass 'New, TLSv1.3, Cipher is TLS_CHACHA20_POLY1305_SHA256' "$h2" good

run_case 'TLS 1.2 summary rejected' reject 'New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384' "$h2" good
run_case 'TLS 1.2 session rejected' reject '    Protocol  : TLSv1.2' "$h2" good
run_case 'missing protocol evidence rejected' reject '' "$h2" good
run_case 'unrequested brief output rejected' reject 'Protocol version: TLSv1.3' "$h2" good
run_case 'unstructured TLS text rejected' reject 'Server supports TLSv1.3' "$h2" good
run_case 'prefixed summary rejected' reject "subject=CN=$tls13" "$h2" good
run_case 'prefixed Protocol rejected' reject 'subject=CN=Protocol: TLSv1.3' "$h2" good
run_case 'summary suffix rejected' reject "$tls13 extra" "$h2" good
run_case 'Protocol suffix rejected' reject 'Protocol: TLSv1.3 extra' "$h2" good
run_case 'summary TLSv1.30 prefix rejected' reject 'New, TLSv1.30, Cipher is TLS_AES_256_GCM_SHA384' "$h2" good
run_case 'Protocol TLSv1.30 prefix rejected' reject 'Protocol: TLSv1.30' "$h2" good
run_case 'missing cipher rejected' reject 'New, TLSv1.3, Cipher is ' "$h2" good
run_case 'NONE cipher rejected' reject 'New, TLSv1.3, Cipher is NONE' "$h2" good
run_case 'parenthesized NONE cipher rejected' reject 'New, TLSv1.3, Cipher is (NONE)' "$h2" good
run_case 'legacy cipher with claimed TLS 1.3 rejected' reject 'New, TLSv1.3, Cipher is ECDHE-RSA-AES256-GCM-SHA384' "$h2" good

run_case 'missing certificate rejected' reject "$tls13" "$h2" missing
run_case 'invalid PEM certificate rejected' reject "$tls13" "$h2" invalid
run_case 'missing ALPN rejected' reject "$tls13" '' good
run_case 'no negotiated ALPN rejected' reject "$tls13" 'No ALPN negotiated' good
run_case 'h2c is not h2' reject "$tls13" 'ALPN protocol: h2c' good
run_case 'prefixed ALPN rejected' reject "$tls13" "subject=CN=$h2" good
run_case 'ALPN suffix rejected' reject "$tls13" "$h2 extra" good
run_case 'real certificate hostname mismatch rejected' reject "$tls13" "$h2" wrong

run_case 'exit 1 with full successful-looking transcript rejected' reject "$tls13"$'\n'"$session13" "$h2" good 1
run_case 'exit 2 with certificate and summary rejected' reject "$tls13" "$h2" good 2
run_case 'fatal TLS error after certificate rejected' reject "$tls13" "$h2" good 1 inherit 'error:0A000126:SSL routines::unexpected eof while reading'
run_case 'timeout 124 with complete transcript rejected' reject "$tls13"$'\n'"$session13" "$h2" good 0 124
run_case 'killed timeout 137 with complete transcript rejected' reject "$tls13" "$h2" good 0 137
run_case 'timeout internal failure 125 rejected' reject "$tls13" "$h2" good 0 125
run_case 'command unavailable 127 despite transcript rejected' reject "$tls13" "$h2" good 0 127
run_case 'network failure without certificate rejected' reject '' '' missing 1 inherit 'connect: Connection refused'

printf 'PASS: A5 target regression: %s isolated cases; no network or service operations\n' "$pass_count"
