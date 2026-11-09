#!/usr/bin/env python3
"""Real-PTY startup regressions; package execution is mocked, never installed."""
import errno
import os
import pty
import select
import shlex
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Deny real package execution in every subprocess, including PTYs and env -i.
import tempfile
_package_guard_tmp = tempfile.TemporaryDirectory(prefix='toolbox-package-deny-')
_package_guard = Path(_package_guard_tmp.name)
_package_log = _package_guard / 'calls'
for _manager in ('sudo', 'apt', 'apt-get', 'apt-cache', 'aptitude', 'apk', 'dpkg', 'dpkg-query', 'dpkg-deb', 'dnf', 'yum', 'rpm'):
    _file = _package_guard / _manager
    _file.write_text('#!/bin/sh\nprintf "%s\\n" "$0 $*" >> ' + shlex.quote(str(_package_log)) + '\nexit 99\n')
    _file.chmod(0o755)
os.environ['PATH'] = str(_package_guard) + os.pathsep + os.environ['PATH']
# UI fixtures do not need elevation, including when run by a non-root user.
os.environ['TOOLBOX_ELEVATED'] = '1'
for _env in (dict(os.environ), {'PATH': os.environ['PATH']}):
    _probe = subprocess.run(['bash', '--noprofile', '--norc', '-c', 'apt-get --fixture-guard-probe'], env=_env, capture_output=True)
    assert _probe.returncode == 99, _probe
assert len(_package_log.read_text().splitlines()) == 2
_package_log.unlink()

def probe(manager, fixture_root=True):
    installed = 'iproute2-ss' if manager == 'apk' else 'iproute2'
    # Bootstrap has an inline EUID gate, so patch only its exact in-memory
    # definition for the success fixture. Never alter product source or elevate.
    root_fixture = r'''
bootstrap_impl=$(declare -f _tb_bootstrap)
root_check='(( EUID == 0 ))'
[[ $bootstrap_impl == *"$root_check"* ]] || exit 93
remainder=${bootstrap_impl#*"$root_check"}
[[ $remainder != *"$root_check"* ]] || exit 94
_tb_fixture_root() { return 0; }
bootstrap_impl=${bootstrap_impl/"$root_check"/_tb_fixture_root}
eval "$bootstrap_impl"
''' if fixture_root else ''
    harness = f'''
source {shlex.quote(str(ROOT / 'toolbox.sh'))} --help >/dev/null
{root_fixture}
_tb_ui_init
TB_OS_ID={'alpine' if manager == 'apk' else 'debian'}
TB_OS='fixture Linux'
ss_installed=0
_tb_bootstrap_has() {{ [[ $1 != ss || $ss_installed == 1 ]]; }}
_tb_bootstrap_exec() {{
  printf 'MOCK_EXEC:%s\\n' "$*"
  if [[ $1 == {manager} && $2 == {'add' if manager == 'apk' else 'install'} ]]; then
    [[ " $* " == *' {installed} '* ]] || return 91
    ss_installed=1
  fi
}}
_tb_bootstrap || exit $?
[[ $ss_installed == 1 ]] || exit 92
'''
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='dumb', NO_COLOR='1', COLUMNS='80')
    proc = subprocess.Popen(['bash', '-c', harness], stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    chunks = []
    deadline = time.monotonic() + 15
    try:
        os.write(master, b'y\n')
        while True:
            assert time.monotonic() < deadline, 'PTY startup hung'
            if not select.select([master], [], [], 0.2)[0]:
                continue
            try:
                part = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not part:
                break
            chunks.append(part)
        proc.wait(timeout=2)
        output = b''.join(chunks).decode(errors='replace')
        if not fixture_root:
            assert proc.returncode == 1, (manager, proc.returncode, output)
            assert '安装依赖需要 root' in output, output
            assert 'MOCK_EXEC:' not in output and '依赖检查通过' not in output, output
            return
        assert proc.returncode == 0, (manager, proc.returncode, output)
        assert '缺少' in output and 'ss' in output, output
        assert '基础依赖已齐全' not in output, 'startup falsely declared complete without ss'
        assert '依赖检查通过' in output, output
        assert f'{installed}' in output, 'command must map to package name'
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        os.close(master)

for manager in ('apk', 'apt-get'):
    if os.geteuid() != 0:
        probe(manager, fixture_root=False)
        print('PASS real PTY non-root package refusal:', manager)
    probe(manager)
    print('PASS real PTY startup ss detection and package mapping:', manager)

assert not _package_log.exists(), _package_log.read_text()
