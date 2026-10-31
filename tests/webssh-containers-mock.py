#!/usr/bin/env python3
"""Privileged Docker/ss boundary mock. State is synthetic, never registry evidence."""
import hashlib
import json
import os
import pathlib
import signal
import sys

root = pathlib.Path(os.environ['WSC_MOCK'])
args = sys.argv[1:]
cmd = pathlib.Path(sys.argv[0]).name
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps([cmd, *args]) + '\n')
statefile = root / 'state.json'
s = json.loads(statefile.read_text()) if statefile.exists() else {'containers': {}, 'networks': {}}

def save():
    statefile.write_text(json.dumps(s))

def emit(obj):
    print(json.dumps(obj))

def ident(text):
    return hashlib.sha256(text.encode()).hexdigest()

def die():
    sys.exit(1)

if cmd == 'ss':
    if os.getenv('MOCK_SS_FAIL'):
        die()
    if os.getenv('MOCK_PORT'):
        print('LISTEN 0 128 127.0.0.1:' + os.environ['MOCK_PORT'] + ' 0.0.0.0:*')
    sys.exit(0)
if args[:2] == ['--host', 'unix:///var/run/docker.sock']:
    args = args[2:]
if args[:2] == ['context', 'show']:
    print(os.getenv('MOCK_CONTEXT', 'default'))
elif args[:2] == ['context', 'inspect']:
    print(os.getenv('MOCK_ENDPOINT', 'unix:///var/run/docker.sock'))
elif args[:1] == ['info']:
    if os.getenv('MOCK_OFFLINE'):
        die()
    emit({'OSType': 'linux', 'Architecture': os.getenv('MOCK_ARCH', 'x86_64'), 'MemTotal': int(os.getenv('MOCK_MEM', str(8 * 1024**3))), 'SecurityOptions': [os.getenv('MOCK_SECURITY', 'name=seccomp,profile=builtin')]})
elif args[:1] == ['version']:
    print(os.getenv('MOCK_VERSION', '28.5.1'))
elif args[:2] == ['image', 'inspect']:
    if os.getenv('MOCK_IMAGE_INSPECT'):
        die()
    emit([{'Id': 'sha256:' + ident(args[2]), 'Architecture': os.getenv('MOCK_IMAGE_ARCH', 'amd64'), 'Os': 'linux', 'RepoDigests': [] if os.getenv('MOCK_IMAGE_DIGEST') else [args[2]]}])
elif args[:1] == ['pull']:
    if os.getenv('MOCK_PULL_FAIL'):
        die()
    print('pulled pinned synthetic fixture')
elif args[:2] in (['container', 'ls'], ['network', 'ls']):
    if os.getenv('MOCK_LIST_FAIL') or (root / 'list-fail').exists():
        die()
    kind = 'containers' if args[0] == 'container' else 'networks'
    for key, val in s[kind].items():
        emit({'ID': key, 'Names': val.get('Name', '').lstrip('/'), 'Name': val.get('Name', '')})
    if kind == 'containers' and os.getenv('MOCK_NAME'):
        emit({'ID': 'f' * 64, 'Names': os.environ['MOCK_NAME']})
elif args[:2] == ['network', 'create']:
    if os.getenv('MOCK_NETWORK_FAIL'):
        die()
    name = args[-1]
    labels = dict(x.split('=', 1) for i, x in enumerate(args) if i and args[i - 1] == '--label')
    nid = ident(name)
    s['networks'][nid] = {'Id': nid, 'Name': name, 'Driver': 'bridge', 'Scope': 'local', 'Internal': False, 'Attachable': False, 'Ingress': False, 'Options': {}, 'Labels': labels, 'Containers': {}}
    save()
    print(nid)
    if os.getenv('MOCK_REPLACE_LOCK'):
        lock = pathlib.Path(os.environ['HOME']) / '.local/share/terry-toolbox/webssh-containers/personal/lock'
        old = lock.stat()
        data = lock.read_bytes()
        lock.rename(lock.with_name('lock-old'))
        lock.write_bytes(data)
        lock.chmod(0o600)
        # Simulate a competing controller that has resealed the new inode. A
        # mere pathname/ledger check passes; the original held fd must reject.
        import hmac
        ledger = lock.with_name('ledger.json')
        d = json.loads(ledger.read_text())
        now = lock.stat()
        d['files'][str(lock)]['stat'] = [now.st_dev, now.st_ino, 0o600, now.st_uid]
        b = json.dumps(d, sort_keys=True, separators=(',', ':')).encode()
        ledger.write_bytes(b)
        lock.with_name('ledger.mac').write_text(hmac.digest(lock.with_name('seal.key').read_bytes(), b, 'sha256').hex())
elif args[:2] == ['network', 'inspect']:
    nid = args[2]
    if nid not in s['networks'] or os.getenv('MOCK_NETWORK_READ_FAIL'):
        die()
    obj = s['networks'][nid]
    if os.getenv('MOCK_PEER'):
        obj['Containers']['f' * 64] = {'Name': 'foreign'}
    emit([obj])
elif args[:1] == ['create']:
    if os.getenv('MOCK_CREATE_FAIL') == 'before':
        die()
    def option(flag, default=''):
        return args[args.index(flag) + 1] if flag in args else default
    name = option('--name')
    if any(v['Name'] == '/' + name for v in s['containers'].values()):
        die()
    nid = option('--network')
    ref = next(x for x in args if '@sha256:' in x)
    labels = dict(x.split('=', 1) for i, x in enumerate(args) if i and args[i - 1] == '--label')
    mounts = []
    ports = {}
    for i, x in enumerate(args):
        if i and args[i-1] == '--mount':
            bits = dict(p.split('=', 1) for p in x.split(',') if '=' in p)
            mounts.append({'Type': bits['type'], 'Source': bits['src'], 'Destination': bits['dst'], 'RW': 'readonly' not in x.split(',')})
        if i and args[i-1] == '--publish':
            ip, hp, cp = x.split(':')
            ports[cp + '/tcp'] = [{'HostIp': ip, 'HostPort': hp}]
    cid = ident(name + nid)
    obj = {'Id': cid, 'Name': '/' + name, 'Image': 'sha256:' + ident(ref), 'Config': {'Image': ref, 'Labels': labels, 'User': option('--user'), 'Entrypoint': [option('--entrypoint')] if '--entrypoint' in args else None, 'Cmd': args[args.index(ref) + 1:], 'WorkingDir': option('--workdir')}, 'HostConfig': {'NetworkMode': nid, 'PortBindings': ports, 'Privileged': False, 'CapAdd': None, 'CapDrop': ['ALL'], 'SecurityOpt': ['no-new-privileges'], 'ReadonlyRootfs': '--read-only' in args, 'RestartPolicy': {'Name': 'unless-stopped', 'MaximumRetryCount': 0}, 'Binds': None}, 'Mounts': mounts, 'NetworkSettings': {'Networks': {}}, 'State': {'Running': False, 'Restarting': False, 'Paused': False, 'Dead': False, 'Pid': 0, 'Status': 'created'}}
    s['containers'][cid] = obj
    save()
    pathlib.Path(option('--cidfile')).write_text(cid)
    print(cid)
    if os.getenv('MOCK_CREATE_FAIL') == 'after':
        die()
elif args[:2] == ['container', 'inspect']:
    cid = args[2]
    if cid not in s['containers'] or os.getenv('MOCK_READ_FAIL'):
        die()
    obj = s['containers'][cid]
    if os.getenv('MOCK_TAMPER'):
        mode = os.environ['MOCK_TAMPER']
        if mode == 'mount':
            obj['Mounts'][0]['Source'] = '/foreign/data'
        elif mode == 'image':
            obj['Image'] = 'sha256:' + 'f' * 64
        elif mode == 'network':
            obj['HostConfig']['NetworkMode'] = 'host'
        elif mode == 'port':
            for p in obj['HostConfig']['PortBindings'].values():
                p[0]['HostIp'] = '0.0.0.0'
        else:
            obj['Config']['Labels']['org.terry.toolbox.wsc.token'] = 'foreign'
    if os.getenv('MOCK_RUNNING_READBACK') and obj['State']['Status'] == 'exited':
        obj['State']['Running'] = True
    emit([obj])
elif args[:1] == ['start']:
    cid = args[1]
    obj = s['containers'][cid]
    obj['State'].update(Running=True, Pid=999999, Status='running')
    s['networks'][obj['HostConfig']['NetworkMode']]['Containers'][cid] = {'Name': obj['Name'].lstrip('/')}
    save()
    if os.getenv('MOCK_SIGNAL'):
        os.kill(os.getppid(), signal.SIGTERM)
        die()
    if os.getenv('MOCK_START_FAIL') and '/terry-webssh-' + os.environ['MOCK_START_FAIL'] == obj['Name']:
        die()
    print(cid)
elif args[:1] == ['stop']:
    if os.getenv('MOCK_STOP_FAIL') or (os.getenv('MOCK_STOP_ROLE') and os.environ['MOCK_STOP_ROLE'] in s['containers'][args[-1]]['Name']):
        die()
    cid = args[-1]
    s['containers'][cid]['State'].update(Running=False, Pid=0, Status='exited')
    save()
    print(cid)
elif args[:1] == ['rm']:
    if os.getenv('MOCK_RM_FAIL'):
        die()
    cid = args[1]
    obj = s['containers'].pop(cid)
    s['networks'][obj['HostConfig']['NetworkMode']]['Containers'].pop(cid, None)
    save()
    print(cid)
    if os.getenv('MOCK_POST_RM_LIST_FAIL'):
        (root / 'list-fail').touch()
elif args[:2] == ['network', 'rm']:
    if os.getenv('MOCK_NETWORK_RM_FAIL'):
        die()
    nid = args[2]
    if s['networks'][nid]['Containers']:
        die()
    s['networks'].pop(nid)
    save()
    print(nid)
elif args[:1] == ['logs']:
    if os.getenv('MOCK_LOG_DELAY') and not (root / 'logs-once').exists():
        (root / 'logs-once').touch()
        print('native key DB initialization pending')
        sys.exit(0)
    print('EasyNode 默认登录凭据 (请及时更改):\n用户名: private-fixture-user\n密码: private-fixture-password')
else:
    print('unsupported Docker fixture call: ' + repr(args), file=sys.stderr)
    die()
