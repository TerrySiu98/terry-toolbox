#!/usr/bin/env bash
# Local tests only: Certbot/systemctl/ss/DNS are replaced at external boundaries.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Until the implementation exists this is an intended interface RED, not source error.
if [[ -f $ROOT/modules/tls-acme.sh ]]; then source "$ROOT/modules/tls-acme.sh"; fi
fail() { printf 'FAIL: %s (case %s)\n' "$*" "${C:-initial}" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
declare -F toolbox_tls_acme >/dev/null || fail 'TLS ACME public interface is not implemented'
python3 - "$ROOT/modules/tls-acme.sh" <<'PY'
import subprocess,sys
src=open(sys.argv[1]).read()
p=subprocess.run(['bash','-s'],input='set -u\nTOOLBOX_BUNDLED=1\n'+src+'\ndeclare -F toolbox_tls_acme >/dev/null\n',text=True,capture_output=True,timeout=15)
assert p.returncode==0 and p.stdout=='' and p.stderr=='',p.stderr
q=subprocess.run(['bash','-n'],input=src,text=True,capture_output=True,timeout=15);assert q.returncode==0,q.stderr
for operation,unlock,want in [(0,0,0),(7,0,7),(0,1,1),(7,1,1)]:
 script='TOOLBOX_BUNDLED=1\n'+src+'\ntls_acme_lock_id=fixture\ntls_acme_fs() { return '+str(unlock)+'; }\ntrap tls_acme_cleanup EXIT\nexit '+str(operation)+'\n'
 result=subprocess.run(['bash','-s'],input=script,text=True,capture_output=True,timeout=15)
 assert result.returncode==want,(operation,unlock,result.returncode,result.stderr)
PY
pass 'source-only/bundle syntax and EXIT cleanup propagates unlock failure'
tls_acme_valid example.com admin@example.com || fail 'valid hostname/email refused'
for h in '../example.com' '-bad.com' 'EXAMPLE.com' '*.example.com' 'example.com.' $'example.com\nx'; do
    if tls_acme_valid "$h" admin@example.com; then fail "unsafe hostname accepted: $h"; fi
done
for e in '' 'a' '-a@example.com' 'a@example.com;id' $'a@example.com\nx'; do
    if tls_acme_valid example.com "$e"; then fail 'unsafe email accepted'; fi
done
for input in '' 'YES' $'YES\nYES' $'YES\nno\n'; do
    if printf '%s' "$input" | tls_acme_confirm >/dev/null 2>&1; then fail 'cancel/unterminated EOF accepted'; fi
done
printf 'yEs\nYES\n' | tls_acme_confirm >/dev/null || fail 'double newline YES refused'
pass 'domain/email and complete-line dual confirmation'
test_tmp=${TOOLBOX_TEST_TMPDIR:-${TMPDIR:-/root/.cache/terry-toolbox-tests}}
mkdir -p -- "$test_tmp"
T=$(mktemp -d "$test_tmp/tls-acme-fixture-XXXXXXXX")
export T
eval "$(declare -f tls_acme_confirm | python3 -c 'import sys;print(sys.stdin.read().replace("tls_acme_confirm", "tls_acme_original_confirm", 1))')"
cleanup() {
    local rc=$?
    if (( rc != 0 )); then printf 'Failed TLS fixture retained: %s\n' "$T" >&2
    else python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$T"; fi
}
trap cleanup EXIT
python3 - "$T" <<'PY'
import sys,os,datetime
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import rsa
p=sys.argv[1]; now=datetime.datetime.now(datetime.timezone.utc)
ca=rsa.generate_private_key(public_exponent=65537,key_size=2048)
name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'LOCAL TEST ONLY')])
b=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(ca.public_key()).serial_number(1).not_valid_before(now-datetime.timedelta(days=1)).not_valid_after(now+datetime.timedelta(days=90)).add_extension(x509.BasicConstraints(ca=True,path_length=1),True)
cert=b.sign(ca,hashes.SHA256())
key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
def write(n,b):
    with open(p+'/'+n,'xb') as f:f.write(b)
    os.chmod(p+'/'+n,0o600)
write('ca.pem',cert.public_bytes(serialization.Encoding.PEM)); write('key.pem',key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.TraditionalOpenSSL,serialization.NoEncryption()))
write('wrong-key.pem',ca.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.TraditionalOpenSSL,serialization.NoEncryption()))
for n,host,before,after in [('cert.pem','example.com',-1,3),('wrong-host.pem','other.com',-1,3),('future.pem','example.com',1,3),('expired.pem','example.com',-3,-1),('near-expiry.pem','example.com',-1,1/48)]:
    leaf=x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,host)])).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now+datetime.timedelta(days=before)).not_valid_after(now+datetime.timedelta(days=after)).add_extension(x509.SubjectAlternativeName([x509.DNSName(host)]),False).add_extension(x509.BasicConstraints(ca=False,path_length=None),True).add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]),False).sign(ca,hashes.SHA256())
    write(n,leaf.public_bytes(serialization.Encoding.PEM))
PY
fixture() {
    C="$T/$1"; export C
    python3 - "$C" "$T" <<'PY'
import os,sys,json,hashlib
p,t=sys.argv[1:]
os.mkdir(p,0o700);os.mkdir(p+'/units',0o700);os.mkdir(p+'/run',0o700);os.mkdir(p+'/bin',0o700)
for n in ('ca.pem','cert.pem','key.pem','wrong-key.pem','wrong-host.pem','future.pem','expired.pem','near-expiry.pem'):
    with open(p+'/'+n,'xb') as f:f.write(open(t+'/'+n,'rb').read())
    os.chmod(p+'/'+n,0o600)
d={'version':1,'root':p+'/owned','units':p+'/units','server':'https://127.0.0.1:14000/dir','requests_ca':p+'/ca.pem','cert_ca':p+'/ca.pem','host':'example.com','addresses':['127.0.0.1'],'mock_systemd':True}
b=json.dumps(d).encode()
for n,data in [('fixture.json',b),('fixture.json.sha256',(hashlib.sha256(b).hexdigest()+'\n').encode()),('os-release',b'ID=debian\n'),('timer-state',b'inactive\n'),('calls',b'')]:
    with open(p+'/'+n,'xb') as f:f.write(data)
    os.chmod(p+'/'+n,0o600)
# Executable is a MOCK boundary, not an ACME client or real issuance evidence.
mock='''#!/usr/bin/python3
import os,sys,json,shutil
from urllib.parse import urlsplit
if sys.argv[1:]==['--version']:
 print('certbot 3.3.0');sys.exit(0)
p=os.environ['C'];a=sys.argv[1:]
with open(p+'/calls','a') as f:f.write('certbot '+json.dumps(a)+'\\n')
if os.getenv('CERTBOT_FAIL')=='1':print('private test failure');sys.exit(1)
r=a[a.index('--config-dir')+1];h=a[a.index('--cert-name')+1];server=a[a.index('--server')+1]
for d in ('archive','live','renewal','accounts','renewal-hooks','renewal-hooks/pre','renewal-hooks/post','renewal-hooks/deploy'):
 os.makedirs(r+'/'+d,mode=0o700,exist_ok=True)
for d in ('archive/'+h,'live/'+h):os.makedirs(r+'/'+d,mode=0o700,exist_ok=True)
account=r+'/accounts/'+os.getenv('ACCOUNT_SERVER',urlsplit(server).netloc)+'/'+os.getenv('ACCOUNT_DIR','dir')+'/'+os.getenv('ACCOUNT_ID','0123456789abcdef0123456789abcdef')
os.makedirs(account,mode=0o700,exist_ok=True)
for n in ('meta','regr','private_key'):
 with open(account+'/'+n+'.json','w') as f:json.dump({'mock':True},f)
 os.chmod(account+'/'+n+'.json',0o600)
if os.getenv('ACCOUNT_ATTACK'):
 attack=os.environ['ACCOUNT_ATTACK']
 if attack=='symlink':
  os.unlink(account+'/meta.json');os.symlink(p+'/ca.pem',account+'/meta.json')
 else:
  dst=r+'/'+attack
  os.makedirs(os.path.dirname(dst),mode=0o700,exist_ok=True)
  with open(dst,'w') as f:f.write('unowned')
  os.chmod(dst,0o600)
g=len(os.listdir(r+'/archive/'+h))//4+1
files={'cert':os.getenv('CERT_FILE','cert.pem'),'chain':'ca.pem','privkey':os.getenv('KEY_FILE','key.pem')}
for n,src in files.items():
 shutil.copyfile(p+'/'+src,r+'/archive/'+h+'/'+n+str(g)+'.pem');os.chmod(r+'/archive/'+h+'/'+n+str(g)+'.pem',0o600)
with open(r+'/archive/'+h+'/fullchain'+str(g)+'.pem','wb') as f:f.write(open(p+'/'+files['cert'],'rb').read()+open(p+'/ca.pem','rb').read())
os.chmod(r+'/archive/'+h+'/fullchain'+str(g)+'.pem',0o600)
for n in ('cert','chain','fullchain','privkey'):
 dst=r+'/live/'+h+'/'+n+'.pem'
 if os.path.lexists(dst):os.unlink(dst)
 os.symlink('../../archive/'+h+'/'+n+str(g)+'.pem',dst)
conf='version = 3.3.0\\narchive_dir = '+r+'/archive/'+h+'\\n'
for k,n in [('cert','cert'),('privkey','privkey'),('chain','chain'),('fullchain','fullchain')]:conf+=k+' = '+r+'/live/'+h+'/'+n+'.pem\\n'
conf+='\\n[renewalparams]\\naccount = 0123456789abcdef0123456789abcdef\\nserver = '+server+'\\nauthenticator = standalone\\nhttp01_port = 80\\n'
with open(r+'/renewal/'+h+'.conf','w') as f:f.write(conf)
os.chmod(r+'/renewal/'+h+'.conf',0o600)
if os.getenv('SWAP_CERTBOT_LOCK')=='1':
 os.rename(p+'/owned/.lock',p+'/retired-lock')
 os.mkdir(p+'/owned/.lock',0o700)
'''
with open(p+'/bin/certbot','x') as f:f.write(mock)
os.chmod(p+'/bin/certbot',0o755)
PY
    export PATH="$C/bin:$BASE_PATH" TOOLBOX_TLS_ACME_ROOT="$C/owned" TOOLBOX_TLS_ACME_UNIT_DIR="$C/units" TOOLBOX_TLS_ACME_TEST_FIXTURE="$C/fixture.json" TOOLBOX_TLS_ACME_OS_RELEASE="$C/os-release" TOOLBOX_TLS_ACME_SYSTEMD_RUN="$C/run"
    unset CERTBOT_FAIL CERT_FILE KEY_FILE SS_FAIL PORT_BUSY SS_BAD SHOW_FAIL START_FAIL STOP_FAIL RELOAD_FAIL UNKNOWN_STATE DROPIN_STATE JOB_STATE ACCOUNT_SERVER ACCOUNT_DIR ACCOUNT_ID ACCOUNT_ATTACK SWAP_CERTBOT_LOCK SWAP_SYSTEMCTL_LOCK
}
BASE_PATH=$PATH
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$C/calls"
    local n=${2:-} state load active sub fragment
    if [[ ${SWAP_SYSTEMCTL_LOCK:-} == "$1" ]]; then
        mv "$C/owned/.lock" "$C/retired-lock"
        mkdir -m 700 "$C/owned/.lock"
    fi
    case $1 in
        show)
            [[ ${SHOW_FAIL:-0} != 1 ]] || return 1
            state=$(<"$C/timer-state"); load=not-found active=inactive sub=dead fragment=''
            if [[ -f $C/units/$n ]]; then load=loaded; fragment="$C/units/$n"; fi
            if [[ $n == *.timer && $state == active ]]; then active=active; sub=waiting; fi
            if [[ ${UNKNOWN_STATE:-0} == 1 ]]; then active=deactivating; sub=stop-sigterm; fi
            printf 'LoadState=%s\nActiveState=%s\nSubState=%s\nFragmentPath=%s\nDropInPaths=%s\nJob=%s\nMainPID=0\n' "$load" "$active" "$sub" "$fragment" "${DROPIN_STATE:-}" "${JOB_STATE:-}"
            ;;
        daemon-reload) [[ ${RELOAD_FAIL:-0} != 1 ]];;
        start) [[ $n == terry-toolbox-acme.timer && ${START_FAIL:-0} != 1 ]] || return 1; printf 'active\n' > "$C/timer-state";;
        stop) [[ $n == terry-toolbox-acme.timer && ${STOP_FAIL:-0} != 1 ]] || return 1; printf 'inactive\n' > "$C/timer-state";;
        *) fail "forbidden service mutation $*";;
    esac
}
ss() {
    [[ $* == -ltnH ]] || fail 'unexpected ss arguments'
    [[ ${SS_FAIL:-0} != 1 ]] || return 1
    if [[ ${SS_BAD:-0} == 1 ]]; then printf 'garbage\n'; fi
    if [[ ${PORT_BUSY:-0} == 1 ]]; then printf 'LISTEN 0 128 [::]:80 [::]:*\n'; fi
}
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
issue() { printf 'YES\nYES\n' | toolbox_tls_acme issue example.com admin@example.com > "$C/output" 2>&1; }
renew() { printf 'YES\nYES\n' | toolbox_tls_acme renew example.com > "$C/output" 2>&1; }
enable() { printf 'YES\nYES\n' | toolbox_tls_acme enable-renewal example.com > "$C/output" 2>&1; }
disable() { printf 'YES\nYES\n' | toolbox_tls_acme disable-renewal example.com > "$C/output" 2>&1; }
no_mutation() {
    [[ ! -e $C/owned && ! -L $C/owned ]] || fail 'cancel/preflight wrote owned root'
    python3 - "$C/calls" <<'PY'
import sys
s=open(sys.argv[1]).read();assert 'certbot ' not in s and 'systemctl start' not in s and 'systemctl stop' not in s and 'daemon-reload' not in s
PY
}
fixture status
before=$(<"$C/calls"); toolbox_tls_acme status > "$C/output" || fail status
no_mutation; [[ $(<"$C/calls") == "$before" ]] || fail 'status called systemd'
pass 'status is read-only/offline without Certbot'
for input in '' 'YES' $'YES\nYES' $'YES\nNO\n'; do
    fixture "cancel-${input//[^a-zA-Z]/x}-${RANDOM}"
    if printf '%s' "$input" | toolbox_tls_acme issue example.com admin@example.com > "$C/output" 2>&1; then fail cancel; fi
    no_mutation
done
pass 'issue cancellation/EOF has zero external mutation'
for kind in certbot python3 openssl systemctl ss timeout; do
    fixture "missing-$kind"
    command() { if [[ $* == "-v $kind" ]]; then return 1; fi; builtin command "$@"; }
    reject issue; unset -f command
    no_mutation
    python3 - "$C/output" "$kind" <<'PY'
import sys
assert '缺少必需命令：'+sys.argv[2] in open(sys.argv[1]).read()
PY
done
pass 'named missing command refusal, no auto install'
for kind in port ss-error ss-malformed os systemd fixture-seal parent-symlink foreign-root lock; do
    fixture "preflight-$kind"
    case $kind in
        port) PORT_BUSY=1;; ss-error) SS_FAIL=1;; ss-malformed) SS_BAD=1;;
        os) printf 'ID=alpine\n' > "$C/os-release";;
        systemd) rmdir "$C/run";;
        fixture-seal) printf 'bad\n' > "$C/fixture.json.sha256";;
        parent-symlink) mv "$C/units" "$C/old-units"; ln -s "$C/old-units" "$C/units";;
        foreign-root) mkdir "$C/owned";; lock) mkdir "$C/owned"; mkdir "$C/owned/.lock";;
    esac
    reject issue
    python3 - "$C/calls" <<'PY'
import sys
s=open(sys.argv[1]).read();assert 'certbot ' not in s and 'systemctl start' not in s
PY
done
pass 'port/unknown ss/platform/fixture/parent/foreign root refusal'
fixture confirmation-race
tls_acme_confirm() { tls_acme_original_confirm && { PORT_BUSY=1; }; }
reject issue; no_mutation
tls_acme_confirm() { tls_acme_original_confirm; }
pass 'port rechecked after confirmation; race causes zero writes'
for kind in wants-alias upholds symlink-dir; do
    fixture "foreign-dependency-$kind"
    dep="$C/units/multi-user.target.wants"
    if [[ $kind == symlink-dir ]]; then
        mkdir -m700 "$C/foreign"
        ln -s "$C/foreign" "$dep"
    else
        name=alias.timer
        if [[ $kind == upholds ]]; then dep="$C/units/multi-user.target.upholds"; name=terry-toolbox-acme.timer; fi
        mkdir -m700 "$dep"
        ln -s "$C/units/terry-toolbox-acme.timer" "$dep/$name"
    fi
    reject issue
    no_mutation
done
pass 'foreign alias/upholds links and symlink dependency directories rejected before writes'
# These are native Certbot account layout fixtures, not real ACME issuance.
for server in 'https://127.0.0.1:14000/dir' 'https://localhost:14000/dir'; do
    fixture "account-native-${RANDOM}"
    python3 - "$C/fixture.json" "$server" <<'PY'
import json,sys,hashlib
p,s=sys.argv[1:];d=json.load(open(p));d['server']=s;b=json.dumps(d).encode()
with open(p,'wb') as f:f.write(b)
with open(p+'.sha256','wb') as f:f.write((hashlib.sha256(b).hexdigest()+'\n').encode())
PY
    issue || { python3 -c 'import sys;print(open(sys.argv[1]).read())' "$C/output"; fail 'native sealed host:port account issue'; }
    toolbox_tls_acme status example.com > "$C/status" || fail 'native account status'
    python3 - "$C" "$server" <<'PY'
import json,sys
from urllib.parse import urlsplit
p,s=sys.argv[1:];m=json.load(open(p+'/owned/metadata.json'));assert m['state']=='ready'
a='config/accounts/'+urlsplit(s).netloc+'/dir/0123456789abcdef0123456789abcdef/'
assert all(a+n+'.json' in m['tree'] for n in ('meta','regr','private_key'))
PY
    renew || fail 'native account manual renewal'
done
pass 'sealed 127.0.0.1/localhost host:port account quartet ancestors and native JSON files issue/status/renew'
for kind in wrong-host wrong-port wrong-no-port extra-colon wrong-dir bad-id log-colon account-file-colon account-symlink; do
    fixture "account-reject-$kind"
    case $kind in
        wrong-host) export ACCOUNT_SERVER=localhost:14000;;
        wrong-port) export ACCOUNT_SERVER=127.0.0.1:14001;;
        wrong-no-port) export ACCOUNT_SERVER=acme-v02.api.letsencrypt.org;;
        extra-colon) export ACCOUNT_SERVER=127.0.0.1:14000:extra;;
        wrong-dir) export ACCOUNT_DIR=di:r;;
        bad-id) export ACCOUNT_ID=0123456789abcdef0123456789abcde:f;;
        log-colon) export ACCOUNT_ATTACK=../logs/action:1.log;;
        account-file-colon) export ACCOUNT_ATTACK=accounts/127.0.0.1:14000/dir/0123456789abcdef0123456789abcdef/meta:extra.json;;
        account-symlink) export ACCOUNT_ATTACK=symlink;;
    esac
    reject issue
    [[ -d $C/owned/config/accounts && ! -e $C/owned/.lock ]] || fail 'account refusal did not retain unlocked pending evidence'
    python3 - "$C" <<'PY'
import json,sys
p=sys.argv[1];assert json.load(open(p+'/owned/metadata.json'))['state']=='pending'
s=open(p+'/output').read();assert 'Certbot 返回成功但证书/ownership 验证失败' in s,s
assert 'systemctl start' not in open(p+'/calls').read()
PY
    reject toolbox_tls_acme status > "$C/status" 2>&1
    reject issue # Pending trees are never adopted, retried or cleaned.
done
fixture account-general-path-refusal
for kind in root units binary fixture; do
    case $kind in
        root) reject env TOOLBOX_TLS_ACME_ROOT="$C/owned:bad" bash -c 'source "$1"; tls_acme_fs preflight' _ "$ROOT/modules/tls-acme.sh" > "$C/output" 2>&1;;
        units) reject env TOOLBOX_TLS_ACME_UNIT_DIR="$C/units:bad" bash -c 'source "$1"; tls_acme_fs preflight' _ "$ROOT/modules/tls-acme.sh" > "$C/output" 2>&1;;
        binary) reject tls_acme_fs program "$C/owned/config/accounts/127.0.0.1:14000/dir/0123456789abcdef0123456789abcdef/meta.json" > "$C/output" 2>&1;;
        fixture) reject env TOOLBOX_TLS_ACME_TEST_FIXTURE="$C/fixture:bad.json" bash -c 'source "$1"; tls_acme_fs preflight' _ "$ROOT/modules/tls-acme.sh" > "$C/output" 2>&1;;
    esac
    python3 - "$C/output" <<'PY'
import sys
assert 'unsafe absolute path' in open(sys.argv[1]).read()
PY
done
no_mutation
pass 'account wrong-server/other colon locations/symlinks refused; general root/unit/program/fixture paths stay strict'
fixture happy
issue || { printf 'diagnostic fixture %s\n' "$C" >&2; python3 -c 'import sys;print(open(sys.argv[1]).read())' "$C/output"; fail 'mock issue'; }
toolbox_tls_acme status example.com > "$C/status" || fail status
python3 - "$C" <<'PY'
import os,sys,json,stat
p=sys.argv[1];m=json.load(open(p+'/owned/metadata.json'));assert m['state']=='ready' and not m['authorized'] and not m['vmess']
s=open(p+'/output').read();assert 'PRIVATE KEY' not in s and 'private test failure' not in s
assert stat.S_IMODE(os.stat(p+'/owned').st_mode)==0o700
assert not os.path.exists(p+'/owned/.lock')
a=open(p+'/calls').read();assert '--no-directory-hooks' in a and '--standalone' in a and '"80"' in a and '--no-verify-ssl' not in a
PY
reject toolbox_tls_acme _renew example.com > "$C/output" 2>&1
renew || fail 'manual renew'
[[ -L $C/owned/config/live/example.com/cert.pem ]] || fail 'native symlink lost'
pass 'mock native lineage / trust+time+hostname+keypair / manual vs unauthorized renewal'
enable || fail enable
# Already-enabled operation is an explicit no-op with readback.
enable || fail 'already enabled readback'
toolbox_tls_acme _renew example.com > "$C/output" 2>&1 || fail 'authorized background renew'
disable || fail disable
reject toolbox_tls_acme _renew example.com > "$C/output" 2>&1
enable || fail 're-enable retained units'
pass 'timer explicit authorization/readback/disable/re-enable and background renew'
(
    systemctl() {
        local unit=$2 active=active sub=running pid=0
        if [[ $unit == *.service ]]; then active=activating; sub=start; pid=${TEST_BACKGROUND_PID:-$$}; fi
        printf 'LoadState=loaded\nActiveState=%s\nSubState=%s\nFragmentPath=%s/units/%s\nDropInPaths=\nJob=\nMainPID=%s\n' "$active" "$sub" "$C" "$unit" "$pid"
    }
    tls_acme_timer_read background || fail 'real running timer/owned oneshot shape'
    TEST_BACKGROUND_PID=999999999 reject tls_acme_timer_read background
    reject tls_acme_timer_read active
)
pass 'timer-triggered oneshot accepts only the current owned runtime PID'
# Construct an already-owned expired lineage, as after offline time elapses.
# This is fixture setup only: preserve file identities and reseal their new bytes.
age_owned_lineage() {
    python3 - "$C" "$1" <<'PY'
import hashlib,json,os,sys
p,leaf=sys.argv[1:];root=p+'/owned';m=json.load(open(root+'/metadata.json'))
for name,data in [('cert',open(p+'/'+leaf,'rb').read()),('fullchain',open(p+'/'+leaf,'rb').read()+open(p+'/ca.pem','rb').read())]:
 path=os.path.realpath(root+'/config/live/example.com/'+name+'.pem')
 with open(path,'wb') as f:f.write(data)
 m['tree'][os.path.relpath(path,root)]['sha256']=hashlib.sha256(data).hexdigest()
raw=(json.dumps(m,sort_keys=True,separators=(',',':'))+'\n').encode()
with open(root+'/metadata.json','wb') as f:f.write(raw)
with open(root+'/metadata.sha256','w') as f:f.write(hashlib.sha256(raw).hexdigest()+'\n')
PY
}
for old_cert in expired.pem near-expiry.pem; do
    for action in renew disable; do
        fixture "recovery-${old_cert%.pem}-$action"
        issue || fail 'recovery issuance setup'; enable || fail 'recovery timer setup'
        age_owned_lineage "$old_cert"
        tls_acme_fs cert --existing >/dev/null || fail 'owned expired/near-expiry identity rejected'
        reject tls_acme_fs cert >/dev/null 2>&1
        "$action" || fail "owned $old_cert cannot $action"
        if [[ $action == renew ]]; then tls_acme_fs cert >/dev/null || fail 'renewed pair not strictly valid'
        else
            [[ ! -L $C/units/timers.target.wants/terry-toolbox-acme.timer ]] || fail 'expired timer link remained'
            reject toolbox_tls_acme _renew example.com > "$C/output" 2>&1
        fi
    done
done
fixture recovery-tamper
issue || fail 'recovery tamper setup'; age_owned_lineage expired.pem
printf 'tamper' >> "$C/owned/config/archive/example.com/cert1.pem"
reject renew
fixture recovery-invalid-new
issue || fail 'recovery invalid candidate setup'; age_owned_lineage expired.pem
export CERT_FILE=expired.pem
reject renew
pass 'expired/near-expiry owned lineages renew or disable; modified old and expired new pairs refuse'
fixture lock-certbot
export SWAP_CERTBOT_LOCK=1
reject issue
python3 - "$C" <<'PY'
import json,sys
p=sys.argv[1]
assert json.load(open(p+'/owned/metadata.json'))['state']=='pending'
assert 'lock replaced' in open(p+'/output').read()
assert 'systemctl start' not in open(p+'/calls').read()
PY
[[ -d $C/retired-lock && -d $C/owned/.lock ]] || fail 'replaced Certbot lock evidence lost'
for action in daemon-reload start stop; do
    fixture "lock-timer-$action"; issue || fail 'lock timer setup'
    if [[ $action == stop ]]; then enable || fail 'lock stop setup'; fi
    : > "$C/calls"; SWAP_SYSTEMCTL_LOCK=$action
    if [[ $action == stop ]]; then reject disable; else reject enable; fi
    [[ -d $C/retired-lock && -d $C/owned/.lock && -L $C/units/timers.target.wants/terry-toolbox-acme.timer ]] || fail 'lost lock must retain owned evidence'
    if [[ $action == daemon-reload ]]; then
        ! grep -q 'systemctl start' "$C/calls" || fail 'started timer after losing lock'
    fi
done
pass 'lock replacement during Certbot/reload/start/stop refuses later commits and retains evidence'
for kind in start-fail reload-fail show-unknown; do
    fixture "timer-failure-$kind"; issue || fail setup
    case $kind in start-fail) START_FAIL=1;; reload-fail) RELOAD_FAIL=1;; show-unknown) UNKNOWN_STATE=1;; esac
    reject enable
    [[ -d $C/owned && ! -d $C/owned/.lock ]] || fail 'timer failure removed data/leaked lock'
done
pass 'timer start/reload/unknown failures retain data and report failure'
for kind in certbot-fail wrong-host future expired mismatch untrusted encrypted; do
    fixture "certificate-$kind"
    case $kind in
        certbot-fail) export CERTBOT_FAIL=1;; wrong-host) export CERT_FILE=wrong-host.pem;; future) export CERT_FILE=future.pem;; expired) export CERT_FILE=expired.pem;; mismatch) export KEY_FILE=wrong-key.pem;;
        untrusted)
            openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj /CN=example.com -addext subjectAltName=DNS:example.com -keyout "$C/untrusted-key.pem" -out "$C/untrusted.pem" > "$C/openssl-output" 2>&1
            export CERT_FILE=untrusted.pem KEY_FILE=untrusted-key.pem;;
        encrypted)
            openssl pkey -in "$C/key.pem" -aes256 -passout pass:fixture -out "$C/encrypted.pem" > "$C/openssl-output" 2>&1
            export KEY_FILE=encrypted.pem;;
    esac
    reject issue
    [[ -d $C/owned/logs && ! -d $C/owned/.lock ]] || fail 'failed issuance not retained/unlocked'
    reject toolbox_tls_acme status > "$C/status" 2>&1
    python3 - "$C/output" <<'PY'
import sys
s=open(sys.argv[1]).read(); assert 'PRIVATE KEY' not in s and 'private test failure' not in s
PY
done
pass 'Certbot failure and real openssl negative time/host/keypair checks retained'
for kind in foreign-symlink duplicate hardlink metadata mode runtime unit link lock timer-unknown dropin show-fail stop-fail trust-change unknown-file; do
    fixture "tamper-$kind"
    issue || fail 'prepare tamper issue'
    case $kind in
        foreign-symlink) rm "$C/owned/config/live/example.com/cert.pem"; ln -s "$C/cert.pem" "$C/owned/config/live/example.com/cert.pem";;
        duplicate) cp "$C/owned/config/archive/example.com/cert1.pem" "$C/owned/config/archive/example.com/duplicate.pem";;
        hardlink) ln "$C/owned/config/archive/example.com/cert1.pem" "$C/owned/config/archive/example.com/cert2.pem";;
        metadata) printf 'x' >> "$C/owned/metadata.json";;
        mode) chmod 755 "$C/owned";;
        runtime) printf 'x' >> "$C/owned/runtime.sh";;
        unit) enable || fail prepare-enable; printf 'x' >> "$C/units/terry-toolbox-acme.service";;
        link) enable || fail prepare-enable; rm "$C/units/timers.target.wants/terry-toolbox-acme.timer"; ln -s "$C/cert.pem" "$C/units/timers.target.wants/terry-toolbox-acme.timer";;
        lock) mkdir -m700 "$C/owned/.lock";;
        timer-unknown) enable || fail prepare-enable; UNKNOWN_STATE=1;;
        dropin) enable || fail prepare-enable; DROPIN_STATE=/foreign/override.conf;;
        show-fail) SHOW_FAIL=1;;
        stop-fail) enable || fail prepare-enable; STOP_FAIL=1;;
        trust-change) printf 'x' >> "$C/ca.pem";;
        unknown-file) printf 'unowned' > "$C/owned/config/foreign";;
    esac
    case $kind in
        lock) reject renew;;
        timer-unknown|dropin|stop-fail) reject disable; [[ -L $C/units/timers.target.wants/terry-toolbox-acme.timer ]] || fail 'failure removed timer link';;
        show-fail) reject enable;;
        *) reject renew;;
    esac
done
pass 'symlink/duplicate/hardlink/seal/permissions/source/unit/link/lock/unknown/stop failure'
fixture renewal-fail
issue || fail setup
export CERTBOT_FAIL=1
reject renew
[[ ! -e $C/owned/.lock ]] || fail 'renew failure lock leaked'
reject renew
pass 'renew failure is fail-closed and retains private evidence'
fixture deploy-missing
issue || fail setup
reject toolbox_tls_acme deploy-vmess example.com <<< $'YES\nYES' > "$C/output" 2>&1
pass 'no VMess API means no certificate copy/adoption'
# Real module logic, mocked VMess API boundary extracted into the sealed source
# snapshot. No host VMess/systemd mutation; this verifies runtime stdin/bundle hook.
source "$ROOT/modules/network.sh"
vmess_fs() { [[ $1 == verify && $2 == --complete ]] || return 1; printf '%s 443 /vmess 127.0.0.1 1\n' "${VMESS_TEST_HOST:-example.com}"; }
vmess_confirm() { fail 'unowned confirmation callback called'; }
toolbox_vmess() {
    [[ $1 == update-cert && $# == 3 ]] || return 1
    vmess_confirm || return 1
    printf 'owned-vmess-api\n' >> "$C/vmess-calls"
}
fixture deploy-ownedhook
issue || fail setup
printf 'YES\nYES\n' | toolbox_tls_acme deploy-vmess example.com > "$C/output" 2>&1 || fail 'ownedhook deploy'
[[ -f $C/owned/vmess-hook.sh && -f $C/owned/vmess-source.sh && -f $C/owned/network-source.sh ]] || fail 'missing sealed source runtime'
renew || fail 'renew authorized ownedhook'
python3 - "$C" <<'PY'
import json,sys
p=sys.argv[1];assert json.load(open(p+'/owned/metadata.json'))['vmess'];assert open(p+'/vmess-calls').read().splitlines()==['owned-vmess-api','owned-vmess-api']
PY
printf 'bad' >> "$C/owned/vmess-hook.sh"
reject renew
pass 'sealed extracted VMess update-cert hook and authorized automatic synchronization'
# Confirmation refusal must not create a hook or authorize deployment.
fixture deploy-cancel
issue || fail setup
reject toolbox_tls_acme deploy-vmess example.com < /dev/null > "$C/output" 2>&1
[[ ! -f $C/owned/vmess-hook.sh ]] || fail 'cancel installed hook'
VMESS_TEST_HOST=other.com
reject toolbox_tls_acme deploy-vmess example.com <<< $'YES\nYES' > "$C/output" 2>&1
unset VMESS_TEST_HOST
pass 'VMess hostname/dual confirmation checked before hook mutation'
printf 'TLS ACME local mocked suite complete (not real CA/public/systemd acceptance).\n'
