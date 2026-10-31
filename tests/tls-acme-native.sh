#!/usr/bin/env bash
# Real Certbot/Pebble HTTP-01 plus owned systemd timer and VMess certificate sync.
# Run after vmess-native.sh's two reboot phases, only in the marked disposable VM.
# Download verified Pebble archives into /root/pebble-artifacts beforehand.
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
phase=${1:?prepare|exercise|restore-clock|stop-fixture}
base=${2:?fresh /root/tls-acme-fixture-NAME}
python3 - "$base" <<'PY'
import os,re,stat,sys
p='/run/terry-toolbox-vmess-acceptance';s=os.lstat(p)
assert os.geteuid()==0 and stat.S_ISREG(s.st_mode) and s.st_nlink==1 and s.st_uid==0
assert stat.S_IMODE(s.st_mode)==0o600 and open(p).read()=='vmess-native\n'
assert re.fullmatch(r'/root/tls-acme-fixture-[A-Za-z0-9_-]+',sys.argv[1])
assert open('/proc/1/comm').read().strip()=='systemd'
PY
work="$base-support"
host=vmess.example.test
if [[ $phase == prepare || $phase == exercise ]]; then
    source "$ROOT/modules/network.sh"
    source "$ROOT/modules/vmess.sh"
    source "$ROOT/modules/tls-acme.sh"
fi
export TOOLBOX_TLS_ACME_ROOT="$base/owned" TOOLBOX_TLS_ACME_UNIT_DIR=/etc/systemd/system
export TOOLBOX_TLS_ACME_TEST_FIXTURE="$base/fixture.json"
export TOOLBOX_NET_CAFILE="$base/certificate-ca.pem" TOOLBOX_NET_CAPATH=''
export TMPDIR="$work/scratch"
source_hashes() {
    sha256sum "$ROOT/modules/tls-acme.sh" "$ROOT/modules/vmess.sh" "$ROOT/modules/network.sh" \
        "$ROOT/tests/tls-acme-native.sh" "$ROOT/tests/tls-acme-integration.sh" "$ROOT/tests/vmess-native-probe.py"
}
native_recover() {
    # The recovery helper never edits the product manifest or adopts foreign units.
    # Clock/NTP restoration runs even when unit, helper or hosts cleanup fails.
    python3 - "$work" "$base" "$1" "${2:-0}" <<'PY'
import hashlib,json,math,os,pathlib,stat,subprocess,sys,tempfile,time
w,b=map(pathlib.Path,sys.argv[1:3]);mode=sys.argv[3];original_exit=int(sys.argv[4])
services={'systemd-timesyncd.service','chrony.service','chronyd.service','ntp.service','ntpd.service'}
boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
def ident(s):return f'{s.st_dev}:{s.st_ino}'
def directory(p):
 for part in reversed((p,*p.parents)):
  s=part.lstat();assert stat.S_ISDIR(s.st_mode) and s.st_uid==0 and not s.st_mode&0o022,str(part)
def record(p,private=True):
 directory(p.parent)
 fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
 try:
  s=os.fstat(fd);assert stat.S_ISREG(s.st_mode) and s.st_uid==0 and s.st_nlink==1
  assert not s.st_mode&(0o077 if private else 0o022)
  with os.fdopen(fd,'rb',closefd=False) as f:raw=f.read()
  return {'id':ident(s),'mode':stat.S_IMODE(s.st_mode),'sha256':hashlib.sha256(raw).hexdigest()},raw
 finally:os.close(fd)
directory(w)
errors=[];events=[];e=None
def recovery_message(message):
 try:print(message,file=sys.stderr,flush=True)
 except OSError:pass # A full evidence filesystem must not block clock recovery.
def evidence_error(step,ex):
 errors.append({'step':step,'error':str(ex)})
 recovery_message('Recovery evidence could not be written ('+step+'): '+str(ex))
try:e=pathlib.Path(tempfile.mkdtemp(prefix='recovery-',dir=w))
except OSError as ex:evidence_error('create-evidence-directory',ex)
def put(path,value):
 stage=None
 try:
  raw=(json.dumps(value,indent=2)+'\n').encode()
  fd,stage=tempfile.mkstemp(prefix='.recovery-',dir=path.parent)
  with os.fdopen(fd,'wb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
  os.replace(stage,path)
  fd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
  try:os.fsync(fd)
  finally:os.close(fd)
 except OSError as ex:evidence_error('write-'+path.name,ex)
 finally:
  if stage is not None and os.path.exists(stage):
   try:os.unlink(stage)
   except OSError as ex:evidence_error('remove-evidence-stage',ex)
def command(args,label,timeout=20):
 try:
  r=subprocess.run(args,capture_output=True,timeout=timeout)
  out,err,code=r.stdout,r.stderr,r.returncode
 except subprocess.TimeoutExpired as ex:
  out,err,code=ex.stdout or b'',ex.stderr or b'',124
 if e is not None:
  for suffix,raw in (('stdout',out),('stderr',err)):
   try:
    with (e/(label+'.'+suffix)).open('wb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
   except OSError as ex:evidence_error('write-'+label+'.'+suffix,ex)
 events.append({'command':args,'exit_code':code,'evidence':label})
 return code,out
def props(unit,label):
 code,out=command(['systemctl','show',unit,'--all','-p','LoadState','-p','ActiveState','-p','SubState',
  '-p','MainPID','-p','FragmentPath','-p','DropInPaths','-p','Result','-p','ExecMainStatus','-p','Job'],label)
 assert code==0,'cannot inspect '+unit
 return dict(line.split('=',1) for line in out.decode().splitlines())
def attempt(label,fn):
 try:fn()
 except Exception as ex:errors.append({'step':label,'error':str(ex)})
def owned_unit(unit):
 root=b/'owned';directory(root)
 mr,raw=record(root/'metadata.json');sr,seal=record(root/'metadata.sha256')
 assert seal==(mr['sha256']+'\n').encode(),'metadata seal mismatch'
 m=json.loads(raw)
 assert m['root_id']==ident(root.lstat()) and m['metadata_id']==mr['id'] and m['seal_id']==sr['id']
 assert m['fixture']==str(b/'fixture.json') and m['host']=='vmess.example.test'
 for parent,want in m['parents'].items():
  p=pathlib.Path(parent);directory(p);assert ident(p.lstat())==want,'owned parent changed'
 target=pathlib.Path('/etc/systemd/system')/unit
 assert set(m['units'])=={'/etc/systemd/system/terry-toolbox-acme.timer','/etc/systemd/system/terry-toolbox-acme.service'}
 assert record(target,False)[0]==m['units'][str(target)],'unit inode/hash/mode changed'
 assert record(root/'runtime.sh')[0]==m['tree']['runtime.sh'],'owned runtime changed'
 p=props(unit,'owned-'+unit)
 assert p['LoadState']=='loaded' and p['FragmentPath']==str(target) and p['DropInPaths']=='','foreign loaded unit'
 pid=int(p.get('MainPID','0'))
 if unit.endswith('.service') and pid:
  proc=pathlib.Path('/proc')/str(pid)
  assert (proc/'exe').resolve()==pathlib.Path('/bin/bash').resolve(),'foreign runtime process'
  assert (proc/'cmdline').read_bytes().rstrip(b'\0').split(b'\0')==[
   b'/bin/bash',str(root/'runtime.sh').encode(),b'_renew',b'vmess.example.test'],'foreign runtime arguments'
 return p
def stop_owned(unit):
 p=owned_unit(unit)
 if p['ActiveState'] in ('inactive','failed') and p.get('MainPID','0')=='0' and not p.get('Job'):return
 code,_=command(['systemctl','stop',unit],'stop-'+unit)
 assert code==0,'owned stop did not complete'
 p=props(unit,'stopped-'+unit)
 assert p['ActiveState']=='inactive' and p.get('MainPID','0')=='0' and not p.get('Job'),'owned unit still active'
def stop_helper(unit,binary):
 p=props(unit,'helper-'+unit)
 if p['ActiveState'] in ('inactive','failed') and p.get('MainPID','0')=='0' and not p.get('Job'):return
 assert p['DropInPaths']=='' and int(p.get('MainPID','0'))>0,'unknown helper state'
 assert (pathlib.Path('/proc')/p['MainPID']/'exe').resolve()==w/binary,'helper executable changed'
 code,_=command(['systemctl','stop',unit],'stop-'+unit)
 assert code==0,'helper stop failed'
def restore_hosts():
 p=pathlib.Path('/etc/hosts');_,current=record(p,False)
 _,before=record(w/'hosts.before');_,after=record(w/'hosts.after.sha256')
 if current==before:return
 assert hashlib.sha256(current).hexdigest()==after.decode(),'hosts changed; preserved'
 with p.open('wb') as f:f.write(before);f.flush();os.fsync(f.fileno())
def restore_clock():
 path=w/'clock.before.json'
 if not path.exists():events.append({'clock':'no saved clock; unchanged'});return
 saved,raw=record(path);d=json.loads(raw)
 assert set(d['active_time_services'])<=services and isinstance(d['boot_id'],str)
 done=w/'clock.restored.json'
 if done.exists():
  _,raw_done=record(done);old=json.loads(raw_done)
  if old.get('complete') and old.get('before_sha256')==saved['sha256'] and old.get('boot_id')==boot:
   events.append({'clock':'already restored; unchanged'});return
 result={'before_sha256':saved['sha256'],'boot_id':boot,'saved_boot_id':d['boot_id'],'complete':False,'services':[]}
 try:
  assert d['boot_id']==boot,'boot changed: refusing a monotonic-based clock estimate'
  assert all(isinstance(d[k],(int,float)) and math.isfinite(d[k]) for k in ('realtime','monotonic'))
  elapsed=time.monotonic()-d['monotonic'];assert elapsed>=0,'monotonic clock moved backwards'
  restored=d['realtime']+elapsed
  time.clock_settime(time.CLOCK_REALTIME,restored)
  result.update(realtime=time.time(),estimated_original_time=restored,clock_restored=True)
 except Exception as ex:
  result['clock_error']=str(ex);errors.append({'step':'restore-clock','error':str(ex)})
 finally:
  for unit in d['active_time_services']:
   try:
    code,_=command(['systemctl','start',unit],'restart-'+unit)
    assert code==0 and props(unit,'restored-'+unit)['ActiveState']=='active','time service did not restart'
    result['services'].append({'unit':unit,'active':True})
   except Exception as ex:
    result['services'].append({'unit':unit,'error':str(ex)})
    errors.append({'step':'restore-'+unit,'error':str(ex)})
  result['complete']=result.get('clock_restored',False) and all(x.get('active') for x in result['services'])
  put(done,result)
try:
 for unit in ('terry-toolbox-acme.timer','terry-toolbox-acme.service','toolbox-native-acme-ca','toolbox-native-acme-dns'):
  attempt('snapshot-'+unit,lambda u=unit:props(u,'before-'+u))
  attempt('journal-'+unit,lambda u=unit:command(['journalctl','-b','-u',u,'--no-pager','-o','short-monotonic'],'journal-'+u))
 if (b/'owned/metadata.json').exists():
  for unit in ('terry-toolbox-acme.timer','terry-toolbox-acme.service'):
   attempt('stop-'+unit,lambda u=unit:stop_owned(u))
 if mode=='stop-fixture':
  for unit,binary in [('toolbox-native-acme-ca','pebble'),('toolbox-native-acme-dns','pebble-challtestsrv')]:
   attempt('stop-'+unit,lambda u=unit,p=binary:stop_helper(u,p))
  attempt('restore-hosts',restore_hosts)
finally:
 attempt('restore-clock-finally',restore_clock)
 if e is not None:put(e/'result.json',{'mode':mode,'original_exit':original_exit,'boot_id':boot,'events':events,'errors':errors})
print('Private recovery evidence:',e if e is not None else 'unavailable; errors are on stderr')
if errors:
 print('Recovery needs review; original test result is unchanged.',file=sys.stderr)
 raise SystemExit(1)
PY
}
native_failure() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if (( rc != 0 )); then
        native_recover failure "$rc" || printf 'Recovery incomplete; inspect private recovery evidence.\n' >&2
    fi
    exit "$rc"
}
if [[ $phase == exercise ]]; then
    trap native_failure EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
fi
case $phase in
prepare)
    [[ ! -e $base && ! -e $work ]]
    mkdir -m 700 "$work"; mkdir -m 700 "$TMPDIR"
    source_hashes > "$work/source.sha256"
    python3 - "$work" <<'PY'
import datetime,hashlib,ipaddress,json,os,pathlib,stat,sys,tarfile
from cryptography import x509
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
p=pathlib.Path(sys.argv[1])
for name,want in [('pebble','4f2fcb5bca8c85c9cf73ad140fccfc0d2be40bd81ab99879c79b7b8a0b4f70ed'),
                  ('pebble-challtestsrv','e93a5aa25ecdf3af2f9fbb2de32b0173e64a2eae81002a4ccfe35fa6f4f60b92')]:
 a=pathlib.Path('/root/pebble-artifacts')/(name+'-linux-amd64.tar.gz')
 assert hashlib.sha256(a.read_bytes()).hexdigest()==want
 with tarfile.open(a) as t:
  m=t.getmember(name+'-linux-amd64/linux/amd64/'+name);assert m.isfile()
  (p/name).write_bytes(t.extractfile(m).read());(p/name).chmod(0o755)
now=datetime.datetime.now(datetime.timezone.utc)
key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Toolbox isolated ACME HTTPS')])
cert=(x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
 .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=5))
 .not_valid_after(now+datetime.timedelta(days=3)).add_extension(x509.BasicConstraints(ca=True,path_length=None),True)
 .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost'),x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]),False)
 .sign(key,hashes.SHA256()))
(p/'api.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
(p/'api.key').write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
config={'pebble':{'listenAddress':'127.0.0.1:14000','managementListenAddress':'127.0.0.1:15000',
 'certificate':str(p/'api.pem'),'privateKey':str(p/'api.key'),'httpPort':80,'tlsPort':5001,
 'externalAccountBindingRequired':False,'retryAfter':{'authz':1,'order':1},
 'profiles':{'default':{'description':'Six-hour isolated acceptance certificates','validityPeriod':21600}}}}
(p/'pebble.json').write_text(json.dumps(config))
hosts=pathlib.Path('/etc/hosts');s=hosts.lstat()
assert stat.S_ISREG(s.st_mode) and s.st_uid==0 and s.st_nlink==1
b=hosts.read_bytes();assert b'vmess.example.test' not in b
(p/'hosts.before').write_bytes(b)
hosts.write_bytes(b+b'\n127.0.0.1 vmess.example.test # toolbox-native-acme\n')
(p/'hosts.after.sha256').write_text(hashlib.sha256(hosts.read_bytes()).hexdigest())
PY
    # DNS-only challenge helper. HTTP-01 is answered by real Certbot on TCP 80.
    systemd-run --unit=toolbox-native-acme-dns --property=Type=exec --property=UMask=0077 \
        "$work/pebble-challtestsrv" -http01 '' -https01 '' -tlsalpn01 '' -doh '' \
        -dnsserver 127.0.0.1:8053 -management 127.0.0.1:8055 -defaultIPv4 127.0.0.1 -defaultIPv6 ''
    systemd-run --unit=toolbox-native-acme-ca --property=Type=exec --property=UMask=0077 \
        --setenv=PEBBLE_VA_NOSLEEP=1 --setenv=PEBBLE_AUTHZREUSE=0 \
        "$work/pebble" -config "$work/pebble.json" -dnsserver 127.0.0.1:8053
    ready=0
    for ((i=0;i<60;i++)); do
        if curl --silent --show-error --fail --cacert "$work/api.pem" https://127.0.0.1:15000/roots/0 > "$work/root.pem" 2>"$work/ca-ready.log"; then ready=1; break; fi
        sleep 1
    done
    [[ $ready == 1 ]]
    TOOLBOX_TLS_ACME_INTEGRATION_SYSTEMD_UNITS=1 TOOLBOX_TLS_ACME_INTEGRATION_TIMER_SECONDS=120 bash "$ROOT/tests/tls-acme-integration.sh" prepare \
        "$base" "$host" https://127.0.0.1:14000/dir "$work/api.pem" "$work/root.pem" > "$work/fixture.log"
    printf 'PASS isolated Pebble v2.10.1 with verified release hashes; real HTTP-01 required.\n'
    ;;
exercise)
    source_hashes > "$work/source-current.sha256"
    cmp "$work/source.sha256" "$work/source-current.sha256"
    printf 'YES\nYES\n' | toolbox_tls_acme issue "$host" admin@example.test > "$work/issue.log" 2>&1
    toolbox_tls_acme status "$host" > "$work/status.log" 2>&1
    [[ -e $base/owned/config/archive/$host/cert1.pem ]]
    printf 'YES\nYES\n' | TOOLBOX_TLS_ACME_TEST_FORCE_RENEWAL=1 toolbox_tls_acme renew "$host" > "$work/renew.log" 2>&1
    [[ -e $base/owned/config/archive/$host/cert2.pem ]]
    ! cmp -s "$base/owned/config/archive/$host/cert1.pem" "$base/owned/config/archive/$host/cert2.pem"
    # Trust both the existing native-test certificate and the new ACME root while
    # validating the old pair; the first update must validate both chains.
    cat /etc/terry-toolbox-vmess/cert.pem "$base/certificate-ca.pem" > "$work/vmess-trust.pem"
    export TOOLBOX_NET_CAFILE="$work/vmess-trust.pem"
    sha256sum /etc/terry-toolbox-vmess/config.json > "$work/config.before.sha256"
    printf 'YES\nYES\n' | toolbox_tls_acme deploy-vmess "$host" > "$work/deploy.log" 2>&1
    cmp /etc/terry-toolbox-vmess/cert.pem "$base/owned/config/live/$host/fullchain.pem"
    printf 'YES\nYES\n' | TOOLBOX_TLS_ACME_TEST_FORCE_RENEWAL=1 toolbox_tls_acme renew "$host" > "$work/renew-sync.log" 2>&1
    [[ -e $base/owned/config/archive/$host/cert3.pem ]]
    cmp /etc/terry-toolbox-vmess/cert.pem "$base/owned/config/live/$host/fullchain.pem"
    sha256sum -c "$work/config.before.sha256" > "$work/config.readback.log"
    toolbox_vmess status > "$work/vmess-status.log" 2>&1
    python3 "$ROOT/tests/vmess-native-probe.py" "$work" "$base/certificate-ca.pem" acme
    printf 'YES\nYES\n' | toolbox_tls_acme enable-renewal "$host" > "$work/timer-enable.log" 2>&1
    # Advance only this marked disposable guest's clock after authorization.
    # The exact owned certificate expires naturally; the unmodified production
    # runtime must recover it through real Certbot and its ordinary timer.
    # CLOCK_MONOTONIC stays unchanged, so OnActiveSec still fires after 120s.
    python3 - "$work" "$base" <<'PY'
import hashlib,json,os,pathlib,ssl,subprocess,sys,time
w,b=map(pathlib.Path,sys.argv[1:])
services=['systemd-timesyncd.service','chrony.service','chronyd.service','ntp.service','ntpd.service']
active=[];states={}
for service in services:
 out=subprocess.check_output(['systemctl','show',service,'--all','-p','LoadState','-p','ActiveState','-p','SubState'],text=True)
 states[service]=dict(line.split('=',1) for line in out.splitlines())
 assert states[service]['ActiveState'] in ('active','inactive','failed'),states[service]
 if states[service]['ActiveState']=='active':active.append(service)
record={'realtime':time.time(),'monotonic':time.monotonic(),'active_time_services':active,
 'time_service_states':states,'boot_id':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()}
def put_new(name,data):
 with (w/name).open('x') as f:json.dump(data,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
 fd=os.open(w,os.O_RDONLY|os.O_DIRECTORY)
 try:os.fsync(fd)
 finally:os.close(fd)
put_new('clock.before.json',record)
for service in active:
 subprocess.run(['systemctl','stop',service],check=True,timeout=30)
 assert subprocess.run(['systemctl','is-active','--quiet',service]).returncode!=0
leaf=b/'owned/config/archive/vmess.example.test/cert3.pem'
dates=subprocess.check_output(['openssl','x509','-in',str(leaf),'-noout','-startdate','-enddate'],text=True)
values=dict(line.split('=',1) for line in dates.splitlines())
start,end=(ssl.cert_time_to_seconds(values[k]) for k in ('notBefore','notAfter'))
assert 21500<=end-start<=21600,(start,end)
pair=pathlib.Path('/etc/terry-toolbox-vmess/cert.pem')
full=b/'owned/config/archive/vmess.example.test/fullchain3.pem'
assert pair.read_bytes()==full.read_bytes(),'installed pair is not cert3 fullchain'
assert not (b/'owned/config/archive/vmess.example.test/cert4.pem').exists()
old_svc=subprocess.check_output(['systemctl','show','terry-toolbox-acme.service','--all','-p','InvocationID','-p','ExecMainStartTimestampMonotonic','-p','ActiveState','-p','MainPID'],text=True)
old_props=dict(line.split('=',1) for line in old_svc.splitlines())
assert old_props['ActiveState']=='inactive' and old_props['MainPID']=='0',old_props
target=end+900
time.clock_settime(time.CLOCK_REALTIME,target)
assert time.time()>end
put_new('expired-before-timer.json',{'certificate_not_before':start,'certificate_not_after':end,
 'certificate_sha256':hashlib.sha256(leaf.read_bytes()).hexdigest(),
 'installed_fullchain_sha256':hashlib.sha256(pair.read_bytes()).hexdigest(),
 'guest_time':time.time(),'monotonic':time.monotonic(),'expired':True,
 'service_before':old_props,'boot_id':record['boot_id']})
PY
    # Wait for the real owned timer to trigger its oneshot. No manual service
    # start: timer SubState=running is part of this acceptance path.
    python3 - "$work" <<'PY'
import json,os,pathlib,subprocess,sys,time
w=pathlib.Path(sys.argv[1]);seen=False;rows=[];deadline=time.monotonic()+840
expired=json.loads((w/'expired-before-timer.json').read_text());invocation=None;started=None
try:
 while time.monotonic()<deadline:
  def props(unit):
   s=subprocess.check_output(['systemctl','show',unit,'--all','-p','ActiveState','-p','SubState','-p','MainPID','-p','Result','-p','ExecMainStatus','-p','ExecMainStartTimestampMonotonic','-p','InvocationID'],text=True)
   return dict(line.split('=',1) for line in s.splitlines())
  timer=props('terry-toolbox-acme.timer');svc=props('terry-toolbox-acme.service')
  if timer.get('SubState')=='running' and int(svc.get('MainPID','0'))>0:
   assert int(svc['ExecMainStartTimestampMonotonic'])>int(expired['monotonic']*1000000),svc
   assert svc['InvocationID'] and svc['InvocationID']!=expired['service_before'].get('InvocationID'),svc
   if invocation is None:invocation=svc['InvocationID'];started=svc['ExecMainStartTimestampMonotonic']
   assert invocation==svc['InvocationID'],'multiple renewal invocations during acceptance'
   seen=True
  rows.append({'monotonic':time.monotonic(),'realtime':time.time(),'timer':timer,'service':svc})
  if svc.get('ActiveState')=='failed':raise SystemExit('timer-triggered renewal failed: '+str(svc))
  if seen and svc.get('ActiveState')=='inactive' and timer.get('SubState')=='waiting':
   assert svc.get('Result')=='success' and svc.get('ExecMainStatus')=='0',svc
   # Some systemd versions clear InvocationID after a oneshot becomes inactive.
   assert not svc['InvocationID'] or svc['InvocationID']==invocation,svc
   assert svc['ExecMainStartTimestampMonotonic']==started,svc
   break
  time.sleep(1)
 else:raise SystemExit('real timer did not complete successfully')
finally:
 with (w/'timer-trigger.json').open('x') as f:json.dump(rows,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
PY
    systemctl show terry-toolbox-acme.service --all -p Result -p ExecMainStatus > "$work/background-result"
    grep -qx 'Result=success' "$work/background-result"
    grep -qx 'ExecMainStatus=0' "$work/background-result"
    [[ -e $base/owned/config/archive/$host/cert4.pem ]]
    ! cmp -s "$base/owned/config/archive/$host/cert3.pem" "$base/owned/config/archive/$host/cert4.pem"
    cmp /etc/terry-toolbox-vmess/cert.pem "$base/owned/config/live/$host/fullchain.pem"
    cmp /etc/terry-toolbox-vmess/cert.pem "$base/owned/config/archive/$host/fullchain4.pem"
    sha256sum -c "$work/config.before.sha256" >> "$work/config.readback.log"
    toolbox_vmess status > "$work/vmess-after-background.log" 2>&1
    python3 "$ROOT/tests/vmess-native-probe.py" "$work" "$base/certificate-ca.pem" after-background
    printf 'YES\nYES\n' | toolbox_tls_acme disable-renewal "$host" > "$work/timer-disable.log" 2>&1
    [[ ! -e /etc/systemd/system/timers.target.wants/terry-toolbox-acme.timer ]]
    toolbox_tls_acme status "$host" > "$work/final-status.log" 2>&1
    journalctl -u toolbox-native-acme-ca --no-pager > "$work/pebble.log"
    journalctl -u terry-toolbox-acme.service --no-pager > "$work/background.log"
    source_hashes > "$work/source-after.sha256"
    cmp "$work/source.sha256" "$work/source-after.sha256"
    python3 - "$base" "$work" <<'PY'
import hashlib,json,os,pathlib,ssl,subprocess,sys,time
b,w=map(pathlib.Path,sys.argv[1:]);a=b/'owned/config/archive/vmess.example.test'
m=json.loads((b/'owned/metadata.json').read_text())
assert m['state']=='ready' and not m['authorized'] and m['vmess']
cs=[a/f'cert{i}.pem' for i in (1,2,3,4)]
hashes=[hashlib.sha256(p.read_bytes()).hexdigest() for p in cs];assert len(set(hashes))==4
expired=json.loads((w/'expired-before-timer.json').read_text())
assert hashes[2]==expired['certificate_sha256']
date_text=subprocess.check_output(['openssl','x509','-in',str(cs[3]),'-noout','-startdate','-enddate'],text=True)
dates=dict(line.split('=',1) for line in date_text.splitlines())
start,end=(ssl.cert_time_to_seconds(dates[k]) for k in ('notBefore','notAfter'))
assert start>expired['certificate_not_after'] and start<=time.time()<end
pid=subprocess.check_output(['systemctl','show','toolbox-native-acme-ca','--value','-p','MainPID'],text=True).strip()
env=pathlib.Path('/proc/'+pid+'/environ').read_bytes().split(b'\0')
assert not any(x.startswith(b'PEBBLE_VA_ALWAYS_VALID=') and x!=b'PEBBLE_VA_ALWAYS_VALID=0' for x in env)
d={'real_certbot':subprocess.check_output(['certbot','--version'],text=True).strip(),
 'pebble':'2.10.1','http01_port':80,'challenge_validation_skipped':False,
 'four_distinct_leaf_sha256':hashes,'real_systemd_background_renewal':True,
 'cert4_not_before':start,'cert4_not_after':end,'verification_guest_time':time.time(),
 'clock_restore_pending':True,
 'expired_lineage_recovery':True,'expired_vmess_pair_recovery':True,
 'vmess_config_preserved':True,'vmess_sync':True,'timer_disabled_at_end':True,
 'boot_id':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()}
with (w/'result.json').open('x') as f:json.dump(d,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
PY
    printf 'PASS real HTTP-01 issuance, forced rotations, expired-pair recovery through the real timer, VMess sync and disable readback.\n'
    ;;
restore-clock|stop-fixture)
    # restore-clock can be retried by the controller after a lost SSH connection.
    # cert4 was issued in the advanced clock: finish TLS probes before restoring.
    native_recover "$phase"
    ;;
*) exit 2;;
esac
