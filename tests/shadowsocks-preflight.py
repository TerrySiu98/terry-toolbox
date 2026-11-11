#!/usr/bin/env python3
"""Native isolated guest refusal checks; no product installation required."""
import os,socket,subprocess,sys
from pathlib import Path
backend=sys.argv[1];module='/root/ss-test/modules/shadowsocks.sh'
service=Path('/etc/init.d/terry-toolbox-shadowsocks' if backend=='alpine' else '/etc/systemd/system/terry-toolbox-shadowsocks.service')
targets=[Path('/etc/terry-toolbox-shadowsocks'),Path('/usr/local/bin/terry-toolbox-shadowsocks'),service]
assert all(not x.exists() for x in targets)
def call(inp='YES\nYES\n'):
 return subprocess.run(['bash',module,backend,'install','127.0.0.1','38388'],input=inp,text=True,capture_output=True,timeout=30)
for kind in (socket.SOCK_STREAM,socket.SOCK_DGRAM):
 s=socket.socket(socket.AF_INET,kind);s.bind(('127.0.0.1',38388))
 if kind==socket.SOCK_STREAM:s.listen()
 try:
  r=call();assert r.returncode!=0 and '占用' in r.stderr and all(not x.exists() for x in targets)
 finally:s.close()
print('TCP-only and UDP-only port conflict preservation PASS')
for inp in ('NO\n','YES\nNO\n','YES','YES\nYES'):
 r=call(inp);assert r.returncode!=0 and all(not x.exists() for x in targets)
print('cancellation and incomplete confirmations PASS')
service.write_text('unknown fixture\n');os.chmod(service,0o755)
try:
 r=call();assert r.returncode!=0 and service.read_text()=='unknown fixture\n' and not targets[0].exists() and not targets[1].exists()
finally:service.unlink()
print('foreign service preserved PASS')
other='alpine' if backend=='systemd' else 'systemd'
r=subprocess.run(['bash',module,other,'install','127.0.0.1','38388'],input='YES\nYES\n',text=True,capture_output=True,timeout=30)
assert r.returncode!=0 and all(not x.exists() for x in targets)
print('wrong OS/init backend refusal PASS')
