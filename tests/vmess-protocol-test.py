#!/usr/bin/env python3
"""Opt-in real pinned Xray protocol test, not a systemd/installer acceptance.

Usage: python3 tests/vmess-protocol-test.py /absolute/path/to/xray
Creates only private scratch files and temporary loopback processes. No package,
service, firewall or global trust changes. Requires openssl and curl.
"""
import copy
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def write_json(path, obj):
    path.write_text(json.dumps(obj), encoding='utf-8')
    path.chmod(0o600)


def wait_listening(proc, port):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise AssertionError(f'Xray exited unexpectedly: {proc.returncode}')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise AssertionError('loopback Xray listener timed out')


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


def run(binary):
    binary = Path(binary).resolve(strict=True)
    version = subprocess.run([str(binary), 'version'], capture_output=True, text=True, check=True, timeout=10)
    assert version.stdout.startswith('Xray 26.10.29 '), 'test requires the pinned 26.10.29 binary'
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    temp_root = Path(os.environ.get('TOOLBOX_TEST_TMPDIR', os.environ.get('TMPDIR', Path.home() / '.cache/terry-toolbox-tests')))
    temp_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='toolbox-vmess-protocol.', dir=temp_root) as work:
        work = Path(work)
        key, cert = work / 'server.key', work / 'server.crt'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=vmess.example.test', '-addext', 'subjectAltName=DNS:vmess.example.test',
                        '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True, timeout=20)
        key.chmod(0o600)
        nonce = secrets.token_hex(24).encode()
        seen = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append(self.path)
                self.send_response(200)
                self.send_header('Content-Length', str(len(nonce)))
                self.end_headers()
                self.wfile.write(nonce)

            def log_message(self, format, *args):
                pass

        target = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=target.serve_forever, daemon=True)
        thread.start()
        server_port = free_port()
        generated = work / 'generated'
        generated.mkdir(mode=0o700)
        module = Path(__file__).resolve().parents[1] / 'modules' / 'vmess.sh'
        env = dict(os.environ, TOOLBOX_VM_WS_ETC=str(generated), TOOLBOX_NET_CAFILE=str(cert), TOOLBOX_NET_CAPATH='')
        subprocess.run(['bash', '-c', 'source "$1"; vmess_write_configs "$2" "$3" "$4" vmess.example.test "$5" /toolbox-ws 127.0.0.1',
                        '_', str(module), str(generated), str(cert), str(key), str(server_port)],
                       env=env, check=True, capture_output=True, timeout=10)
        # Exercise the module's actual generated configs, not a parallel prototype.
        original_server = json.loads((generated / 'config.json').read_text())
        original_client = json.loads((generated / 'client.json').read_text())
        identifier = original_server['inbounds'][0]['settings']['clients'][0]['id']
        assert original_client['outbounds'][0]['settings']['vnext'][0]['users'][0]['id'] == identifier
        assert original_server['outbounds'] == [{'protocol': 'freedom', 'tag': 'direct'}]
        assert original_client['outbounds'][0]['streamSettings']['tlsSettings']['allowInsecure'] is False
        subprocess.run([str(binary), 'run', '-test', '-c', str(generated / 'config.json')],
                       check=True, capture_output=True, timeout=10)
        subprocess.run([str(binary), 'run', '-test', '-c', str(generated / 'client.json')],
                       check=True, capture_output=True, timeout=10)
        server_config = copy.deepcopy(original_server)
        # Test fixture only: permit our exact ephemeral nonce listener. Do not
        # rewrite the generated production config or allow other private IPs.
        server_config['outbounds'][0]['settings'] = {'finalRules': [
            {'action': 'allow', 'network': 'tcp', 'ip': ['127.0.0.1/32'], 'port': str(target.server_port)}
        ]}
        config = work / 'server.json'
        write_json(config, server_config)
        subprocess.run([str(binary), 'run', '-test', '-c', str(config)], check=True, capture_output=True, timeout=10)
        processes = []
        logfiles = []

        def launch(config_path, name, port):
            logfile = (work / (name + '.log')).open('wb')
            logfiles.append(logfile)
            proc = subprocess.Popen([str(binary), 'run', '-c', str(config_path)], stdout=logfile, stderr=subprocess.STDOUT)
            processes.append(proc)
            wait_listening(proc, port)
            return proc

        def probe(name, good=True, wrong_uuid=False, wrong_path=False, wrong_host=False, untrusted=False):
            socks_port = free_port()
            cfg = copy.deepcopy(original_client)
            cfg['inbounds'][0]['port'] = socks_port
            outbound = cfg['outbounds'][0]
            endpoint = outbound['settings']['vnext'][0]
            endpoint['address'] = '127.0.0.1'
            if wrong_uuid:
                endpoint['users'][0]['id'] = str(uuid.uuid4())
            stream = outbound['streamSettings']
            if wrong_path:
                stream['wsSettings']['path'] = '/wrong'
            if wrong_host:
                stream['wsSettings']['host'] = 'wrong.example.test'
            if not untrusted:
                stream['tlsSettings'].update({'disableSystemRoot': True, 'certificates': [{'certificateFile': str(cert), 'usage': 'verify'}]})
            path = work / (name + '.json')
            write_json(path, cfg)
            client = launch(path, name, socks_port)
            try:
                count_before = len(seen)
                result = subprocess.run(['curl', '--noproxy', '', '--socks5-hostname', f'127.0.0.1:{socks_port}',
                                         '--silent', '--show-error', '--fail', '--connect-timeout', '3', '--max-time', '6',
                                         f'http://127.0.0.1:{target.server_port}/{name}'], capture_output=True, timeout=9)
                if good:
                    if result.returncode != 0 or result.stdout != nonce:
                        diagnostic = f'target_requests={seen!r}\n' + result.stderr.decode(errors='replace')
                        for logpath in sorted(work.glob('*.log')):
                            diagnostic += '\n' + logpath.name + ':\n' + logpath.read_text(errors='replace')[-5000:]
                        raise AssertionError(f'{name}: positive transfer failed: rc={result.returncode}\n{diagnostic}')
                    assert len(seen) == count_before + 1 and seen[-1] == '/' + name, 'request bypassed intended data-plane check'
                else:
                    assert result.returncode != 0, f'{name}: invalid connection succeeded'
                    assert result.stdout != nonce and len(seen) == count_before, f'{name}: invalid connection reached the target'
                print(f'PASS {name}: ' + ('HTTP 200 and exact nonce via SOCKS/VMess/WS/TLS' if good else 'connection rejected; target received no request'), flush=True)
            finally:
                stop(client)

        try:
            server = launch(config, 'server', server_port)
            probe('correct-auth')
            probe('wrong-uuid', good=False, wrong_uuid=True)
            probe('wrong-ws-path', good=False, wrong_path=True)
            probe('wrong-ws-host', good=False, wrong_host=True)
            probe('untrusted-cert', good=False, untrusted=True)
            probe('positive-control-after-rejections')
            stop(server)
            server = launch(config, 'server-restarted', server_port)
            probe('positive-after-restart')
            # Prove the fixture exception is necessary: the default production
            # freedom behavior still blocks this private target.
            stop(server)
            server = launch(generated / 'config.json', 'server-default-private-block', server_port)
            probe('default-private-target-blocked', good=False)
            print(json.dumps({'protocol': 'VMess+WS+TLS', 'xray_version': version.stdout.splitlines()[0],
                              'binary_sha256': digest, 'cases': 8, 'generated_by_module': True, 'installer_or_systemd_tested': False,
                              'listeners': 'loopback only', 'private_ca_only': True}, ensure_ascii=False))
        finally:
            for proc in processes:
                stop(proc)
            for logfile in logfiles:
                logfile.close()
            target.shutdown()
            target.server_close()
            thread.join(timeout=3)
        assert all(proc.poll() is not None for proc in processes), 'task-owned process left running'
    print('PASS cleanup: all task-owned processes stopped and scratch directory removed')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: vmess-protocol-test.py /absolute/path/to/pinned/xray')
    run(sys.argv[1])
