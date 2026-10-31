#!/usr/bin/env bash
# B19: source-only, independent Alpine/OpenRC swap. No fstab/sysctl/systemd edits.
# API: toolbox_alpine_swap install [128..8192 MiB] | status | uninstall
# Optional fixture paths (absolute, canonical, root-owned, no symlink ancestors):
# TOOLBOX_ALPINE_SWAP_ROOT       /var/lib/terry-toolbox-alpine-swap
# TOOLBOX_ALPINE_SWAP_INITD      /etc/init.d
# TOOLBOX_ALPINE_SWAP_CONFD      /etc/conf.d
# TOOLBOX_ALPINE_SWAP_RUNLEVELS  /etc/runlevels
# TOOLBOX_ALPINE_SWAP_LOCK       /run/terry-toolbox-alpine-swap.lock
# TOOLBOX_ALPINE_SWAP_OS_RELEASE /etc/os-release
# TOOLBOX_ALPINE_SWAP_OPENRC_RUN /run/openrc
# TOOLBOX_ALPINE_SWAP_SWAPS      /proc/swaps
# TOOLBOX_ALPINE_SWAP_MOUNTINFO  /proc/self/mountinfo
# Read-only exceptions: etc/os-release may point exactly to ../usr/lib/os-release
# or /usr/lib/os-release in the same fixture tree; OPENRC_RUN may be root:root 0775.
# Its state files and all write paths retain the strict checks above.
# Overrides are explicit test boundaries, NOT kernel isolation. Never point mocks
# at host paths. Runtime freezes these paths and command locations at installation.
# Concurrency: outer /run lock serializes installers; private runtime.lock uses
# nonblocking flock for runtime operations. Installer NEVER holds runtime.lock
# while synchronously calling rc-service. Before stop it seals phase=retiring
# under runtime.lock: all later/queued starts refuse, even after lock release.
# The outer lock is deliberately retained after uninstall (never unlink a lock).
# Ownership is inode/dev/mode/nlink/size + swap UUID and immutable first page;
# NOT a whole-swap hash. Root-only paths prevent unprivileged path races; concurrent
# hostile root can defeat any userspace precheck and is outside this guarantee.
# Remember only the source directory; dependency work remains lazy. Bundles
# already contain the core and must never look beside the downloaded script.
_TOOLBOX_ALPINE_SWAP_MODULE_DIR=''
if [[ ${TOOLBOX_BUNDLED:-0} != 1 ]]; then
    case ${BASH_SOURCE[0]} in
        */*) _TOOLBOX_ALPINE_SWAP_MODULE_DIR=${BASH_SOURCE[0]%/*};;
        *) _TOOLBOX_ALPINE_SWAP_MODULE_DIR=.;;
    esac
    _TOOLBOX_ALPINE_SWAP_MODULE_DIR=$(CDPATH= builtin cd -- "$_TOOLBOX_ALPINE_SWAP_MODULE_DIR" && builtin pwd -P) || _TOOLBOX_ALPINE_SWAP_MODULE_DIR=''
fi

_toolbox_alpine_swap_engine() {
    cat <<'PY'
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import uuid

NAME = 'terry-toolbox-alpine-swap'
PAGE = os.sysconf('SC_PAGE_SIZE')
DEFAULTS = dict(ROOT='/var/lib/'+NAME, INITD='/etc/init.d', CONFD='/etc/conf.d',
                RUNLEVELS='/etc/runlevels', LOCK='/run/'+NAME+'.lock',
                OS_RELEASE='/etc/os-release', OPENRC_RUN='/run/openrc',
                SWAPS='/proc/swaps', MOUNTINFO='/proc/self/mountinfo')
RUNTIME = 'CONFIG' in globals()
C = CONFIG if RUNTIME else {k: os.environ.get('TOOLBOX_ALPINE_SWAP_'+k, v)
                            for k, v in DEFAULTS.items()}
ROOT = C['ROOT']
SWAP = ROOT+'/swapfile'
MANIFEST = ROOT+'/manifest'
HELPER = ROOT+'/runtime.py'
RLOCK = ROOT+'/runtime.lock'
SERVICE = C['INITD']+'/'+NAME
LINK = C['RUNLEVELS']+'/default/'+NAME
REQUIRED = ('python3', 'cat', 'flock', 'dd', 'mkswap', 'swapon', 'swapoff', 'rc-service', 'openrc-run')
COMMANDS = C.get('commands', {})

class Refusal(Exception):
    pass

def require(ok, text):
    if not ok:
        raise Refusal(text)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def exists(path):
    return os.path.lexists(path)

def safe_path(path, leaf=True, *, openrc_state=False):
    if path == '/proc/self/mountinfo':
        path = '/proc/'+str(os.getpid())+'/mountinfo'
    require(isinstance(path, str) and re.fullmatch(r'/[A-Za-z0-9_./-]+', path)
            and os.path.normpath(path) == path, '不安全路径: '+str(path))
    parts = path.split('/')[1:]
    current = ''
    result = []
    for part in (parts if leaf else parts[:-1]):
        current += '/'+part
        s = os.lstat(current)
        # Official OpenRC grants gid 0 write access to its state directory.
        # Trust that existing authority only for this read-only check; this does
        # not defend against hostile root/root-group OpenRC state writers.
        openrc_directory = (openrc_state and current == C['OPENRC_RUN']
                            and stat.S_ISDIR(s.st_mode) and s.st_gid == 0
                            and stat.S_IMODE(s.st_mode) == 0o775)
        require(not stat.S_ISLNK(s.st_mode) and s.st_uid == 0
                and (not s.st_mode & 0o022 or openrc_directory),
                '路径必须 root-owned、不可组/其他写且无符号链接: '+current)
        if current != path or not leaf:
            require(stat.S_ISDIR(s.st_mode), '祖先不是目录: '+current)
        result.append((current, s.st_dev, s.st_ino, stat.S_IMODE(s.st_mode)))
    return result

def identity(path, directory=False):
    safe_path(path)
    s = os.lstat(path)
    require(stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode),
            '资源类型变化: '+path)
    if not directory:
        require(s.st_nlink == 1, '硬链接冲突: '+path)
    return dict(dev=s.st_dev, ino=s.st_ino, uid=s.st_uid, mode=stat.S_IMODE(s.st_mode),
                **({} if directory else dict(nlink=s.st_nlink, size=s.st_size)))

def read_bytes(path, *, openrc_state=False):
    if path == '/proc/self/mountinfo':
        path = '/proc/'+str(os.getpid())+'/mountinfo'
    safe_path(path, openrc_state=openrc_state)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode), '不是普通文件: '+path)
        with os.fdopen(fd, 'rb', closefd=False) as f:
            return f.read()
    finally:
        os.close(fd)

def os_release_path():
    path = C['OS_RELEASE']
    safe_path(path, leaf=False)
    s = os.lstat(path)
    if stat.S_ISLNK(s.st_mode):
        require(path.endswith('/etc/os-release') and s.st_uid == 0
                and os.readlink(path) in ('../usr/lib/os-release', '/usr/lib/os-release'),
                '不安全 os-release 链接: '+path)
        # An overridden fixture /etc lives under its own root. Read the matching
        # usr/lib leaf directly, even for the canonical absolute link spelling;
        # never follow a fixture link into the host's /usr/lib.
        path = path[:-len('/etc/os-release')]+'/usr/lib/os-release'
    safe_path(path)
    require(stat.S_ISREG(os.lstat(path).st_mode), 'os-release 不是普通文件: '+path)
    return path

def cmd(name, *args, **kwargs):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('RC_', 'EINFO_', 'IN_BACKGROUND'))}
    env.update(LC_ALL='C', NO_COLOR='1', RC_COLOR='NO')
    return subprocess.run([COMMANDS[name], *args], env=env, check=False,
                          stderr=subprocess.PIPE, **kwargs)

def service(action):
    resolved = cmd('rc-service', '-r', NAME, stdout=subprocess.PIPE)
    require(resolved.returncode == 0 and resolved.stdout.decode().strip() == SERVICE,
            'OpenRC 服务解析路径变化，拒绝操作')
    p = cmd('rc-service', '-D', NAME, action, stdout=subprocess.PIPE)
    text = (p.stdout+p.stderr).decode(errors='replace')
    if action == 'status':
        if p.returncode == 0 and re.search(r'\bstatus:\s*started\b', text):
            return 'started'
        if p.returncode == 3 and re.search(r'\bstatus:\s*stopped\b', text):
            return 'stopped'
        raise Refusal('OpenRC 状态未知/过渡/故障，保留现场: '+text.strip())
    require(p.returncode == 0, 'rc-service '+action+' 失败，保留现场: '+text.strip())

def swap_table():
    # /proc files are regular files despite their zero st_size. Never infer absence
    # from a failed read, an empty table, a duplicate target, or malformed rows.
    lines = read_bytes(C['SWAPS']).decode('ascii').splitlines()
    require(lines and lines[0].split() == ['Filename','Type','Size','Used','Priority'],
            '无法可靠读取 /proc/swaps 表头')
    rows = {}
    for line in lines[1:]:
        fields = line.split()
        require(len(fields) == 5 and fields[2].isdigit() and fields[3].isdigit()
                and re.fullmatch(r'-?[0-9]+', fields[4]), '损坏的 /proc/swaps 行')
        path = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), fields[0])
        require(path not in rows, '重复 swap 成员')
        rows[path] = (fields[1], int(fields[2]))
    return rows

def kernel(file_size=None):
    rows = swap_table()
    if file_size is None:
        require(SWAP not in rows, '内核仍含目标 swap，保留现场')
    else:
        member = rows.get(SWAP)
        require(member is not None and member[0] == 'file', '内核 swap 路径/类型不匹配')
        # /proc/swaps reports usable KiB, not file length minus its header:
        # ext4 physical extent alignment can discard additional pages.
        usable = member[1]*1024
        require(0 < usable <= file_size-PAGE and usable % PAGE == 0,
                '内核 swap 可用容量无效或超过文件容量上界')

def filesystem(path, size=0):
    entries = []
    for line in read_bytes(C['MOUNTINFO']).decode().splitlines():
        left, sep, right = line.partition(' - ')
        a, b = left.split(), right.split()
        require(sep and len(a) >= 6 and len(b) >= 3, 'mountinfo 不可解析')
        mount = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), a[4])
        if path == mount or path.startswith(mount.rstrip('/')+'/'):
            entries.append((len(mount), a, b))
    require(entries, '不能确定持久文件系统')
    _, a, b = max(entries, key=lambda row: row[0])
    s = os.stat(path)
    require(a[2] == str(os.major(s.st_dev))+':'+str(os.minor(s.st_dev))
            and b[0] == 'ext4' and 'rw' in a[5].split(',') and 'rw' in b[2].split(','),
            '仅支持可写持久 ext4；拒绝 tmpfs/overlay/btrfs/NFS/未知挂载')
    fs = os.statvfs(path)
    if size:
        require(fs.f_bavail * fs.f_frsize >= size + 16*1024*1024, 'ext4 可用空间不足（需额外 16 MiB）')

def prerequisites():
    require(os.geteuid() == 0, '需要 root')
    for key in DEFAULTS:
        if key == 'OS_RELEASE':
            os_release = os_release_path()
        else:
            safe_path(C[key], leaf=key not in ('ROOT', 'LOCK'), openrc_state=key == 'OPENRC_RUN')
    require(len(set(C[k] for k in DEFAULTS)) == len(DEFAULTS), '路径 override 冲突')
    require(os.path.dirname(ROOT) not in (C['INITD'], C['CONFD'], C['RUNLEVELS']), '数据路径冲突')
    require(os.path.basename(C['LOCK']) != '', 'lock 路径错误')
    for command in REQUIRED:
        resolved = COMMANDS.get(command) if RUNTIME else shutil.which(command)
        require(resolved and os.path.isfile(resolved) and os.access(resolved, os.X_OK),
                '运行时仍缺少必要命令: '+command+'；请检查依赖安装结果和命令路径')
        require(re.fullmatch(r'/[A-Za-z0-9_./-]+', resolved), '命令路径不安全: '+command)
        safe_path(os.path.realpath(resolved))
        COMMANDS[command] = resolved
    ids = re.findall(r'^ID=(.*)$', read_bytes(os_release).decode(), re.M)
    require(len(ids) == 1 and ids[0] in ('alpine', '"alpine"', "'alpine'"), '仅支持 ID=alpine')
    softlevel = C['OPENRC_RUN']+'/softlevel'
    require(exists(softlevel), '不是已启动的 OpenRC（缺少 softlevel）')
    read_bytes(softlevel, openrc_state=True)
    safe_path(C['RUNLEVELS']+'/default')
    if exists(C['LOCK']):
        require(identity(C['LOCK'])['mode'] == 0o600, '安装锁已有不安全权限')
    filesystem(ROOT if exists(ROOT) else os.path.dirname(ROOT))
    swap_table()

def conflicts(allowed_link=None):
    for entry in os.listdir(C['CONFD']):
        require(entry != NAME and not entry.startswith(NAME+'.'), '存在 conf.d override，拒绝接管')
    found = []
    for entry in os.listdir(C['RUNLEVELS']):
        directory = C['RUNLEVELS']+'/'+entry
        if os.path.isdir(directory):
            safe_path(directory)
            path = directory+'/'+NAME
            if exists(path):
                found.append(path)
    require(found == ([] if allowed_link is None else [LINK]), '同名 runlevel 条目变化/冲突')
    if allowed_link is not None:
        s = os.lstat(LINK)
        require(stat.S_ISLNK(s.st_mode) and s.st_uid == 0 and os.readlink(LINK) == SERVICE
                and [s.st_dev, s.st_ino] == allowed_link, '自启链接归属变化')

def fresh(size):
    prerequisites()
    conflicts()
    for path in (ROOT, SERVICE):
        require(not exists(path), 'fresh install only，拒绝已有目标: '+path)
    for state in os.listdir(C['OPENRC_RUN']):
        directory = C['OPENRC_RUN']+'/'+state
        if os.path.isdir(directory):
            require(not exists(directory+'/'+NAME), 'OpenRC 已有同名状态，拒绝接管')
    p = cmd('rc-service', '-e', NAME, stdout=subprocess.PIPE)
    require(p.returncode == 1, '同名 OpenRC 服务存在或查询失败')
    kernel()
    filesystem(os.path.dirname(ROOT), size)

def unique_json(pairs):
    result = {}
    for k, v in pairs:
        require(k not in result, 'manifest 重复键')
        result[k] = v
    return result

def load():
    raw = read_bytes(MANIFEST)
    m = json.loads(raw, object_pairs_hook=unique_json)
    require(m.get('version') == 1 and m.get('config') == {k:C[k] for k in DEFAULTS}
            and m.get('phase') in ('ready','retiring'), 'manifest 格式/路径/阶段不匹配')
    require(set(m['files']) == {SWAP, HELPER, RLOCK, SERVICE}, 'manifest 资源集合不匹配')
    validate(m)
    return m, raw

def validate(m):
    require(identity(ROOT, True) == m['directory'], '私有目录归属变化')
    require(identity(MANIFEST) == m['manifest_identity'], 'manifest inode/权限/大小变化')
    require(os.listdir(ROOT) and set(os.listdir(ROOT)) == {'swapfile','manifest','runtime.py','runtime.lock'},
            '私有目录有未知/缺失文件')
    for parent, expected in m['parents'].items():
        require([list(x) for x in safe_path(parent)] == expected, '祖先目录被替换: '+parent)
    for path, record in m['files'].items():
        require(identity(path) == record['identity'], '文件 inode/权限/大小变化: '+path)
        if path != SWAP:
            require(digest(read_bytes(path)) == record['sha256'], '脚本/配置内容变化: '+path)
    fd = os.open(SWAP, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        s = os.fstat(fd)
        header = os.read(fd, PAGE)
    finally:
        os.close(fd)
    require(s.st_blocks*512 >= s.st_size and digest(header) == m['header']
            and header[1036:1052].hex() == m['uuid'] and header[-10:] == b'SWAPSPACE2',
            'swap 分配/固定 header/UUID 归属变化')
    require(m['directory']['mode'] == 0o700 and m['files'][SWAP]['identity']['mode'] == 0o600,
            'swap 私有权限不匹配')
    conflicts(m['link'])

def check_snapshot(raw):
    m, current = load()
    require(current == raw, '确认后 manifest 改变')
    return m

@contextlib.contextmanager
def runtime_lock():
    fd = os.open(RLOCK, os.O_RDWR | os.O_NOFOLLOW)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require(identity(RLOCK)['ino'] == os.fstat(fd).st_ino, 'runtime lock 被替换')
        yield
    finally:
        os.close(fd)

# Same inode, fixed-length phase token; on interrupted/I/O-failed writes the
# manifest becomes invalid and ALL cleanup refuses. Never adopt a partial seal.
def seal(m, phase=None, link='unchanged'):
    before = read_bytes(MANIFEST)
    if phase is not None:
        m['phase'] = phase
    if link != 'unchanged':
        m['link'] = link
    # Self size reaches a fixed point (size digits may grow once).
    for _ in range(4):
        data = json.dumps(m, sort_keys=True).encode()+b'\n'
        if m['manifest_identity']['size'] == len(data):
            break
        m['manifest_identity']['size'] = len(data)
    data = json.dumps(m, sort_keys=True).encode()+b'\n'
    fd = os.open(MANIFEST, os.O_WRONLY | os.O_NOFOLLOW)
    try:
        s = os.fstat(fd)
        require((s.st_dev,s.st_ino) == (m['manifest_identity']['dev'],m['manifest_identity']['ino'])
                and read_bytes(MANIFEST) == before, 'manifest 写入前发生替换')
        require(os.write(fd, data) == len(data), 'manifest 部分写入；保留现场')
        os.ftruncate(fd, len(data))
        os.fsync(fd)
    finally:
        os.close(fd)
    require(read_bytes(MANIFEST) == data, 'manifest 写后验证失败')
    return data

def runtime(action):
    require(action in ('start','stop'), 'runtime 只支持 start/stop')
    prerequisites()
    with runtime_lock():
        m, _ = load()
        if action == 'start':
            require(m['phase'] == 'ready', '正在退役，拒绝启动')
            rows = swap_table()
            if SWAP not in rows:
                validate(m)
                p = cmd('swapon', SWAP, stdout=subprocess.PIPE)
                require(p.returncode == 0, 'swapon 失败: '+p.stderr.decode(errors='replace'))
            validate(m)
            kernel(m['files'][SWAP]['identity']['size'])
        else:
            rows = swap_table()
            if SWAP in rows:
                kernel(m['files'][SWAP]['identity']['size'])
                validate(m)
                p = cmd('swapoff', SWAP, stdout=subprocess.PIPE)
                require(p.returncode == 0, 'swapoff 失败（可能内存不足）；保留 swap: '+p.stderr.decode(errors='replace'))
            validate(m)
            kernel()

class Transaction:
    def __init__(self):
        self.parents = {p:[list(x) for x in safe_path(p)] for p in
                        (os.path.dirname(ROOT), C['INITD'], C['CONFD'], C['RUNLEVELS'], C['RUNLEVELS']+'/default')}
        self.claim = {}
        self.directory = None
        self.m = None
        self.raw = None
        self.possible_start = False
        self.link = None

    def create(self, path, content=b'', mode=0o600):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
        s = os.fstat(fd)
        record = dict(dev=s.st_dev, ino=s.st_ino, uid=s.st_uid, mode=stat.S_IMODE(s.st_mode), nlink=s.st_nlink, size=0)
        self.claim[path] = {'identity':record, 'sha256':digest(b'')}
        try:
            done = 0
            while done < len(content):
                n = os.write(fd, content[done:])
                require(n > 0, '零长度写入')
                done += n
                record['size'] = done
                self.claim[path]['sha256'] = digest(content[:done])
            os.fsync(fd)
        finally:
            os.close(fd)
        require(identity(path) == record and digest(read_bytes(path)) == digest(content), '新建资源 claim 不匹配')

    def early_validate(self):
        for parent, expected in self.parents.items():
            require([list(x) for x in safe_path(parent)] == expected, '本次祖先目录 claim 不匹配')
        require(self.directory is not None and identity(ROOT, True) == self.directory, '本次目录 claim 不匹配')
        require(set(os.listdir(ROOT)) == {os.path.basename(p) for p in self.claim if os.path.dirname(p) == ROOT},
                '早期回滚遇到未知文件，保留')
        for path, record in self.claim.items():
            require(identity(path) == record['identity'], '本次资源 claim 不匹配: '+path)
            if 'sha256' in record:
                require(digest(read_bytes(path)) == record['sha256'], '本次创建内容变化: '+path)
        require(not exists(SERVICE) or SERVICE in self.claim, '服务非本次创建')
        conflicts()
        kernel()

    def rollback(self):
        if self.directory is None:
            return
        if self.possible_start:
            require(self.raw is not None, '无法证明启用后事务归属，保留现场')
            m = check_snapshot(self.raw)
            # A separate per-attempt inode claim is required, not just a plausible
            # persistent manifest that raced into this path.
            require(m['directory'] == self.directory and all(
                m['files'][p]['identity'] == r['identity'] for p,r in self.claim.items()
                if p in m['files']), '本次 claim 与安装不匹配')
            remove_owned(m, self.raw)
        else:
            self.early_validate()
            for path in reversed(list(self.claim)):
                os.unlink(path)
            os.rmdir(ROOT)
        print('已回滚本次创建的资源。')

def remove_owned(m, raw):
    # Reject unknown/starting/stopping/inactive/crashed BEFORE asking OpenRC to stop.
    service('status')
    with runtime_lock():
        m = check_snapshot(raw)
        raw = seal(m, phase='retiring')
    # No inner lock across rc-service: the owned runtime must obtain it itself.
    service('stop')
    require(service('status') == 'stopped', 'stop 后不是准确 stopped，保留现场')
    kernel()
    with runtime_lock():
        m = check_snapshot(raw)
        require(service('status') == 'stopped', '删除前状态变化，保留现场')
        kernel()
        if m['link'] is not None:
            os.unlink(LINK)
        # Verify all leaves BEFORE any deletion; never recursive-delete a name.
        for path in (SERVICE, HELPER, SWAP, MANIFEST):
            os.unlink(path)
        os.unlink(RLOCK)
        os.rmdir(ROOT)

def install(size):
    tx = Transaction()
    try:
        os.mkdir(ROOT, 0o700)
        tx.directory = identity(ROOT, True)
        tx.create(SWAP)
        fd = os.open(SWAP, os.O_WRONLY | os.O_NOFOLLOW)
        try:
            require(os.fstat(fd).st_ino == tx.claim[SWAP]['identity']['ino'], 'swap claim 被替换')
            try:
                p = cmd('dd', 'if=/dev/zero', 'bs=1048576', 'count='+str(size//1048576), stdout=fd)
            finally:
                s = os.fstat(fd)
                tx.claim[SWAP]['identity']['size'] = s.st_size
                tx.claim[SWAP].pop('sha256', None)
            require(p.returncode == 0, 'dd 完整分配失败')
            os.fsync(fd)
            require(s.st_size == size and s.st_blocks*512 >= size, '拒绝稀疏/未完整分配 swapfile')
        finally:
            os.close(fd)
        tx.early_validate()
        p = cmd('mkswap', SWAP, stdout=subprocess.PIPE)
        require(p.returncode == 0, 'mkswap 失败')
        tx.early_validate()
        fd = os.open(SWAP, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            header = os.read(fd, PAGE)
        finally:
            os.close(fd)
        require(len(header) == PAGE and header[-10:] == b'SWAPSPACE2'
                and struct.unpack('=I', header[1024:1028])[0] == 1
                and struct.unpack('=I', header[1028:1032])[0] == size//PAGE-1
                and struct.unpack('=I', header[1032:1036])[0] == 0
                and header[1036:1052] != b'\0'*16, 'mkswap header/UUID 验证失败')
        config = {**C, 'commands':COMMANDS}
        code = ('CONFIG = '+repr(config)+'\n'+os.environ['TOOLBOX_ALPINE_SWAP_ENGINE']).encode()
        tx.create(HELPER, code)
        tx.create(RLOCK)
        tx.create(MANIFEST)
        tx.early_validate()
        parents = tx.parents
        script = (f'#!{COMMANDS["openrc-run"]}\n'
                  'description="Private toolbox swap (owned file only)"\n'
                  'depend() { need localmount; }\n'
                  f'start() {{ {COMMANDS["python3"]} {HELPER} runtime start; }}\n'
                  f'stop() {{ {COMMANDS["python3"]} {HELPER} runtime stop; }}\n'
                  'status() { _status; }\n').encode()
        # Publishing a service makes a concurrent external start possible. Set
        # this flag FIRST; any interruption now retains an incomplete manifest.
        tx.possible_start = True
        tx.create(SERVICE, script, 0o700)
        tx.m = dict(version=1, config={k:C[k] for k in DEFAULTS}, phase='ready',
                    directory=tx.directory, manifest_identity=identity(MANIFEST),
                    parents=parents, files={p:r for p,r in tx.claim.items() if p != MANIFEST},
                    header=digest(header), uuid=header[1036:1052].hex(), link=None)
        tx.raw = seal(tx.m)
        validate(tx.m)
        service('start')
        require(service('status') == 'started', 'start 后不是准确 started')
        kernel(size)
        with runtime_lock():
            check_snapshot(tx.raw)
            os.symlink(SERVICE, LINK)
            s = os.lstat(LINK)
            tx.link = [s.st_dev, s.st_ino]
            # Seal immediately, before any further fallible action. If this write
            # fails rollback refuses the mismatching snapshot and keeps evidence.
            tx.raw = seal(tx.m, link=tx.link)
            validate(tx.m)
        require(service('status') == 'started', '添加自启后服务状态变化')
        kernel(size)
        print('安装成功: '+SWAP+'；文件 '+str(size//1048576)+' MiB；OpenRC started；default 自启已回读。')
    except BaseException:
        try:
            tx.rollback()
        except BaseException as cleanup_error:
            print('安全回滚拒绝，保留现场: '+str(cleanup_error), file=sys.stderr)
        raise

def confirm(text):
    print(text+'（仅 YES，不区分大小写；空白/EOF/其他输入取消）: ', end='', flush=True)
    answer = sys.stdin.readline()
    require(answer.endswith('\n') and answer.rstrip('\r\n').lower() == 'yes', '已取消；未执行变更')

def preview(action, size=None):
    print('B19 精确变更预览: '+action)
    print('数据目录 0700: '+ROOT+'；swapfile 0600；manifest/runtime.py/runtime.lock')
    print('独占安装锁（保留）: '+C['LOCK'])
    print('仅服务: '+SERVICE+'；仅自启链接: '+LINK+' -> '+SERVICE)
    if size:
        print('完整分配 '+str(size//1048576)+' MiB；mkswap；仅 swapon '+SWAP)
    else:
        print('stop 自有服务，仅 swapoff '+SWAP+'；确认 stopped + 内核无成员后删除上述自有文件')
    print('不改 fstab/sysctl/B6/其他 swap/其他服务；不安装软件包。')

@contextlib.contextmanager
def installer_lock():
    safe_path(C['LOCK'], leaf=False)
    fd = os.open(C['LOCK'], os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        s = os.fstat(fd)
        require(stat.S_ISREG(s.st_mode) and s.st_uid == 0 and stat.S_IMODE(s.st_mode) == 0o600
                and s.st_nlink == 1, '安装锁类型/归属不安全')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require(identity(C['LOCK'])['ino'] == s.st_ino, '安装锁被替换')
        yield
        require(identity(C['LOCK'])['ino'] == s.st_ino, '安装锁被替换，需人工检查')
    finally:
        os.close(fd)

def main(args):
    if RUNTIME:
        require(len(args) == 2 and args[0] == 'runtime', 'runtime 参数错误')
        runtime(args[1])
        return
    require(len(args) <= 2, '用法: toolbox_alpine_swap install [size_mib] | status | uninstall')
    if not args:
        print('B19: install / status / uninstall（空白取消）: ', end='', flush=True)
        args = [sys.stdin.readline().rstrip('\r\n')]
    action = args[0]
    require(action in ('install','status','uninstall') and (len(args) == 1 or action == 'install'), '动作/参数错误；已取消')
    size = None
    if action == 'install':
        if len(args) == 1:
            print('swap 大小 MiB [默认建议 1024，须显式输入；空白/EOF 取消]: ', end='', flush=True)
            token = sys.stdin.readline().rstrip('\r\n')
        else:
            token = args[1]
        require(re.fullmatch(r'[1-9][0-9]{2,3}', token) and 128 <= int(token) <= 8192,
                '大小必须是 128..8192 MiB 十进制整数，无前导零；已取消')
        size = int(token)*1048576
        fresh(size)
    else:
        prerequisites()
        if not exists(ROOT):
            conflicts()
            require(not exists(SERVICE), '数据缺失但同名服务存在，拒绝接管')
            kernel()
            require(action == 'status', '尚未安装')
            print('未安装 B19 Alpine swap。')
            return
        m, raw = load()
        state = service('status')
        if state == 'started':
            kernel(m['files'][SWAP]['identity']['size'])
        else:
            kernel()
        if action == 'status':
            print('B19: '+state+'；phase='+m['phase']+'；default='+('yes' if m['link'] else 'no')+'；'+SWAP)
            return
    preview(action, size)
    confirm('第一次确认')
    confirm('第二次确认')
    with installer_lock():
        prerequisites()
        if action == 'install':
            fresh(size)
            install(size)
        else:
            m = check_snapshot(raw)
            remove_owned(m, raw)
            print('卸载成功；仅删除自有资源，安装锁保留。')

def interrupted(signum, frame):
    raise Refusal('收到信号 '+str(signum)+'；尝试安全回滚/保留')

if __name__ == '__main__':
    os.umask(0o077)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        main(sys.argv[1:])
    except (Exception, KeyboardInterrupt) as error:
        print('B19 拒绝/失败: '+str(error), file=sys.stderr)
        sys.exit(1)
PY
}

toolbox_alpine_swap() {
    local code dependency
    for dependency in python3 cat flock dd mkswap swapon swapoff rc-service openrc-run; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            declare -F toolbox_require_commands >/dev/null || { [[ -n ${_TOOLBOX_ALPINE_SWAP_MODULE_DIR:-} ]] && source "$_TOOLBOX_ALPINE_SWAP_MODULE_DIR/dependencies.sh"; } || return 1
            toolbox_require_commands 'B19 Alpine swap' python3 cat flock dd mkswap swapon swapoff rc-service openrc-run || return 1
            break
        fi
    done
    code=$(_toolbox_alpine_swap_engine) || return 1
    TOOLBOX_ALPINE_SWAP_ENGINE=$code python3 -c "$code" "$@" || return 1
}
