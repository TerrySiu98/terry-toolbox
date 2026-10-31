#!/usr/bin/env python3
"""Short isolated supervisor regressions; never run a product/install suite."""
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

RUNNER = Path(__file__).with_name('regression-runner.py')
spec = importlib.util.spec_from_file_location('toolbox_test_runner', RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def record(pid, parent, start=1, state='S'):
    return dict(pid=pid, parent=parent, start=start, state=state)


class IdentityTest(unittest.TestCase):
    def test_ancestry_excludes_parallel_tree(self):
        owner = record(100, 1, 4)
        snapshot = {r['pid']: r for r in (owner, record(101, 100), record(102, 101),
                                         record(103, 100), record(200, 1), record(201, 200))}
        self.assertEqual(set(runner.descendants(snapshot, owner)), {101, 102, 103})
        snapshot[100]['start'] = 9
        with self.assertRaises(RuntimeError):
            runner.descendants(snapshot, record(100, 1, 4))

    def test_proc_stat_parentheses_and_starttime(self):
        fields = ['S', '12', '42', '42'] + ['0'] * 15 + ['87654']
        with patch.object(Path, 'read_text', return_value='73 (comm ) with spaces) ' + ' '.join(fields)):
            self.assertEqual(runner.process_record(73), record(73, 12, 87654))

    def test_pid_reuse_after_pidfd_open_is_not_signalled(self):
        owner, target = record(10, 1, 100), record(11, 10, 110)
        with patch.object(runner, 'process_snapshot', return_value={10: owner, 11: target}), \
                patch.object(runner.os, 'pidfd_open', return_value=41, create=True), \
                patch.object(runner, 'process_record', return_value=record(11, 10, 999)), \
                patch.object(runner.signal, 'pidfd_send_signal', create=True) as send, \
                patch.object(runner.os, 'close') as close:
            self.assertFalse(runner.signal_owned(target, owner, signal.SIGTERM))
            send.assert_not_called()
            close.assert_called_once_with(41)

    def test_reparented_or_parallel_identity_is_not_signalled(self):
        owner, target = record(10, 1, 100), record(11, 10, 110)
        for current in (record(11, 10, 999), record(11, 200, 110)):
            with patch.object(runner, 'process_snapshot', return_value={10: owner, 11: current}), \
                    patch.object(runner.os, 'pidfd_open', create=True) as opened:
                self.assertFalse(runner.signal_owned(target, owner, signal.SIGKILL))
                opened.assert_not_called()

    def test_cleanup_discovers_new_child_then_escalates(self):
        supervisor = object.__new__(runner.Supervisor)
        supervisor.owner = record(10, 1)
        supervisor.grace, supervisor.kill_wait = .1, 1
        first, born = record(11, 10), record(12, 10)
        with patch.object(supervisor, 'remaining', side_effect=[{11: first}, {12: born}, {}]), \
                patch.object(runner, 'direct_children', return_value=[]), \
                patch.object(runner.time, 'monotonic', side_effect=[0, .01, .2]), \
                patch.object(runner.time, 'sleep'), patch.object(runner, 'signal_owned', return_value=True) as send:
            result = supervisor.cleanup(object())
            self.assertTrue(result['complete'])
            self.assertEqual([x.args for x in send.call_args_list],
                             [(first, supervisor.owner, signal.SIGTERM), (born, supervisor.owner, signal.SIGKILL)])

    def test_empty_racy_snapshot_is_not_cleanup_success(self):
        supervisor = object.__new__(runner.Supervisor)
        supervisor.owner = record(10, 1)
        supervisor.grace, supervisor.kill_wait = .1, 1
        adopted = record(12, 10)
        with patch.object(supervisor, 'remaining', side_effect=[{}, {12: adopted}, {}]), \
                patch.object(runner, 'direct_children', side_effect=[[12], []]), \
                patch.object(runner.time, 'monotonic', side_effect=[0, .01, .2]), \
                patch.object(runner.time, 'sleep'), patch.object(runner, 'signal_owned', return_value=True) as send:
            result = supervisor.cleanup(object())
            self.assertTrue(result['complete'])
            send.assert_called_once_with(adopted, supervisor.owner, signal.SIGKILL)


DRIVER = '''import importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location('runner',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
w=pathlib.Path(sys.argv[2])
with m.Supervisor(grace=.2,kill_wait=3) as s:
 with (w/'log').open('wb') as log:
  result=s.run([sys.executable,str(w/'target.py'),str(w)],log,float(sys.argv[3]),cwd=w)
 result['cancelled_signal']=s.cancel_signal
 (w/'result.json').write_text(json.dumps(result))
sys.exit(0 if result['cleanup']['complete'] else 90)
'''

TARGET = '''import json,os,pathlib,signal,subprocess,sys,time
w=pathlib.Path(sys.argv[1])
def track(name):
 raw=pathlib.Path('/proc/self/stat').read_text();start=int(raw[raw.rfind(')')+2:].split()[19])
 (w/name).write_text(json.dumps({'pid':os.getpid(),'start':start}))
def forever():
 while True:time.sleep(.05)
track('leader.json')
MODE
'''


@unittest.skipUnless(sys.platform == 'linux', 'native subreaper/pidfd checks require Linux')
class NativeTest(unittest.TestCase):
    def run_tree(self, mode, *, cancel=None, limit=.5):
        with tempfile.TemporaryDirectory(prefix='runner-supervisor-') as directory:
            work = Path(directory)
            (work/'target.py').write_text(TARGET.replace('MODE', mode))
            outsider = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(30)'], start_new_session=True)
            driver = None
            try:
                driver = subprocess.Popen([sys.executable, '-c', DRIVER, str(RUNNER), str(work), str(limit)],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                if cancel is not None:
                    deadline = time.monotonic() + 5
                    while not (work/'ready').exists():
                        self.assertIsNone(driver.poll(), 'driver ended before cancellation fixture was ready')
                        self.assertLess(time.monotonic(), deadline, 'fixture readiness timeout')
                        time.sleep(.01)
                    os.kill(driver.pid, cancel)
                out, err = driver.communicate(timeout=10)
                self.assertEqual(driver.returncode, 0, out + err)
                result = json.loads((work/'result.json').read_text())
                self.assertTrue(result['cleanup']['complete'], result)
                self.assertIsNone(outsider.poll(), 'unrelated parallel process was killed')
                for path in work.glob('*pid.json'):
                    expected = json.loads(path.read_text())
                    current = runner.process_record(expected['pid'])
                    self.assertTrue(current is None or current['start'] != expected['start'], (path, current, result))
                leader = json.loads((work/'leader.json').read_text())
                current = runner.process_record(leader['pid'])
                self.assertTrue(current is None or current['start'] != leader['start'], result)
                return result
            finally:
                outsider.terminate()
                outsider.wait(timeout=3)
                if driver is not None and driver.poll() is None:
                    driver.terminate()
                    try:
                        driver.communicate(timeout=6)
                    except subprocess.TimeoutExpired:
                        driver.kill()
                        driver.communicate()

    def test_success_and_failure_exit_codes(self):
        for code in (0, 7):
            result = self.run_tree(f'sys.exit({code})', limit=3)
            self.assertEqual(result['exit_code'], code)
            self.assertFalse(result['timeout'] or result['cancelled'] or result['leaked_descendants'])

    def test_timeout_reaps_double_forked_setsid_orphan(self):
        mode = '''pid=os.fork()
if pid==0:
 os.setsid()
 if os.fork():os._exit(0)
 signal.signal(signal.SIGTERM,signal.SIG_IGN);track('orphan-pid.json');forever()
os.waitpid(pid,0)
forever()'''
        result = self.run_tree(mode)
        self.assertTrue(result['timeout'])
        self.assertIn(signal.SIGKILL, [a['signal'] for a in result['cleanup']['signals']])

    def test_successful_leader_with_live_descendant_is_reported(self):
        mode = '''if os.fork()==0:
 os.setsid();track('leftover-pid.json');forever()
while not (w/'leftover-pid.json').exists():time.sleep(.01)
sys.exit(0)'''
        result = self.run_tree(mode, limit=3)
        self.assertEqual(result['exit_code'], 0)
        self.assertTrue(result['leaked_descendants'])

    def test_cancel_cleans_children_forked_by_term_handler(self):
        mode = '''def onterm(signum,frame):
 if os.fork()==0:
  os.setsid();signal.signal(signal.SIGTERM,signal.SIG_IGN);track('late-pid.json');forever()
 os._exit(0)
signal.signal(signal.SIGTERM,onterm)
(w/'ready').touch()
forever()'''
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig):
                result = self.run_tree(mode, cancel=sig, limit=20)
                self.assertTrue(result['cancelled'])
                self.assertEqual(result['cancelled_signal'], sig)


if __name__ == '__main__':
    unittest.main(verbosity=2)
