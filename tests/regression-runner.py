#!/usr/bin/env python3
"""Serial regression runner; writes private logs and a source-bound JSON result."""
import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def process_record(pid):
    """Read identity plus ancestry; comm can itself contain spaces/parentheses."""
    try:
        raw = Path(f'/proc/{pid}/stat').read_text()
    except (FileNotFoundError, ProcessLookupError):
        return None
    fields = raw[raw.rfind(')') + 2:].split()
    if len(fields) < 20 or int(raw.split(' ', 1)[0]) != pid:
        raise RuntimeError(f'invalid process identity for {pid}')
    return dict(pid=pid, start=int(fields[19]), parent=int(fields[1]), state=fields[0])


def process_snapshot():
    found = {}
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            record = process_record(int(entry.name))
            if record is not None:
                found[record['pid']] = record
    return found


def direct_children(owner):
    # A /proc directory walk is not atomic: a parent can exit while its child is
    # adopted. Check the runner's direct-child list before declaring no survivors.
    current = process_record(owner['pid'])
    if current is None or identity(current) != identity(owner):
        raise RuntimeError('runner identity changed')
    raw = Path(f"/proc/{owner['pid']}/task/{owner['pid']}/children").read_text()
    return [int(pid) for pid in raw.split()]


def identity(record):
    return record['pid'], record['start']


def descendants(snapshot, owner):
    """Only the live runner's ancestry tree, never a name/PGID/global PID match."""
    current = snapshot.get(owner['pid'])
    if current is None or identity(current) != identity(owner):
        raise RuntimeError('runner identity changed')
    found = {}
    parents = {owner['pid']}
    while parents:
        generation = {pid: r for pid, r in snapshot.items()
                      if r['parent'] in parents and pid != owner['pid'] and pid not in found}
        found.update(generation)
        parents = set(generation)
    return found


def enable_subreaper():
    if sys.platform != 'linux' or not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
        raise RuntimeError('runner requires Linux pidfds and Python 3.11+; no unsafe process cleanup fallback')
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    libc.prctl.restype = ctypes.c_int
    # Descendants which double-fork or call setsid are adopted by this runner.
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise OSError(ctypes.get_errno(), 'cannot enable child subreaper')
    fd = os.pidfd_open(os.getpid())
    os.close(fd)


def signal_owned(record, owner, signum):
    """Reprove ancestry, then signal a pidfd bound to the same starttime."""
    current = descendants(process_snapshot(), owner).get(record['pid'])
    if current is None or identity(current) != identity(record):
        return False
    try:
        fd = os.pidfd_open(record['pid'])
    except ProcessLookupError:
        return False
    try:
        current = process_record(record['pid'])
        if current is None or identity(current) != identity(record):
            return False
        signal.pidfd_send_signal(fd, signum)
        return True
    except ProcessLookupError:
        return False
    finally:
        os.close(fd)


class Supervisor:
    def __init__(self, grace=3.0, kill_wait=5.0):
        enable_subreaper()
        self.owner = process_record(os.getpid())
        self.grace, self.kill_wait = grace, kill_wait
        self.cancel_signal = None
        self.handlers = {}

    def __enter__(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            self.handlers[sig] = signal.signal(sig, self.cancel)
        return self

    def __exit__(self, *exc):
        for sig, handler in self.handlers.items():
            signal.signal(sig, handler)

    def cancel(self, signum, _frame):
        # A signal never interrupts cleanup or the small Popen registration gap.
        if self.cancel_signal is None:
            self.cancel_signal = signum

    def remaining(self, proc):
        proc.poll()  # Popen owns and records the leader's wait status.
        found = descendants(process_snapshot(), self.owner)
        for pid, record in found.items():
            if pid != proc.pid and record['parent'] == self.owner['pid'] and record['state'] == 'Z':
                current = process_record(pid)
                if current is None or identity(current) != identity(record) or current['parent'] != self.owner['pid'] or current['state'] != 'Z':
                    continue
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    pass
        return descendants(process_snapshot(), self.owner)

    def cleanup(self, proc):
        sent = set()
        actions = []
        errors = []
        stop_at = time.monotonic() + self.grace
        kill_at = stop_at + self.kill_wait
        while True:
            found = self.remaining(proc)
            if not found and not direct_children(self.owner):
                return dict(complete=True, signals=actions, errors=errors, remaining=[])
            now = time.monotonic()
            if now >= kill_at:
                return dict(complete=False, signals=actions, errors=errors, remaining=list(found.values()))
            sig = signal.SIGTERM if now < stop_at else signal.SIGKILL
            # Repeated discovery catches children forked by TERM handlers and
            # newly adopted orphans, including those in separate sessions.
            for record in found.values():
                key = (*identity(record), int(sig))
                if key in sent or record['state'] == 'Z':
                    continue
                try:
                    if signal_owned(record, self.owner, sig):
                        actions.append(dict(pid=record['pid'], start=record['start'], signal=int(sig)))
                        sent.add(key)
                except OSError as exc:
                    if exc.errno != errno.ESRCH:
                        errors.append(str(exc))
            time.sleep(0.05)

    def run(self, command, log, limit, cwd=ROOT):
        if direct_children(self.owner):
            raise RuntimeError('unclaimed child processes before test; refusing to mix process trees')
        result = dict(exit_code=None, timeout=False, cancelled=False, harness_error=None,
                      cleanup=dict(complete=True, signals=[], errors=[], remaining=[]), leaked_descendants=[])
        proc = None
        try:
            if self.cancel_signal is not None:
                result['cancelled'] = True
                return result
            proc = subprocess.Popen(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + limit
            while proc.poll() is None:
                if self.cancel_signal is not None:
                    result['cancelled'] = True
                    break
                if time.monotonic() >= deadline:
                    result['timeout'] = True
                    break
                time.sleep(0.05)
            if not result['timeout'] and not result['cancelled']:
                result['leaked_descendants'] = [r for r in self.remaining(proc).values() if r['state'] != 'Z']
        except Exception as exc:
            result['harness_error'] = repr(exc)
        finally:
            if proc is not None:
                try:
                    result['cleanup'] = self.cleanup(proc)
                except Exception as exc:
                    result['cleanup'] = dict(complete=False, signals=[], errors=[repr(exc)], remaining=[])
                result['exit_code'] = proc.poll()
            result['cancelled'] = result['cancelled'] or self.cancel_signal is not None
        return result


def evidence_directory(requested):
    raw = str(requested.expanduser().absolute())
    if os.path.normpath(raw) != raw or os.path.commonpath((raw, str(ROOT))) == str(ROOT):
        raise ValueError('evidence must use a normalized path outside the source repository')
    path = Path(raw)
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(path.parts[1:], 1):
            parent = os.fstat(fd)
            if parent.st_uid not in (0, os.geteuid()) or parent.st_mode & 0o022:
                raise ValueError('evidence parent is writable by another user')
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
            except FileExistsError:
                if index == len(path.parts)-1:
                    raise ValueError('evidence directory must be new')
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        leaf = os.fstat(fd)
        if leaf.st_uid != os.geteuid() or stat.S_IMODE(leaf.st_mode) != 0o700:
            raise ValueError('evidence directory must be private and owned by the test user')
    finally:
        os.close(fd)
    return path


def source_hashes():
    files = [p for folder in ("modules", "scripts", "tests", "web")
             for p in (ROOT / folder).rglob("*") if p.is_file() and "__pycache__" not in p.parts]
    files.extend((ROOT / "toolbox.sh", ROOT / "docs/index.html"))
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new evidence directory")
    parser.add_argument("--only", nargs="*", help="test basenames, for focused reruns")
    args = parser.parse_args()
    os.umask(0o077)
    args.output = evidence_directory(args.output)
    sources = source_hashes()
    commands = [("syntax", ["bash", "-c", 'for f in toolbox.sh modules/*.sh tests/*.sh scripts/*.sh; do bash -n "$f" || exit; done'], 60)]
    limits = {"alpine-swap-test.sh": 1200, "vmess-management-test.sh": 5400, "docker-ipv6-test.sh": 1800,
              "reinstall-test.sh": 900, "webssh-containers-test.sh": 5400,
              "tls-acme-test.sh": 1800, "webssh-test.sh": 5400}
    commands.extend((p.name, ["bash", str(p)], limits.get(p.name, 600))
                    for p in sorted((ROOT / "tests").glob("*-test.sh")))
    commands.extend((name, ["python3", str(ROOT / "tests" / name)], 180)
                    for name in ("regression-runner-test.py", "menu-test.py", "entry-feedback-test.py", "docker-origin-test.py", "deploy-cloudflare-test.py", "certificate-recovery-test.py"))
    commands.append(("worker-test.mjs", ["node", str(ROOT / "tests/worker-test.mjs")], 60))
    if args.only:
        known = {c[0] for c in commands}
        if set(args.only) - known:
            parser.error("unknown tests: " + ", ".join(sorted(set(args.only) - known)))
        commands = [c for c in commands if c[0] in args.only]
    results = []
    summary = args.output / "summary.json"
    with Supervisor() as supervisor:
        for name, command, limit in commands:
            if supervisor.cancel_signal is not None:
                break
            started = time.monotonic()
            with (args.output / (name + ".log")).open("xb") as log:
                execution = supervisor.run(command, log, limit)
            clean = execution['cleanup']['complete'] and not execution['leaked_descendants']
            failed = execution['timeout'] or execution['cancelled'] or execution['harness_error'] or not clean
            code = execution['exit_code']
            result = dict(test=name, command=command, **execution,
                          timeout_seconds=limit, elapsed_seconds=round(time.monotonic() - started, 2),
                          status="passed" if code == 0 and not failed else "skipped" if code == 77 and not failed else "failed")
            results.append(result)
            summary.write_text(json.dumps(dict(source_sha256=sources, results=results), indent=2) + "\n")
            print(f"{result['status'].upper()} {name} ({result['elapsed_seconds']}s)", flush=True)
            if supervisor.cancel_signal is not None or not execution['cleanup']['complete']:
                break  # Never run another test beside an unproved leftover tree.
        cancelled = supervisor.cancel_signal
    after = source_hashes()
    changed = sorted(k for k in sources.keys() | after.keys() if sources.get(k) != after.get(k))
    summary.write_text(json.dumps(dict(source_sha256=sources, source_sha256_after=after,
                                      changed_sources=changed, cancelled_signal=cancelled,
                                      planned_tests=len(commands), results=results), indent=2) + "\n")
    if changed:
        print("SOURCE CHANGED: " + ", ".join(changed), flush=True)
    raise SystemExit(128 + cancelled if cancelled else
                     0 if len(results) == len(commands) and all(r["status"] == "passed" for r in results) and not changed else 1)


if __name__ == "__main__":
    main()
