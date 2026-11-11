#!/usr/bin/env python3
"""Real Xray SOCKS TCP/UDP transport fixture; runs only inside isolated guest."""
import json, os, socket, struct, subprocess, tempfile, threading, time
from pathlib import Path

os.umask(0o077)
config=json.loads(Path('/etc/terry-toolbox-shadowsocks/client.json').read_text())
config['inbounds'][0]['port']=39080
stop=threading.Event()
def server(kind, port):
    s=socket.socket(socket.AF_INET,kind); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind(('8.8.4.4',port)); s.settimeout(.2)
    if kind==socket.SOCK_STREAM: s.listen()
    while not stop.is_set():
        try:
            if kind==socket.SOCK_STREAM:
                c,_=s.accept(); c.settimeout(1)
                try: c.sendall(c.recv(1024))
                except OSError: pass
                finally: c.close()
            else:
                data,addr=s.recvfrom(1024); s.sendto(data,addr)
        except (TimeoutError,OSError): pass
    s.close()
for k,p in ((socket.SOCK_STREAM,39081),(socket.SOCK_DGRAM,39082)):
 threading.Thread(target=server,args=(k,p),daemon=True).start()
def recv_exact(s,n):
 out=b''
 while len(out)<n:
  b=s.recv(n-len(out))
  if not b: raise OSError('unexpected EOF')
  out+=b
 return out
def handshake(s,cmd,port):
 s.sendall(b'\x05\x01\x00'); assert recv_exact(s,2)==b'\x05\x00'
 s.sendall(b'\x05'+bytes([cmd])+b'\x00\x01'+socket.inet_aton('8.8.4.4' if cmd==1 else '127.0.0.1')+struct.pack('!H',port))
 h=recv_exact(s,4)
 if h[:2]!=b'\x05\x00': raise OSError('SOCKS rejected')
 if h[3]!=1: raise OSError('unexpected address')
 return socket.inet_ntoa(recv_exact(s,4)),struct.unpack('!H',recv_exact(s,2))[0]
def probe_tcp():
 with socket.create_connection(('127.0.0.1',39080),timeout=3) as s:
  s.settimeout(3); handshake(s,1,39081); s.sendall(b'tcp-ss-nonce-473'); return recv_exact(s,16)==b'tcp-ss-nonce-473'
def probe_udp():
 with socket.create_connection(('127.0.0.1',39080),timeout=3) as ctl:
  ctl.settimeout(3); addr=handshake(ctl,3,0)
  with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as u:
   u.settimeout(3); u.sendto(b'\0\0\0\1'+socket.inet_aton('8.8.4.4')+struct.pack('!H',39082)+b'udp-ss-nonce-958',addr)
   data,_=u.recvfrom(2048); return data[10:]==b'udp-ss-nonce-958'
def run(wrong=False):
 c=json.loads(json.dumps(config))
 if wrong: c['outbounds'][0]['settings']['servers'][0]['password']+='wrong'
 with tempfile.NamedTemporaryFile(mode='w',prefix='ssx-probe-',suffix='.json',dir='/root',delete=False) as f:
  json.dump(c,f); filename=f.name
 proc=subprocess.Popen(['/usr/local/bin/terry-toolbox-shadowsocks','run','-config',filename],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 try:
  for _ in range(40):
   try:
    s=socket.create_connection(('127.0.0.1',39080),timeout=.1); s.close(); break
   except OSError: time.sleep(.1)
  else: raise RuntimeError('client not ready')
  result=[]
  for test in (probe_tcp,probe_udp):
   try: result.append(test())
   except (OSError,AssertionError) as exc:
    result.append(False)
  return result
 finally:
  proc.terminate()
  try: proc.wait(timeout=5)
  except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)
  os.unlink(filename)
try:
 good=run(); bad=run(True); again=run()
 print('TCP/UDP positive',good,'wrong password',bad,'positive control after rejection',again)
 assert good==[True,True] and bad==[False,False] and again==[True,True]
finally: stop.set()
