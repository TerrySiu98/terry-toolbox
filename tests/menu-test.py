#!/usr/bin/env python3
"""Regression tests for the reference-style menu and safe first-run dependency check."""
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'toolbox.sh'


def run(data, columns=80):
    env = dict(os.environ, NO_COLOR='1', TERM='dumb', COLUMNS=str(columns))
    result = subprocess.run(['bash', str(SCRIPT)], input=data, capture_output=True, text=True, env=env, timeout=15)
    assert result.returncode == 0, result.stderr
    return result.stdout, result.stderr


out, err = run('0\n')
assert 'TERRY' in out or 'Terry' in out, 'missing branded reference-style banner'
assert '1. 网络服务' in out, 'missing numeric main menu'
assert '99. 重新启动' in out, 'missing reference restart key'
assert 'B31' not in out, 'flat all-options dump still present on home'
assert '\x1b' not in out, 'ANSI in non-tty output'
assert 'readonly variable' not in err
out, err = run('1\n0\n5\n0\n0\n')
assert 'Alpine 版 HY2' in out and 'DDNS-GO' in out, 'submenus missing'
assert '请输入数字选择操作' in out, 'input prompt missing'
assert 'readonly variable' not in err
out, err = run('5\n18\n0\n0\n')
assert '预留，暂未实现' in out
out, err = run('DIAG\nDIAG\n0\n')
assert out.count('=== 系统 ===') == 2, 'repeat action regression'
assert 'readonly variable' not in err, 'modules re-sourced into readonly constants'
out, err = run('nonsense\n0\n')
assert '无效' in out
out, err = run('1\n0\n5\n0\n0\n', 40)
import unicodedata
for line in out.splitlines():
    width = sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in line)
    assert width <= 40, f'wide line in narrow mode ({width}): {line}'
# Management pages must return one level; choosing Return is not a failed action.
out, err = run('1\n4\n0\n0\n0\n')
assert 'A4 Hysteria 2' in out, 'HY2 management page missing'
assert 'command not found' not in err, err
assert '操作未完成或已取消' not in out, 'Return treated as a failed action'
assert out.count('Alpine 版 HY2') == 2, 'return skipped the network level'
out, err = run('5\n10\n0\n0\n0\n')
assert 'B10 WebSSH' in out, 'WebSSH has no management/return page'
assert '操作未完成或已取消' not in out, 'WebSSH Return ran an installation'
for key in ('A1', 'A2', 'A3', 'A4', 'A5', 'B10', 'B12', 'B16', 'B19', 'B23', 'B31'):
    out, err = run(f'{key}\n0\n0\n', 40)
    assert '返回上一层' in out and '操作未完成或已取消' not in out, f'{key} cannot return cleanly'
    assert not err, (key, err)
    for line in out.splitlines():
        width = sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in line)
        assert width <= 40, f'{key} overflows a 40-column terminal: {line}'

# A real PTY proves screen replacement and pause semantics; privileged work is mocked.
import errno
import fcntl
import pty
import select
import shlex
import struct
import termios
import time


def run_tty(data, no_clear=False):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 80, 0, 0))
    env = dict(os.environ, NO_COLOR='1', TERM='xterm')
    env.pop('TOOLBOX_NO_CLEAR', None)
    if no_clear:
        env['TOOLBOX_NO_CLEAR'] = '1'
    harness = f'''source {shlex.quote(str(SCRIPT))} --help >/dev/null
_tb_bootstrap() {{ :; }}
load_modules() {{ :; }}
toolbox_network() {{ printf 'MOCK_NETWORK:%s\\n' "$*"; }}
net_dns_preset() {{ printf '1.1.1.1 1.0.0.1'; }}
toolbox_webssh() {{ printf 'MOCK_WEBSSH:%s\\n' "$1"; }}
_toolbox_system_netopt_apply() {{ printf 'MOCK_NETOPT:apply\\n'; }}
_toolbox_system_netopt_rollback() {{ printf 'MOCK_NETOPT:rollback\\n'; }}
_toolbox_system_alpine_webtop() {{ printf 'MOCK_ALPINE:webtop\\n'; }}
_toolbox_system_alpine_hop_apply() {{ printf 'MOCK_ALPINE:hop-apply\\n'; }}
_toolbox_system_alpine_hop_remove() {{ printf 'MOCK_ALPINE:hop-remove\\n'; }}
_toolbox_system_alpine_swap() {{ printf 'MOCK_ALPINE:swap-disabled\\n'; return 1; }}
menu
'''
    proc = subprocess.Popen(['bash', '-c', harness], stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    chunks = []
    deadline = time.monotonic() + 15
    try:
        os.write(master, data.encode())
        while True:
            assert time.monotonic() < deadline, 'PTY menu hung (extra pause or wrong return level)'
            if not select.select([master], [], [], 0.2)[0]:
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            chunks.append(chunk)
        proc.wait(timeout=2)
        assert proc.returncode == 0, b''.join(chunks).decode(errors='replace')
        return b''.join(chunks).decode(errors='replace')
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        os.close(master)


tty_out = run_tty('1\n4\n3\n\n0\n0\n0\n')
assert 'MOCK_NETWORK:A4 status' in tty_out, tty_out
# DNS presets are returned as one space-separated line without a final newline.
dns_out = run_tty('B23\n1\n\n0\n0\n')
assert 'MOCK_NETWORK:B23 install 1.1.1.1 1.0.0.1' in dns_out, 'DNS preset did not pass two addresses'
system_out = run_tty('B16\n1\n\n2\n\n0\nB19\n1\n\n2\n\n3\n\n4\n\n0\nB10\n3\n\n0\n0\n')
for marker in ('MOCK_NETOPT:apply', 'MOCK_NETOPT:rollback', 'MOCK_ALPINE:webtop', 'MOCK_ALPINE:hop-apply', 'MOCK_ALPINE:hop-remove', 'MOCK_ALPINE:swap-disabled', 'MOCK_WEBSSH:status'):
    assert marker in system_out, marker
assert system_out.count('操作结束') == 7, 'system actions skipped or duplicated pauses'
assert tty_out.count('操作结束') == 1, 'Return added an unnecessary pause'
frames = tty_out.split('\x1b[H\x1b[2J')
assert len(frames) >= 7, 'not replacing every menu screen'
assert any('A4 Hysteria 2' in frame and 'Alpine 版 HY2' not in frame for frame in frames), 'service screen appended below network menu'
assert any('Alpine 版 HY2' in frame and '请选择要执行的操作' not in frame for frame in frames), 'network screen appended below home'
assert '\x1b[3J' not in tty_out, 'must not erase terminal scrollback'
assert 'command not found' not in tty_out, tty_out
assert '\x1b' not in run_tty('0\n', no_clear=True), 'TOOLBOX_NO_CLEAR ignored'
print('menu regression tests passed: hierarchy, service management, PTY redraw/pause, direct keys, repeat action, 40-column layout')
