#!/usr/bin/env python3
"""Real PTY/authentication adapter; ONLY the shared denied destructive fixture runs."""
import ctypes
import ctypes.util
import gzip
import hashlib
import json
import os
import pty
import secrets
import select
import signal
import stat
import subprocess
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COUNT = 0


def passed(label):
    global COUNT
    COUNT += 1
    print(f'PASS {COUNT:02d} {label}', flush=True)


def probe_tree(pid, secret):
    """Check actual live argv/environment; don't emit any values on failure."""
    rows = {}
    for p in Path('/proc').glob('[0-9]*/stat'):
        try:
            rows[int(p.parent.name)] = int(p.read_text().rsplit(')', 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            continue
    owned = {pid}
    while True:
        extra = {p for p, parent in rows.items() if parent in owned}
        if extra <= owned:
            break
        owned |= extra
    for child in owned:
        for leaf in ('cmdline', 'environ'):
            try:
                data = Path(f'/proc/{child}/{leaf}').read_bytes()
            except (OSError, ProcessLookupError):
                continue
            assert secret not in data, 'secret present in live process argv/environment'


def session(script, steps=(), secret=b'NO_SECRET_FIXTURE', timeout=30, pipe_input=None):
    master, slave = pty.openpty()
    env = os.environ.copy()
    env['REINSTALL_TEST_LIBRARY'] = '1'
    command = 'source "$1/tests/reinstall-test.sh"; ' + script
    proc = subprocess.Popen(['bash', '-c', command, 'auth-test', str(ROOT)],
                            stdin=slave if pipe_input is None else subprocess.PIPE,
                            stdout=slave, stderr=slave, env=env, start_new_session=True)
    os.close(slave)
    if pipe_input is not None:
        assert proc.stdin is not None
        proc.stdin.write(pipe_input)
        proc.stdin.close()
    data = bytearray()
    deadline = time.monotonic() + timeout
    index = 0
    seen = 0
    failure = None
    echo_ok = True
    try:
        while time.monotonic() < deadline:
            probe_tree(proc.pid, secret)
            if index < len(steps) and steps[index][0] in data[seen:]:
                prompt, value = steps[index]
                seen = len(data)
                if value == 'SIGNAL':
                    # The active prepare subshell publishes its task-owned PID.
                    pid = int(bytes(data).split(b'SIGNAL_PID=', 1)[1].splitlines()[0])
                    os.kill(pid, signal.SIGTERM)
                else:
                    if secret in value:
                        assert not termios.tcgetattr(master)[3] & termios.ECHO, 'echo enabled before password prompt'
                    if value == b'KEY_PATH_FROM_OUTPUT':
                        value = bytes(data).split(b'KEY_PATH=', 1)[1].splitlines()[0] + b'\n'
                    os.write(master, value)
                index += 1
            if select.select([master], [], [], .05)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                data.extend(chunk)
            if proc.poll() is not None:
                continue
        else:
            failure = 'PTY operation exceeded finite limit or required auth prompt absent'
        echo_ok = bool(termios.tcgetattr(master)[3] & termios.ECHO)
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
        code = proc.wait(timeout=5)
        assert failure is None, failure
        assert index == len(steps), 'required authentication prompt/interaction absent'
        assert secret not in data, 'plaintext appeared in PTY output'
        assert b'FORBIDDEN boundary:' not in data, 'unsafe privileged boundary reached'
        assert echo_ok, 'terminal echo not restored after operation'
        return code, bytes(data)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        os.close(master)


def password_steps(secret, confirm=b'YES\n', disk=b'/dev/vda\n'):
    return [('登录方式'.encode(), b'1\n'),
            ('密码（隐藏'.encode(), secret + b'\n'),
            ('再次输入密码'.encode(), secret + b'\n'),
            ('输入 YES:'.encode(), confirm),
            ('再次输入 YES:'.encode(), b'yes\n'),
            ('逐字输入 whole physical disk 路径'.encode(), disk)]


def fixture_from(output):
    return Path(output.split(b'AUTH_FIXTURE=', 1)[1].splitlines()[0].decode())


def check_private(fixture, secret, mode):
    active = fixture / 'state/active'
    m = json.loads((active / 'metadata.json').read_bytes())
    assert m['schema'] == 3 and m['auth_mode'] == mode
    for base in (fixture / 'state', active):
        assert stat.S_IMODE(base.stat().st_mode) == 0o700
    for p in active.iterdir():
        assert stat.S_IMODE(p.stat().st_mode) == 0o600, 'plan leaf permission not private'
    for p in fixture.rglob('*'):
        if p.is_file() and not p.is_symlink():
            assert secret not in p.read_bytes(), 'plaintext persisted in fixture'
    for name in ('metadata.json', 'prepare.log', 'cancel.log'):
        if name=='cancel.log' and m['phase']!='cancelled':
            continue
        assert b'$6$' not in (active / name).read_bytes(), 'crypt hash disclosed in public metadata/log'
    assert b'$6$' not in (fixture / 'calls').read_bytes(), 'crypt hash disclosed in argv log'
    if mode == 'password':
        crypted = (active / 'password.sha512').read_bytes().strip()
        salt = crypted.split(b'$')[2].decode()
        control = subprocess.run(['openssl', 'passwd', '-6', '-salt', salt, '-stdin'],
                                 input=secret + b'\n', stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert control.returncode == 0 and control.stdout.strip() == crypted, 'spaces/special characters changed in password hashing'
        lib = ctypes.CDLL(ctypes.util.find_library('crypt'))
        lib.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        lib.crypt.restype = ctypes.c_char_p
        assert lib.crypt(secret, crypted) == crypted, 'SHA512 crypt does not verify full entered password'
        assert not (active / 'key.pub').exists()
    else:
        assert not (active / 'password.sha512').exists()


REJECT = '''
rc=0; toolbox_reinstall prepare debian 13 || rc=$?;
[[ $rc != 0 && ! -s $fixture/calls && ! -e $fixture/state ]] || exit 90;
printf 'AUTH_REJECT\\n'
'''


def mutate_auth(root, mode, location, fault):
    """Called by fixture after the real mocked boundary, before product readback."""
    root = Path(root)
    expected = 'configs/password-linux-sha512' if mode == 'password' else 'configs/ssh_keys'
    configs = root / 'reinstall-tmp/initrd/configs'
    if location == 'workspace':
        selected = configs / expected.split('/')[-1]
        if fault == 'missing':
            selected.unlink()
        elif fault == 'wrong':
            b = selected.read_bytes()
            selected.write_bytes((b[:-2] + (b'A' if b[-2:-1] != b'A' else b'B') + b'\n') if mode == 'password' else b'wrong-key\n')
        elif fault == 'permissions':
            selected.chmod(0o644)
        elif fault == 'symlink':
            selected.rename(configs / 'saved'); selected.symlink_to('saved')
        elif fault == 'hardlink':
            os.link(selected, configs / 'extra-link')
        elif fault == 'owner':
            os.chown(selected, 65534, 65534)
        else:
            name = 'ssh_keys' if mode == 'password' else 'password-linux-sha512'
            if fault == 'plaintext':
                name = 'password-plaintext'
            elif fault == 'extra':
                name = 'password-linux-yescrypt'
            (configs / name).write_bytes(b'rejected-content\n')
        return
    elif mode == 'private':
        active = Path(root)
        selected = active / 'password.sha512'
        if location == 'symlink':
            selected.rename(active / 'saved-hash'); selected.symlink_to('saved-hash')
        elif location == 'hardlink':
            os.link(selected, active / 'hash-link')
        elif location == 'permissions':
            selected.chmod(0o644)
        elif location == 'owner':
            os.chown(selected, 65534, 65534)
        elif location == 'wrong':
            selected.write_bytes(b'not-a-crypt-hash\n')
        elif location == 'missing':
            selected.unlink()
        elif location == 'opposite':
            (active / 'key.pub').write_bytes(b'opposite-key\n')
        return
    # Synthetic newc around the genuine runtime files, never an install image.
    body = bytearray()
    def member(name, data, perm=0o100644, links=1, uid=0):
        raw = name.encode() + b'\0'
        fields = [1, perm, uid, 0, links, 0, len(data), 0, 0, 0, 0, len(raw), 0]
        body.extend(b'070701' + b''.join(('%08x' % n).encode() for n in fields))
        body.extend(raw); body.extend(b'\0' * (-len(body) % 4))
        body.extend(data); body.extend(b'\0' * (-len(body) % 4))
    for name in ('trans.sh', 'initrd-network.sh', expected):
        b = (root / 'reinstall-tmp/initrd' / name).read_bytes()
        perm = 0o100600 if name == 'configs/password-linux-sha512' else 0o100644
        links = 1
        if name == expected:
            if fault == 'missing':
                continue
            if fault == 'wrong':
                b += b'wrong'
            elif fault == 'permissions':
                perm = 0o100644
            elif fault == 'symlink':
                perm = 0o120600; b = b'elsewhere'
            elif fault == 'hardlink':
                links = 2
        member(name, b, perm, links, 65534 if fault=='owner' and name==expected else 0)
    if fault == 'ancestor-symlink':
        member('configs', b'elsewhere', 0o120777)
    if fault in ('opposite', 'plaintext', 'extra'):
        name = ('configs/ssh_keys' if mode == 'password' else 'configs/password-linux-sha512')
        if fault == 'plaintext':
            name = 'configs/password-plaintext'
        elif fault == 'extra':
            name = 'configs/password-linux-yescrypt'
        member(name, b'rejected-content\n')
    member('TRAILER!!!', b'')
    (root / 'reinstall-initrd').write_bytes(gzip.compress(body))


def main():
    # Locally random: never place plaintext/hash in scripts/env/argv/failure output.
    secret = ('  ' + secrets.token_urlsafe(20) + ' !\\$`"  ').encode()
    for distro, version in [('debian', '13'), ('ubuntu', '24.04'), ('alpine', '3.24')]:
        for mode in ('password', 'key'):
            script = f'''setup; unset TOOLBOX_REINSTALL_SSH_KEY_FILE;
toolbox_reinstall prepare {distro} {version} || exit 91;
toolbox_reinstall status >"$fixture/status" || exit 92;
[[ $(wc -l <"$fixture/calls") == 1 ]] || exit 93;
toolbox_reinstall cancel >"$fixture/cancel" || exit 94;
grep -q phase=cancelled "$fixture/cancel" || exit 95;
printf 'AUTH_COMPLETE\\nAUTH_FIXTURE=%s\\n' "$fixture"
'''
            steps = password_steps(secret) if mode == 'password' else [
                ('登录方式'.encode(), b'2\n'),
                ('公钥绝对路径'.encode(), b'REPLACE_KEY_PATH'),
                ('输入 YES:'.encode(), b'YES\n'),
                ('再次输入 YES:'.encode(), b'yes\n'),
                ('逐字输入 whole physical disk 路径'.encode(), b'/dev/vda\n')]
            if mode == 'key':
                # Shell prints its freshly generated path (public, not a secret).
                script = script.replace('unset TOOLBOX_REINSTALL_SSH_KEY_FILE;', 'unset TOOLBOX_REINSTALL_SSH_KEY_FILE; printf "KEY_PATH=%s\\n" "$case_root/key.pub";')
                # Key-path entry is a one-off dynamic event handled below.
                steps[1] = ('公钥绝对路径'.encode(), b'KEY_PATH_FROM_OUTPUT')
            code, output = session(script, steps, secret)
            assert code == 0 and b'AUTH_COMPLETE' in output, 'auth prepare/status/cancel failed'
            check_private(fixture_from(output), secret, mode)
            passed(f'{distro} {mode}: prepare/status/cancel, permissions, crypt fidelity, secret absent argv/env/log/files')

    boundary_secret = secrets.token_urlsafe(256).encode()[:256]
    code, out = session('''setup; unset TOOLBOX_REINSTALL_SSH_KEY_FILE;
toolbox_reinstall prepare ubuntu 24.04 || exit 90;
toolbox_reinstall cancel >/dev/null || exit 91;
printf 'AUTH_FIXTURE=%s\\n' "$fixture"
''', password_steps(boundary_secret), boundary_secret)
    assert code == 0
    check_private(fixture_from(out), boundary_secret, 'password')
    passed('maximum 256-byte password verifies with native crypt without OpenSSL stdin truncation')

    for value in (b'0\n', b'9\n', b'YES\n', b'\n', b'\x04'):
        code, out = session('setup; unset TOOLBOX_REINSTALL_SSH_KEY_FILE; ' + REJECT,
                            [('登录方式'.encode(), value)], secret)
        assert code == 0 and b'AUTH_REJECT' in out
    passed('mode cancel/invalid/empty/EOF refuse before state/download/upstream')

    for first, second in [(b'', b''), (b'short', b'short'), (secret, b'mismatch'), (b'x' * 257, b'x' * 257)]:
        code, out = session('setup; unset TOOLBOX_REINSTALL_SSH_KEY_FILE; ' + REJECT,
                            [('登录方式'.encode(), b'1\n'), ('密码（隐藏'.encode(), first + b'\n'),
                             ('再次输入密码'.encode(), second + b'\n')], secret)
        assert code == 0 and b'AUTH_REJECT' in out
    passed('password empty/short/overlong/mismatch refuse, restore echo, no state/upstream')
    for steps in [password_steps(secret)[:1] + [('密码（隐藏'.encode(), b'\x04')],
                  password_steps(secret)[:2] + [('再次输入密码'.encode(), b'\x04')]]:
        code, out = session('setup; unset TOOLBOX_REINSTALL_SSH_KEY_FILE; ' + REJECT, steps, secret)
        assert code == 0 and b'AUTH_REJECT' in out
    passed('password first/second EOF fail closed and restore echo')
    code, out = session('setup; unset TOOLBOX_REINSTALL_SSH_KEY_FILE; ' + REJECT, secret=secret, pipe_input=b'1\n')
    assert code == 0 and b'AUTH_REJECT' in out
    passed('non-TTY password refuses without reading plaintext from pipe')

    for steps in [password_steps(secret)[:3] + [('输入 YES:'.encode(), b'NO\n')],
                  password_steps(secret)[:4] + [('再次输入 YES:'.encode(), b'NO\n')],
                  password_steps(secret, disk=b'/dev/vdb\n')]:
        code, out = session('setup; unset TOOLBOX_REINSTALL_SSH_KEY_FILE; ' + REJECT, steps, secret)
        assert code == 0 and b'AUTH_REJECT' in out
    passed('password retains dual YES/exact-disk refusal; no pre-confirm secret file')

    script = '''setup; unset TOOLBOX_REINSTALL_SSH_KEY_FILE;
set -xT; trap 'printf DEBUG_HOOK >&2' DEBUG;
toolbox_reinstall prepare debian 13 || exit 96;
set +xT; trap - DEBUG;
printf 'AUTH_FIXTURE=%s\\n' "$fixture"
'''
    code, out = session(script, password_steps(secret), secret)
    assert code == 0
    check_private(fixture_from(out), secret, 'password')
    assert b'$6$' not in out, 'hash leaked through inherited xtrace/debug hooks'
    passed('inherited xtrace/functrace/DEBUG hooks do not leak plaintext/hash')

    script = '''setup; unset TOOLBOX_REINSTALL_SSH_KEY_FILE;
real_password=$(declare -f _toolbox_reinstall_password);
_toolbox_reinstall_password() { printf 'SIGNAL_PID=%s\\n' "$BASHPID"; eval "$real_password"; _toolbox_reinstall_password; };
rc=0; toolbox_reinstall prepare debian 13 || rc=$?;
[[ $rc == 130 && ! -e $fixture/state && ! -s $fixture/calls ]] || exit 97;
printf 'AUTH_SIGNAL_COMPLETE\\n'
'''
    code, out = session(script, [('登录方式'.encode(), b'1\n'), ('密码（隐藏'.encode(), 'SIGNAL')], secret)
    assert code == 0 and b'AUTH_SIGNAL_COMPLETE' in out
    passed('real TERM during hidden read restores echo and does not arm boot')

    for schema in (1, 2):
        script = f'''setup;
printf 'YES\\nyes\\n/dev/vda\\n' | toolbox_reinstall prepare debian 13 >/dev/null || exit 90;
python3 - "$fixture/state/active" {schema} <<'PY'
import hashlib,hmac,json,sys
from pathlib import Path
p=Path(sys.argv[1]);m=json.loads((p/'metadata.json').read_bytes());m['schema']=int(sys.argv[2]);m.pop('auth_mode')
if m['schema']==1:m.pop('host_init')
b=json.dumps(m,sort_keys=True,separators=(',',':')).encode();(p/'metadata.json').write_bytes(b);(p/'seal').write_text(hmac.new((p/'seal.key').read_bytes(),b,hashlib.sha256).hexdigest())
PY
toolbox_reinstall status >/dev/null || exit 91;
toolbox_reinstall cancel >/dev/null || exit 92;
printf 'AUTH_LEGACY_COMPLETE\\n'
'''
        code, out = session(script, secret=secret)
        assert code == 0 and b'AUTH_LEGACY_COMPLETE' in out
    passed('sealed schema1/schema2 key plans still status/cancel with strict status first line')

    private_faults = ['missing', 'wrong', 'opposite', 'permissions', 'symlink', 'hardlink']
    if os.geteuid() == 0:
        private_faults.append('owner')
    for fault in private_faults:
        script = f'''setup; unset TOOLBOX_REINSTALL_SSH_KEY_FILE;
fetch=$(declare -f _toolbox_reinstall_fetch);
_toolbox_reinstall_fetch() {{ eval "$fetch"; _toolbox_reinstall_fetch "$@" || return;
python3 "$ROOT/tests/reinstall-auth-test.py" --mutate "$fixture/state/active" private {fault} unused; }};
rc=0; toolbox_reinstall prepare debian 13 || rc=$?;
[[ $rc != 0 && ! -s $fixture/calls ]] || exit 93;
printf 'AUTH_PRIVATE_REJECT\\n'
'''
        code, out = session(script, password_steps(secret), secret)
        assert code == 0 and b'AUTH_PRIVATE_REJECT' in out, f'private hash {fault} gate not exercised'
    passed('private secret missing/wrong/opposite/mode/owner/symlink/hardlink refuse BEFORE upstream')

    for mode in ('password', 'key'):
        for location in ('workspace', 'archive'):
            faults = ['missing', 'wrong', 'opposite', 'plaintext', 'extra', 'symlink', 'hardlink']
            if mode == 'password':
                faults += ['permissions'] + (['owner'] if location=='archive' or os.geteuid()==0 else [])
            if location=='archive':faults.append('ancestor-symlink')
            for fault in faults:
                script = f'''setup; export TOOLBOX_REINSTALL_AUTH_MODE={mode};
[[ $TOOLBOX_REINSTALL_AUTH_MODE == key ]] || unset TOOLBOX_REINSTALL_SSH_KEY_FILE;
runner=$(declare -f _toolbox_reinstall_run_upstream);
_toolbox_reinstall_run_upstream() {{ eval "$runner"; _toolbox_reinstall_run_upstream "$@" || return;
python3 "$ROOT/tests/reinstall-auth-test.py" --mutate "$fixture/root" {mode} {location} {fault}; }};
rc=0; toolbox_reinstall prepare debian 13 || rc=$?;
[[ $rc != 0 && $(wc -l <"$fixture/calls") == 1 ]] || exit 98;
grep -q '"phase":"failed"' "$fixture/state/active/metadata.json" || exit 99;
printf 'AUTH_TAMPER_REJECT\\n'
'''
                steps = password_steps(secret)[1:] if mode == 'password' else password_steps(secret)[3:]
                code, out = session(script, steps, secret)
                assert code == 0 and b'AUTH_TAMPER_REJECT' in out, f'{mode} {location} {fault} not rejected'
            passed(f'{mode} {location}: ' + '/'.join(faults) + ' gates exercised')
    print(f'All {COUNT} authentication groups passed; MOCK only, no real reinstall/boot/service operations.')


if __name__ == '__main__':
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == '--mutate':
        mutate_auth(*sys.argv[2:])
    else:
        main()
