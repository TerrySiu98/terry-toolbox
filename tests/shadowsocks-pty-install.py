#!/usr/bin/env python3
"""Isolated guest install with TTY; output stays private; verify disclosure order."""
import json,os,pty,select,subprocess,sys,time
from pathlib import Path
backend=sys.argv[1];module='/root/ss-test/modules/shadowsocks.sh'; master,slave=pty.openpty()
p=subprocess.Popen(['bash',module,backend,'install','127.0.0.1','38388'],stdin=slave,stdout=slave,stderr=slave,close_fds=True);os.close(slave)
buf=bytearray(); sent=0; deadline=time.monotonic()+180
while time.monotonic()<deadline:
 ready,_,_=select.select([master],[],[],.2)
 if ready:
  try:data=os.read(master,16384)
  except OSError:break
  if not data:break
  buf.extend(data)
  text=buf.decode(errors='replace')
  while sent<2 and text.count('输入 YES')>sent:
   os.write(master,b'YES\n');sent+=1
 if p.poll() is not None and not ready:break
try:rc=p.wait(timeout=10)
except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);raise
os.close(master)
if rc:
 print('PTY install failed rc',rc,'confirmations',sent);sys.exit(1)
password=json.loads(Path('/etc/terry-toolbox-shadowsocks/config.json').read_text())['inbounds'][0]['settings']['password']
text=buf.decode(errors='replace')
assert sent==2 and text.count(password)==1 and text.index('请勿分享')<text.index('输入 YES')<text.index(password)
print('TTY install disclosure ordering and exactly-once secret display PASS')
