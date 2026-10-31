#!/usr/bin/env bash
# Dedicated integration helper. Only prepare a private fixture; no install/service,
# firewall, DNS, trust-store changes or implicit challenge bypass. Father executes
# issue/renew in an isolated Debian/Ubuntu systemd VM with real Certbot + Pebble.
# Usage: bash tests/tls-acme-integration.sh prepare BASE HOST CA_URL REQUESTS_CA CERT_CA
# BASE must be fresh /root/.../tls-acme-fixture-*; PEM anchors copied privately.
# CA hostname must resolve solely to loopback in guest (e.g. /etc/hosts fixture);
# --server https://acme-fixture.example.test:14000/dir is supported. Pebble must have
# httpPort=80, never PEBBLE_VA_ALWAYS_VALID=1 or validation skip. Certificate anchor
# is Pebble issuer/root, separate from ACME HTTPS API CA. No insecure fallback.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ ${1:-} == prepare && $# == 6 ]] || { printf 'Usage: %s prepare /root/.../tls-acme-fixture-NAME HOST HTTPS_CA_DIR REQUESTS_CA_PEM CERT_CA_PEM\n' "$0" >&2; exit 2; }
shift
python3 - "$@" "${TOOLBOX_TLS_ACME_INTEGRATION_SYSTEMD_UNITS:-0}" "${TOOLBOX_TLS_ACME_INTEGRATION_TIMER_SECONDS:-}" <<'PY'
import sys,os,stat,re,json,hashlib,socket,ipaddress,subprocess
from urllib.parse import urlsplit
base,host,server,requests_ca,cert_ca,systemd_units,timer_seconds=sys.argv[1:]
unitdir='/etc/systemd/system' if systemd_units=='1' else base+'/units'
if systemd_units not in ('0','1'): raise SystemExit('SYSTEMD_UNITS must be explicitly 0 or 1')
if os.geteuid()!=0: raise SystemExit('root required inside disposable VM')
if not re.fullmatch(r'/root/[A-Za-z0-9_./-]*tls-acme-fixture-[A-Za-z0-9_-]+',base) or any(x in ('','.','..') for x in base.split('/')[1:]): raise SystemExit('unsafe/nonfixture base')
if not re.fullmatch(r'([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}',host):raise SystemExit('invalid hostname')
u=urlsplit(server)
if u.scheme!='https' or u.path!='/dir' or not u.port or u.username or u.password or u.query or u.fragment:raise SystemExit('HTTPS CA directory required')
if u.hostname not in ('127.0.0.1','localhost') and not re.fullmatch(r'[a-z0-9.-]+\.test',u.hostname or ''):raise SystemExit('isolated loopback/.test CA required')
a={a[4][0] for a in socket.getaddrinfo(u.hostname,u.port,type=socket.SOCK_STREAM)}
if not a or any(not ipaddress.ip_address(x).is_loopback for x in a):raise SystemExit('guest CA hostname must resolve ONLY to loopback')
# No symlink / writable parent (same gate as production module).
p='/'
for part in os.path.dirname(base).split('/')[1:]:
    p=os.path.join(p,part);s=os.lstat(p)
    if not stat.S_ISDIR(s.st_mode) or s.st_uid!=0 or s.st_mode&0o022:raise SystemExit('unsafe fixture ancestor '+p)
anchors=[]
for source in (requests_ca,cert_ca):
    s=os.lstat(source)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise SystemExit('anchor must be exclusive regular PEM')
    b=open(source,'rb').read()
    if b'PRIVATE KEY' in b or b'BEGIN CERTIFICATE' not in b:raise SystemExit('anchor must contain only public CA certificate PEM')
    subprocess.run(['openssl','x509','-in',source,'-noout'],check=True)
    anchors.append(b)
os.mkdir(base,0o700);os.mkdir(base+'/units',0o700)
def put(n,b):
    fd=os.open(base+'/'+n,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as f:f.write(b)
put('requests-ca.pem',anchors[0]);put('certificate-ca.pem',anchors[1])
addresses=sorted({x[4][0] for x in socket.getaddrinfo(host,80,type=socket.SOCK_STREAM)})
if not addresses:raise SystemExit('no guest domain fixture A/AAAA')
d={'version':1,'root':base+'/owned','units':unitdir,'server':server,'requests_ca':base+'/requests-ca.pem','cert_ca':base+'/certificate-ca.pem','host':host,'addresses':addresses,'mock_systemd':False}
if timer_seconds:
    if systemd_units!='1' or not timer_seconds.isdigit() or not 60<=int(timer_seconds)<=600:raise SystemExit('native timer interval must be 60..600 seconds with real systemd units')
    d['timer_seconds']=int(timer_seconds)
b=(json.dumps(d,sort_keys=True)+'\n').encode();put('fixture.json',b);put('fixture.json.sha256',(hashlib.sha256(b).hexdigest()+'\n').encode())
print('Created isolated fixture: '+base+'/fixture.json')
PY
printf '\nIn that disposable VM only, use the real source module:\n'
printf 'source %q\n' "$ROOT/modules/tls-acme.sh"
unitdir="$1/units"
if [[ ${TOOLBOX_TLS_ACME_INTEGRATION_SYSTEMD_UNITS:-0} == 1 ]]; then unitdir=/etc/systemd/system; fi
printf 'export TOOLBOX_TLS_ACME_ROOT=%q TOOLBOX_TLS_ACME_UNIT_DIR=%q TOOLBOX_TLS_ACME_TEST_FIXTURE=%q\n' "$1/owned" "$unitdir" "$1/fixture.json"
printf 'toolbox_tls_acme issue %q admin@example.test\n' "$2"
printf 'toolbox_tls_acme status %q\n' "$2"
printf 'TOOLBOX_TLS_ACME_TEST_FORCE_RENEWAL=1 toolbox_tls_acme renew %q\n' "$2"
printf '\nPrerequisites: existing stable Certbot + standalone dependencies, openssl/python3/ss/timeout; PID1 systemd; actual free TCP80; guest/challtestsrv DNS routes HOST to standalone. Pin and record official Pebble binary checksum; trust correct private API CA and current Pebble certificate root. No skipped HTTP-01. Verify archive generation and real openssl hostname/time/keypair before claiming issue/rotation. Set TOOLBOX_TLS_ACME_INTEGRATION_SYSTEMD_UNITS=1 when preparing a fresh fixture to opt into the real guest /etc/systemd/system unit scope for timer tests; default fixture units directory is issue/renew-only. Do not change fixture/trust records after issue: their inodes/hash are sealed.\n'
