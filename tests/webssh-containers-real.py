#!/usr/bin/env python3
"""Real B10 acceptance, only in an explicitly marked disposable Linux VM.

Requires Docker >=28, openssh-server and OpenSSL. It uses the unmodified public
install/status/uninstall functions, original pinned images and real SSH/SFTP.
No mock, TLS bypass, public listener, dependency installer or name-based cleanup.
Failed application resources are preserved with private evidence for inspection.

Run as root after placing exactly `webssh-containers\n` in a root-owned 0600
/run/terry-toolbox-disposable-acceptance marker. This authorizes a dedicated
root SSH test process bound to the owned Docker bridge gateway, using only a
new fixture public key. Never run against a business machine.
"""
import argparse
import base64
import hashlib
import http.client
import json
import os
import pathlib
import secrets
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse


class Failure(RuntimeError):
    pass


def need(value, message):
    if not value:
        raise Failure(message)


def run(args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kwargs).stdout


class HTTP:
    def __init__(self, port):
        self.port, self.cookie, self.token = port, '', ''

    def request(self, method, path, data=None, form=False, auth=True):
        headers = {}
        if data is not None:
            data = (urllib.parse.urlencode(data).encode() if form else
                    json.dumps(data).encode())
            headers['Content-Type'] = ('application/x-www-form-urlencoded' if form
                                       else 'application/json')
        if auth and self.cookie:
            headers['Cookie'] = self.cookie
        if auth and self.token:
            headers['token'] = self.token
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=15)
        try:
            connection.request(method, path, body=data, headers=headers)
            response = connection.getresponse()
            body = response.read()
            fields=response.getheaders()
            result=dict(fields)
            cookies=[v.split(';',1)[0] for k,v in fields if k.lower()=='set-cookie']
            if cookies:
                result['Set-Cookie']='; '.join(cookies)
            return response.status, result, body
        finally:
            connection.close()

    def api(self, method, path, data=None):
        status, _, body = self.request(method, path, data)
        need(status == 200, 'authenticated API rejected '+path)
        value = json.loads(body)
        need(value.get('status') == 200, 'API application status rejected '+path)
        return value.get('data')


class WebSocket:
    """Small RFC6455 client; no third-party libraries or protocol stubs."""
    def __init__(self, port, path, cookie=''):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=15)
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        request = ('GET '+path+' HTTP/1.1\r\nHost: 127.0.0.1:'+str(port)+
                   '\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                   'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+key+'\r\n')
        if cookie:
            request += 'Cookie: '+cookie+'\r\n'
        self.sock.sendall((request+'\r\n').encode())
        data = b''
        while b'\r\n\r\n' not in data:
            chunk = self.sock.recv(1)
            need(chunk, 'WebSocket upgrade closed')
            data += chunk
            need(len(data)<32768, 'WebSocket upgrade headers too large')
        need(data.startswith(b'HTTP/1.1 101 '), 'WebSocket upgrade rejected')
        expected = base64.b64encode(hashlib.sha1(
            (key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        headers=dict(line.split(b':',1) for line in data.split(b'\r\n')[1:] if b':' in line)
        headers={key.lower():value.strip() for key,value in headers.items()}
        need(headers.get(b'sec-websocket-accept')==expected, 'WebSocket accept mismatch')

    def exact(self, size):
        value = b''
        while len(value)<size:
            chunk = self.sock.recv(size-len(value))
            need(chunk, 'WebSocket closed')
            value += chunk
        return value

    def send(self, value, opcode=1):
        data = value.encode() if isinstance(value, str) else value
        mask = secrets.token_bytes(4)
        length = len(data)
        head = bytes([0x80|opcode, 0x80|(length if length<126 else 126 if length<65536 else 127)])
        if length>=126:
            head += struct.pack('!H' if length<65536 else '!Q', length)
        self.sock.sendall(head+mask+bytes(x ^ mask[i%4] for i,x in enumerate(data)))

    def receive(self):
        while True:
            first, second = self.exact(2)
            need(first & 0x80, 'fragmented server message unsupported')
            size = second & 127
            if size in (126,127):
                size = struct.unpack('!H' if size==126 else '!Q', self.exact(2 if size==126 else 8))[0]
            need(size<1024*1024, 'WebSocket message too large')
            mask = self.exact(4) if second&128 else None
            data = self.exact(size)
            if mask:
                data = bytes(x ^ mask[i%4] for i,x in enumerate(data))
            opcode = first & 15
            if opcode==9:
                self.send(data,10)
                continue
            need(opcode!=8, 'WebSocket closed')
            if opcode in (1,2):
                return data.decode(errors='replace')

    def close(self):
        self.sock.close()


class SocketIO(WebSocket):
    def __init__(self, port, path, cookie, token):
        super().__init__(port, path+'/?EIO=4&transport=websocket', cookie)
        need(self.receive().startswith('0{'), 'Engine.IO open packet absent')
        self.send('40'+json.dumps({'token':token}))
        packet = self.receive()
        while packet=='2':
            self.send('3')
            packet=self.receive()
        need(packet.startswith('40{'), 'Socket.IO authenticated connection rejected')

    def event(self, name, data):
        self.send('42'+json.dumps([name,data]))

    def wait(self, name, timeout=20):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            self.sock.settimeout(max(0.1,deadline-time.monotonic()))
            packet=self.receive()
            if packet=='2':
                self.send('3')
            elif packet.startswith('42'):
                event=json.loads(packet[2:])
                if event[0]==name:
                    return event[1] if len(event)>1 else None
                need(event[0] not in ('terminal_connect_fail','terminal_create_fail',
                                      'connect_fail','file_save_error','file_read_error'),
                     'Socket.IO operation rejected '+event[0])
        raise Failure('Socket.IO event timeout '+name)


def evp_key(password, salt):
    result, previous=b'',b''
    while len(result)<48:
        previous=hashlib.md5(previous+password+salt).digest()
        result+=previous
    return result[:32], result[32:48]


def aes_cryptojs(value, password):
    salt=secrets.token_bytes(8)
    key,iv=evp_key(password.encode(),salt)
    encrypted=run(['openssl','enc','-aes-256-cbc','-K',key.hex(),'-iv',iv.hex()],
                  input=value.encode())
    return base64.b64encode(b'Salted__'+salt+encrypted).decode()


def rsa_encrypt(value, pem, work):
    path=work/'public.pem'
    path.write_text(pem)
    return base64.b64encode(run(['openssl','pkeyutl','-encrypt','-pubin','-inkey',str(path),
                                '-pkeyopt','rsa_padding_mode:pkcs1'],input=value.encode())).decode()


def credentials(data):
    return dict(line.split('=',1) for line in (data/'credentials.txt').read_text().splitlines())


def login(http, branch, data, work, wrong=False):
    cred=credentials(data)
    password=cred['password']+('-wrong' if wrong else '')
    if branch=='personal':
        status,headers,body=http.request('POST','/api/login',
                                        {'username':cred['username'],'password':password},form=True,auth=False)
        need(status==302, 'native login response invalid')
        if wrong:
            need('session_token=' not in headers.get('Set-Cookie','') and
                 headers.get('Location')=='/?error=invalid','wrong password granted personal login')
        else:
            cookie=headers.get('Set-Cookie','')
            need(cookie.startswith('session_token=') and len(cookie)>30,'personal session cookie absent')
            http.cookie=cookie
            status,_,body=http.request('GET','/api/backup')
            need(status==200 and json.loads(body)['config']['admin_user']==cred['username'],
                 'personal session failed protected readback')
    else:
        status,_,body=http.request('GET','/api/v1/get-pub-pem',auth=False)
        need(status==200,'Easynode native public key unavailable')
        pem=json.loads(body)['data']
        status,headers,body=http.request('POST','/api/v1/login',
            {'loginName':cred['username'],'ciphertext':rsa_encrypt(password,pem,work),'jwtExpires':'3d'},auth=False)
        result=json.loads(body)
        if wrong:
            need(status==400 and not result.get('data',{}).get('token') and
                 'session=' not in headers.get('Set-Cookie',''),'wrong password granted Easynode login')
        else:
            need(status==200 and result.get('status')==200 and result['data'].get('token'),
                 'Easynode native login rejected')
            http.token=result['data']['token']
            http.cookie=headers.get('Set-Cookie','')
            need(http.cookie.startswith('session='),'Easynode session cookie absent')
            http.api('GET','/api/v1/host-catalog')
            return pem


def ready(client, branch, timeout=60):
    endpoint='/api/backup' if branch=='personal' else '/api/v1/host-catalog'
    deadline=time.monotonic()+timeout
    while True:
        try:
            status,_,_=client.request('GET',endpoint,auth=False)
            if status==401:
                return
            need(status!=200,'anonymous protected API allowed')
        except (OSError,http.client.HTTPException):
            pass
        need(time.monotonic()<deadline,'native API readiness/auth guard failed')
        time.sleep(1)


def business(http,branch,data,work,gateway,ssh_port,key,nonce):
    login(http,branch,data,work,wrong=True)
    pem=login(http,branch,data,work)
    if branch=='personal':
        status,_,_=http.request('POST','/api/save',{'type':'credential','action':'add',
            'credential':{'id':nonce,'name':nonce,'username':'root','private_key':key}})
        need(status==200,'personal credential write rejected')
        status,_,_=http.request('POST','/api/save',{'type':'server','action':'add',
            'server':{'id':nonce,'name':nonce,'ip':gateway,'port':ssh_port,'credential_id':nonce}})
        need(status==200,'personal server write rejected')
        ws=WebSocket(http.port,'/ws/ssh?id='+nonce,http.cookie)
        try:
            ws.send('stty -echo; printf "B10_%s\\n" "'+nonce+'"\r')
            output=''
            deadline=time.monotonic()+20
            while 'B10_'+nonce not in output and time.monotonic()<deadline:
                ws.sock.settimeout(max(0.1,deadline-time.monotonic()))
                output+=ws.receive()
            need('B10_'+nonce in output,'personal actual SSH nonce absent')
        finally:
            ws.close()
        path=str(work/'sftp-nonce.txt')
        status,_,_=http.request('POST','/api/sftp/save',{'id':nonce,'path':path,'content':nonce},form=True)
        need(status==200,'personal SFTP write rejected')
        status,_,body=http.request('GET','/api/sftp/cat?'+urllib.parse.urlencode({'id':nonce,'path':path}))
        need(status==200 and body.decode()==nonce and pathlib.Path(path).read_text()==nonce,
             'personal actual SFTP readback mismatch')
        return nonce
    tempkey=secrets.token_urlsafe(32)
    http.api('POST','/api/v1/host-save',{'name':nonce,'host':gateway,'port':ssh_port,
        'username':'root','authType':'privateKey','privateKey':aes_cryptojs(key,tempkey),
        'tempKey':rsa_encrypt(tempkey,pem,work),'group':'default','command':'','tag':[]})
    hosts=http.api('GET','/api/v1/host-catalog')['hosts']
    host=next((h for h in hosts if h['name']==nonce),None)
    need(host and host['isConfig'],'Easynode encrypted host write readback failed')
    ws=SocketIO(http.port,'/terminal',http.cookie,http.token)
    try:
        ws.event('ws_terminal',{'hostId':host['id'],'rows':24,'cols':80})
        ws.wait('terminal_connect_shell_success')
        ws.event('input','stty -echo; printf "B10_%s\\n" "'+nonce+'"\r')
        output=''
        deadline=time.monotonic()+20
        while 'B10_'+nonce not in output and time.monotonic()<deadline:
            output+=str(ws.wait('output',max(0.1,deadline-time.monotonic())))
        need('B10_'+nonce in output,'Easynode actual SSH nonce absent')
    finally:
        ws.close()
    sftp=SocketIO(http.port,'/sftp-v2',http.cookie,http.token)
    try:
        sftp.event('ws_sftp',{'hostId':host['id']})
        sftp.wait('connect_success')
        path=str(work/'sftp-nonce.txt')
        sftp.event('save_file',{'filePath':path,'content':nonce,'encoding':'utf8'})
        sftp.wait('file_saved')
        sftp.event('read_file',{'filePath':path,'fileSize':len(nonce),'encoding':'utf8'})
        result=sftp.wait('file_content')
        need(result['content']==nonce and pathlib.Path(path).read_text()==nonce,
             'Easynode actual SFTP readback mismatch')
    finally:
        sftp.close()
    return host['id']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--branch',choices=('personal','easynode','both'),default='both')
    parser.add_argument('--output',required=True,help='New absolute private evidence directory')
    args=parser.parse_args()
    os.umask(0o077)
    marker=pathlib.Path('/run/terry-toolbox-disposable-acceptance')
    need(sys.platform=='linux' and os.geteuid()==0,'requires root in disposable Linux VM')
    facts=marker.lstat()
    need(stat.S_ISREG(facts.st_mode) and facts.st_uid==0 and facts.st_nlink==1 and
         stat.S_IMODE(facts.st_mode)==0o600 and marker.read_text()=='webssh-containers\n',
         'disposable acceptance marker invalid')
    work=pathlib.Path(args.output)
    need(work.is_absolute() and not work.exists() and not work.is_symlink(),'new absolute evidence path required')
    work.mkdir(mode=0o700)
    source=pathlib.Path(__file__).resolve().parents[1]/'modules/webssh-containers.sh'
    need(source.is_file(),'source module missing')
    summary={'module_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
             'harness_sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
             'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
             'cases':[],'passed':False}
    (work/'summary.json').write_text(json.dumps(summary,indent=2))
    for branch in (('personal','easynode') if args.branch=='both' else (args.branch,)):
        private=work/branch
        private.mkdir(mode=0o700)
        home=private/'home'
        home.mkdir(mode=0o700)
        env={k:v for k,v in os.environ.items() if not k.startswith('DOCKER_')}
        env['HOME']=str(home)
        def lifecycle(action):
            process=subprocess.Popen(['bash','-c','source "$1"; toolbox_webssh_container "$2" "$3"',
                'acceptance',str(source),branch,action],env=env,
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                start_new_session=True)
            timed_out=False
            try:
                output,_=process.communicate(b'YES\nYES\n',timeout=600)
            except subprocess.TimeoutExpired:
                timed_out=True
                # Terminate the owned lifecycle process group, including the
                # Docker CLI and shell children; allow the product EXIT cleanup.
                try:
                    os.killpg(process.pid,signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    output,_=process.communicate(timeout=45)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid,signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    output,_=process.communicate()
            (private/(action+'-'+secrets.token_hex(4)+'.log')).write_bytes(output)
            need(not timed_out,branch+' '+action+' timed out; private logs retained')
            need(process.returncode==0,branch+' '+action+' failed; private logs retained')
        lifecycle('install')
        data=home/'.local/share/terry-toolbox/webssh-containers'/branch
        ledger=json.loads((data/'ledger.json').read_text())
        network=ledger['network']['id']
        app=next(c['id'] for c in ledger['containers'] if c['role']=='app')
        net=json.loads(run(['docker','--host','unix:///var/run/docker.sock','network','inspect',network]))[0]
        gateway=net['IPAM']['Config'][0]['Gateway']
        keypath=private/'fixture-key'
        run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(keypath)])
        hostkey=private/'host-key'
        run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(hostkey)])
        sshport=22222
        config=private/'sshd.conf'
        # Debian cloud images deliberately lock the root password. PAM account
        # checks keep key-only root login usable without unlocking/changing it;
        # both password and keyboard-interactive authentication remain disabled.
        config.write_text('Port '+str(sshport)+'\nListenAddress '+gateway+'\nHostKey '+str(hostkey)+
            '\nPidFile '+str(private/'sshd.pid')+'\nAuthorizedKeysFile '+str(keypath)+'.pub'+
            '\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nKbdInteractiveAuthentication no'+
            '\nUsePAM yes\nStrictModes yes\nSubsystem sftp internal-sftp\n')
        pathlib.Path('/run/sshd').mkdir(mode=0o755,exist_ok=True)
        run(['/usr/sbin/sshd','-t','-f',str(config)])
        with (private/'sshd.log').open('wb') as log:
            sshd=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=log,stderr=log)
            try:
                time.sleep(0.5)
                need(sshd.poll() is None,'fixture sshd failed')
                client=HTTP(ledger['port'])
                ready(client,branch)
                nonce='nonce-'+secrets.token_hex(16)
                record=business(client,branch,data,private,gateway,sshport,keypath.read_text(),nonce)
                run(['docker','--host','unix:///var/run/docker.sock','restart',app])
                client=HTTP(ledger['port'])
                ready(client,branch)
                login(client,branch,data,private)
                if branch=='personal':
                    status,_,body=client.request('GET','/api/backup')
                    need(status==200 and any(s['id']==record for s in json.loads(body)['servers']),
                         'personal data did not survive full container ID restart')
                else:
                    need(any(h['id']==record for h in client.api('GET','/api/v1/host-catalog')['hosts']),
                         'Easynode data did not survive full container ID restart')
                lifecycle('status')
                # Native NeDB and log writers may append/compact while stopping.
                # Preserve every pre-existing data leaf and prove the business
                # record and immutable credential bytes remain after uninstall.
                before=[str(p.relative_to(data)) for p in data.rglob('*') if p.is_file()]
                cred_hash=hashlib.sha256((data/'credentials.txt').read_bytes()).hexdigest()
                lifecycle('uninstall')
                need(all((data/path).is_file() for path in before) and
                     hashlib.sha256((data/'credentials.txt').read_bytes()).hexdigest()==cred_hash,
                     'uninstall removed retained app files/credentials')
                database=data/'data'/('data.json' if branch=='personal' else 'host.db')
                need(nonce in database.read_text(),'uninstall lost persisted business record')
                ids=run(['docker','--host','unix:///var/run/docker.sock','container','ls','-a','--no-trunc','--format','{{.ID}}']).decode().splitlines()
                networks=run(['docker','--host','unix:///var/run/docker.sock','network','ls','--no-trunc','--format','{{.ID}}']).decode().splitlines()
                need(all(c['id'] not in ids for c in ledger['containers']) and network not in networks,
                     'owned resources survived uninstall')
                summary['cases'].append({'branch':branch,'passed':True,'checks':['anonymous-rejection',
                    'wrong-password-rejection','native-session-protected-read','real-ssh-nonce',
                    'real-sftp-write-read','container-id-restart-persistence','owned-uninstall-data-retention'],
                    'container_ids':[c['id'] for c in ledger['containers']],
                    'network_id':network,
                    'images':[{'role':c['role'],'reference':c['critical']['Config']['Image'],
                               'image_id':c['critical']['Image']} for c in ledger['containers']]})
                (work/'summary.json').write_text(json.dumps(summary,indent=2))
                print('PASS: B10 '+branch+' real login/SSH/SFTP/restart/uninstall',flush=True)
            finally:
                if sshd.poll() is None:
                    sshd.terminate()
                    try:
                        sshd.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        sshd.kill()
                        sshd.wait()
    summary['passed']=True
    summary['finished_utc']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
    (work/'summary.json').write_text(json.dumps(summary,indent=2))


if __name__=='__main__':
    try:
        main()
    except (Failure,OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
        print('FAIL: '+str(error),file=sys.stderr)
        sys.exit(1)
