#!/usr/bin/env python3
"""Exercise real offline APT using explicitly synthetic indexes and real fixture debs.
No network or package installation; privileged production commands are intercepted.
"""
from pathlib import Path
import hashlib
import os
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = Path(os.environ.get('TOOLBOX_TEST_TMPDIR', Path.home() / '.cache/terry-toolbox-tests'))
SCRATCH.mkdir(mode=0o700, parents=True, exist_ok=True)
PACKAGES = ('docker-ce', 'docker-ce-cli', 'containerd.io', 'docker-buildx-plugin', 'docker-compose-plugin')
VERSION = '5:29.1.1-1~debian.13~trixie'
with tempfile.TemporaryDirectory(prefix='toolbox-apt-origin-test.', dir=SCRATCH) as tmp:
    r = Path(tmp)
    env = {'HOME': str(r / 'home'), 'TMPDIR': str(r), 'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'}
    # Explicit /usr/bin APT calls below only simulate/print fixture URIs;
    # production execution must stay behind the shell mocks or these deny files.
    deny = r / 'package-deny'
    deny.mkdir()
    package_log = r / 'package-boundary.log'
    for name in ('sudo', 'apt', 'apt-get', 'aptitude', 'apk', 'dpkg', 'dpkg-query', 'dpkg-deb', 'dnf', 'yum', 'rpm'):
        target = deny / name
        target.write_text('#!/bin/sh\nprintf "%s\\n" "$0 $*" >> ' + shlex.quote(str(package_log)) + '\nexit 99\n')
        target.chmod(0o755)
    env['PATH'] = str(deny) + ':/usr/bin:/bin'
    for probe_env in (env, {'PATH': env['PATH']}):
        probe = subprocess.run(['/usr/bin/bash', '--noprofile', '--norc', '-c', 'apt-get --fixture-guard-probe'], env=probe_env, capture_output=True)
        assert probe.returncode == 99, probe
    assert len(package_log.read_text().splitlines()) == 2
    package_log.unlink()
    for sub in ('home', 'etc/apt/sources.list.d', 'etc/apt/preferences.d', 'var/lib/dpkg',
                'var/lib/apt/lists/partial', 'var/cache/apt/archives/partial', 'fixtures', 'captured'):
        (r / sub).mkdir(parents=True, exist_ok=True)
    (r / 'var/lib/dpkg/status').write_text('')
    (r / 'os-release').write_text('ID=debian\nVERSION_CODENAME=trixie\n')
    (r / 'etc/apt/sources.list').write_text('deb [trusted=yes] http://mirror.fixture.invalid/linux/debian trixie stable\n')
    for pkg in PACKAGES:
        control = r / f'build-{pkg}/DEBIAN'
        control.mkdir(parents=True)
        control.chmod(0o755)  # dpkg requires this even with the private runner's umask.
        (control / 'control').write_text(f'Package: {pkg}\nVersion: {VERSION}\nArchitecture: amd64\nMaintainer: offline fixture\nDescription: synthetic empty package, never installed\n')
        subprocess.run(['/usr/bin/dpkg-deb', '--build', str(control.parent), str(r / f'fixtures/{pkg}.deb')],
                       env=env, check=True, capture_output=True)
    commands = r / 'apt-commands'
    harness = r / 'harness.sh'
    harness.write_text('''#!/usr/bin/env bash
set -euo pipefail
source "$MODULE"
_toolbox_system_root() { :; }
_toolbox_system_os() { printf 'debian\\n'; }
_toolbox_system_has() { [[ $1 != docker ]]; }
_toolbox_system_package_installed() { return 1; }
_toolbox_system_missing_packages() { missing_packages=(); }
_toolbox_system_confirm() { :; }
_toolbox_system_docker_verify() { :; }
dpkg() { printf 'amd64\\n'; }
# Real metadata checks are read-only and restricted to the captured fixture debs.
dpkg-deb() {
 [[ $# == 3 && $1 == --show && $2 == '--showformat=${Package} ${Version} ${Architecture}' && $3 == "$TMPDIR/"*.deb ]] || return 99
 /usr/bin/dpkg-deb "$@"
}
apt-cache() { printf '%s:\\n  Candidate: (none)\\n' "${*: -1}"; }
curl() {
 local out=''
 while (( $# )); do case $1 in -o) out=$2; shift 2;; *) shift;; esac; done
 printf 'synthetic key fixture\\n' > "$out"
}
gpg() { printf 'pub:-:4096:1:fixture:0:0::-:::scSC:\\nfpr:::::::::%s:\\n' "$_TOOLBOX_DOCKER_GPG_FINGERPRINT"; }
apt-get() {
 printf '%q ' "$@" >> "$COMMANDS"; printf '\\n' >> "$COMMANDS"
 local a
 if [[ " $* " == *' download '* ]]; then cp -- "$FIXTURES/"*.deb ./; fi
 for a in "$@"; do [[ $a != /*.deb ]] || cp -- "$a" "$CAPTURED/"; done
 return 0
}
_toolbox_system_docker
''')
    hen = dict(env, MODULE=str(ROOT / 'modules/system.sh'), COMMANDS=str(commands),
               FIXTURES=str(r / 'fixtures'), CAPTURED=str(r / 'captured'),
               TOOLBOX_DOCKER_OS_RELEASE=str(r / 'os-release'), TOOLBOX_DOCKER_APT_ROOT=str(r / 'etc/apt'),
               TOOLBOX_DOCKER_DATA_ROOT=str(r / 'docker-data'))
    p = subprocess.run(['/usr/bin/bash', str(harness)], env=hen, capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError(f'production harness failed {p.returncode}: {p.stdout} {p.stderr}')
    rows = [shlex.split(line) for line in commands.read_text().splitlines()]
    download = next((row for row in rows if 'download' in row), None)
    install = next(row for row in rows if 'install' in row and any('docker-ce' in arg for arg in row))
    baseline = ['-o', f'Dir={r}', '-o', f'Dir::Etc={r}/etc/apt', '-o', f'Dir::State={r}/var/lib/apt',
                '-o', f'Dir::State::status={r}/var/lib/dpkg/status', '-o', f'Dir::Cache={r}/var/cache/apt',
                '-o', 'Dir::Cache::pkgcache=', '-o', 'Dir::Cache::srcpkgcache=',
                '-o', 'APT::Architecture=amd64', '-o', 'APT::Architectures::=amd64', '-o', 'Debug::NoLocking=1']
    private = next((arg.split('=', 1)[1] for arg in download or [] if arg.startswith('Dir::State::lists=')), None)
    cache = Path(private) if private else r / 'var/lib/apt/lists'
    (cache / 'partial').mkdir(parents=True, exist_ok=True)

    def index(folder, prefix, version, origin):
        (folder / f'{prefix}_dists_trixie_Release').write_text(f'Origin: {origin}\nLabel: {origin}\nSuite: trixie\nCodename: trixie\nArchitectures: amd64\nComponents: stable\n')
        records = ''
        for name in PACKAGES:
            data = (r / f'fixtures/{name}.deb').read_bytes()
            records += f'Package: {name}\nVersion: {version}\nArchitecture: amd64\nMaintainer: fixture\nFilename: pool/{name}.deb\nSize: {len(data)}\nSHA256: {hashlib.sha256(data).hexdigest()}\nDescription: synthetic resolver fixture\n\n'
        (folder / f'{prefix}_dists_trixie_stable_binary-amd64_Packages').write_text(records)

    for foreign in (VERSION, '5:99.0.0-1~debian.13~trixie'):
        global_lists = r / 'var/lib/apt/lists'
        index(global_lists, 'mirror.fixture.invalid_linux_debian', foreign, 'UnverifiedMirror')
        index(global_lists, 'download.docker.com_linux_debian', VERSION, 'Docker')
        index(cache, 'download.docker.com_linux_debian', VERSION, 'Docker')
        if download:
            result = subprocess.run(['/usr/bin/apt-get', *baseline, '--print-uris', *download], env=env,
                                    cwd=r / 'captured', capture_output=True, text=True)
            uris = [line for line in result.stdout.splitlines() if line.startswith("'")]
            if result.returncode or len(uris) != len(PACKAGES) or any(not line.startswith("'https://download.docker.com/") for line in uris):
                raise RuntimeError(f'foreign download accepted: {result.stdout} {result.stderr}')
            install_argv = [str(r / 'captured' / Path(arg).name) if arg.endswith('.deb') else arg for arg in install]
        else:
            install_argv = install
        result = subprocess.run(['/usr/bin/apt-get', *baseline, '--simulate', *install_argv],
                                env=env, capture_output=True, text=True)
        inst = [line for line in result.stdout.splitlines() if line.startswith('Inst ')]
        if result.returncode or len(inst) != len(PACKAGES) or any('99.0.0' in line for line in inst):
            raise RuntimeError(f'foreign Docker version accepted: {result.stdout} {result.stderr}')
        apt_config = r / 'apt-root.conf'
        apt_config.write_text(f'Dir "{r}"; Dir::Etc "{r}/etc/apt"; Dir::State "{r}/var/lib/apt"; Dir::State::status "{r}/var/lib/dpkg/status"; Dir::Cache "{r}/var/cache/apt"; Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache ""; APT::Architecture "amd64";')
        gate_env = dict(env, APT_CONFIG=str(apt_config), MODULE=str(ROOT / 'modules/system.sh'))
        gate = subprocess.run(['/usr/bin/bash', '-c', 'source "$MODULE"; _toolbox_system_docker_global_candidates_absent'],
                              env=gate_env, capture_output=True, text=True)
        if gate.returncode == 0 or '全局 APT 已有 docker-ce' not in gate.stderr:
            raise RuntimeError(f'production collision gate failed to prove refusal for {foreign}: {gate.stdout} {gate.stderr}')
        print(f'PASS real offline APT + production refusal: foreign same/higher-version fixture {foreign}')
    for entry in (r / 'var/lib/apt/lists').iterdir():
        if entry.is_file():
            entry.unlink()
    gate = subprocess.run(['/usr/bin/bash', '-c', 'source "$MODULE"; _toolbox_system_docker_global_candidates_absent'],
                          env=gate_env, capture_output=True, text=True)
    if gate.returncode:
        raise RuntimeError(f'clean global index refused: {gate.stdout} {gate.stderr}')
    result = subprocess.run(['/usr/bin/apt-get', *baseline, '--simulate', *install_argv], env=env, capture_output=True, text=True)
    if result.returncode or len([line for line in result.stdout.splitlines() if line.startswith('Inst ')]) != len(PACKAGES):
        raise RuntimeError(f'clean local deb resolver failed: {result.stdout} {result.stderr}')
    uris = subprocess.run(['/usr/bin/apt-get', *baseline, '--print-uris', *install_argv], env=env, capture_output=True, text=True)
    if uris.returncode or 'mirror.fixture.invalid' in uris.stdout:
        raise RuntimeError(f'clean local archive selection failed: {uris.stdout} {uris.stderr}')
    print('PASS real offline APT: clean global index installs only captured official-path fixture debs')
    global_lists = r / 'var/lib/apt/lists'
    index(global_lists, 'mirror.fixture.invalid_linux_debian', VERSION, 'UnverifiedMirror')
    (r / 'etc/apt/preferences').write_text('Package: docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin\nPin: version *\nPin-Priority: -1\n')
    gate = subprocess.run(['/usr/bin/bash', '-c', 'source "$MODULE"; _toolbox_system_docker_global_candidates_absent'],
                          env=gate_env, capture_output=True, text=True)
    if gate.returncode == 0 or '全局 APT 已有 docker-ce' not in gate.stderr:
        raise RuntimeError(f'pinned-out indexed vendor refusal not verified: {gate.stdout} {gate.stderr}')
    print('PASS real offline APT: pinned-out (Candidate none) foreign indexes still refused')
    print('Synthetic indexes/empty debs only; no download, installation or host APT changes.')
    assert not package_log.exists(), package_log.read_text()
