#!/usr/bin/env bash
set -euo pipefail
# All path overrides are task-owned private scratch. Native dockerd fixture only
# sleeps or validates fixture JSON; all service/Docker/ip/ss calls are mocks.
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export IPV6_MODULE=$repo/modules/docker-ipv6.sh
python3 - "$@" <<'PY'
import json, os, pathlib, shlex, signal, stat, subprocess, sys, tempfile, time
if sys.platform != 'linux' or os.geteuid() != 0:
 print('B1 fixture suite requires Linux root (/proc and root-owned private paths); no service/network changes performed.',file=sys.stderr)
 sys.exit(77)
BASE=pathlib.Path(os.environ.get('TOOLBOX_TEST_TMPDIR','/root/.cache/terry-toolbox-tests'))
if not BASE.is_absolute() or str(BASE)!=os.path.normpath(str(BASE)):
 raise RuntimeError('TOOLBOX_TEST_TMPDIR must be a protected absolute directory')
for part in reversed((BASE,*BASE.parents)):
 if not part.exists():part.mkdir(mode=0o700)
 s=part.lstat()
 if not stat.S_ISDIR(s.st_mode) or s.st_uid!=0 or s.st_mode&0o022:
  raise RuntimeError('unsafe fixture parent: '+str(part))
E=pathlib.Path(tempfile.mkdtemp(prefix='docker-ipv6-evidence-',dir=BASE)); os.chmod(E,0o700)
selected=set(sys.argv[1:]); results=[]; processes=[]
package_log=E/'package-boundary.log'
package_deny='#!/bin/sh\nprintf "%s\\n" "$0 $*" >> '+shlex.quote(str(package_log))+'\nexit 99\n'
def packages_untouched():
 assert not package_log.exists() or not package_log.read_text(), package_log.read_text()
MOCK=r'''#!/usr/bin/python3
import json,os,pathlib,signal,subprocess,sys
r=pathlib.Path(os.environ['TOOLBOX_DOCKER_IPV6_TEST_ROOT']); a=sys.argv[1:]; name=pathlib.Path(sys.argv[0]).name
with (r/'calls').open('a') as f:f.write(json.dumps([name]+a)+'\n')
def flag(n):return (r/n).exists()
def get(n,d=''):return (r/n).read_text().strip() if (r/n).exists() else d
def swaplock():
 p=r/'replacement-lock';p.write_bytes(b'');os.chmod(p,0o600);p.replace(r/'lock')
def bridge():
 c=json.loads((r/'etc/docker/daemon.json').read_text()) if (r/'etc/docker/daemon.json').exists() else {}
 return {'Id':'b'*64,'Name':'bridge','Driver':'bridge','EnableIPv6':(c.get('ipv6',False) and not flag('badbridge')) or flag('bridgewrong'),'IPAM':{'Config':[{'Subnet':c['fixed-cidr-v6']}] if c.get('ipv6') else [{'Subnet':'172.17.0.0/16'}]}}
if name=='dockerd-validate':
 count=int(get('validations','0'))+1;(r/'validations').write_text(str(count))
 if flag('rollbackvalidationfail') and count>1:sys.exit(1)
 if flag('racelock') or flag('rollbackvalidationlock') and count>1:swaplock()
 if flag('raceconfig'): (r/'etc/docker/daemon.json').write_text('{"foreign":"race"}')
 if flag('raceparent'):
  (r/'etc/docker').rename(r/'etc/old-docker'); (r/'etc/docker').mkdir(); (r/'etc/docker/daemon.json').write_text('{"foreign":"parent"}')
 if flag('racecontainers'): (r/'containers').write_text('c'*64)
 if flag('raceservice'): (r/'unit').write_text('foreign unit\n')
 if flag('validationfail'):sys.exit(1)
 print('configuration OK');sys.exit(0)
if name=='docker':
 if a[:1]==['--host']:a=a[2:]
 if get('service','active')!='active' and flag('socketactivate'):
  (r/'activated').touch();(r/'service').write_text('active')
 if a==['context','show']:print(get('context','default'))
 elif a[:3]==['context','inspect','default']:print(get('endpoint','unix:///var/run/docker.sock'))
 elif a[:1]==['version']:print(get('version','28.5.1'))
 elif a==['info','--format','{{json .}}']:print(json.dumps({'ID':'fixture-engine','Swarm':{'LocalNodeState':get('swarm','inactive')},'SecurityOptions':[]}))
 elif a[:2]==['container','ls']:
  if flag('containerreadfail'):sys.exit(1)
  print(get('containers'))
 elif a[:2]==['network','ls']:
  ids=['b'*64]
  if flag('nativebuiltins'):ids+=['1'*64,'2'*64]
  if flag('networkconflict'):ids+=['a'*64]
  print('\n'.join(ids))
 elif a[:2]==['network','inspect']:
  if flag('networkreadfail'):sys.exit(1)
  networks=[bridge()]
  if flag('nativebuiltins') and a[2:]!=['bridge']:
   networks += [{'Id':'1'*64,'Name':'host','Driver':'host','EnableIPv6':False,'IPAM':{'Config':None}}, {'Id':'2'*64,'Name':'none','Driver':'null','EnableIPv6':False,'IPAM':{'Config':None}}]
  if flag('networkconflict') and a[2:]!=['bridge']:networks += [{'Id':'a'*64,'Name':'foreign','Driver':'bridge','EnableIPv6':True,'IPAM':{'Config':[{'Subnet':'fd00:1234::/64'}]}}]
  print(json.dumps(networks))
 else:raise RuntimeError(a)
elif name=='systemctl':
 if a[0]=='show':
  active=get('service','active')=='active'; pid=get('pid') if active else '0'
  socket='docker.socket' in a
  state=get('socket-stopped-state','inactive') if socket and not active else 'active' if active else 'inactive'
  substate=get('socket-substate','listening') if socket and active else get('socket-stopped-substate','dead') if socket else 'running' if active else 'dead'
  # Native socket units have no MainPID property. Empty values must be explicitly
  # requested, and unknown/missing properties are never synthesized as safe.
  values={'LoadState':'loaded','ActiveState':state,'SubState':substate,
          'FragmentPath':str(r/'socket-unit' if socket else r/'unit'),
          'DropInPaths':get('socket-dropins') if socket else '',
          'Job':'42' if flag('pending') or socket and flag('socketpending') else ''}
  if not socket:values['MainPID']=get('servicepid',pid)
  if socket and flag('socketmissing'):del values['Job']
  for k,v in values.items():
   if v or '--all' in a:print(k+'='+v)
 elif a[0] in ('restart','stop','start'):
  if flag(a[0]+'fail'):sys.exit(1)
  (r/'service').write_text('inactive' if a[0]=='stop' else 'active')
  if flag(a[0]+'lock'):swaplock()
  if a[0]=='restart':(r/'restarted').touch()
  if flag(a[0]+'inject') and (a[0]=='restart' or (r/'restarted').exists()):
   try:os.kill(int(get('pid')),signal.SIGTERM)
   except Exception:pass
   d=subprocess.Popen([str(r/'bin/dockerd'),'--host=tcp://0.0.0.0:2375'],env=dict(os.environ),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   (r/'pid').write_text(str(d.pid))
   with (r/'extra-pids').open('a') as f:f.write(str(d.pid)+'\n')
  if flag(a[0]+'engine'):(r/'version').write_text('29.9.9')
  if a[0]=='restart' and flag('restartforeign'):(r/'etc/docker/daemon.json').write_text('{"foreign":"restart"}');sys.exit(1)
  if a[0]=='restart' and flag('restartunit'):(r/'unit').write_text('unknown service resource');sys.exit(1)
  if a[0]=='restart' and flag('restartsnapshotfail'):(r/'pending').touch();sys.exit(1)
  if a[0]=='start' and flag('startreadfail'):(r/'pending').touch()
  if a[0]=='restart' and flag('restartslow'):time=__import__('time'); (r/'restarting').touch();time.sleep(20)
  if a[0]=='stop' and flag('stopreadfail'):(r/'pending').touch()
 else:raise RuntimeError(a)
elif name=='rc-service':
 if a==['--resolve','docker']: print(r/'init.d/docker')
 elif a==['docker','status']:
  active=get('service','active')=='active';print(' * status: '+('started' if active else 'stopped'));sys.exit(0 if active else 3)
 elif a[0]=='docker' and a[1] in ('restart','stop','start'):
  if flag(a[1]+'fail'):sys.exit(1)
  (r/'service').write_text('inactive' if a[1]=='stop' else 'active')
 else:raise RuntimeError(a)
elif name=='rc-status':print('default')
elif name=='ss':
 if get('service','active')=='active' or flag('lingering'):
  print('u_str LISTEN 0 4096 /run/docker.sock 123 * 0 users:(("dockerd",pid='+get('listenerpid',get('pid',get('actualpid')))+',fd=3))')
  if flag('fdactivation'):print('u_str LISTEN 0 4096 /run/docker.sock 123 * 0 users:(("systemd",pid=1,fd=5))')
elif name=='ip':
 if flag('ipreadfail'):sys.exit(1)
 if flag('lifetimecountdowns'):
  n=int(get('ip-probes','0'))
  if 'route' in a:n+=1;(r/'ip-probes').write_text(str(n))
  if 'route' in a:
   row={'dst':'fd99::/64','dev':'eth0','gateway':'fe80::1','expires':86400-n}
   if n>1 and flag('routeidentityrace'):row['gateway']='fe80::2'
   if n>1 and flag('routeconflictrace'):row['dst']='fd00:1234::/64'
   print(json.dumps([row]))
  else:
   addr={'family':'inet6','local':'fd99::1','prefixlen':64,'valid_life_time':86400-n,'preferred_life_time':14400-n}
   if n>1 and flag('addridentityrace'):addr['local']='fd99::2'
   if n>1 and flag('addrconflictrace'):addr['local']='fd00:1234::1'
   print(json.dumps([{'ifname':'eth0','addr_info':[addr]}]))
 elif 'route' in a:print(json.dumps([{'dst':'fd00:1234::/64','dev':'eth0'}] if flag('routeconflict') else [{'dst':'default','dev':'eth0'}]))
 else:print(json.dumps([{'ifname':'eth0','addr_info':[{'family':'inet6','local':'fd00:1234::1','prefixlen':64}]}] if flag('addrconflict') else []))
else:raise RuntimeError(name)
'''
C=r'''#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
int main(int argc,char **argv) {
 for(int i=1;i<argc;i++) if(!strcmp(argv[i],"--validate")) {
  char *root=getenv("TOOLBOX_DOCKER_IPV6_TEST_ROOT"); char path[4096];snprintf(path,sizeof(path),"%s/bin/dockerd-validate",root);
  char **args=calloc(argc+1,sizeof(char*));args[0]=path;for(int j=1;j<argc;j++)args[j]=argv[j];execv(path,args);return 99;
 }
 for(;;)pause();
}
'''
(E/'dockerd.c').write_text(C)
build=subprocess.run(['cc','-O2',str(E/'dockerd.c'),'-o',str(E/'dockerd')],capture_output=True,text=True)
assert build.returncode==0,build.stderr

def fixture(alpine=False):
 r=pathlib.Path(tempfile.mkdtemp(prefix='docker-ipv6-case-',dir=E));os.chmod(r,0o700)
 for p in ('etc/docker','bin','init.d','conf.d','openrc'): (r/p).mkdir(parents=True,exist_ok=True)
 (r/'etc/os-release').write_text('ID='+('alpine' if alpine else 'debian')+'\n');(r/'init').write_text('openrc' if alpine else 'systemd')
 (r/'openrc/softlevel').write_text('default');(r/'unit').write_text('fixture docker.service\n');(r/'init.d/docker').write_text('#!/sbin/openrc-run\ncommand=/usr/bin/dockerd\n');(r/'conf.d/docker').write_text('DOCKER_OPTS=""\n')
 (r/'disable_ipv6').write_text('0\n');(r/'service').write_text('active')
 (r/'etc/docker/daemon.json').write_text('{"log-driver":"local","labels":["keep=me"]}\n');os.chmod(r/'etc/docker/daemon.json',0o640)
 (r/'bin/dockerd').write_bytes((E/'dockerd').read_bytes());os.chmod(r/'bin/dockerd',0o755)
 for cmd in ('docker','systemctl','rc-service','rc-status','ip','ss','dockerd-validate','iptables','ip6tables'):
  (r/'bin'/cmd).write_text(MOCK);os.chmod(r/'bin'/cmd,0o755)
 (r/'bin/python3').symlink_to(sys.executable);(r/'bin/bash').symlink_to(__import__('shutil').which('bash'))
 (r/'bin/cat').write_bytes(pathlib.Path(__import__('shutil').which('cat')).read_bytes());os.chmod(r/'bin/cat',0o755)
 for name in ('sudo','apt','apt-get','apt-cache','aptitude','apk','dpkg','dpkg-query','dpkg-deb','dnf','yum','rpm'):
  (r/'bin'/name).write_text(package_deny);(r/'bin'/name).chmod(0o755)
 env={k:v for k,v in os.environ.items() if not k.startswith('DOCKER_')};env.update(TOOLBOX_DOCKER_IPV6_TEST_ROOT=str(r),PATH=str(r/'bin')+':/usr/bin:/bin')
 if not processes:
  for probe_env in (env, {'PATH':env['PATH']}):
   probe=subprocess.run(['bash','--noprofile','--norc','-c','apt-get --fixture-guard-probe'],env=probe_env,capture_output=True)
   assert probe.returncode==99,probe
  assert len(package_log.read_text().splitlines())==2
  package_log.unlink()
 daemon=subprocess.Popen([str(r/'bin/dockerd'),'--host=unix:///var/run/docker.sock'],env=env);processes.append(daemon);(r/'pid').write_text(str(daemon.pid))
 return r,env

def invoke(r,env,action='apply',data='YES\nYES\n',extra=()):
 script='source "$IPV6_MODULE"; '
 if env.get('FIXTURE_DECLINE_DEPENDENCIES')=='1':
  script+='source "${IPV6_MODULE%/*}/dependencies.sh"; _toolbox_deps_os() { printf "debian\\n"; }; _toolbox_deps_confirm() { return 1; }; '
 script+='toolbox_docker_ipv6 "$@"'
 p=subprocess.Popen(['bash','-c',script,'b1',action,*extra],env=env,
                    stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try:out,err=p.communicate(data,timeout=60)
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGKILL);out,err=p.communicate()
  (r/'timeout.json').write_text(json.dumps({'action':action,'limit_seconds':60,'stdout':out,'stderr':err},ensure_ascii=False,indent=2))
  raise
 p.stdout=out;p.stderr=err
 n=len(list(r.glob('result-*.json')));(r/f'result-{n}.json').write_text(json.dumps({'action':action,'rc':p.returncode,'stdout':p.stdout,'stderr':p.stderr},ensure_ascii=False,indent=2))
 packages_untouched()
 return p

def assert_ok(p):assert p.returncode==0,(p.returncode,p.stdout,p.stderr)
def calls(r):return [json.loads(x) for x in (r/'calls').read_text().splitlines()] if (r/'calls').exists() else []
def mutations(r):return [c for c in calls(r) if c[0] in ('systemctl','rc-service') and any(x in c for x in ('restart','stop','start'))]
def case(name,fn):
 if selected and name not in selected:return
 started=time.monotonic();mark=len(processes);print('RUN '+name,flush=True)
 try:fn();packages_untouched();results.append({'case':name,'passed':True,'seconds':round(time.monotonic()-started,3)});print('PASS '+name+' seconds='+str(results[-1]['seconds']),flush=True)
 except Exception as e:results.append({'case':name,'passed':False,'error':str(e)});raise
 finally:
  (E/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
  for proc in processes[mark:]:
   if proc.poll() is None:
    proc.terminate()
    try:proc.wait(timeout=3)
    except subprocess.TimeoutExpired:proc.kill();proc.wait()


def readonly():
 r,env=fixture();before={str(p):p.read_bytes() for p in r.rglob('*') if p.is_file()};p=invoke(r,env,'status','');assert_ok(p)
 assert '本地模块' in p.stdout and '尚未真实验收' in p.stdout
 assert not (r/'state').exists() and not (r/'lock').exists() and not calls(r)
 assert all(pathlib.Path(k).read_bytes()==v for k,v in before.items())

def apply():
 r,env=fixture();p=invoke(r,env);assert_ok(p)
 c=json.loads((r/'etc/docker/daemon.json').read_text());assert c=={'log-driver':'local','labels':['keep=me'],'ipv6':True,'fixed-cidr-v6':'fd00:1234::/64','ip6tables':True},c
 assert (r/'etc/docker/daemon.json').stat().st_mode&0o777==0o640
 assert [c[1] for c in mutations(r)]==['restart'],mutations(r)
 assert any(c[0]=='dockerd-validate' and '--validate' in c for c in calls(r))
 assert (r/'state').exists();assert_ok(invoke(r,env,'status',''))
 assert 'YES' in p.stdout and '公网' in p.stdout
 assert '不改 sysctl' not in p.stdout and 'forwarding' in p.stdout,(p.stdout)

def restore():
 r,env=fixture();original=(r/'etc/docker/daemon.json').read_bytes();assert_ok(invoke(r,env))
 p=invoke(r,env,'restore');assert_ok(p)
 assert (r/'etc/docker/daemon.json').read_bytes()==original
 assert (r/'etc/docker/daemon.json').stat().st_mode&0o777==0o640
 assert json.loads((r/'state/record.json').read_text())['phase']=='restored'
 assert_ok(invoke(r,env,'status',''))

def failure_status():
 r,env=fixture();(r/'validationfail').touch();p=invoke(r,env);assert p.returncode!=0
 assert not mutations(r)
 p=invoke(r,env,'status','');assert_ok(p);assert 'prepared' in p.stdout

def denied_flag(flag,reason):
 r,env=fixture();original=(r/'etc/docker/daemon.json').read_bytes();(r/flag).touch();p=invoke(r,env)
 assert p.returncode!=0 and reason.lower() in (p.stdout+p.stderr).lower(),(flag,p.returncode,p.stdout,p.stderr)
 assert not mutations(r) and not (r/'state').exists()
 assert (r/'etc/docker/daemon.json').read_bytes()==original

def cancel():
 for data in ('NO\n','YES\nNO\n','','YES','YES\n','YES\nYES','YES \nYES\n'):
  r,env=fixture();original=(r/'etc/docker/daemon.json').read_bytes();p=invoke(r,env,data=data)
  assert p.returncode!=0 and '取消' in p.stderr,(data,p.stdout,p.stderr)
  assert not mutations(r) and not (r/'state').exists() and not (r/'lock').exists()
  assert (r/'etc/docker/daemon.json').read_bytes()==original
 r,env=fixture();assert_ok(invoke(r,env,data='yes\nYeS\n'))

def remote():
 for key,value in [('DOCKER_HOST',''),('DOCKER_CONTEXT','default'),('DOCKER_API_VERSION','1.48'),('DOCKER_CONFIG','/root'),('DOCKER_TLS_VERIFY','')]:
  r,env=fixture();env[key]=value;p=invoke(r,env);assert p.returncode!=0 and 'DOCKER_*' in p.stderr
  # systemctl/ss probes are API-free; only a docker CLI call could activate.
  assert not [c for c in calls(r) if c[0]=='docker'] and not (r/'state').exists()
 for flag,value in [('context','remote'),('endpoint','tcp://host:2375')]:
  r,env=fixture();(r/flag).write_text(value);p=invoke(r,env);assert p.returncode!=0 and 'remote' in p.stderr
  assert not mutations(r) and not (r/'state').exists()

def versions():
 for version in ('27.5.1','28.0.0-rc1','29.0.0-beta.2','28','garbage','028.0.0-dev'):
  r,env=fixture();(r/'version').write_text(version);p=invoke(r,env)
  assert p.returncode!=0 and 'stable Engine' in p.stderr,(version,p.stderr)
  assert not mutations(r) and not (r/'state').exists()

def json_refusals():
 for value in ('{"x":1,"x":2}','{"nested":{"x":1,"x":2}}','[]','NaN','{"ipv6":false}','{"fixed-cidr-v6":"fd88::/64"}','{"ip6tables":false}','{"iptables":false}','{"ip-forward":false}','{"ip-masq":false}','{"icc":false}','{"experimental":true}','{"hosts":["tcp://0.0.0.0:2375"]}'):
  r,env=fixture();(r/'etc/docker/daemon.json').write_text(value);p=invoke(r,env)
  assert p.returncode!=0,(value,p.stdout,p.stderr)
  assert not mutations(r) and not (r/'state').exists()
  assert (r/'etc/docker/daemon.json').read_text()==value

def paths():
 for kind in ('leaf-symlink','parent-symlink','parent-writable','leaf-hardlink','lock-symlink','state-symlink'):
  r,env=fixture();config=r/'etc/docker/daemon.json'
  if kind=='leaf-symlink': config.rename(r/'foreign');config.symlink_to(r/'foreign')
  if kind=='parent-symlink': (r/'etc/docker').rename(r/'foreign');(r/'etc/docker').symlink_to(r/'foreign',target_is_directory=True)
  if kind=='parent-writable':os.chmod(r/'etc/docker',0o777)
  if kind=='leaf-hardlink':os.link(config,r/'foreign')
  if kind=='lock-symlink':(r/'lock').symlink_to(r/'foreign');(r/'foreign').write_text('foreign')
  if kind=='state-symlink':(r/'state').symlink_to(r/'foreign');(r/'foreign').mkdir()
  p=invoke(r,env);assert p.returncode!=0,(kind,p.stdout,p.stderr)
  assert not mutations(r)
 r,env=fixture();env['TOOLBOX_DOCKER_IPV6_TEST_ROOT']='/etc';p=invoke(r,env);assert p.returncode!=0 and 'private scratch' in p.stderr;assert not calls(r)
 r,env=fixture();env['TOOLBOX_DOCKER_IPV6_CONFIG']='/etc/docker/daemon.json';p=invoke(r,env);assert p.returncode!=0 and '覆盖' in p.stderr;assert not calls(r)

def subnet_cases():
 for subnet in ('2001:db8::/64','fe80::/64','fc00::/64','fd00:1234::1/64','fd00::/48','oops'):
  r,env=fixture();p=invoke(r,env,extra=(subnet,));assert p.returncode!=0 and 'ULA' in p.stderr
  assert not calls(r) and not mutations(r)
 r,env=fixture();assert_ok(invoke(r,env,extra=('fd7a:115c:a1e0:ab12::/64',)));assert json.loads((r/'etc/docker/daemon.json').read_text())['fixed-cidr-v6']=='fd7a:115c:a1e0:ab12::/64'

def conflicts():
 for flag,reason in [('networkconflict','network'),('routeconflict','route'),('addrconflict','地址'),('containerreadfail','命令失败'),('networkreadfail','命令失败'),('ipreadfail','命令失败'),('pending','pending')]:denied_flag(flag,reason)
 r,env=fixture();(r/'containers').write_text('c'*64);p=invoke(r,env);assert p.returncode!=0 and '容器' in p.stderr;assert not mutations(r)
 r,env=fixture();(r/'swarm').write_text('active');p=invoke(r,env);assert p.returncode!=0 and 'Swarm' in p.stderr

def native_binary_and_flags():
 r,env=fixture();daemon=processes[-1];daemon.terminate();daemon.wait()
 with (r/'bin/dockerd').open('ab') as f:f.write(b'\0'*(3*1024*1024))
 daemon=subprocess.Popen([str(r/'bin/dockerd'),'--host=unix:///var/run/docker.sock'],env=env);processes.append(daemon);(r/'pid').write_text(str(daemon.pid))
 assert_ok(invoke(r,env))
 for args,reason in [(['--host=tcp://0.0.0.0:2375'],'remote'),(['--iptables=false'],'iptables'),(['--ip-forward=false'],'ip-forward'),(['--ip-masq=false'],'ip-masq'),(['--icc=false'],'icc'),(['--ipv6=false'],'flags'),(['--config-file=/other.json'],'flags')]:
  r,env=fixture();old=processes[-1];old.terminate();old.wait()
  d=subprocess.Popen([str(r/'bin/dockerd'),*args],env=env);processes.append(d);(r/'pid').write_text(str(d.pid))
  p=invoke(r,env);assert p.returncode!=0 and reason in p.stderr,(args,p.stdout,p.stderr)
  assert not mutations(r) and not (r/'state').exists()
 r,env=fixture();(r/'etc/docker/daemon.json').write_text('{"hosts":["unix:///var/run/docker.sock"]}')
 p=invoke(r,env);assert p.returncode!=0 and 'duplicate' in p.stderr;assert not mutations(r)

def lifecycle_failures():
 for flag in ('restartfail','badbridge'):
  r,env=fixture();original=(r/'etc/docker/daemon.json').read_bytes();(r/flag).touch();p=invoke(r,env)
  assert p.returncode!=0,(flag,p.stdout,p.stderr)
  assert (r/'etc/docker/daemon.json').read_bytes()==original,(flag,p.stderr)
  assert [c[1] for c in mutations(r)]==['restart','stop','start'],(flag,mutations(r),p.stderr)
  assert json.loads((r/'state/record.json').read_text())['phase']=='rolled-back'
  assert_ok(invoke(r,env,'status',''))
 for flag in ('stopfail','stopreadfail','startfail','lingering'):
  r,env=fixture();original=(r/'etc/docker/daemon.json').read_bytes();(r/'restartfail').touch();(r/flag).touch();p=invoke(r,env)
  assert p.returncode!=0 and '保守保留' in p.stderr,(flag,p.stdout,p.stderr)
  m=json.loads((r/'state/record.json').read_text());assert m['phase']=='retained' and (r/'state/operations.log').exists()
  if flag!='startfail':assert json.loads((r/'etc/docker/daemon.json').read_text()).get('ipv6') is True
  else:assert (r/'etc/docker/daemon.json').read_bytes()==original
  assert_ok(invoke(r,env,'status',''))
 r,env=fixture();(r/'restartforeign').touch();p=invoke(r,env);assert p.returncode!=0 and '未知配置改变' in p.stderr
 assert [c[1] for c in mutations(r)]==['restart'] and (r/'etc/docker/daemon.json').read_text()=='{"foreign":"restart"}'

def race():
 for flag in ('raceconfig','raceparent','racecontainers','raceservice'):
  r,env=fixture();(r/flag).touch();p=invoke(r,env);assert p.returncode!=0,(flag,p.stdout,p.stderr)
  assert not mutations(r),(flag,mutations(r))
  assert json.loads((r/'state/record.json').read_text())['phase']=='prepared'
  if flag=='raceconfig':assert json.loads((r/'etc/docker/daemon.json').read_text())=={'foreign':'race'}
  if flag=='raceparent':assert json.loads((r/'etc/docker/daemon.json').read_text())=={'foreign':'parent'}

def absent_and_alpine():
 for missing in ('file','parent'):
  r,env=fixture();(r/'etc/docker/daemon.json').unlink()
  if missing=='parent':(r/'etc/docker').rmdir()
  assert_ok(invoke(r,env,'status',''));assert_ok(invoke(r,env));assert_ok(invoke(r,env,'restore'))
  assert not (r/'etc/docker/daemon.json').exists()
 r,env=fixture(alpine=True);assert_ok(invoke(r,env));assert_ok(invoke(r,env,'restore'))
 assert [c[2] for c in mutations(r)]==['restart','restart'],mutations(r)
 r,env=fixture(alpine=True);(r/'openrc/softlevel').unlink();p=invoke(r,env);assert p.returncode!=0 and 'OpenRC 未引导' in p.stderr;assert not mutations(r)
 r,env=fixture(alpine=True);(r/'restartfail').touch();(r/'stopfail').touch();p=invoke(r,env);assert p.returncode!=0 and '保守保留' in p.stderr
 assert json.loads((r/'etc/docker/daemon.json').read_text()).get('ipv6') is True

def concurrent_and_confirm_race():
 import fcntl
 r,env=fixture();lock=r/'lock';lock.touch(mode=0o600)
 with lock.open('r+') as f:
  fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);p=invoke(r,env);assert p.returncode!=0 and 'concurrent' in p.stderr
 assert not mutations(r) and not (r/'state').exists()
 r,env=fixture();p=subprocess.Popen(['bash','-c','source "$IPV6_MODULE"; toolbox_docker_ipv6 apply'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 prefix=''
 while '确认 (1/2): ' not in prefix:
  ch=p.stdout.read(1);assert ch,(prefix,p.stderr.read());prefix+=ch
 (r/'containers').write_text('d'*64)
 out,err=p.communicate('YES\nYES\n',timeout=60)
 assert p.returncode!=0 and '容器' in err and not mutations(r) and not (r/'state').exists()
 (r/'confirm-race-output').write_text(prefix+out+err)

 def run_signal(stopfail=False):
  r,env=fixture();(r/'restartslow').touch()
  if stopfail:(r/'stopfail').touch()
  original=(r/'etc/docker/daemon.json').read_bytes()
  p=subprocess.Popen(['bash','-c','source "$IPV6_MODULE"; toolbox_docker_ipv6 apply'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
  p.stdin.write('YES\nYES\n');p.stdin.flush()
  try:
   deadline=time.monotonic()+90
   while not (r/'restarting').exists() and time.monotonic()<deadline:
    assert p.poll() is None;time.sleep(0.01)
   assert (r/'restarting').exists()
   # Deliver SIGTERM to the real Python controller, not the mock daemon.
   def descendants(pid):
    try:children=pathlib.Path('/proc/'+str(pid)+'/task/'+str(pid)+'/children').read_text().split()
    except FileNotFoundError:return []
    return [int(c) for c in children]+[d for c in children for d in descendants(int(c))]
   targets=[]
   for pid in descendants(p.pid):
    try:cmdline=pathlib.Path('/proc/'+str(pid)+'/cmdline').read_bytes()
    except FileNotFoundError:continue
    if cmdline.startswith(b'python3\0-c\0'):targets.append(pid)
   assert len(targets)==1,targets;os.kill(targets[0],signal.SIGTERM)
   out,err=p.communicate(timeout=90);(r/'signal-output').write_text(out+err)
  except BaseException:
   if p.poll() is None:os.killpg(p.pid,signal.SIGKILL)
   out,err=p.communicate();(r/'signal-harness-failure').write_text(out+err)
   raise
  assert p.returncode!=0 and 'signal' in err
  if stopfail:assert json.loads((r/'etc/docker/daemon.json').read_text())['ipv6'] is True and '保守保留' in err
  else:assert (r/'etc/docker/daemon.json').read_bytes()==original and json.loads((r/'state/record.json').read_text())['phase']=='rolled-back'
 run_signal();run_signal(True)

def restore_refusals():
 for flag in ('content','inode','record','unit','parent','running','cancel','restartfail','validationfail'):
  r,env=fixture();assert_ok(invoke(r,env));config=r/'etc/docker/daemon.json';owned=config.read_bytes();oldcalls=len(mutations(r))
  if flag=='content':config.write_text('{"foreign":true}')
  if flag=='inode':t=r/'etc/docker/replacement';t.write_bytes(owned);os.chmod(t,0o640);t.replace(config)
  if flag=='record':(r/'state/record.json').write_text('{"schema":1}')
  if flag=='unit':(r/'unit').write_text('changed\n')
  if flag=='parent':(r/'etc/docker').rename(r/'etc/old-docker');(r/'etc/docker').mkdir();config.write_bytes(owned);os.chmod(config,0o640)
  if flag=='running':(r/'containers').write_text('c'*64)
  if flag in ('restartfail','validationfail'):(r/flag).touch()
  p=invoke(r,env,'restore',data='YES\nNO\n' if flag=='cancel' else 'YES\nYES\n')
  assert p.returncode!=0,(flag,p.stdout,p.stderr)
  if flag not in ('restartfail',):assert len(mutations(r))==oldcalls,(flag,mutations(r))
  if flag not in ('content',):assert config.read_bytes()==owned,(flag,p.stderr)
  if flag=='restartfail':assert json.loads((r/'state/record.json').read_text())['phase']=='applied'

def nativefdactivation(substate='listening'):
 r,env=fixture();old=processes[-1];old.terminate();old.wait()
 (r/'socket-unit').write_text('[Socket]\nListenStream=/run/docker.sock\n');(r/'socket-substate').write_text(substate)
 (r/'fdactivation').touch();d=subprocess.Popen([str(r/'bin/dockerd'),'-H','fd://','--containerd=/run/containerd/containerd.sock'],env=env);processes.append(d);(r/'pid').write_text(str(d.pid))
 return r,env

def native_socket_running():
 r,env=nativefdactivation('running');original=(r/'etc/docker/daemon.json').read_bytes()
 assert_ok(invoke(r,env));assert json.loads((r/'state/record.json').read_text())['phase']=='applied'
 assert_ok(invoke(r,env,'restore'));assert (r/'etc/docker/daemon.json').read_bytes()==original
 assert [c[1] for c in mutations(r)]==['restart','restart'],mutations(r)

def native_socket_refusals():
 for substate,noactualpid in [('stopping',False),('listening',True),('running',True)]:
  r,env=nativefdactivation(substate);original=(r/'etc/docker/daemon.json').read_bytes()
  if noactualpid:(r/'listenerpid').write_text('1')
  p=invoke(r,env);reason='listener 不属于实际 dockerd PID' if noactualpid else 'docker.socket pending/状态/drop-in'
  assert p.returncode!=0 and reason in p.stderr,(substate,noactualpid,p.stdout,p.stderr)
  assert not mutations(r) and not (r/'state').exists() and (r/'etc/docker/daemon.json').read_bytes()==original
 for flag in ('socketpending','socketdropin','socketmissing','badpid'):
  r,env=nativefdactivation('running');original=(r/'etc/docker/daemon.json').read_bytes()
  if flag=='socketdropin':(r/'socket-dropins').write_text('/etc/systemd/system/docker.socket.d/foreign.conf')
  elif flag=='badpid':(r/'servicepid').write_text('../1')
  else:(r/flag).touch()
  p=invoke(r,env)
  assert p.returncode!=0,(flag,p.stdout,p.stderr)
  assert not mutations(r) and not (r/'state').exists() and (r/'etc/docker/daemon.json').read_bytes()==original

def lock_inode_boundaries():
 for flag in ('racelock','restartlock','stoplock','rollbackvalidationlock'):
  r,env=fixture();original=(r/'etc/docker/daemon.json').read_bytes();(r/flag).touch()
  if flag in ('stoplock','rollbackvalidationlock'):(r/'restartfail').touch()
  p=invoke(r,env)
  assert p.returncode!=0 and '锁 inode/内容' in p.stderr,(flag,p.stdout,p.stderr)
  m=json.loads((r/'state/record.json').read_text())
  if flag=='racelock':
   assert not mutations(r) and (r/'etc/docker/daemon.json').read_bytes()==original
   assert m['phase']=='prepared'
  else:
   assert m['phase']=='retained' and json.loads((r/'etc/docker/daemon.json').read_text())['ipv6'] is True
   assert [c[1] for c in mutations(r)]==(['restart','stop'] if flag=='stoplock' else ['restart'])

def native_socket_stopped_gate():
 for state,substate in [('inactive','running'),('inactive','listening'),('active','dead'),('active','running'),('active','listening')]:
  r,env=nativefdactivation('running');(r/'restartfail').touch()
  (r/'socket-stopped-state').write_text(state);(r/'socket-stopped-substate').write_text(substate)
  p=invoke(r,env);assert p.returncode!=0 and '保守保留' in p.stderr and 'docker.socket pending/状态/drop-in' in p.stderr,(state,substate,p.stdout,p.stderr)
  assert [c[1] for c in mutations(r)]==['restart','stop'],mutations(r)
  assert json.loads((r/'state/record.json').read_text())['phase']=='retained'
  assert json.loads((r/'etc/docker/daemon.json').read_text())['ipv6'] is True

def native_fd_and_openrc():
 r,env=fixture();old=processes[-1];old.terminate();old.wait()
 (r/'socket-unit').write_text('[Socket]\nListenStream=/run/docker.sock\n')
 (r/'fdactivation').touch();d=subprocess.Popen([str(r/'bin/dockerd'),'-H','fd://','--containerd=/run/containerd/containerd.sock'],env=env);processes.append(d);(r/'pid').write_text(str(d.pid))
 (r/'restartfail').touch();p=invoke(r,env);assert p.returncode!=0
 assert [c[1] for c in mutations(r)]==['restart','stop','start'],(mutations(r),p.stderr)
 assert any(c[1:]==['stop','docker.service','docker.socket'] for c in mutations(r)),mutations(r)
 r,env=fixture(alpine=True);(r/'actualpid').write_text((r/'pid').read_text());(r/'pid').unlink();assert_ok(invoke(r,env));assert_ok(invoke(r,env,'restore'))

def additional_failure_boundaries():
 for flag in ('rollbackvalidationfail','restartunit','restartsnapshotfail','startreadfail'):
  r,env=fixture();original=(r/'etc/docker/daemon.json').read_bytes();(r/flag).touch()
  if flag in ('rollbackvalidationfail','startreadfail'):(r/'restartfail').touch()
  p=invoke(r,env);assert p.returncode!=0 and '保守保留' in p.stderr,(flag,p.stdout,p.stderr)
  assert json.loads((r/'state/record.json').read_text())['phase']=='retained'
  if flag=='startreadfail':assert (r/'etc/docker/daemon.json').read_bytes()==original
  else:assert json.loads((r/'etc/docker/daemon.json').read_text())['ipv6'] is True
  if flag in ('restartunit','restartsnapshotfail','rollbackvalidationfail'):assert [x[1] for x in mutations(r)]==['restart']

def killextra(r):
 if (r/'extra-pids').exists():
  for pid in (r/'extra-pids').read_text().split():
   try:os.kill(int(pid),signal.SIGTERM)
   except ProcessLookupError:pass

def stopped_service_preflight():
 # A stopped daemon with a listening docker.socket would be STARTED by any
 # docker CLI call; preflight must prove non-activation (or refuse).
 def sockunit(r):
  (r/'socket-unit').write_text('[Socket]\nListenStream=/run/docker.sock\n');(r/'socketactivate').touch();(r/'service').write_text('inactive')
 r,env=fixture();sockunit(r);(r/'lingering').touch();(r/'listenerpid').write_text('1')
 original=(r/'etc/docker/daemon.json').read_bytes()
 p=invoke(r,env)
 assert p.returncode!=0 and 'socket' in p.stderr and '激活' in p.stderr,(p.stdout,p.stderr)
 assert not (r/'activated').exists() and (r/'service').read_text()=='inactive'
 assert not mutations(r) and not (r/'state').exists() and (r/'etc/docker/daemon.json').read_bytes()==original
 # Stopped with no listener at all: no API possible, refusal names it.
 r,env=fixture();sockunit(r)
 p=invoke(r,env)
 assert p.returncode!=0 and '未运行' in p.stderr,(p.stdout,p.stderr)
 assert not (r/'activated').exists() and not mutations(r) and not (r/'state').exists()

def runtime_recheck():
 # restart injects a foreign --host: success must not be reported.
 r,env=fixture();(r/'restartinject').touch();original=(r/'etc/docker/daemon.json').read_bytes()
 p=invoke(r,env);killextra(r)
 assert p.returncode!=0 and '复验' in p.stderr,(p.stdout,p.stderr)
 assert json.loads((r/'state/record.json').read_text())['phase']=='retained'
 assert (r/'etc/docker/daemon.json').read_bytes()==original
 assert [c[1] for c in mutations(r)]==['restart','stop','start'],mutations(r)
 # rollback start injects it: rollback must not claim restored.
 r,env=fixture();assert_ok(invoke(r,env));original=(r/'etc/docker/daemon.json').read_bytes()
 (r/'startinject').touch();(r/'bridgewrong').touch()
 p=invoke(r,env,'restore');killextra(r)
 assert p.returncode!=0 and '复验' in p.stderr,(p.stdout,p.stderr)
 assert json.loads((r/'state/record.json').read_text())['phase']=='retained'
 assert (r/'etc/docker/daemon.json').read_bytes()==original
 # engine identity change across restart.
 r,env=fixture();(r/'restartengine').touch();p=invoke(r,env)
 assert p.returncode!=0 and 'Engine' in p.stderr,(p.stdout,p.stderr)

def generator_dependencies():
 r,env=fixture();env['PATH']=str(r/'bin');env['FIXTURE_DECLINE_DEPENDENCIES']='1';(r/'bin/cat').unlink()
 original=(r/'etc/docker/daemon.json').read_bytes()
 p=invoke(r,env)
 assert p.returncode!=0 and 'cat' in p.stderr,(p.stdout,p.stderr)
 assert not calls(r) and (r/'etc/docker/daemon.json').read_bytes()==original
 r,env=fixture();env['PATH']=str(r/'bin');(r/'bin/cat').unlink();(r/'bin/cat').write_text('#!/bin/sh\nexit 3\n');os.chmod(r/'bin/cat',0o755)
 p=invoke(r,env)
 assert p.returncode!=0 and '生成' in p.stderr and 'cat' in p.stderr,(p.stdout,p.stderr)
 assert not calls(r) and not (r/'state').exists()

def firewall_dependencies():
 for cmd in ('iptables','ip6tables'):
  r,env=fixture();env['PATH']=str(r/'bin');env['FIXTURE_DECLINE_DEPENDENCIES']='1';(r/'bin'/cmd).unlink()
  p=invoke(r,env);assert p.returncode!=0 and ('缺少命令：' in p.stderr and cmd in p.stderr),(cmd,p.stdout,p.stderr)
  assert not mutations(r) and not (r/'state').exists()

def safety_switch_parity():
 # JSON must gate exactly what the flag parser gates.
 for key in ('ip-forward','ip-masq','icc'):
  r,env=fixture();(r/'etc/docker/daemon.json').write_text(json.dumps({key:False})+'\n')
  p=invoke(r,env);assert p.returncode!=0 and key in p.stderr,(key,p.stdout,p.stderr)
  r,env=fixture();old=processes[-1];old.terminate();old.wait()
  d=subprocess.Popen([str(r/'bin/dockerd'),'--host=unix:///var/run/docker.sock','--'+key+'=false'],env=env)
  processes.append(d);(r/'pid').write_text(str(d.pid))
  p=invoke(r,env);assert p.returncode!=0 and key in p.stderr,(key,p.stdout,p.stderr)
  assert not mutations(r) and not (r/'state').exists()
 r,env=fixture();(r/'etc/docker/daemon.json').write_text('{"icc":true,"ip-masq":true,"ip-forward":true}\n');assert_ok(invoke(r,env))

def lifetime_countdowns():
 r,env=fixture();(r/'lifetimecountdowns').touch();original=(r/'etc/docker/daemon.json').read_bytes()
 assert_ok(invoke(r,env));assert_ok(invoke(r,env,'restore'))
 assert (r/'etc/docker/daemon.json').read_bytes()==original
 for flag,reason in [('routeidentityrace','race'),('addridentityrace','race'),('routeconflictrace','路由冲突'),('addrconflictrace','地址冲突')]:
  r,env=fixture();(r/'lifetimecountdowns').touch();(r/flag).touch();original=(r/'etc/docker/daemon.json').read_bytes()
  p=invoke(r,env);assert p.returncode!=0 and reason in p.stderr,(flag,p.stdout,p.stderr)
  assert not mutations(r) and not (r/'state').exists() and (r/'etc/docker/daemon.json').read_bytes()==original

try:
 case('readonly-status',readonly)
 case('apply-preserve',apply)
 case('restore-exact',restore)
 case('validation-failure-status',failure_status)
 case('cancel-eof',cancel)
 case('remote-context',remote)
 case('stable-version',versions)
 case('json-preserve-refuse',json_refusals)
 case('path-trust',paths)
 case('ula-format',subnet_cases)
 case('container-network-route',conflicts)
 case('actual-executable-flags',native_binary_and_flags)
 case('restart-rollback',lifecycle_failures)
 case('validation-races',race)
 case('missing-config-alpine',absent_and_alpine)
 case('native-host-none-networks',lambda: (lambda r,env: ((r/'nativebuiltins').touch(),assert_ok(invoke(r,env))))(*fixture()))
 case('concurrency-signal-races',concurrent_and_confirm_race)
 case('restore-trust-failures',restore_refusals)
 case('native-socket-active-running',native_socket_running)
 case('native-socket-state-pid-refusals',native_socket_refusals)
 case('lock-inode-boundaries',lock_inode_boundaries)
 case('native-socket-stopped-gate',native_socket_stopped_gate)
 case('native-fd-openrc-layout',native_fd_and_openrc)
 case('unknown-state-retention',additional_failure_boundaries)
 case('stopped-service-preflight',stopped_service_preflight)
 case('runtime-recheck',runtime_recheck)
 case('generator-dependencies',generator_dependencies)
 case('firewall-dependencies',firewall_dependencies)
 case('safety-switch-parity',safety_switch_parity)
 case('native-ipv6-lifetime-countdowns',lifetime_countdowns)
finally:
 for p in processes:
  p.terminate()
  try:p.wait(timeout=3)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 (E/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2));print('EVIDENCE='+str(E),flush=True)
 packages_untouched()
PY
