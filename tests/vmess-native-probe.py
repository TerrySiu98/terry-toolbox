#!/usr/bin/env python3
"""Probe the installed, unchanged Xray service through its generated client.

The separate protocol suite tests exact loopback nonces and all rejection cases.
This native check also exercises real public HTTPS egress with certificate
verification, leaving the server's private-destination restrictions intact.
"""
import copy
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

state, ca = map(Path, sys.argv[1:3])
name = sys.argv[3] if len(sys.argv) > 3 else 'initial'
work = state / ('probe-' + name)
work.mkdir(mode=0o700)
client = json.loads(Path('/etc/terry-toolbox-vmess/client.json').read_text())
binary = '/usr/local/bin/terry-toolbox-vmess'
results = []


def save_curl_result(case, stdout, stderr, returncode, timed_out=False):
    stdout, stderr = stdout or b'', stderr or b''
    (work / (case + '.curl.stdout')).write_bytes(stdout)
    (work / (case + '.curl.stderr')).write_bytes(stderr)
    (work / (case + '.curl.json')).write_text(json.dumps({
        'case': case, 'returncode': returncode, 'timed_out': timed_out,
        'stdout_bytes': len(stdout), 'stderr_bytes': len(stderr),
    }, indent=2) + '\n')


for case in ('correct', 'wrong-uuid', 'wrong-path', 'untrusted', 'correct-after-rejections'):
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    cfg = copy.deepcopy(client)
    cfg['inbounds'][0]['port'] = port
    out = cfg['outbounds'][0]
    out['settings']['vnext'][0]['address'] = '127.0.0.1'
    if case == 'wrong-uuid':
        out['settings']['vnext'][0]['users'][0]['id'] = str(uuid.uuid4())
    if case == 'wrong-path':
        out['streamSettings']['wsSettings']['path'] = '/not-toolbox'
    if case != 'untrusted':
        out['streamSettings']['tlsSettings'].update({
            'disableSystemRoot': True,
            'certificates': [{'certificateFile': str(ca), 'usage': 'verify'}]})
    path = work / (case + '.json')
    path.write_text(json.dumps(cfg)); path.chmod(0o600)
    with (work / (case + '.log')).open('wb') as log:
        proc = subprocess.Popen([binary, 'run', '-c', str(path)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while True:
                assert proc.poll() is None, 'client process exited'
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.2): pass
                    break
                except OSError:
                    assert time.monotonic() < deadline, 'client listen timed out'
                    time.sleep(.1)
            try:
                result = subprocess.run(['curl', '--noproxy', '', '--socks5-hostname', f'127.0.0.1:{port}',
                    '--silent', '--show-error', '--fail', '--connect-timeout', '8', '--max-time', '30',
                    'https://example.com/'], capture_output=True, timeout=40)
            except subprocess.TimeoutExpired as exc:
                save_curl_result(case, exc.stdout, exc.stderr, None, timed_out=True)
                raise
            save_curl_result(case, result.stdout, result.stderr, result.returncode)
            good = case.startswith('correct')
            assert (result.returncode == 0 and b'Example Domain' in result.stdout) if good else result.returncode != 0, case
            results.append({'case': case, 'exit_code': result.returncode,
                            'response_sha256': hashlib.sha256(result.stdout).hexdigest()})
            print('PASS native VMess: ' + case, flush=True)
        finally:
            proc.terminate()
            try: proc.wait(timeout=8)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()
(work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
