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

def probe(manager):
    installed = 'iproute2-ss' if manager == 'apk' else 'iproute2'
    harness = f'''
source {shlex.quote(str(ROOT / 'toolbox.sh'))} --help >/dev/null
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
    probe(manager)
    print('PASS real PTY startup ss detection and package mapping:', manager)
