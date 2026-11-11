#!/usr/bin/env python3
"""Capture generated fixture credentials in memory, never in test output."""
import errno
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
CHILD = r"""
set -euo pipefail
TOOLBOX_HY2_FIXTURE_ONLY=1 source "$1/tests/hy2-test.sh"
export MOCK_PORT=18443
mode=$2
out=$work/install.out
err=$work/install.err
if [[ $mode == failure ]]; then hy2_export_clients() { return 1; }; fi
install_action() {
    if [[ $mode == existing ]]; then
        toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443
    else
        toolbox_hy2 install-self 192.0.2.10 www.cloudflare.com 18443
    fi
}
rc=0
case $mode in
    output-file) install_action >"$out" 2>"$err" || rc=$? ;;
    input-pipe|both-pipe) printf 'YES\nYES\n' | install_action || rc=$? ;;
    trace) ( set -x; install_action ) 2>"$err" || rc=$? ;;
    *) install_action || rc=$? ;;
esac
python3 - "$mode" "$rc" "$TOOLBOX_HY2_ETC" "$out" "$err" <<'PY_RESULT'
import hashlib,json,pathlib,sys,yaml
mode,rc,etc,out,err=sys.argv[1:]
p=pathlib.Path(etc)
r=dict(mode=mode,rc=int(rc))
if mode == 'failure':
    assert int(rc)!=0 and not p.exists(), 'failure did not roll back'
else:
    assert int(rc)==0, 'install failed'
    pw=yaml.safe_load((p/'config.yaml').read_text())['auth']['password']
    for name in ('config.yaml','hysteria2.txt','client.yaml','mihomo.yaml'):
        assert (p/name).stat().st_mode & 0o777 == 0o600, 'private mode changed'
    for f in (out,err):
        q=pathlib.Path(f)
        if q.exists(): assert pw not in q.read_text(), 'password in redirected log'
    r['password_sha256']=hashlib.sha256(pw.encode()).hexdigest()
print('\nRESULT_JSON '+json.dumps(r),flush=True)
PY_RESULT
if [[ $mode == self ]]; then
    before=$(sha256sum "$TOOLBOX_HY2_ETC/config.yaml")
    if toolbox_hy2 install-self 192.0.2.10 www.cloudflare.com 18443 </dev/null >"$work/reinstall.out" 2>&1; then fail 'existing install overwritten'; fi
    [[ $(sha256sum "$TOOLBOX_HY2_ETC/config.yaml") == "$before" ]] || fail 'existing password changed'
fi
"""

def run_case(mode):
    master, slave = pty.openpty()
    stdin = subprocess.DEVNULL if mode in ('input-pipe', 'both-pipe') else slave
    stdout = subprocess.PIPE if mode == 'both-pipe' else slave
    proc = subprocess.Popen(['bash', '--noprofile', '--norc', '-c', CHILD, '_', str(ROOT), mode],
                            cwd=ROOT, stdin=stdin, stdout=stdout, stderr=slave, close_fds=True)
    os.close(slave)
    captured = bytearray()
    streams = {master}
    if proc.stdout is not None:
        streams.add(proc.stdout.fileno())
    if mode not in ('input-pipe', 'both-pipe'):
        os.write(master, b'YES\nYES\n')
    deadline = time.monotonic() + 90
    try:
        while streams:
            if time.monotonic() > deadline:
                raise AssertionError(f'{mode}: timed out')
            for fd in select.select(list(streams), [], [], 0.1)[0]:
                try:
                    block = os.read(fd, 65536)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    block = b''
                if block:
                    captured.extend(block)
                else:
                    streams.remove(fd)
        assert proc.wait(timeout=3) == 0, f'{mode}: fixture failed (raw credentials suppressed)'
    finally:
        os.close(master)
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=3)
    text = captured.decode(errors='replace').replace('\r', '')
    results = re.findall(r'^RESULT_JSON (.*)$', text, re.M)
    assert len(results) == 1, f'{mode}: missing fixture result'
    result = json.loads(results[0])
    shown = re.findall(r'^HY2 密码：([A-Za-z0-9]{32})$', text, re.M)
    expected_show = mode in ('self', 'existing', 'trace')
    assert '随机密码仅存文件，不打印' not in text, f'{mode}: obsolete privacy promise'
    if expected_show:
        assert text.index('成功后在交互终端显示密码') < text.index('确认安装？'), f'{mode}: missing advance disclosure'
    if expected_show:
        assert len(shown) == 1, f'{mode}: successful terminal install must show one password'
        assert hashlib.sha256(shown[0].encode()).hexdigest() == result['password_sha256'], f'{mode}: wrong password'
        assert '请勿分享屏幕或终端日志' in text, f'{mode}: warning missing'
        assert text.index('安装完成') < text.index('HY2 密码：'), f'{mode}: premature display'
    else:
        assert not shown and 'HY2 密码：' not in text, f'{mode}: password display must be suppressed'
        # Catch a password printed without the label too.
        for token in re.findall(r'[A-Za-z0-9]{32}', text):
            assert hashlib.sha256(token.encode()).hexdigest() != result.get('password_sha256'), f'{mode}: raw password leaked'
    assert 'hysteria2://' not in text, f'{mode}: share URI leaked'
    print(f'PASS: HY2 password {mode}', flush=True)

for case in ('self','existing','output-file','input-pipe','both-pipe','trace','failure'):
    run_case(case)
print('All HY2 password display tests passed.')
