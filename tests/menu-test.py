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
assert '4. 重装系统（开发中）' in out, 'unreleased reinstall must be visibly marked before selection'
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
for key in ('A1', 'A2', 'A3', 'A4', 'A5', 'B1', 'B10', 'B12', 'B16', 'B19', 'B23', 'B31', 'M3', 'TLS'):
    out, err = run(f'{key}\n0\n0\n', 40)
    assert '返回上一层' in out and '操作未完成或已取消' not in out, f'{key} cannot return cleanly'
    assert not err, (key, err)
    for line in out.splitlines():
        width = sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in line)
        assert width <= 40, f'{key} overflows a 40-column terminal: {line}'

# A5 adds VMess + WS without renumbering the existing REALITY actions.
out, err = run('A5\n0\n0\n', 40)
for label in ('1. 安装 REALITY', '2. 卸载 REALITY', '3. REALITY 状态',
              '4. 安装 VMess + WS', '5. 卸载 VMess + WS', '6. VMess + WS 状态',
              '7. VMess 开机自启', '8. 关闭 VMess 自启', '9. VMess 自启状态',
              '10. 更新 VMess 证书'):
    assert label in out, f'A5 protocol action missing: {label}'
assert not err, err
for line in out.splitlines():
    width = sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in line)
    assert width <= 40, f'A5 protocol menu overflows: {line}'

out, err = run('B19\n0\n0\n', 40)
for label in ('4. 安装 swap', '5. 卸载 swap', '6. swap 状态'):
    assert label in out, f'B19 swap action missing: {label}'
assert not err, err
for line in out.splitlines():
    width = sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in line)
    assert width <= 40, f'B19 swap menu overflows: {line}'

# A real PTY proves screen replacement and pause semantics; privileged work is mocked.
for page, labels in (
    ('B1', ('1. 安装 Docker', '2. 配置 Docker IPv6', '3. IPv6 状态', '4. 回滚 IPv6 配置')),
    ('B10', ('1. 安装 WebSSH', '4. 安装个人版', '6. 个人版状态', '7. 安装 Easynode', '9. Easynode 状态')),
    ('M3', ('1. 重装预检', '2. 准备重装', '3. 重装计划状态', '4. 取消本工具重装计划')),
    ('TLS', ('1. 申请证书', '2. 证书状态', '3. 手动续期', '4. 启用自动续期', '5. 关闭自动续期', '6. 同步至 VMess')),
):
    out, err = run(f'{page}\n0\n0\n', 40)
    for label in labels:
        assert label in out, (page, label)
    assert not err, (page, err)
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
toolbox_webssh_container() {{ printf 'MOCK_WEBSSH_CONTAINER:%s\\n' "$*"; }}
toolbox_tls_acme() {{ printf 'MOCK_TLS:%s\\n' "$*"; }}
_toolbox_system_docker() {{ printf 'MOCK_DOCKER:install\\n'; }}
_toolbox_system_docker_ipv6() {{ printf 'MOCK_DOCKER_IPV6:%s\\n' "$1"; }}
_toolbox_system_reinstall() {{ printf 'MOCK_REINSTALL:%s\\n' "$*"; }}
_toolbox_system_netopt_apply() {{ printf 'MOCK_NETOPT:apply\\n'; }}
_toolbox_system_netopt_rollback() {{ printf 'MOCK_NETOPT:rollback\\n'; }}
_toolbox_system_alpine_webtop() {{ printf 'MOCK_ALPINE:webtop\\n'; }}
_toolbox_system_alpine_hop_apply() {{ printf 'MOCK_ALPINE:hop-apply\\n'; }}
_toolbox_system_alpine_hop_remove() {{ printf 'MOCK_ALPINE:hop-remove\\n'; }}
_toolbox_system_alpine_swap() {{ printf 'MOCK_ALPINE:swap-%s\\n' "$1"; }}
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
vmess_out = run_tty('1\n5\n4\n\n5\n\n6\n\n0\n0\n0\n')
for action in ('install-ws', 'uninstall-ws', 'status-ws'):
    assert f'MOCK_NETWORK:A5 {action}' in vmess_out, f'A5 VMess action not dispatched: {action}'
assert vmess_out.count('操作结束') == 3, 'VMess actions have extra or missing pauses'
assert '操作未完成或已取消' not in vmess_out, vmess_out
assert vmess_out.count('Alpine 版 HY2') == 2, 'VMess page return skipped the network level'
# M3 preflight reads the Debian target before the action-completion pause.
remaining_out = run_tty('B1\n2\n\n3\n\n4\n\n0\nB10\n4\n\n5\n\n6\n\n7\n\n8\n\n9\n\n0\nM3\n1\n1\n\n3\n\n4\n\n0\nTLS\n1\n\n2\n\n3\n\n4\n\n5\n\n6\n\n0\nA5\n7\n\n8\n\n9\n\n0\n0\n')
for marker in ('MOCK_DOCKER_IPV6:apply', 'MOCK_DOCKER_IPV6:status', 'MOCK_DOCKER_IPV6:restore',
               'MOCK_WEBSSH_CONTAINER:personal install', 'MOCK_WEBSSH_CONTAINER:personal uninstall',
               'MOCK_WEBSSH_CONTAINER:personal status', 'MOCK_WEBSSH_CONTAINER:easynode install',
               'MOCK_WEBSSH_CONTAINER:easynode uninstall', 'MOCK_WEBSSH_CONTAINER:easynode status',
               'MOCK_REINSTALL:preflight debian', 'MOCK_REINSTALL:status', 'MOCK_REINSTALL:cancel',
               'MOCK_TLS:issue', 'MOCK_TLS:status', 'MOCK_TLS:renew', 'MOCK_TLS:enable-renewal',
               'MOCK_TLS:disable-renewal', 'MOCK_TLS:deploy-vmess',
               'MOCK_NETWORK:A5 enable-boot-ws', 'MOCK_NETWORK:A5 disable-boot-ws', 'MOCK_NETWORK:A5 boot-status-ws'):
    assert marker in remaining_out, marker
assert remaining_out.count('操作结束') == 21, 'remaining actions skipped/duplicated pauses'
assert '操作未完成或已取消' not in remaining_out, remaining_out
# DNS presets are returned as one space-separated line without a final newline.
dns_out = run_tty('B23\n1\n\n0\n0\n')
assert 'MOCK_NETWORK:B23 install 1.1.1.1 1.0.0.1' in dns_out, 'DNS preset did not pass two addresses'
system_out = run_tty('B16\n1\n\n2\n\n0\nB19\n1\n\n2\n\n3\n\n4\n\n5\n\n6\n\n0\nB10\n3\n\n0\n0\n')
for marker in ('MOCK_NETOPT:apply', 'MOCK_NETOPT:rollback', 'MOCK_ALPINE:webtop', 'MOCK_ALPINE:hop-apply', 'MOCK_ALPINE:hop-remove', 'MOCK_ALPINE:swap-install', 'MOCK_ALPINE:swap-uninstall', 'MOCK_ALPINE:swap-status', 'MOCK_WEBSSH:status'):
    assert marker in system_out, marker
assert system_out.count('操作结束') == 9, 'system actions skipped or duplicated pauses'
assert '操作未完成或已取消' not in system_out, system_out
assert tty_out.count('操作结束') == 1, 'Return added an unnecessary pause'
frames = tty_out.split('\x1b[H\x1b[2J')
assert len(frames) >= 7, 'not replacing every menu screen'
assert any('A4 Hysteria 2' in frame and 'Alpine 版 HY2' not in frame for frame in frames), 'service screen appended below network menu'
assert any('Alpine 版 HY2' in frame and '请选择要执行的操作' not in frame for frame in frames), 'network screen appended below home'
assert '\x1b[3J' not in tty_out, 'must not erase terminal scrollback'
assert 'command not found' not in tty_out, tty_out
assert '\x1b' not in run_tty('0\n', no_clear=True), 'TOOLBOX_NO_CLEAR ignored'
print('menu regression tests passed: hierarchy, service management, PTY redraw/pause, direct keys, repeat action, 40-column layout')
