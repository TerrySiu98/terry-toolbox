#!/usr/bin/env python3
"""Focused certificate/production-path regressions; no service or host mutation.

Uses the product's actual OpenSSL checks with locally signed certificates. The
TLS lineage reader and VMess ledger are explicit mocked boundaries here; their
real inode/hash and lifecycle coverage lives in the Linux shell suites.
"""
import ast
import datetime
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[1]


def python_body(module):
    return (ROOT / 'modules' / module).read_text().split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]


def boot_paths():
    parsed = ast.parse(python_body('vmess.sh'))
    names = {'BOOTDIR', 'BOOTLINK', 'SYSTEMD_ROOTS', 'DEPDIRS'}
    selected = [n for n in parsed.body if
                (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in names for t in n.targets)) or
                (isinstance(n, ast.FunctionDef) and n.name == 'depscan')]
    for unitdir in ('/etc/systemd/system', '/isolated-fixture/units'):
        unit = unitdir + '/terry-toolbox-vmess.service'
        env = {'os': os, 'unit': unit, 'NAME': 'terry-toolbox-vmess.service'}
        exec(compile(ast.Module(body=selected, type_ignores=[]), '<product depscan>', 'exec'), env)
        assert len(env['SYSTEMD_ROOTS']) == len(set(env['SYSTEMD_ROOTS']))
        link = env['BOOTLINK']
        foreign = unitdir + '/other.target.requires/foreign-name.service'
        links = [link]

        def entry(path, directory):
            return SimpleNamespace(name=os.path.basename(path), path=path,
                                   is_symlink=lambda: not directory,
                                   is_dir=lambda **kwargs: directory)

        def scandir(path):
            if path == unitdir:
                return [entry(p, True) for p in sorted({os.path.dirname(x) for x in links})]
            return [entry(p, False) for p in links if os.path.dirname(p) == path]

        env['os'] = SimpleNamespace(
            path=SimpleNamespace(isdir=lambda p: p == unitdir,
                                 realpath=lambda p: unit if p in links else p),
            scandir=scandir)
        assert env['depscan'](True) == [link], 'one native owned link must count once'
        assert env['depscan']() == [], 'owned boot link is exempt from foreign scan'
        links.append(foreign)
        assert env['depscan']() == [foreign], 'foreign named dependency must remain visible'
        assert len(env['depscan'](True)) == 2
    print('PASS: production and fixture systemd roots count one owned link once; foreign link retained')


def certificates(root):
    now = datetime.datetime.now(datetime.timezone.utc)
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Recovery fixture CA')])
    ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name)
          .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(now - datetime.timedelta(days=10)).not_valid_after(now + datetime.timedelta(days=90))
          .add_extension(x509.BasicConstraints(ca=True, path_length=0), True).sign(ca_key, hashes.SHA256()))
    (root / 'ca.pem').write_bytes(ca.public_bytes(serialization.Encoding.PEM))
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    (root / 'key.pem').write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    (root / 'wrong.key').write_bytes(ca_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    (root / 'encrypted.key').write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.BestAvailableEncryption(b'fixture')))
    for kind, host, before, after, signing in [
        ('valid', 'example.com', -86400, 86400, ca_key),
        ('expired', 'example.com', -86400, -3600, ca_key),
        ('near', 'example.com', -86400, 1800, ca_key),
        ('future', 'example.com', 3600, 86400, ca_key),
        ('wrong-host', 'other.example.com', -86400, 86400, ca_key),
        ('untrusted', 'example.com', -86400, 86400, key),
    ]:
        leaf = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, host)]))
                .issuer_name(ca_name).public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now + datetime.timedelta(seconds=before)).not_valid_after(now + datetime.timedelta(seconds=after))
                .add_extension(x509.SubjectAlternativeName([x509.DNSName(host)]), False)
                .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
                .add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]), False)
                .sign(signing, hashes.SHA256()))
        (root / (kind + '.pem')).write_bytes(leaf.public_bytes(serialization.Encoding.PEM))


def check_tls(root):
    parsed = ast.parse(python_body('tls-acme.sh'))
    selected = [n for n in parsed.body if isinstance(n, ast.FunctionDef) and n.name == 'certcheck']
    live = root / 'config/live/example.com'
    live.mkdir(parents=True)
    env = dict(os=os, subprocess=subprocess, ssl=ssl, time=time, re=re,
               root=str(root), F={'cert_ca': str(root / 'ca.pem')},
               renewal=lambda m: None,
               record=lambda p, **kw: ({}, Path(p).read_bytes()))
    exec(compile(ast.Module(body=selected, type_ignores=[]), '<product certcheck>', 'exec'), env)
    for kind in ('valid', 'expired', 'near', 'future', 'wrong-host', 'untrusted', 'mismatch', 'encrypted', 'fullchain'):
        leaf = root / ((kind if kind in ('expired', 'near', 'future', 'wrong-host', 'untrusted') else 'valid') + '.pem')
        (live / 'cert.pem').write_bytes(leaf.read_bytes())
        (live / 'chain.pem').write_bytes((root / 'ca.pem').read_bytes())
        (live / 'fullchain.pem').write_bytes(leaf.read_bytes() + (root / 'ca.pem').read_bytes() + (b'changed' if kind == 'fullchain' else b''))
        shutil.copyfile(root / {'mismatch': 'wrong.key', 'encrypted': 'encrypted.key'}.get(kind, 'key.pem'), live / 'privkey.pem')
        for existing in (False, True):
            expected = kind == 'valid' or (existing and kind in ('expired', 'near'))
            try:
                env['certcheck']({'host': 'example.com'}, existing=existing)
                passed = True
            except ValueError:
                passed = False
            assert passed == expected, (kind, existing, passed)
    print('PASS: TLS real chain/SAN/hostname/key/time checks: 20 strict/existing cases')


def check_vmess(root):
    # Supply only GNU date/stat spellings on macOS; cryptographic checks are real.
    env = dict(os.environ,
               TOOLBOX_VM_WS_ETC=str(root), TOOLBOX_NET_CAFILE=str(root / 'ca.pem'), TOOLBOX_NET_CAPATH='')
    if sys.platform == 'darwin':
        bindir = root / 'bin'
        bindir.mkdir()
        (bindir / 'date').write_text('#!' + sys.executable + '\nimport datetime,sys,time\n'
                                    'if sys.argv[1:]==["+%s"]: print(int(time.time()))\n'
                                    'elif sys.argv[1]=="-d": print(int(datetime.datetime.strptime(sys.argv[2],"%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc).timestamp()))\n'
                                    'else: sys.exit(2)\n')
        (bindir / 'stat').write_text('#!' + sys.executable + '\nimport os,sys\n'
                                    'assert sys.argv[1:4]==["-c","%s","--"]\nprint(os.stat(sys.argv[4]).st_size)\n')
        for file in bindir.iterdir(): file.chmod(0o700)
        env['PATH'] = str(bindir) + os.pathsep + os.environ['PATH']
    script = '''source "$1/modules/network.sh"
source "$1/modules/vmess.sh"
vmess_fs() { [[ $* == 'verify --complete' && ${LEDGER_FAIL:-0} == 0 ]] || return 1; printf 'example.com 443 /vmess 127.0.0.1 1\\n'; }
if [[ $2 == existing ]]; then vmess_existing_certificate
else vmess_certificate "$TOOLBOX_VM_WS_ETC/cert.pem" "$TOOLBOX_VM_WS_ETC/key.pem" example.com; fi
'''
    original_key = (root / 'key.pem').read_bytes()
    cases = 0
    for kind in ('valid', 'expired', 'near', 'future', 'wrong-host', 'untrusted', 'mismatch', 'encrypted', 'ledger'):
        leaf = root / ((kind if kind in ('expired', 'near', 'future', 'wrong-host', 'untrusted') else 'valid') + '.pem')
        (root / 'cert.pem').write_bytes(leaf.read_bytes())
        (root / 'key.pem').write_bytes((root / {'mismatch': 'wrong.key', 'encrypted': 'encrypted.key'}[kind]).read_bytes() if kind in ('mismatch', 'encrypted') else original_key)
        for mode in ('existing', 'new'):
            if kind == 'ledger' and mode == 'new': continue
            expected = kind in ('valid', 'near') or (kind == 'expired' and mode == 'existing')
            result = subprocess.run(['bash', '-c', script, '_', str(ROOT), mode],
                                    env=dict(env, LEDGER_FAIL='1' if kind == 'ledger' else '0'),
                                    capture_output=True, text=True, errors='replace', timeout=15)
            assert (result.returncode == 0) == expected, (kind, mode, result.stderr)
            cases += 1
    print(f'PASS: VMess real certificate checks: {cases} strict/existing cases, including denied ledger gate')


def main():
    boot_paths()
    with tempfile.TemporaryDirectory(prefix='certificate-recovery-') as directory:
        root = Path(directory)
        certificates(root)
        check_tls(root)
        check_vmess(root)
    print('Focused recovery regressions complete; no native service acceptance claimed.')


if __name__ == '__main__':
    main()
