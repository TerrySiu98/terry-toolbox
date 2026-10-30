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
print('menu regression tests passed: home, hierarchy, direct keys, repeat action, invalid input, 40-column layout')
