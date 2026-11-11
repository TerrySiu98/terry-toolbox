#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
[[ -f modules/shadowsocks.sh ]] || { echo 'FAIL: module missing' >&2; exit 1; }
source modules/shadowsocks.sh
for f in toolbox_shadowsocks ssx_valid_endpoint ssx_valid_port ssx_write_configs ssx_port_free; do
 declare -F "$f" >/dev/null || { echo "FAIL: missing $f" >&2; exit 1; }
done
ssx_valid_endpoint example.com
ssx_valid_endpoint 127.0.0.1
ssx_valid_endpoint ::1
! ssx_valid_endpoint 'bad/x'
ssx_valid_port 8388
! ssx_valid_port 65536
! ssx_valid_port 00
stage=$(mktemp -d "${TMPDIR:-/root}/ssx-test.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
ssx_write_configs "$stage" example.com 8388 0.0.0.0
python3 - "$stage" <<'PY_TEST'
import base64,json,os,stat,sys,urllib.parse
p=sys.argv[1]
for n in ('config.json','client.json','mihomo.yaml','shadowsocks.txt'):
 assert stat.S_IMODE(os.stat(p+'/'+n).st_mode)==0o600,n
s=json.load(open(p+'/config.json')); c=json.load(open(p+'/client.json'))
i=s['inbounds'][0]; assert i['protocol']=='shadowsocks' and i['settings']['network']=='tcp,udp'
assert i['settings']['method']=='chacha20-ietf-poly1305'
passwd=i['settings']['password']; assert len(passwd)>=32
assert c['outbounds'][0]['settings']['servers'][0]['password']==passwd
uri=open(p+'/shadowsocks.txt').read().strip(); u=urllib.parse.urlsplit(uri); assert u.scheme=='ss' and u.hostname=='example.com' and u.port==8388
assert base64.urlsafe_b64decode(u.username+'='*(-len(u.username)%4)).decode()=='chacha20-ietf-poly1305:'+passwd
assert passwd in open(p+'/mihomo.yaml').read()
print('config/export checks passed')
PY_TEST
# Port parser must reject failed/malformed ss, and never confuse TCP with UDP.
mkdir "$stage/bin"
cat > "$stage/bin/ss" <<'MOCK'
#!/usr/bin/env bash
case ${SS_TEST_MODE:-none}:$1 in
 fail:*) exit 42;; malformed:*) printf 'broken\n';;
 tcp:-ltnpH) printf 'LISTEN 0 128 127.0.0.1:8388 0.0.0.0:*\n';;
 udp:-uanpH) printf 'UNCONN 0 0 127.0.0.1:8388 0.0.0.0:*\n';;
esac
MOCK
chmod 755 "$stage/bin/ss"
export PATH="$stage/bin:$PATH"
for SS_TEST_MODE in tcp udp fail malformed; do
 export SS_TEST_MODE
 if ssx_port_free 8388 >/dev/null 2>&1; then echo "FAIL: port check $SS_TEST_MODE" >&2; exit 1; fi
done
SS_TEST_MODE=none; export SS_TEST_MODE; ssx_port_free 8388
# No backend guessing even if an inherited variable is set.
ssx_install() { printf 'backend=%s\n' "${SSX_BACKEND:-none}"; }
[[ $(SSX_BACKEND=alpine toolbox_shadowsocks systemd install) == backend=systemd ]]
[[ $(SSX_BACKEND=systemd toolbox_shadowsocks alpine install) == backend=alpine ]]
printf '%s\n' 'PASS shadowsocks focused' 
