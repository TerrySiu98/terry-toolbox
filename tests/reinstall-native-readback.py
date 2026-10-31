#!/usr/bin/env python3
"""Read-only proof after controller-authenticated SSH to a reinstalled VM.

Pass the BEFORE manifest copied off the disposable VM and the same PUBLIC key.
SSH key authentication itself must be enforced by the controller (IdentitiesOnly,
BatchMode, password disabled). This script does not reboot or write a disk.
"""
import base64
import hashlib
import json
import os
import pathlib
import subprocess
import sys

if len(sys.argv) != 3:
    sys.exit('Usage: reinstall-native-readback.py before.json absolute-key.pub')
before = json.load(open(sys.argv[1]))
assert os.geteuid() == 0, 'SSH must authenticate the expected root account'
release = {}
for line in pathlib.Path('/etc/os-release').read_text().splitlines():
    if '=' in line:
        key, value = line.split('=', 1)
        release[key] = value.strip('"')
assert release['ID'] == before['target'], 'installed distribution mismatch'
version = release['VERSION_ID']
assert version == before['version'] or version.startswith(before['version'] + '.'), 'installed version mismatch'
assert pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip() != before['old_boot_id'], 'no real boot occurred'
machine_id = pathlib.Path('/etc/machine-id')
assert not machine_id.exists() or machine_id.read_text().strip() != before['old_machine_id'], 'old machine identity survived'
assert not pathlib.Path('/root/.terry-toolbox-old-system-nonce').exists(), 'old disk filesystem nonce survived'
public = pathlib.Path(sys.argv[2]).read_text().split()[:2]
assert hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest() == before['key_sha256'], 'controller public key differs from before manifest'
assert public[0] == 'ssh-ed25519' and base64.b64decode(public[1], validate=True), 'invalid public key'
authorized = [line.split()[:2] for line in pathlib.Path('/root/.ssh/authorized_keys').read_text().splitlines() if line.strip()]
assert public in authorized, 'installed root key differs'
sshd = next((p for p in ('/usr/sbin/sshd', '/sbin/sshd') if pathlib.Path(p).exists()), None)
assert sshd, 'installed SSH daemon absent'
config = dict(line.split(None, 1) for line in subprocess.check_output([sshd, '-T'], text=True).splitlines() if ' ' in line)
assert config.get('passwordauthentication') == 'no', 'password SSH unexpectedly enabled'
assert config.get('kbdinteractiveauthentication', 'no') == 'no', 'interactive password SSH unexpectedly enabled'
assert config.get('permitrootlogin') in ('prohibit-password', 'without-password'), 'root SSH is not restricted to keys'
# Some installed kernels enumerate an empty legacy floppy as TYPE=disk. Linux
# major 2 is the floppy driver; exclude it while retaining every actual disk.
inventory = json.loads(subprocess.check_output(['lsblk', '--exclude', '2', '--json', '--bytes', '--paths', '--output', 'NAME,TYPE,SERIAL,SIZE'], text=True))
disks = [d for d in inventory['blockdevices'] if d['type'] == 'disk']
assert len(disks) == 1 and disks[0]['name'] == before['disk']['name'] and disks[0]['size'] == before['disk']['size'], 'reinstalled VM disk identity differs from disposable guest'
# Alpine uses mdev and lsblk may have no udev serial property. The virtio disk
# exposes the authoritative serial in sysfs on every tested target.
serial = (pathlib.Path('/sys/class/block') / pathlib.Path(disks[0]['name']).name / 'serial').read_text().strip()
assert serial == before['disk']['serial'] and disks[0]['serial'] in (None, serial), 'reinstalled VM disk serial differs from disposable guest'
# Alpine's RAM installer also exposes the requested release and root SSH key.
# It is not installation success: require the running / filesystem to come from
# a partition on the verified disposable disk before accepting the SSH readback.
mounted = json.loads(subprocess.check_output(['findmnt', '--json', '--target', '/', '--output', 'TARGET,SOURCE,FSTYPE,OPTIONS'], text=True))['filesystems']
assert len(mounted) == 1 and mounted[0]['target'] == '/' and mounted[0]['fstype'] in ('ext2', 'ext3', 'ext4', 'xfs') and 'rw' in mounted[0]['options'].split(','), 'SSH reached a live installer or unsupported root filesystem'
partitions = []
def walk(nodes):
    for node in nodes:
        if node['type'] == 'part':
            partitions.append(node['name'])
        walk(node.get('children', []))
walk(disks[0].get('children', []))
assert mounted[0]['source'] in partitions, 'running root is not installed on the disposable disk'
assert pathlib.Path('/boot').is_dir() and any(p.is_file() for p in pathlib.Path('/boot').glob('vmlinuz*')), 'installed boot kernel absent'
print(json.dumps({'result': 'PASS', 'guest_id': before['guest_id'], 'distribution': release['ID'], 'version': version, 'new_boot_id': pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(), 'root_device': mounted[0]['source'], 'old_filesystem_nonce_absent': True, 'root_key_matches': True, 'password_ssh_disabled': True}, sort_keys=True))
