#!/usr/bin/env python3
"""Exercise generated Mihomo proxy entry inside an isolated guest."""
import json,os,socket,struct,subprocess,tempfile,threading,time,shutil
from pathlib import Path
os.umask(0o077)
stop=threading.Event()
def echo(kind,port):
 s=socket.socket(socket.AF_INET,kind);s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('8.8.4.4',port));s.settimeout(.2)
 if kind==socket.SOCK_STREAM:s.listen()
 while not stop.is_set():
  try:
   if kind==socket.SOCK_STREAM:
    c,_=s.accept();c.settimeout(1)
    try:c.sendall(c.recv(512))
    except OSError:pass
    finally:c.close()
   else:
    d,a=s.recvfrom(512);s.sendto(d,a)
  except OSError:pass
 s.close()
for typ,port in ((socket.SOCK_STREAM,39081),(socket.SOCK_DGRAM,39082)):threading.Thread(target=echo,args=(typ,port),daemon=True).start()
def exact(s,n):
 out=b''
 while len(out)<n:
  x=s.recv(n-len(out))
  if not x:raise OSError('closed')
  out+=x
 return out
def setup(s,cmd,port):
 s.sendall(b'\5\1\0');assert exact(s,2)==b'\5\0'
 s.sendall(b'\5'+bytes([cmd])+b'\0\1'+socket.inet_aton('8.8.4.4' if cmd==1 else '127.0.0.1')+struct.pack('!H',port))
 h=exact(s,4);assert h[:2]==b'\5\0' and h[3]==1
 return socket.inet_ntoa(exact(s,4)),struct.unpack('!H',exact(s,2))[0]
def tcp():
 with socket.create_connection(('127.0.0.1',39080),timeout=3) as s:
  s.settimeout(3);setup(s,1,39081);s.sendall(b'mihomo-tcp-nonce');return exact(s,16)==b'mihomo-tcp-nonce'
def udp():
 with socket.create_connection(('127.0.0.1',39080),timeout=3) as s:
  s.settimeout(3);addr=setup(s,3,0)
  with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as u:
   u.settimeout(3);u.sendto(b'\0\0\0\1'+socket.inet_aton('8.8.4.4')+struct.pack('!H',39082)+b'mihomo-udp-nonce',addr);return u.recvfrom(2048)[0][10:]==b'mihomo-udp-nonce'
def run(wrong=False):
 d=tempfile.mkdtemp(prefix='ssx-mihomo-',dir='/root'); p=None
 try:
  proxy=Path('/etc/terry-toolbox-shadowsocks/mihomo.yaml').read_text()
  if wrong:
   config=json.loads(Path('/etc/terry-toolbox-shadowsocks/config.json').read_text()); password=config['inbounds'][0]['settings']['password']
   proxy=proxy.replace(json.dumps(password),json.dumps(password+'wrong'))
  path=Path(d)/'config.yaml';path.write_text('mixed-port: 39080\nbind-address: 127.0.0.1\nallow-lan: false\nmode: rule\nlog-level: error\n'+proxy+'proxy-groups:\n  - name: SS-TEST\n    type: select\n    proxies: [Terry-SS]\nrules:\n  - MATCH,SS-TEST\n')
  p=subprocess.Popen(['/root/ss-test/mihomo','-d',d,'-f',str(path)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  for _ in range(50):
   try:
    s=socket.create_connection(('127.0.0.1',39080),timeout=.1);s.close();time.sleep(1);break
   except OSError:time.sleep(.1)
  else:raise RuntimeError('mihomo not ready')
  out=[]
  for f in (tcp,udp):
   try:out.append(f())
   except (OSError,AssertionError):out.append(False)
  return out
 finally:
  if p is not None:
   p.terminate()
   try:p.wait(timeout=5)
   except subprocess.TimeoutExpired:p.kill();p.wait(timeout=5)
  shutil.rmtree(d)
try:
 good=run();bad=run(True);again=run();print('Mihomo TCP/UDP positive',good,'wrong password',bad,'positive control',again)
 assert good==[True,True] and bad==[False,False] and again==[True,True]
finally:stop.set()
