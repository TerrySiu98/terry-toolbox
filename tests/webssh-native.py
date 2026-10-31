#!/usr/bin/env python3
"""Native PyPI WebSSH 1.6.3 acceptance in a marked disposable Debian VM.

Prerequisites: root, native systemd with cgroup v2, Python >=3.11 with venv/ensurepip, nginx,
www-data, openssh-server/client, curl, OpenSSL, flock and iproute2. Prepare the
fixed sdist outside the repository. This helper does not install prerequisites.

Create root-owned 0600 /run/terry-toolbox-webssh-native-acceptance containing
exactly ``webssh-native\n``. Run with --evidence /root/webssh-native-NAME and
--sdist /root/.../webssh-1.6.3.tar.gz. All evidence, fixture keys and test
credentials stay in that new private directory. Failed product resources are
retained. Only the exact temporary loopback sshd is stopped in finally.

API verified against the pinned sdist: Basic GET / issues Tornado's _xsrf cookie;
urlencoded POST / accepts hostname/port/username/privatekey/_xsrf and returns
id/status/encoding. Basic + same-origin /ws?id=ID consumes that worker once;
JSON {"data": command} sends terminal input and binary frames carry output.
No browser UI, MFA, SFTP, public TLS or whole-VM reboot claim is made here.
"""
import argparse
import base64
import ctypes
import hashlib
import http.client
import http.cookies
import inspect
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import signal
import shutil
import socket
import stat
import struct
import subprocess
import sys
import time
import urllib.parse


ROOT = Path(__file__).resolve().parents[1]
SDIST_SHA = '2bce5bbaf206ad345910c7e4dc8024b3c418e681c9f5ff098f1802beff76e100'
BACK = 'terry-toolbox-webssh.service'
FRONT = 'terry-toolbox-webssh-nginx.service'
SSH_UNIT = 'toolbox-native-webssh-sshd.service'
OWNED = [Path(p) for p in ('/etc/terry-toolbox-webssh', '/opt/terry-toolbox-webssh',
    '/var/lib/terry-toolbox-webssh', '/var/log/terry-toolbox-webssh', '/run/terry-toolbox-webssh',
    '/etc/systemd/system/' + BACK, '/etc/systemd/system/' + FRONT)]


def need(ok, reason):
    if not ok:
        raise RuntimeError(reason)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def run(args, *, timeout=30, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, **kwargs).stdout


def private_parent(path):
    for p in reversed((path, *path.parents)):
        s = p.lstat()
        need(stat.S_ISDIR(s.st_mode) and s.st_uid == 0 and not s.st_mode & 0o022,
             'unsafe parent: ' + str(p))


def file_record(path):
    s = path.lstat()
    need(stat.S_ISREG(s.st_mode) and s.st_uid == 0 and s.st_nlink == 1,
         'not an exclusive root-owned file: ' + str(path))
    return {'id': f'{s.st_dev}:{s.st_ino}', 'mode': stat.S_IMODE(s.st_mode),
            'sha256': digest(path.read_bytes())}


def write_json(path, value):
    with path.open('x') as f:
        json.dump(value, f, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())


def unit_props(unit):
    names = ('LoadState', 'ActiveState', 'SubState', 'MainPID', 'FragmentPath',
             'DropInPaths', 'InvocationID', 'Job')
    args = ['systemctl', 'show', '--all', unit]
    for name in names:
        args.extend(('-p', name))
    raw = run(args).decode()
    rows = [line.split('=', 1) for line in raw.splitlines()]
    need(len(rows) == len({k for k, _ in rows}) and {k for k, _ in rows} <= set(names),
         'duplicate/unknown systemd property')
    value = dict(rows)
    if value.get('LoadState') == 'not-found':
        value.setdefault('MainPID', '0')
        value.setdefault('InvocationID', '')
    need(set(value) == set(names), 'incomplete systemd snapshot')
    return value


def fixture_cgroup_props():
    raw = run(['systemctl', 'show', '--all', SSH_UNIT, '-p', 'ControlGroup', '-p', 'KillMode']).decode()
    rows = [line.split('=', 1) for line in raw.splitlines()]
    need(len(rows) == 2 and {key for key, _ in rows} == {'ControlGroup', 'KillMode'},
         'incomplete/duplicate fixture cgroup properties')
    return dict(rows)


def cgroup_identity(path):
    private_parent(path.parent)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
         'untrusted fixture cgroup directory')
    return f'{info.st_dev}:{info.st_ino}'


def bind_fixture_cgroup(unit):
    props = fixture_cgroup_props()
    expected = '/system.slice/' + SSH_UNIT
    need(Path('/sys/fs/cgroup/cgroup.controllers').is_file(), 'unified cgroup v2 required')
    need(props == {'ControlGroup': expected, 'KillMode': 'control-group'}, 'unexpected fixture cgroup')
    path = Path('/sys/fs/cgroup' + expected)
    identity = cgroup_identity(path)
    need(identity is not None and int(unit['MainPID']) > 0, 'fixture cgroup/leader missing')
    need((Path('/proc') / unit['MainPID'] / 'cgroup').read_text().splitlines() == ['0::' + expected],
         'fixture leader is outside its cgroup')
    return {'path': str(path), 'id': identity, **props}


def fixture_cgroup_empty(binding):
    path = Path(binding['path'])
    current = cgroup_identity(path)
    if current is None:
        return {'path': str(path), 'exists': False, 'pids': []}
    need(current == binding['id'], 'fixture cgroup identity changed; preserved')
    pids = set()

    def inspect_group(fd):
        with os.fdopen(os.open('cgroup.procs', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)) as stream:
            for line in stream:
                need(re.fullmatch(r'[1-9][0-9]*\n?', line), 'invalid cgroup process record')
                pids.add(int(line))
        for name in os.listdir(fd):
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            need(not stat.S_ISLNK(info.st_mode), 'unexpected cgroup symlink')
            if stat.S_ISDIR(info.st_mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    inspect_group(child)
                finally:
                    os.close(child)

    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            need(f'{info.st_dev}:{info.st_ino}' == binding['id'], 'fixture cgroup raced')
            inspect_group(fd)
        finally:
            os.close(fd)
    except FileNotFoundError:
        need(cgroup_identity(path) is None, 'fixture cgroup evidence disappeared while group remains')
        return {'path': str(path), 'exists': False, 'pids': []}
    current = cgroup_identity(path)
    need(current is None or current == binding['id'], 'fixture cgroup replaced during readback')
    need(not pids, 'fixture cgroup still contains processes: ' + repr(sorted(pids)))
    return {'path': str(path), 'exists': current is not None, 'id': current, 'pids': []}


def stop_fixture(unit, unit_record, binding):
    need(unit is not None and binding is not None, 'fixture identity was not established; preserved')
    value = unit_props(SSH_UNIT)
    path = Path(binding['path'])
    current = cgroup_identity(path)
    need(current is None or current == binding['id'], 'fixture cgroup identity changed; preserved')
    quiet = value['ActiveState'] in ('inactive', 'failed') and value['MainPID'] == '0' and not value['Job']
    if value['LoadState'] == 'not-found':
        need(quiet and current is None and not Path(unit['FragmentPath']).exists(),
             'unloaded fixture still has unit/cgroup resources')
    else:
        need(value['LoadState'] == 'loaded' and value['FragmentPath'] == unit['FragmentPath']
             and not value['DropInPaths'] and not value['Job']
             and file_record(Path(unit['FragmentPath'])) == unit_record,
             'fixture unit identity changed; preserved')
        need(value['InvocationID'] == unit['InvocationID'] or (quiet and not value['InvocationID']),
             'fixture invocation changed; preserved')
        props = fixture_cgroup_props()
        need(props['KillMode'] == binding['KillMode'] and
             (props['ControlGroup'] == binding['ControlGroup'] or (quiet and not props['ControlGroup'])),
             'fixture cgroup properties changed; preserved')
        if value['MainPID'] != '0':
            proc = Path('/proc') / value['MainPID']
            need(value['MainPID'] == unit['MainPID'] and current == binding['id']
                 and (proc / 'exe').resolve() == Path('/usr/sbin/sshd').resolve()
                 and (proc / 'cgroup').read_text().splitlines() == ['0::' + binding['ControlGroup']],
                 'fixture leader identity changed; preserved')
        # MainPID=0 does not prove that sshd session children have exited.
        run(['systemctl', 'stop', SSH_UNIT], timeout=30)
    value = unit_props(SSH_UNIT)
    need(value['ActiveState'] in ('inactive', 'failed') and value['MainPID'] == '0' and not value['Job'],
         'fixture sshd did not stop')
    return {'unit': value, 'cgroup': fixture_cgroup_empty(binding)}


def config_snapshot(root):
    result = {}
    for p in sorted(root.rglob('*')):
        s = p.lstat()
        value = {'mode': stat.S_IMODE(s.st_mode), 'id': f'{s.st_dev}:{s.st_ino}'}
        if p.is_symlink():
            value['symlink'] = os.readlink(p)
        elif p.is_file():
            value['sha256'] = digest(p.read_bytes())
        elif not p.is_dir():
            raise RuntimeError('unexpected system config resource')
        result[str(p)] = value
    return result


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class HTTP:
    def __init__(self, port, credential):
        self.port = port
        self.origin = 'http://127.0.0.1:' + str(port)
        self.auth = 'Basic ' + base64.b64encode(credential.encode()).decode()
        self.cookies = http.cookies.SimpleCookie()

    def request(self, method, path, data=None, auth=True):
        headers = {'Origin': self.origin}
        if auth:
            headers['Authorization'] = self.auth if auth is True else auth
        if self.cookies:
            headers['Cookie'] = '; '.join(k + '=' + v.value for k, v in self.cookies.items())
        if data is not None:
            data = urllib.parse.urlencode(data).encode()
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=20)
        try:
            connection.request(method, path, data, headers)
            response = connection.getresponse()
            for key, value in response.getheaders():
                if key.lower() == 'set-cookie':
                    self.cookies.load(value)
            return response.status, response.read()
        finally:
            connection.close()

    def connect(self, ssh_port, key):
        status, body = self.request('GET', '/')
        need(status == 200 and b'WebSSH' in body and '_xsrf' in self.cookies,
             'authenticated WebSSH form/XSRF missing')
        status, body = self.request('POST', '/', {'hostname': '127.0.0.1', 'port': str(ssh_port),
            'username': 'root', 'password': '', 'privatekey': key, 'passphrase': '',
            '_xsrf': self.cookies['_xsrf'].value, 'term': 'xterm'})
        need(status == 200, 'SSH connect HTTP failure')
        result = json.loads(body)
        need(isinstance(result.get('id'), str) and result['id'] and not result.get('status'),
             'WebSSH did not authenticate to fixture SSH server')
        return result['id']


class WebSocket:
    """Small RFC6455 client, adapted from the existing B10 native harness."""
    def __init__(self, client, worker, *, auth=True, origin=None):
        self.sock = socket.create_connection(('127.0.0.1', client.port), timeout=15)
        try:
            key = base64.b64encode(secrets.token_bytes(16)).decode()
            headers = {'Host': '127.0.0.1:' + str(client.port), 'Upgrade': 'websocket',
                'Connection': 'Upgrade', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': key,
                'Origin': client.origin if origin is None else origin}
            if auth:
                headers['Authorization'] = client.auth if auth is True else auth
            if client.cookies:
                headers['Cookie'] = '; '.join(k + '=' + v.value for k, v in client.cookies.items())
            request = 'GET /ws?' + urllib.parse.urlencode({'id': worker}) + ' HTTP/1.1\r\n'
            request += ''.join(k + ': ' + v + '\r\n' for k, v in headers.items()) + '\r\n'
            self.sock.sendall(request.encode())
            data = b''
            while b'\r\n\r\n' not in data:
                chunk = self.sock.recv(1)
                need(chunk, 'WebSocket upgrade closed')
                data += chunk
                need(len(data) < 32768, 'WebSocket headers too large')
            self.status = int(data.split(b' ', 2)[1])
            if self.status == 101:
                fields = dict(line.split(b':', 1) for line in data.split(b'\r\n')[1:] if b':' in line)
                fields = {k.lower(): v.strip() for k, v in fields.items()}
                expected = base64.b64encode(hashlib.sha1((key +
                    '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
                need(fields.get(b'sec-websocket-accept') == expected, 'WebSocket accept mismatch')
        except BaseException:
            self.sock.close()
            raise

    def exact(self, size):
        value = b''
        while len(value) < size:
            chunk = self.sock.recv(size - len(value))
            need(chunk, 'WebSocket closed')
            value += chunk
        return value

    def send(self, data, opcode=1):
        data = data.encode() if isinstance(data, str) else data
        mask = secrets.token_bytes(4)
        size = len(data)
        head = bytes([0x80 | opcode, 0x80 | (size if size < 126 else 126 if size < 65536 else 127)])
        if size >= 126:
            head += struct.pack('!H' if size < 65536 else '!Q', size)
        self.sock.sendall(head + mask + bytes(x ^ mask[i % 4] for i, x in enumerate(data)))

    def receive(self):
        while True:
            first, second = self.exact(2)
            need(first & 0x80 and not second & 0x80, 'unexpected fragmented/masked server frame')
            size = second & 127
            if size in (126, 127):
                size = struct.unpack('!H' if size == 126 else '!Q', self.exact(2 if size == 126 else 8))[0]
            need(size < 1024 * 1024, 'oversize WebSocket frame')
            data = self.exact(size)
            opcode = first & 15
            if opcode == 9:
                self.send(data, 10)
            else:
                return opcode, data

    def close(self):
        self.sock.close()


def product(work, action, env, data='', port=None):
    args = ['bash', '-c', 'source "$1"; shift; toolbox_webssh "$@"', 'webssh-native',
            str(ROOT / 'modules/webssh.sh'), action]
    if port is not None:
        args.append(str(port))
    with (work / (action + '.log')).open('xb') as log:
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=log, stderr=log,
                                   env=env, start_new_session=True)
        # The product owns its rollback. Do not kill unrelated services on failure.
        try:
            process.communicate(data.encode(), timeout=900)
        except BaseException:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
            raise
    need(process.returncode == 0, 'product ' + action + ' failed; inspect private log')


def listener_check(ports):
    raw = run(['ss', '-ltnpH']).decode()
    found = {}
    for line in raw.splitlines():
        fields = line.split()
        need(len(fields) >= 5, 'unrecognized ss output')
        local = fields[3]
        for port in ports:
            if local.rsplit(':', 1)[-1] == str(port):
                need(local == '127.0.0.1:' + str(port), 'non-loopback listener')
                found[port] = line
    need(set(found) == set(ports), 'expected listeners missing')
    return found


def probe(work, stage, port, ssh_port, credential, key):
    client = HTTP(port, credential)
    deadline = time.monotonic() + 25
    while True:
        try:
            status, body = client.request('GET', '/')
            if status == 200 and b'WebSSH' in body:
                break
        except OSError:
            pass
        need(time.monotonic() < deadline, 'frontend did not become ready')
        time.sleep(.2)
    wrong = 'Basic ' + base64.b64encode(b'native:incorrect').decode()
    result = {'stage': stage, 'checks': []}
    for name, auth in [('anonymous', False), ('wrong-basic', wrong)]:
        for path in ('/', '/static/js/main.js'):
            status, _ = client.request('GET', path, auth=auth)
            need(status == 401, name + ' HTTP was not rejected')
        ws = WebSocket(client, 'invalid', auth=auth)
        try:
            need(ws.status == 401, name + ' WebSocket was not rejected')
        finally:
            ws.close()
        result['checks'].append(name + '-http-and-websocket-401')
    worker = client.connect(ssh_port, key)
    ws = WebSocket(client, worker, origin='http://foreign.example.test')
    try:
        need(ws.status == 403, 'foreign-origin WebSocket accepted')
    finally:
        ws.close()
    result['checks'].append('foreign-origin-403')
    nonce = secrets.token_hex(32)
    nonce_file = work / ('nonce-' + stage + '.txt')
    nonce_file.write_text(nonce + '\n')
    ws = WebSocket(client, worker)
    try:
        need(ws.status == 101, 'authenticated WebSocket upgrade failed')
        # Only the filename is sent, so terminal command echo cannot forge proof.
        ws.send(json.dumps({'data': 'stty -echo; cat ' + str(nonce_file) + '; printf "\\n"\r'}))
        output = b''
        deadline = time.monotonic() + 25
        while nonce.encode() not in output and time.monotonic() < deadline:
            ws.sock.settimeout(max(.1, deadline - time.monotonic()))
            opcode, data = ws.receive()
            need(opcode in (1, 2), 'terminal closed before nonce readback')
            output += data
        need(nonce.encode() in output, 'actual SSH nonce missing')
        (work / ('terminal-' + stage + '.bin')).write_bytes(output)
        result.update(nonce_sha256=digest(nonce.encode()), terminal_sha256=digest(output))
    finally:
        ws.close()
    result['checks'].append('authenticated-real-ssh-nonce')
    # A worker is a single-use handle: replay must close after the HTTP upgrade.
    ws = WebSocket(client, worker)
    try:
        need(ws.status == 101, 'worker replay failed before application check')
        opcode, data = ws.receive()
        need(opcode == 8 and b'authentication failed' in data, 'worker reuse was not rejected')
    finally:
        ws.close()
    result['checks'].append('worker-replay-closed')
    write_json(work / ('probe-' + stage + '.json'), result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--sdist', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    need(os.geteuid() == 0 and sys.platform == 'linux', 'disposable Linux root required')
    need(sys.version_info >= (3, 11) and 'dir_fd' in inspect.signature(shutil.rmtree).parameters
         and shutil.rmtree.avoids_symlink_attacks and hasattr(ctypes.CDLL(None), 'renameat2'),
         'Python 3.11+ with safe dir_fd/renameat2 required')
    marker = Path('/run/terry-toolbox-webssh-native-acceptance')
    need(file_record(marker)['mode'] == 0o600 and marker.read_bytes() == b'webssh-native\n',
         'disposable acceptance marker missing')
    need(Path('/proc/1/comm').read_text().strip() == 'systemd', 'native systemd required')
    need(Path('/sys/fs/cgroup/cgroup.controllers').is_file(), 'unified cgroup v2 required')
    need(re.search(r'^ID=["\']?debian["\']?$', Path('/etc/os-release').read_text(), re.M), 'Debian required')
    need(re.fullmatch(r'/root/webssh-native-[A-Za-z0-9_-]+', str(args.evidence)), 'unsafe evidence path')
    private_parent(args.evidence.parent)
    for name in ('nginx', 'sshd', 'ssh-keygen', 'ssh', 'curl', 'openssl', 'flock', 'ss', 'systemd-run'):
        need(shutil.which(name), 'prepare dependency first: ' + name)
    run(['python3', '-c', 'import venv,ensurepip'])
    pwd.getpwnam('www-data')
    need(Path('/etc/nginx/mime.types').is_file() and Path('/run/sshd').is_dir(), 'prepare nginx/sshd first')
    need(args.sdist.is_absolute(), 'sdist requires an absolute path')
    private_parent(args.sdist.parent)
    need(file_record(args.sdist)['sha256'] == SDIST_SHA, 'fixed PyPI sdist hash mismatch')
    for path in OWNED:
        need(not path.exists() and not path.is_symlink(), 'existing product resource: ' + str(path))
    for unit in (BACK, FRONT, SSH_UNIT):
        need(unit_props(unit)['LoadState'] == 'not-found', 'existing unit: ' + unit)
    work = args.evidence
    work.mkdir(mode=0o700)
    source = {name: digest((ROOT / name).read_bytes()) for name in ('modules/webssh.sh', 'tests/webssh-native.py')}
    original_configs = {str(p): config_snapshot(p) for p in (Path('/etc/nginx'), Path('/etc/ssh'))}
    system_units = {name: unit_props(name) for name in ('nginx.service', 'ssh.service')}
    baseline = {'source_sha256': source, 'sdist_sha256': SDIST_SHA, 'python': sys.version,
        'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
        'os_release': Path('/etc/os-release').read_text(), 'system_units': system_units,
        'system_configs': original_configs}
    write_json(work / 'baseline.json', baseline)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('TOOLBOX_', 'PIP_', 'BASH_FUNC_'))
           and k not in ('BASH_ENV', 'ENV', 'PYTHONHOME', 'PYTHONPATH')}
    env.update(TOOLBOX_WEBSSH_SDIST_SRC=str(args.sdist), PIP_INDEX_URL='https://pypi.org/simple',
               PIP_CONFIG_FILE='/dev/null', PYTHONNOUSERSITE='1')
    user, password = 'native', secrets.token_hex(18)
    write_json(work / 'credentials.json', {'username': user, 'password': password})
    front_port, ssh_port = free_port(), free_port()
    need(front_port != ssh_port, 'retry: ephemeral port collision')
    ssh_started = False
    ssh_identity = None
    ssh_cgroup = None
    ssh_unit_record = None
    success_result = None
    def cancel(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, cancel)
    try:
        for name in ('client-key', 'host-key'):
            run(['ssh-keygen', '-q', '-t', 'rsa', '-b', '2048', '-m', 'PEM', '-N', '', '-f', str(work / name)])
        config = work / 'sshd.conf'
        config.write_text('Port ' + str(ssh_port) + '\nListenAddress 127.0.0.1\nHostKey ' + str(work / 'host-key') +
            '\nPidFile ' + str(work / 'sshd.pid') + '\nAuthorizedKeysFile ' + str(work / 'client-key.pub') +
            '\nPermitRootLogin prohibit-password\nPasswordAuthentication no\nKbdInteractiveAuthentication no'
            '\nUsePAM yes\nStrictModes yes\nAllowUsers root\nAllowTcpForwarding no\nX11Forwarding no\n')
        run(['/usr/sbin/sshd', '-t', '-f', str(config)])
        run(['systemd-run', '--unit=' + SSH_UNIT, '--property=Type=exec', '--property=UMask=0077',
             '--property=KillMode=control-group', '/usr/sbin/sshd', '-D', '-e', '-f', str(config)])
        ssh_started = True
        ssh_identity = unit_props(SSH_UNIT)
        ssh_unit_path = Path(ssh_identity['FragmentPath'])
        need(ssh_identity['InvocationID'] and ssh_identity['ActiveState'] == 'active'
             and not ssh_identity['DropInPaths']
             and ssh_unit_path == Path('/run/systemd/transient') / SSH_UNIT, 'unexpected fixture unit')
        ssh_unit_record = file_record(ssh_unit_path)
        ssh_cgroup = bind_fixture_cgroup(ssh_identity)
        write_json(work / 'fixture-started.json', {'unit': ssh_identity, 'file': ssh_unit_record,
                                                'cgroup': ssh_cgroup})
        deadline = time.monotonic() + 15
        while True:
            try:
                with socket.create_connection(('127.0.0.1', ssh_port), timeout=.2):
                    break
            except OSError:
                need(time.monotonic() < deadline, 'fixture sshd did not listen')
                time.sleep(.1)
        product(work, 'install', env, user + '\n' + password + '\n' + password + '\nYES\n', front_port)
        product(work, 'status', env)
        etc = Path('/etc/terry-toolbox-webssh')
        meta = (etc / 'meta').read_text().strip().split('|')
        need(len(meta) == 6 and meta[:3] == [user, password, str(front_port)] and meta[4] == '1.6.3',
             'installed metadata mismatch')
        internal = int(meta[3])
        write_json(work / 'listeners.json', listener_check((front_port, internal, ssh_port)))
        unit_files = {str(p): file_record(p) for p in OWNED[-2:]}
        installed_units = {name: unit_props(name) for name in (BACK, FRONT)}
        for name, value in installed_units.items():
            need(value['ActiveState'] == 'active' and value['SubState'] == 'running'
                 and int(value['MainPID']) > 0 and not value['DropInPaths']
                 and value['FragmentPath'] == '/etc/systemd/system/' + name, 'unexpected product unit')
        write_json(work / 'installed-units.json', installed_units)
        (work / 'pip-freeze.txt').write_bytes(run(['/opt/terry-toolbox-webssh/venv/bin/pip', 'freeze']))
        key = (work / 'client-key').read_text()
        results = [probe(work, 'initial', front_port, ssh_port, user + ':' + password, key)]
        for name, record in unit_files.items():
            need(file_record(Path(name)) == record, 'unit changed before restart')
        run(['systemctl', 'restart', BACK, FRONT], timeout=60)
        deadline = time.monotonic() + 30
        while True:
            restarted = {name: unit_props(name) for name in (BACK, FRONT)}
            if all(v['ActiveState'] == 'active' and v['SubState'] == 'running' for v in restarted.values()):
                break
            need(time.monotonic() < deadline, 'product did not restart')
            time.sleep(.2)
        for name, value in restarted.items():
            need(value['InvocationID'] and value['InvocationID'] != installed_units[name]['InvocationID'],
                 'service invocation did not change after restart')
        write_json(work / 'restarted-units.json', restarted)
        results.append(probe(work, 'after-restart', front_port, ssh_port, user + ':' + password, key))
        need({name: config_snapshot(Path(name)) for name in original_configs} == original_configs,
             'system nginx/SSH config changed')
        product(work, 'uninstall', env, 'YES\n')
        for path in OWNED:
            need(not path.exists() and not path.is_symlink(), 'owned uninstall target remains')
        for port in (front_port, internal):
            with socket.socket() as s:
                need(s.connect_ex(('127.0.0.1', port)) != 0, 'product listener remains after uninstall')
        for name in (BACK, FRONT):
            value = unit_props(name)
            need(value['LoadState'] == 'not-found' and value['MainPID'] == '0', 'product unit remains')
            link = Path('/etc/systemd/system/multi-user.target.wants', name)
            need(not link.exists() and not link.is_symlink(), 'boot link remains')
        need({name: config_snapshot(Path(name)) for name in original_configs} == original_configs,
             'system nginx/SSH config changed during uninstall')
        need({name: unit_props(name) for name in system_units} == system_units, 'system nginx/SSH unit changed')
        need(all(digest((ROOT / name).read_bytes()) == value for name, value in source.items()), 'source changed')
        success_result = {'passed': True, 'source_sha256': source, 'probes': results,
            'system_configs_preserved': True, 'uninstalled': True,
            'evidence_contains_private_test_credentials': True}
    except BaseException as error:
        write_json(work / 'failed.json', {'type': type(error).__name__, 'message': str(error),
                                        'product_resources_retained': True})
        raise
    finally:
        primary_failed = sys.exc_info()[0] is not None
        cleanup_errors = []
        stopped = None
        if ssh_started:
            try:
                stopped = stop_fixture(ssh_identity, ssh_unit_record, ssh_cgroup)
            except Exception as error:
                cleanup_errors.append(str(error))
        # Actual cleanup precedes every evidence write and journal collection.
        if stopped is not None:
            try:
                write_json(work / 'fixture-stopped.json', stopped)
            except Exception as error:
                cleanup_errors.append('fixture cleanup evidence: ' + str(error))
        for name in (BACK, FRONT, SSH_UNIT):
            try:
                (work / ('journal-' + name + '.log')).write_bytes(run(['journalctl', '-b', '-u', name, '--no-pager']))
            except Exception:
                pass
        if cleanup_errors:
            write_json(work / 'cleanup-failed.json', {'errors': cleanup_errors})
            if not primary_failed:
                raise RuntimeError('fixture cleanup failed; inspect private evidence')
    need(success_result is not None, 'acceptance did not finish')
    success_result['fixture_stopped'] = True
    write_json(work / 'result.json', success_result)
    print('PASS native WebSSH installation, Basic/WS rejection, SSH nonce, service restart and uninstall.')


if __name__ == '__main__':
    main()
