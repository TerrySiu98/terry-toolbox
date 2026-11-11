#!/usr/bin/env python3
"""Native isolated guest safety probes; installed service required; no secrets printed."""
import json,os,pty,select,subprocess,sys,time
from pathlib import Path
backend=sys.argv[1]; module='/root/ss-test/modules/shadowsocks.sh'; etc=Path('/etc/terry-toolbox-shadowsocks'); service='terry-toolbox-shadowsocks';
def call(args,input=''):
 return subprocess.run(['bash',module,backend]+args,input=input,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
def active():
 args=['rc-service',service,'status'] if backend=='alpine' else ['systemctl','is-active','--quiet',service+'.service']
 return subprocess.run(args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
assert active()
passwd=json.loads((etc/'config.json').read_text())['inbounds'][0]['settings']['password']
for name,data in [('foreign-extra',b'keep'),('foreign-extra-2',b'keep-two')]:
 p=etc/name;p.write_bytes(data)
 try:
  r=call(['uninstall'],'YES\nYES\n');assert r.returncode!=0 and p.read_bytes()==data and active()
 finally:p.unlink()
print('unknown resource preservation PASS')
if backend=='alpine':
 link=Path('/etc/runlevels/default/foreign-ss-alias'); assert not link.exists() and not link.is_symlink()
 link.symlink_to('/etc/init.d/terry-toolbox-shadowsocks')
 try:
  r=call(['uninstall'],'YES\nYES\n'); assert r.returncode!=0 and link.is_symlink() and active(), 'foreign alias must block stopping/deleting'
 finally:link.unlink()
 print('foreign OpenRC dependency preservation PASS')

config=etc/'config.json'; original=config.read_bytes(); original_mode=config.stat().st_mode
try:
 config.write_bytes(original+b' ')
 r=call(['uninstall'],'YES\nYES\n');assert r.returncode!=0 and config.read_bytes()==original+b' ' and active()
finally:
 config.write_bytes(original); os.chmod(config,original_mode & 0o777)
print('changed owned resource retention PASS')
# A failed stop must not delete any owned resource or signal other services.
import tempfile
with tempfile.TemporaryDirectory(prefix='ssx-stop-fault-',dir='/root') as d:
 command='rc-service' if backend=='alpine' else 'systemctl'
 real='/sbin/rc-service' if backend=='alpine' else '/usr/bin/systemctl'
 wrapper=Path(d)/command
 wrapper.write_text('#!/bin/sh\ncase " $* " in *" stop "*) exit 51;; esac\nexec '+real+' "$@"\n')
 wrapper.chmod(0o755)
 env=os.environ.copy();env['PATH']=d+':'+env.get('PATH','')
 r=subprocess.run(['bash',module,backend,'uninstall'],input='YES\nYES\n',text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=30)
 assert r.returncode!=0 and active() and (etc/'config.json').read_bytes()==original
print('failed stop preserves service and files PASS')
r=call(['show']);assert r.returncode!=0 and passwd not in r.stdout+r.stderr
print('non-TTY secret suppression PASS')
master,slave=pty.openpty();p=subprocess.Popen(['bash',module,backend,'show'],stdin=slave,stdout=slave,stderr=slave,close_fds=True);os.close(slave)
buf=b'';limit=time.monotonic()+10
while time.monotonic()<limit:
 r,_,_=select.select([master],[],[],.2)
 if r:
  try: buf+=os.read(master,8192)
  except OSError: break
 if p.poll() is not None and not r:break
p.wait(timeout=5);os.close(master)
text=buf.decode(errors='replace');assert p.returncode==0 and passwd in text and text.index('请勿分享')<text.index(passwd)
print('PTY password display and warning ordering PASS')
assert active()
