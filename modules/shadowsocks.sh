#!/usr/bin/env bash
# Independent Shadowsocks using pinned Xray on Alpine/OpenRC or Debian/systemd.
# Filesystem safety ledger adapted from this repository's VMess module.
ssx_err() { printf '%s\n' "$*" >&2; }
ssx_etc() { printf '%s\n' "${TOOLBOX_SS_ETC:-/etc/terry-toolbox-shadowsocks}"; }
ssx_bin() { printf '%s/terry-toolbox-shadowsocks\n' "${TOOLBOX_SS_BIN_DIR:-/usr/local/bin}"; }
ssx_unit() { if [[ ${SSX_BACKEND:-systemd} == alpine ]]; then printf '%s/terry-toolbox-shadowsocks\n' "${TOOLBOX_SS_INIT_DIR:-/etc/init.d}"; return; fi; printf '%s/terry-toolbox-shadowsocks.service\n' "${TOOLBOX_SS_UNIT_DIR:-/etc/systemd/system}"; }
ssx_lock() { printf '%s\n' "${TOOLBOX_SS_LOCK:-/run/terry-toolbox-shadowsocks.lock}"; }
ssx_valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
ssx_valid_endpoint() {
 python3 - "$1" <<'PY_ENDPOINT'
import ipaddress,re,sys
s=sys.argv[1]
try:
 if '%' in s: raise ValueError()
 ipaddress.ip_address(s)
except ValueError:
 if len(s)>253 or not re.fullmatch(r'(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}',s): sys.exit(1)
PY_ENDPOINT
}
ssx_confirm() {
 local answer i
 for i in 1 2; do
  printf '第 %s 次确认，输入 YES（空白或 EOF 取消）：' "$i"
  IFS= read -r answer && [[ ${answer^^} == YES ]] || { ssx_err '已取消。'; return 1; }
 done
}
ssx_arch() { case $(uname -m) in x86_64|amd64) printf amd64;; aarch64|arm64) printf arm64;; *) ssx_err '不支持的架构。'; return 1;; esac; }
ssx_require_systemd() {
 [[ ${EUID:-1} == 0 ]] || { ssx_err '需要 root。'; return 1; }
 local id='' line c
 [[ -r ${TOOLBOX_SS_OS_RELEASE:-/etc/os-release} ]] || return 1
 while IFS= read -r line || [[ -n $line ]]; do case $line in ID=*) [[ -z $id ]] || return 1; id=${line#ID=}; id=${id#\"}; id=${id%\"};; esac; done < "${TOOLBOX_SS_OS_RELEASE:-/etc/os-release}"
 [[ $id == debian ]] || { ssx_err '仅支持 Debian。'; return 1; }
 [[ -d ${TOOLBOX_SS_SYSTEMD_RUN:-/run/systemd/system} ]] || { ssx_err 'systemd 未运行。'; return 1; }
 for c in python3 systemctl ss curl mktemp uname stat sleep; do command -v "$c" >/dev/null || { ssx_err "缺少依赖：$c"; return 1; }; done
 ssx_arch >/dev/null || return 1
}
ssx_require() {
 if [[ ${SSX_BACKEND:-systemd} == systemd ]]; then ssx_require_systemd; return; fi
 [[ ${EUID:-1} == 0 ]] || { ssx_err '需要 root。'; return 1; }
 local id='' line c
 [[ -r ${TOOLBOX_SS_OS_RELEASE:-/etc/os-release} ]] || return 1
 while IFS= read -r line || [[ -n $line ]]; do case $line in ID=*) [[ -z $id ]] || return 1; id=${line#ID=}; id=${id#\"}; id=${id%\"};; esac; done < "${TOOLBOX_SS_OS_RELEASE:-/etc/os-release}"
 [[ $id == alpine ]] || { ssx_err '该后端仅支持 Alpine。'; return 1; }
 [[ -d /run/openrc ]] && [[ -r /run/openrc/softlevel ]] || { ssx_err 'OpenRC 未运行。'; return 1; }
 for c in python3 rc-service rc-update ss curl mktemp uname stat sleep; do command -v "$c" >/dev/null || { ssx_err "缺少依赖：$c"; return 1; }; done
 ssx_arch >/dev/null || return 1
}
ssx_fs() {
    python3 - "$1" "$(ssx_etc)" "$(ssx_bin)" "$(ssx_unit)" "$(ssx_lock)" "${SSX_BACKEND:-systemd}" "${@:2}" <<'PY'
import os, sys, stat, json, hashlib, re, ipaddress, uuid
op, etc, binary, unit, lock, backend, *args = sys.argv[1:]
NAME = 'terry-toolbox-shadowsocks.service' if backend == 'systemd' else 'terry-toolbox-shadowsocks'
LEAVES = ('config.json', 'client.json', 'mihomo.yaml', 'shadowsocks.txt')
allowed = {os.path.join(etc, n): 0o600 for n in LEAVES}
allowed.update({binary: 0o755, unit: 0o755 if backend == 'alpine' else 0o644})
def ident(st): return f'{st.st_dev}:{st.st_ino}'
def pathok(p):
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', p) or any(x in ('', '.', '..') for x in p.split('/')[1:]):
        raise ValueError('unsafe absolute path')
def directory(p):
    if p != '/': pathok(p)
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in p.split('/')[1:]:
            st = os.fstat(fd)
            if st.st_uid != 0 or st.st_mode & 0o022: raise ValueError('ancestor must be root-owned, not group/world writable')
            if not part: continue
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = nxt
        st = os.fstat(fd)
        if st.st_uid != 0 or st.st_mode & 0o022: raise ValueError('parent must be root-owned, not group/world writable')
        return fd
    except BaseException:
        os.close(fd); raise

def parent(p):
    pathok(p)
    return directory(os.path.dirname(p)), os.path.basename(p)
def exists(p):
    fd, name = parent(p)
    try:
        try: os.stat(name, dir_fd=fd, follow_symlinks=False); return True
        except FileNotFoundError: return False
    finally: os.close(fd)
def filedata(p):
    fd, name = parent(p)
    try: f = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    finally: os.close(fd)
    try:
        st = os.fstat(f)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_nlink != 1: raise ValueError('not an exclusive root-owned regular file')
        out = bytearray()
        while True:
            chunk = os.read(f, 1048576)
            if not chunk: break
            out.extend(chunk)
        return bytes(out), {'id': ident(st), 'mode': stat.S_IMODE(st.st_mode), 'sha256': hashlib.sha256(out).hexdigest()}
    finally: os.close(f)
def create(p, data, mode, entries):
    fd, name = parent(p)
    tmp = '.terry-shadowsocks-' + uuid.uuid4().hex
    f = None; owned = None
    try:
        f = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=fd)
        owned = ident(os.fstat(f))
        view = memoryview(data); written = 0
        while written < len(view):
            n = os.write(f, view[written:])
            if n <= 0: raise OSError('short write')
            written += n
        os.fchmod(f, mode); os.fsync(f)
        # linkat is atomic and refuses any existing target, including symlinks.
        os.link(tmp, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
        entries[p] = {'id': owned, 'mode': mode, 'sha256': hashlib.sha256(data).hexdigest()}
    finally:
        if f is not None: os.close(f)
        if owned is not None:
            st = os.stat(tmp, dir_fd=fd, follow_symlinks=False)
            if ident(st) != owned: raise ValueError('temporary file replaced; retained')
            os.unlink(tmp, dir_fd=fd)
        os.close(fd)
def parentmap(include_lock=False):
    result = {}
    for p in ((etc, binary, unit, lock) if include_lock else (etc, binary, unit)):
        fd, _ = parent(p)
        try: result[os.path.dirname(p)] = ident(os.fstat(fd))
        finally: os.close(fd)
    return result
def parents():
    # The lock lives on tmpfs (/run): its parent inode is boot-local, so only the
    # lock directory's own inode is a gate (checked while the lock is held).
    if len({etc, binary, unit, lock}) != 4: raise ValueError('overlapping paths')
    for p in (binary, unit, lock):
        if p.startswith(etc + '/') or etc.startswith(p + '/'): raise ValueError('overlapping paths')
    return parentmap()
def parents_match(stored):
    # Ledgers sealed before the split also carry the boot-local lock parent; its
    # recorded inode is accepted as extra, never as a persistent gate.
    current = parents()
    if not isinstance(stored, dict): return False
    if set(stored) not in (set(current), set(current) | {os.path.dirname(lock)}): return False
    return {k: v for k, v in stored.items() if k in current} == current

BOOTDIR = os.path.join(os.path.dirname(unit), 'multi-user.target.wants')
BOOTLINK = os.path.join(BOOTDIR, NAME)
SYSTEMD_ROOTS = tuple(dict.fromkeys((os.path.dirname(unit), '/etc/systemd/system', '/run/systemd/system', '/usr/local/lib/systemd/system', '/usr/lib/systemd/system', '/lib/systemd/system')))
DEPDIRS = ('.wants', '.requires', '.upholds')
def linkdata():
    fd, name = parent(BOOTLINK)
    try:
        st = os.stat(name, dir_fd=fd, follow_symlinks=False)
        if not stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or st.st_nlink != 1: raise ValueError('unknown boot link')
        target = os.readlink(name, dir_fd=fd)
        if target != unit: raise ValueError('wrong boot link target')
        return {'id':ident(st), 'target':target, 'parent':ident(os.fstat(fd))}
    finally: os.close(fd)
def bootverify(boot):
    if boot is not None and (not isinstance(boot, dict) or set(boot) != {'id','target','parent'}): raise ValueError('invalid boot record')
    if boot is not None and linkdata() != boot: raise ValueError('boot link changed')
    if boot is None and os.path.lexists(BOOTLINK): raise ValueError('unowned boot link')
def depscan(include_boot=False):
    # Any link naming this unit is a boot dependency. Only the exact recorded
    # multi-user.target.wants leaf is ours; systemctl disable unlinks every link
    # to the unit, so foreign ones would be lost silently and must be refused.
    real = os.path.realpath(unit)
    found = []
    for root in SYSTEMD_ROOTS:
        if not os.path.isdir(root): continue
        for ent in os.scandir(root):
            if not ent.name.endswith(DEPDIRS): continue
            if ent.is_symlink(): raise ValueError('symlink dependency directory conflict')
            if not ent.is_dir(follow_symlinks=False): raise ValueError('unknown dependency directory')
            for dep in os.scandir(ent.path):
                if dep.is_symlink() and os.path.realpath(dep.path) == real and (include_boot or dep.path != BOOTLINK):
                    found.append(dep.path)
    return sorted(found)
def dropins(absent=False, boot=None):
    if backend == 'alpine':
        if boot is not None: raise ValueError('unknown Alpine boot record')
        for root in ('/etc/conf.d','/etc/runlevels'):
            if not os.path.isdir(root) or os.path.islink(root): raise ValueError('unknown OpenRC layout')
        if os.path.lexists('/etc/conf.d/'+NAME): raise ValueError('foreign OpenRC configuration')
        for ent in os.scandir('/etc/runlevels'):
            if ent.is_symlink() or not ent.is_dir(follow_symlinks=False): raise ValueError('unknown runlevel')
            if os.path.lexists(os.path.join(ent.path,NAME)): raise ValueError('foreign OpenRC enablement')
            for dep in os.scandir(ent.path):
                if dep.is_symlink() and os.path.realpath(dep.path)==os.path.realpath(unit):
                    raise ValueError('foreign OpenRC dependency alias')
        if os.path.lexists('/run/'+NAME+'.pid') and absent: raise ValueError('foreign pidfile')
        if absent and any(exists(p) for p in (etc,binary,unit)): raise ValueError('target already exists')
        return
    bootverify(boot)
    for root in SYSTEMD_ROOTS:
        if not os.path.isdir(root): continue
        for name in (NAME + '.d', 'service.d', 'terry-.service.d', 'terry-toolbox-.service.d', 'terry-.d', 'terry-toolbox-.d'):
            if os.path.lexists(os.path.join(root, name)): raise ValueError('systemd drop-in conflict')
        # Scan only the immediate wants/requires/upholds directory, never follow symlinks.
        for ent in os.scandir(root):
            if ent.name == NAME and os.path.join(root, NAME) != unit: raise ValueError('foreign unit path')
            if ent.name.endswith(DEPDIRS):
                if ent.is_symlink(): raise ValueError('symlink dependency directory conflict')
                if not ent.is_dir(follow_symlinks=False): raise ValueError('unknown dependency directory')
                if os.path.lexists(os.path.join(ent.path, NAME)):
                    if os.path.join(ent.path, NAME) != BOOTLINK or boot is None: raise ValueError('enabled or dependent unit conflict')
    foreign = depscan()
    if foreign: raise ValueError('foreign dependency link: ' + foreign[0])
    if absent and any(exists(p) for p in (etc, binary, unit)): raise ValueError('target already exists')

def verify():
    parents()
    efd = directory(etc)
    try:
        est = os.fstat(efd); eid = ident(est); names = set(os.listdir(efd))
        if stat.S_IMODE(est.st_mode) != 0o700: raise ValueError('private directory mode changed')
    finally: os.close(efd)
    raw, info = filedata(etc + '/manifest.json')
    seal, sealinfo = filedata(etc + '/manifest.sha256')
    if len(raw) > 65536 or seal != (info['sha256'] + '\n').encode(): raise ValueError('manifest changed')
    m = json.loads(raw)
    keys = {'version','directory','manifest_id','seal_id','parents','meta','entries'}
    if m.get('version') == 2: keys.add('boot')
    if set(m) != keys or m['version'] not in (1, 2): raise ValueError('invalid manifest')
    dropins(boot=m.get('boot'))
    if m['directory'] != eid or m['manifest_id'] != info['id'] or m['seal_id'] != sealinfo['id']: raise ValueError('ledger inode changed')
    if info['mode'] != 0o600 or sealinfo['mode'] != 0o600 or not parents_match(m['parents']): raise ValueError('ledger/parent changed')
    meta = m['meta']
    if set(meta) != {'host','port','path','listen'}: raise ValueError('invalid metadata')
    if not isinstance(meta['port'], int) or not 1 <= meta['port'] <= 65535: raise ValueError('invalid port')
    if not isinstance(meta['host'], str) or not re.fullmatch(r'[a-zA-Z0-9.:-]{1,253}', meta['host']): raise ValueError('invalid host')
    if not isinstance(meta['path'], str) or not re.fullmatch(r'/[A-Za-z0-9_/-]{0,127}', meta['path']): raise ValueError('invalid path')
    ipaddress.IPv4Address(meta['listen'])
    entries = m['entries']
    if not isinstance(entries, dict) or not set(entries) <= set(allowed): raise ValueError('unknown manifest path')
    wantnames = {'manifest.json', 'manifest.sha256'} | {os.path.basename(p) for p in entries if os.path.dirname(p) == etc}
    if names != wantnames: raise ValueError('directory has unknown/missing contents')
    for p, record in entries.items():
        _, current = filedata(p)
        if current != record: raise ValueError('resource changed: ' + p)
    for p in allowed:
        if p not in entries and exists(p): raise ValueError('unowned resource: ' + p)
    return m

def unlink_owned(p, record):
    _, current = filedata(p)
    if current != record: raise ValueError('changed before unlink')
    fd, name = parent(p)
    try:
        if ident(os.stat(name, dir_fd=fd, follow_symlinks=False)) != record['id']: raise ValueError('swapped before unlink')
        os.unlink(name, dir_fd=fd)
    finally: os.close(fd)
def exchange(p, q, expected, replacement):
    # Linux renameat2 exchange never follows either leaf. Check both sides after
    # the atomic swap; unknown concurrent state is retained, never overwritten.
    import ctypes
    if filedata(p)[1] != expected or filedata(q)[1] != replacement: raise ValueError('changed before exchange')
    a, an = parent(p); b, bn = parent(q)
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renameat2(a, an.encode(), b, bn.encode(), 2) != 0:
            raise OSError(ctypes.get_errno(), 'renameat2 exchange failed')
        os.fsync(a); os.fsync(b)
    finally: os.close(a); os.close(b)
    if filedata(p)[1] != replacement or filedata(q)[1] != expected: raise ValueError('exchange race; both objects retained')
def complete(m):
    if set(m['entries']) != set(allowed): raise ValueError('incomplete installation')
def staged(stage):
    fd = directory(stage)
    try:
        if stat.S_IMODE(os.fstat(fd).st_mode) != 0o700: raise ValueError('staging permissions changed')
        return ident(os.fstat(fd))
    finally: os.close(fd)
def newledger(stage, m, changes, before):
    mp = etc + '/manifest.json'; sp = etc + '/manifest.sha256'
    oldraw, oldinfo = filedata(mp); oldseal, oldsealinfo = filedata(sp)
    if json.loads(oldraw) != before or oldinfo['id'] != before['manifest_id'] or oldsealinfo['id'] != before['seal_id']:
        raise ValueError('original manifest changed during prepare')
    if oldseal != (oldinfo['sha256']+'\n').encode() or oldinfo['mode'] != 0o600 or oldsealinfo['mode'] != 0o600:
        raise ValueError('original seal changed during prepare')
    oldrecords = {mp:oldinfo,sp:oldsealinfo}
    records = {}
    for name in ('new-manifest.json','new-manifest.sha256'): create(stage + '/' + name, b'', 0o600, records)
    m['manifest_id'] = records[stage + '/new-manifest.json']['id']
    m['seal_id'] = records[stage + '/new-manifest.sha256']['id']
    data = (json.dumps(m, sort_keys=True) + '\n').encode()
    for dest, name, content in ((mp,'new-manifest.json',data), (sp,'new-manifest.sha256',(hashlib.sha256(data).hexdigest()+'\n').encode())):
        q = stage + '/' + name
        fd, leaf = parent(q)
        try: f = os.open(leaf, os.O_WRONLY | os.O_NOFOLLOW, dir_fd=fd)
        finally: os.close(fd)
        try:
            if ident(os.fstat(f)) != records[q]['id']: raise ValueError('staged ledger replaced')
            with os.fdopen(f, 'wb', closefd=False) as out: out.write(content); out.flush(); os.fsync(f)
        finally: os.close(f)
        changes[dest] = {'stage':name, 'before':oldrecords[dest], 'after':filedata(q)[1]}
def transaction(stage, token):
    raw, record = filedata(stage + '/transaction.json')
    if record['sha256'] != token or record['mode'] != 0o600: raise ValueError('transaction changed')
    t = json.loads(raw)
    if set(t) != {'stage_id','before','after','changes','aux'} or staged(stage) != t['stage_id']: raise ValueError('invalid transaction')
    before = t['before']; after = t['after']; changes = t['changes']
    auxiliaries = t['aux']
    if not isinstance(auxiliaries, dict) or not set(auxiliaries) <= {'config.json','validate.log','old-boot-link'}: raise ValueError('unknown transaction auxiliary')
    fd = directory(stage)
    try:
        expectednames = {'transaction.json'} | set(auxiliaries) | {x['stage'] for x in changes.values()}
        if set(os.listdir(fd)) != expectednames: raise ValueError('unknown staging content; retained')
    finally: os.close(fd)
    for name, record in auxiliaries.items():
        if name == 'old-boot-link':
            fd = directory(stage)
            try:
                st = os.stat(name,dir_fd=fd,follow_symlinks=False)
                if not stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or ident(st) != record['id'] or os.readlink(name,dir_fd=fd) != record['target']: raise ValueError('retired link changed')
            finally: os.close(fd)
        elif filedata(stage+'/'+name)[1] != record: raise ValueError('staging auxiliary changed; retained')
    if not parents_match(before['parents']) or not parents_match(after['parents']): raise ValueError('transaction parents changed')
    fd = directory(etc)
    try:
        if ident(os.fstat(fd)) != before['directory'] or stat.S_IMODE(os.fstat(fd).st_mode) != 0o700: raise ValueError('transaction directory changed')
        if set(os.listdir(fd)) != set(LEAVES) | {'manifest.json','manifest.sha256'}: raise ValueError('unknown transaction contents')
    finally: os.close(fd)
    bootverify(after.get('boot'))
    dropins(boot=after.get('boot'))
    permitted = {etc+'/cert.pem':'new-cert.pem', etc+'/key.pem':'new-key.pem', unit:'new-unit',
                 etc+'/manifest.json':'new-manifest.json', etc+'/manifest.sha256':'new-manifest.sha256'}
    if not set(changes) <= set(permitted): raise ValueError('unknown transaction path')
    positions = {}
    for p, change in changes.items():
        if set(change) != {'stage','before','after'} or change['stage'] != permitted[p]: raise ValueError('invalid transaction resource')
        current = filedata(p)[1]; backup = filedata(stage+'/'+change['stage'])[1]
        if current == change['before'] and backup == change['after']: positions[p] = 'before'
        elif current == change['after'] and backup == change['before']: positions[p] = 'after'
        else: raise ValueError('transaction object changed; retain pair and backups')
    for p, record in before['entries'].items():
        if p not in changes and filedata(p)[1] != record: raise ValueError('unchanged transaction resource modified')
    return t, positions
def pairdigest(stage):
    return hashlib.sha256(json.dumps({name:filedata(stage+'/'+name)[1] for name in ('new-cert.pem','new-key.pem','config.json')},sort_keys=True).encode()).hexdigest()
def prepare(stage, mode, expected=''):
    m = verify(); complete(m); staged(stage)
    original = json.loads(json.dumps(m)); changes = {}
    if mode != 'cert': m['version'] = 2; m.setdefault('boot', None)
    if mode == 'cert':
        if pairdigest(stage) != expected: raise ValueError('validated pair/config changed')
        for dest, name in ((etc+'/cert.pem','new-cert.pem'), (etc+'/key.pem','new-key.pem')):
            record = filedata(stage+'/'+name)[1]
            if record['mode'] != 0o600: raise ValueError('new pair permissions changed')
            changes[dest] = {'stage':name,'before':m['entries'][dest],'after':record}
            m['entries'][dest] = record
    elif mode == 'migrate':
        if original['version'] != 1: raise ValueError('migration requires legacy manifest')
        data, _ = filedata(unit)
        old = b'# Deliberately no [Install] section: no automatic boot enablement.\n'
        if data.count(old) != 1 or re.search(rb'^\[Install\]\s*$', data, re.M): raise ValueError('unknown legacy unit format')
        data = data.replace(old, b'[Install]\nWantedBy=multi-user.target\n')
        records = {}; create(stage+'/new-unit',data,0o644,records)
        record = records[stage+'/new-unit']
        changes[unit] = {'stage':'new-unit','before':m['entries'][unit],'after':record}; m['entries'][unit] = record
    elif mode in ('boot-on','boot-off'):
        if original['version'] != 2: raise ValueError('migrate complete legacy resources first')
        if mode == 'boot-on':
            if m['boot'] is not None: raise ValueError('already enabled')
            fd, name = parent(BOOTDIR)
            try:
                try: os.mkdir(name, 0o755, dir_fd=fd)
                except FileExistsError: pass
            finally: os.close(fd)
            fd = directory(BOOTDIR); tmp = '.terry-shadowsocks-link-' + uuid.uuid4().hex; owned = None
            try:
                os.symlink(unit, tmp, dir_fd=fd)
                st = os.stat(tmp, dir_fd=fd, follow_symlinks=False); owned = ident(st)
                m['boot'] = {'id':owned,'target':unit,'parent':ident(os.fstat(fd))}
                os.link(tmp, NAME, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
                if ident(os.stat(tmp,dir_fd=fd,follow_symlinks=False)) != owned: raise ValueError('temporary boot link changed; retained')
                os.unlink(tmp,dir_fd=fd); owned = None; os.fsync(fd)
            finally:
                # On any uncertain publication leave evidence, never adopt a
                # link observed after the exclusive create as newly owned.
                os.close(fd)
            bootverify(m['boot'])
        else:
            if m['boot'] is None: raise ValueError('already disabled')
            # Atomic no-clobber retirement, not check-then-unlink: if a link is
            # exchanged concurrently, preserve the moved unknown link as evidence.
            import ctypes
            fd, name = parent(BOOTLINK); sfd = directory(stage)
            try:
                if linkdata() != m['boot']: raise ValueError('changed boot link; retained')
                libc = ctypes.CDLL(None, use_errno=True)
                if libc.renameat2(fd, name.encode(), sfd, b'old-boot-link', 1) != 0: raise OSError(ctypes.get_errno(),'boot link retirement failed')
                st = os.stat('old-boot-link', dir_fd=sfd, follow_symlinks=False)
                if ident(st) != m['boot']['id'] or not stat.S_ISLNK(st.st_mode) or os.readlink('old-boot-link',dir_fd=sfd) != unit:
                    raise ValueError('retired link changed; retained, no unknown unlink')
                os.fsync(fd); os.fsync(sfd)
            finally: os.close(fd); os.close(sfd)
            m['boot'] = None
    else: raise ValueError('unknown transaction mode')
    newledger(stage, m, changes, original)
    aux = {name:filedata(stage+'/'+name)[1] for name in ('config.json','validate.log') if exists(stage+'/'+name)}
    if mode == 'boot-off': aux['old-boot-link'] = original['boot']
    t = {'stage_id':staged(stage),'before':original,'after':m,'changes':changes,'aux':aux}
    data = (json.dumps(t,sort_keys=True)+'\n').encode()
    create(stage+'/transaction.json',data,0o600,{})
    return hashlib.sha256(data).hexdigest()
def apply(stage, token, restore=False):
    t, positions = transaction(stage, token)
    for p, change in t['changes'].items():
        wanted = 'before' if restore else 'after'
        if positions[p] == wanted: continue
        current = change['after'] if restore else change['before']
        replacement = change['before'] if restore else change['after']
        exchange(p, stage+'/'+change['stage'], current, replacement)
    verify()

try:
    if op == 'parents': print(json.dumps(parents(), sort_keys=True))
    elif op == 'conflict': parents(); dropins(True)
    elif op == 'lock-prepare':
        claim = args[0]
        if not re.fullmatch(re.escape(lock) + r'\.claim\.[0-9a-f]{24}', claim): raise ValueError('invalid lock claim')
        fd, name = parent(claim)
        try:
            os.mkdir(name, 0o700, dir_fd=fd)
            print(ident(os.stat(name, dir_fd=fd, follow_symlinks=False)), flush=True)
        finally: os.close(fd)
    elif op == 'lock':
        claim, expected = args
        if not re.fullmatch(re.escape(lock) + r'\.claim\.[0-9a-f]{24}', claim): raise ValueError('invalid lock claim')
        fd, name = parent(lock); cfd, cname = parent(claim)
        try:
            st = os.stat(cname, dir_fd=cfd, follow_symlinks=False)
            if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or stat.S_IMODE(st.st_mode) != 0o700 or ident(st) != expected: raise ValueError('lock claim changed')
            if ident(os.fstat(fd)) != ident(os.fstat(cfd)): raise ValueError('lock claim parent changed')
            import ctypes
            libc = ctypes.CDLL(None, use_errno=True)
            # Register the identity BEFORE publishing the globally blocking name.
            if libc.renameat2(cfd, cname.encode(), fd, name.encode(), 1) != 0: raise OSError(ctypes.get_errno(), 'another installer holds the lock')
            if ident(os.stat(name, dir_fd=fd, follow_symlinks=False)) != expected: raise ValueError('published lock replaced')
        finally: os.close(fd); os.close(cfd)
    elif op == 'unlock':
        expected, claim = args
        if not re.fullmatch(re.escape(lock) + r'\.claim\.[0-9a-f]{24}', claim): raise ValueError('invalid lock claim')
        fd, name = parent(lock); cfd, cname = parent(claim)
        try:
            try: st = os.stat(cname, dir_fd=cfd, follow_symlinks=False)
            except FileNotFoundError: st = None
            if st is not None:
                if not stat.S_ISDIR(st.st_mode) or ident(st) != expected: raise ValueError('lock claim replaced; retained')
                os.rmdir(cname, dir_fd=cfd)
            else:
                if ident(os.stat(name, dir_fd=fd, follow_symlinks=False)) != expected: raise ValueError('lock replaced; retained')
                os.rmdir(name, dir_fd=fd)
        finally: os.close(fd); os.close(cfd)
    elif op == 'lock-check':
        # A replacement lock during confirmation means another holder may already
        # be acting; checked again right before every disruptive step.
        fd, name = parent(lock)
        try:
            if ident(os.stat(name, dir_fd=fd, follow_symlinks=False)) != args[0]: raise ValueError('lock replaced')
        finally: os.close(fd)
    elif op == 'links': print(len(depscan(True)))
    elif op == 'publish':
        stage, expected, host, port, ws, listen = args
        if parents() != json.loads(expected): raise ValueError('parent changed')
        dropins(True)
        fd, name = parent(etc)
        try:
            os.mkdir(name, 0o700, dir_fd=fd)
            created_id = ident(os.stat(name, dir_fd=fd, follow_symlinks=False))
        finally: os.close(fd)
        # A per-attempt claim prevents rollback from adopting an existing valid
        # installation that raced into place before this mkdir succeeded.
        create(stage + '/owned.json', json.dumps({'directory':created_id}).encode(), 0o600, {})
        entries = {}; error = None
        try:
            for p, mode in allowed.items():
                source = os.path.join(stage, 'xray' if p == binary else 'unit' if p == unit else os.path.basename(p))
                data, _ = filedata(source)
                create(p, data, mode, entries)
        except BaseException as exc: error = exc
        # Write a sealed ledger even for a partially written resource. If sealing
        # itself fails, keep everything; callers cannot infer ownership from names.
        efd = directory(etc)
        try: eid = ident(os.fstat(efd))
        finally: os.close(efd)
        if eid != created_id: raise ValueError('created directory replaced; retained')
        ledger = {}; mp = etc + '/manifest.json'; sp = etc + '/manifest.sha256'
        create(mp, b'', 0o600, ledger); create(sp, b'', 0o600, ledger)
        m = {'version':2, 'boot':None, 'directory':eid, 'manifest_id':ledger[mp]['id'], 'seal_id':ledger[sp]['id'], 'parents':json.loads(expected),
             'meta':{'host':host,'port':int(port),'path':ws,'listen':listen}, 'entries':entries}
        data = (json.dumps(m, sort_keys=True) + '\n').encode()
        for p, content in ((mp, data), (sp, (hashlib.sha256(data).hexdigest()+'\n').encode())):
            fd, name = parent(p)
            try: f = os.open(name, os.O_WRONLY | os.O_NOFOLLOW, dir_fd=fd)
            finally: os.close(fd)
            try:
                if ident(os.fstat(f)) != ledger[p]['id']: raise ValueError('ledger replaced')
                with os.fdopen(f, 'wb', closefd=False) as out: out.write(content); out.flush(); os.fsync(f)
            finally: os.close(f)
        if error: raise error
        verify()
    elif op == 'pair-check':
        for p in args: filedata(p)
    elif op == 'boot-info':
        m = verify()
        if args and args[0] == '--complete': complete(m)
        print(m['version'], 'enabled' if m.get('boot') is not None else 'disabled')
    elif op == 'snapshot-pair':
        stage, cert, key = args
        m = verify(); complete(m); staged(stage)
        for src, dest in ((cert,'new-cert.pem'), (key,'new-key.pem')):
            data, _ = filedata(src); create(stage+'/'+dest, data, 0o600, {})
        data, _ = filedata(etc+'/config.json'); cfg = json.loads(data)
        certificates = cfg['inbounds'][0]['streamSettings']['tlsSettings']['certificates']
        if certificates != [{'certificateFile':etc+'/cert.pem','keyFile':etc+'/key.pem'}]: raise ValueError('unknown certificate configuration')
        certificates[0] = {'certificateFile':stage+'/new-cert.pem','keyFile':stage+'/new-key.pem'}
        create(stage+'/config.json',(json.dumps(cfg,sort_keys=True)+'\n').encode(),0o600,{})
        print(pairdigest(stage))
    elif op == 'prepare': print(prepare(*args))
    elif op == 'apply': apply(*args)
    elif op == 'restore': apply(*args, restore=True)
    elif op == 'transaction-check': transaction(*args)
    elif op == 'transaction-clean':
        stage, token = args; t, positions = transaction(stage,token)
        for p, change in t['changes'].items():
            record = change['before'] if positions[p] == 'after' else change['after']
            unlink_owned(stage+'/'+change['stage'],record)
        for name, record in t['aux'].items():
            if name == 'old-boot-link':
                fd = directory(stage)
                try:
                    if ident(os.stat(name,dir_fd=fd,follow_symlinks=False)) != record['id']: raise ValueError('retired link changed before cleanup')
                    os.unlink(name,dir_fd=fd)
                finally: os.close(fd)
            else: unlink_owned(stage+'/'+name,record)
        raw, record = filedata(stage+'/transaction.json')
        if record['sha256'] != token: raise ValueError('transaction changed before cleanup')
        unlink_owned(stage+'/transaction.json',record)
        fd,name = parent(stage)
        try:
            if ident(os.stat(name,dir_fd=fd,follow_symlinks=False)) != t['stage_id']: raise ValueError('staging directory replaced')
            os.rmdir(name,dir_fd=fd)
        finally: os.close(fd)
    elif op == 'verify':
        m = verify(); v = m['meta']
        if args and args[0] == '--complete':
            if set(m['entries']) != set(allowed): raise ValueError('incomplete installation')
            args = args[1:]
        if args:
            claim, _ = filedata(args[0] + '/owned.json')
            if json.loads(claim) != {'directory':m['directory']}: raise ValueError('not owned by this install attempt')
        print(v['host'], v['port'], v['path'], v['listen'], int(unit in m['entries']))
    elif op == 'remove':
        m = verify()
        if binary in m['entries']:
            target = os.stat(binary,follow_symlinks=False)
            for ent in os.scandir('/proc'):
                if not ent.name.isdigit(): continue
                try: live = os.stat(ent.path+'/exe')
                except (FileNotFoundError,ProcessLookupError): continue
                if (live.st_dev,live.st_ino)==(target.st_dev,target.st_ino): raise ValueError('owned executable still running; retained')
        if m.get('boot') is not None: raise ValueError('disable and verify owned boot link before removal')
        # Revalidate every object at deletion time; no recursive directory deletion.
        for p in (unit, binary, *(etc + '/' + n for n in LEAVES)):
            if p in m['entries']: unlink_owned(p, m['entries'][p])
        for p in (etc + '/manifest.sha256', etc + '/manifest.json'):
            _, record = filedata(p); unlink_owned(p, record)
        fd, name = parent(etc)
        try:
            if ident(os.stat(name, dir_fd=fd, follow_symlinks=False)) != m['directory']: raise ValueError('directory replaced')
            os.rmdir(name, dir_fd=fd)
        finally: os.close(fd)
    else: raise ValueError('unknown filesystem operation')
except BaseException as exc:
    print('Shadowsocks 文件安全检查失败: ' + str(exc), file=sys.stderr); sys.exit(1)
PY
}

# Read one coherent systemd property snapshot. Unreadable/missing/duplicate facts
# are unknown, never a claim of an absent or stopped service.
ssx_service_read() {
    local output line key value
    local -A seen=()
    output=$(systemctl show terry-toolbox-shadowsocks.service --no-pager --all \
        -p LoadState -p ActiveState -p SubState -p MainPID -p FragmentPath -p DropInPaths -p Job 2>/dev/null) || return 1
    ssx_load='' ssx_active='' ssx_sub='' ssx_pid='' ssx_fragment='' ssx_dropins='' ssx_job=''
    while IFS= read -r line; do
        [[ $line == *=* ]] || return 1
        key=${line%%=*}; value=${line#*=}
        [[ ! ${seen[$key]+x} ]] || return 1
        seen[$key]=1
        case $key in
            LoadState) ssx_load=$value ;; ActiveState) ssx_active=$value ;; SubState) ssx_sub=$value ;;
            MainPID) ssx_pid=$value ;; FragmentPath) ssx_fragment=$value ;; DropInPaths) ssx_dropins=$value ;; Job) ssx_job=$value ;;
            *) return 1 ;;
        esac
    done <<< "$output"
    [[ ${#seen[@]} == 7 && $ssx_pid =~ ^[0-9]+$ ]] || return 1
    [[ -z $ssx_dropins && ( -z $ssx_job || $ssx_job == 0 ) ]] || return 1
}
ssx_absent_service() {
    ssx_service_read || return 1
    [[ $ssx_load == not-found && $ssx_active == inactive && $ssx_sub == dead && $ssx_pid == 0 && -z $ssx_fragment ]]
}
ssx_port_lines() { # tcp or udp, port
    local flags output
    case $1 in tcp) flags=-ltnpH;; udp) flags=-uanpH;; *) return 1;; esac
    output=$(ss "$flags" 2>/dev/null) || { ssx_err '监听表读取失败，状态未知。'; return 1; }
    SSX_TABLE="$output" python3 - "$1" "$2" <<'PY_SOCKETS'
import os,sys
proto,port=sys.argv[1:]
for line in os.environ['SSX_TABLE'].splitlines():
 f=line.split()
 if len(f)<5 or (proto=='tcp' and f[0]!='LISTEN') or (proto=='udp' and f[0] not in ('UNCONN','ESTAB')): sys.exit('unparseable socket table')
 if f[3].rsplit(':',1)[-1]==port: print(line)
PY_SOCKETS
}
ssx_port_free() {
 local lines proto
 for proto in tcp udp; do
  lines=$(ssx_port_lines "$proto" "$1") || return 1
  [[ -z $lines ]] || { ssx_err "$proto 端口 $1 已占用；未接管。"; return 1; }
 done
}
ssx_socket_owned() { # proto port pid listen binary
 local lines
 lines=$(ssx_port_lines "$1" "$2") || return 1
 SSX_TABLE="$lines" python3 - "$3" "$4" "$5" <<'PY_OWN'
import os,re,sys
pid,listen,binary=sys.argv[1:]
try:
 if not re.fullmatch(r'[1-9][0-9]*',pid): raise ValueError()
 a,b=os.stat('/proc/'+pid+'/exe'),os.stat(binary)
 if os.readlink('/proc/'+pid+'/exe')!=binary or (a.st_dev,a.st_ino)!=(b.st_dev,b.st_ino): raise ValueError()
 lines=os.environ['SSX_TABLE'].splitlines()
 if not lines: raise ValueError()
 for line in lines:
  fields=line.split(); address=fields[3].rsplit(':',1)[0]
  if address!=listen and not (listen=='0.0.0.0' and address=='*'): raise ValueError()
  if set(re.findall(r'pid=([0-9]+)',line))!={pid}: raise ValueError()
except (ValueError,OSError): sys.exit(1)
PY_OWN
}
ssx_running() {
 if [[ ${SSX_BACKEND:-systemd} == alpine ]]; then
  local pidfile=/run/terry-toolbox-shadowsocks.pid pid
  ssx_pidfile_safe "$pidfile" || return 1
  pid=$(<"$pidfile"); [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  rc-service terry-toolbox-shadowsocks status >/dev/null 2>&1 || return 1
  ssx_socket_owned tcp "$1" "$pid" "$2" "$(ssx_bin)" || return 1
  ssx_socket_owned udp "$1" "$pid" "$2" "$(ssx_bin)" || return 1
  return 0
 fi
 ssx_service_read || return 1
 [[ $ssx_load == loaded && $ssx_active == active && $ssx_sub == running && $ssx_fragment == "$(ssx_unit)" ]] || return 1
 ssx_socket_owned tcp "$1" "$ssx_pid" "$2" "$(ssx_bin)" || return 1
 ssx_socket_owned udp "$1" "$ssx_pid" "$2" "$(ssx_bin)" || return 1
}
ssx_conflict() {
    ssx_fs conflict || return 1
    if [[ ${SSX_BACKEND:-systemd} == alpine ]]; then ssx_port_free "$1"; return; fi
    ssx_absent_service || { ssx_err 'systemd 已加载/状态未知/存在任务或 drop-in；拒绝接管。'; return 1; }
    ssx_port_free "$1" || return 1
}
ssx_fetch() { # stage: fixed official URL and whitelist, local archive is not trusted
    local arch url hash
    arch=$(ssx_arch) || return 1
    case $arch in
      amd64) url=https://github.com/XTLS/Xray-core/releases/download/v26.10.31/Xray-linux-64.zip; hash=e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214;;
      arm64) url=https://github.com/XTLS/Xray-core/releases/download/v26.10.31/Xray-linux-arm64-v8a.zip; hash=1811c8f1da0c3b6dc707ebaf1c8390e987ba39859a8f0a7aadd8526157f2ec8d;;
      *) return 1;; esac
    [[ $hash =~ ^[0-9a-f]{64}$ && $url == https://github.com/XTLS/Xray-core/releases/download/v26.10.31/Xray-linux-*.zip ]] \
        || { ssx_err "固定版本/校验值/下载地址不一致：$url"; return 1; }
    if [[ -n ${TOOLBOX_SS_ZIP_SRC:-} ]]; then
        python3 - "$TOOLBOX_SS_ZIP_SRC" "$1/xray.zip" <<'PY'
import sys, shutil
with open(sys.argv[1], 'rb') as src, open(sys.argv[2], 'xb') as dst: shutil.copyfileobj(src, dst)
PY
        [[ $? == 0 ]] || return 1
    else
        curl --proto '=https' --tlsv1.2 -fSL --connect-timeout 15 --max-time 180 "$url" -o "$1/xray.zip" || return 1
    fi
    python3 - "$1" "$hash" <<'PY'
import sys, hashlib, zipfile, os
stage, expected = sys.argv[1:]
digest = hashlib.sha256()
with open(stage + '/xray.zip', 'rb') as f:
    for chunk in iter(lambda: f.read(1048576), b''): digest.update(chunk)
actual = digest.hexdigest()
if actual != expected: sys.exit('Xray zip SHA-256 mismatch')
with zipfile.ZipFile(stage + '/xray.zip') as z:
    entries = [i for i in z.infolist() if i.filename == 'xray']
    if len(entries) != 1 or entries[0].file_size > 200_000_000: sys.exit('invalid Xray archive')
    # Extract only this exact member; never extractall on archive paths.
    data = z.read(entries[0])
with open(stage + '/xray', 'xb') as f: f.write(data)
os.chmod(stage + '/xray', 0o755)
PY
}
ssx_write_configs() { # stage endpoint port IPv4 listen
 python3 - "$@" "$(ssx_etc)" "$(ssx_bin)" "${SSX_BACKEND:-systemd}" <<'PY_CONFIG'
import os,sys,json,secrets,base64,ipaddress
stage,host,port,listen,etc,binary,backend=sys.argv[1:]
port=int(port); ipaddress.IPv4Address(listen)
password=secrets.token_urlsafe(32); method='chacha20-ietf-poly1305'
server={'log':{'loglevel':'warning'},'inbounds':[{'listen':listen,'port':port,'protocol':'shadowsocks','settings':{'method':method,'password':password,'network':'tcp,udp'}}], 'outbounds':[{'protocol':'freedom'}]}
client={'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':1080,'protocol':'socks','settings':{'auth':'noauth','udp':True}}], 'outbounds':[{'protocol':'shadowsocks','settings':{'servers':[{'address':host,'port':port,'method':method,'password':password}]}}]}
userinfo=base64.urlsafe_b64encode((method+':'+password).encode()).decode().rstrip('=')
addr='['+host+']' if ':' in host else host
uri='ss://'+userinfo+'@'+addr+':'+str(port)+'#Terry-SS\n'
mihomo='proxies:\n  - name: Terry-SS\n    type: ss\n    server: '+json.dumps(host)+'\n    port: '+str(port)+'\n    cipher: '+method+'\n    password: '+json.dumps(password)+'\n    udp: true\n'
for name,data in [('config.json',json.dumps(server,indent=2)+'\n'),('client.json',json.dumps(client,indent=2)+'\n'),('mihomo.yaml',mihomo),('shadowsocks.txt',uri)]:
 fd=os.open(stage+'/'+name,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as f:f.write(data)
unit=f"""[Unit]
Description=Terry Toolbox Shadowsocks server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart={binary} run -config {etc}/config.json
WorkingDirectory={etc}
Restart=no
TimeoutStopSec=15
KillMode=control-group
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
[Install]
WantedBy=multi-user.target
"""
if backend=='alpine':
 unit=f"""#!/sbin/openrc-run
description=\"Terry Toolbox Shadowsocks server\"
command=\"{binary}\"
command_args=\"run -config {etc}/config.json\"
command_background=\"yes\"
pidfile=\"/run/terry-toolbox-shadowsocks.pid\"
retry=\"TERM/5/KILL/5\"
depend() {{ need net; }}
"""
fd=os.open(stage+'/unit',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o755 if backend=='alpine' else 0o644)
with os.fdopen(fd,'w') as f:f.write(unit)
PY_CONFIG
}
ssx_pidfile_safe() {
 python3 - "$1" <<'PY_PIDFILE'
import os,stat,sys
try:
 st=os.lstat(sys.argv[1])
 if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_nlink != 1 or st.st_mode & 0o022: raise ValueError()
except (OSError,ValueError): sys.exit(1)
PY_PIDFILE
}
# Refuse deletion while any live process executes the owned inode, including aliases
# and processes outside the service manager. Unknown processes are not signalled.
ssx_no_processes() {
 python3 - "$(ssx_bin)" <<'PY_NO_PROCESSES'
import os,stat,sys
try:
 try: wanted=os.stat(sys.argv[1],follow_symlinks=False)
 except FileNotFoundError: sys.exit(0)
 if not stat.S_ISREG(wanted.st_mode): raise ValueError('binary is not a regular file')
 for entry in os.scandir('/proc'):
  if not entry.name.isdigit(): continue
  try: current=os.stat(entry.path+'/exe')
  except (FileNotFoundError,ProcessLookupError): continue
  if (current.st_dev,current.st_ino)==(wanted.st_dev,wanted.st_ino):
   raise ValueError('same executable still running (PID '+entry.name+'); resources retained')
except (OSError,ValueError) as exc:
 print('Shadowsocks 停止检查失败: '+str(exc),file=sys.stderr);sys.exit(1)
PY_NO_PROCESSES
}
ssx_alpine_stop() {
 local port=$1 hasunit=$2 pidfile=/run/terry-toolbox-shadowsocks.pid pid='' rc=0
 if [[ $hasunit != 1 ]]; then ssx_port_free "$port" && ssx_no_processes; return; fi
 if [[ -e $pidfile || -L $pidfile ]]; then
  ssx_pidfile_safe "$pidfile" || return 1
  pid=$(<"$pidfile"); [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  python3 - "$pid" "$(ssx_bin)" <<'PY_PID'
import os,sys
pid,b=sys.argv[1:]
try:
 a,z=os.stat('/proc/'+pid+'/exe'),os.stat(b)
 if os.readlink('/proc/'+pid+'/exe')!=b or (a.st_dev,a.st_ino)!=(z.st_dev,z.st_ino): sys.exit(1)
except OSError: sys.exit(1)
PY_PID
  [[ $? == 0 ]] || return 1
 else
  rc-service terry-toolbox-shadowsocks status >/dev/null 2>&1 || rc=$?
  [[ $rc == 3 && ${ssx_started:-0} == 0 ]] || return 1
  ssx_port_free "$port" && ssx_no_processes; return
 fi
 rc-service terry-toolbox-shadowsocks stop >/dev/null 2>&1 || return 1
 rc=0; rc-service terry-toolbox-shadowsocks status >/dev/null 2>&1 || rc=$?
 [[ $rc == 3 && ! -e /proc/$pid && ! -e $pidfile && ! -L $pidfile ]] || return 1
 ssx_port_free "$port" && ssx_no_processes
}
ssx_stop_gate() { # port has_owned_unit
    if [[ ${SSX_BACKEND:-systemd} == alpine ]]; then ssx_alpine_stop "$@"; return; fi
    if [[ $2 == 1 ]]; then
        ssx_service_read || return 1
        if [[ $ssx_load == not-found && $ssx_active == inactive && $ssx_sub == dead && $ssx_pid == 0 && -z $ssx_fragment && ${ssx_started:-0} == 0 ]]; then
            # Published, daemon-reload or the first reload failed, and start was
            # never attempted. verify() already proved the unit file is ours.
            ssx_port_free "$1" && ssx_no_processes || return 1
            return 0
        fi
        [[ $ssx_fragment == "$(ssx_unit)" && $ssx_load == loaded ]] || return 1
        case $ssx_active:$ssx_sub in active:running|inactive:dead|failed:failed) ;; *) return 1 ;; esac
        if [[ $ssx_pid != 0 ]]; then
            python3 - "$ssx_pid" "$(ssx_bin)" <<'PY'
import os, sys
pid, binary = sys.argv[1:]
try:
    actual, wanted = os.stat('/proc/' + pid + '/exe'), os.stat(binary)
    if os.readlink('/proc/' + pid + '/exe') != binary or (actual.st_dev, actual.st_ino) != (wanted.st_dev, wanted.st_ino): sys.exit(1)
except OSError: sys.exit(1)
PY
            [[ $? == 0 ]] || return 1
        fi
        # A start in flight is ambiguous even if the read says inactive: still
        # require a successful stop before deleting.
        [[ $ssx_active == inactive && ${ssx_started:-0} == 0 ]] \
            || systemctl stop terry-toolbox-shadowsocks.service || return 1
        ssx_service_read || return 1
        [[ $ssx_load == loaded && $ssx_fragment == "$(ssx_unit)" && $ssx_pid == 0 ]] || return 1
        [[ $ssx_active == inactive && $ssx_sub == dead || $ssx_active == failed && $ssx_sub == failed ]] || return 1
    else
        ssx_absent_service || return 1
    fi
    ssx_port_free "$1" && ssx_no_processes || return 1
}
ssx_removed() { # exact readback after deletion + daemon-reload
    if [[ ${SSX_BACKEND:-systemd} == alpine ]]; then ssx_fs conflict && ssx_port_free "$1"; return; fi
    ssx_fs conflict || return 1
    ssx_service_read || return 1
    [[ $ssx_load == not-found && -z $ssx_fragment && $ssx_pid == 0 ]] || return 1
    [[ $ssx_active == inactive && $ssx_sub == dead || $ssx_active == failed && $ssx_sub == failed ]] || return 1
    ssx_port_free "$1" || return 1
}
ssx_rollback() {
    local info host port path listen hasunit
    info=$(ssx_fs verify "$ssx_stage") || { ssx_err '没有本次创建的完整可信归属清单，保留现场。'; return 1; }
    read -r host port path listen hasunit <<< "$info"
    ssx_lock_check || return 1
    ssx_stop_gate "$port" "$hasunit" || { ssx_err '停止未确认（未知状态/任务/监听亦拒绝删除）；保留全部文件。'; return 1; }
    ssx_lock_check || return 1
    ssx_fs remove || return 1
    if [[ ${SSX_BACKEND:-systemd} == systemd ]]; then systemctl daemon-reload || return 1; fi
    ssx_removed "$port" || return 1
}
ssx_stage_cleanup() {
    [[ -n ${ssx_stage:-} ]] || return 0
    python3 - "$ssx_stage" "${ssx_stage_id:-}" <<'PY'
import os, sys
p, expected = sys.argv[1:]
st = os.lstat(p)
if f'{st.st_dev}:{st.st_ino}' != expected: sys.exit('staging directory replaced; retained')
allowed = {'config.json','client.json','mihomo.yaml','shadowsocks.txt','xray','xray.zip','unit','validate.log','owned.json',
           'new-cert.pem','new-key.pem','new-unit','new-manifest.json','new-manifest.sha256','old-cert.pem','old-key.pem','old-unit',
           'old-manifest.json','old-manifest.sha256','transaction.json','old-boot-link'}
if os.path.islink(p) or set(os.listdir(p)) - allowed: sys.exit('unknown staging content retained')
for name in os.listdir(p): os.unlink(os.path.join(p, name))
os.rmdir(p)
PY
}
ssx_signal() {
 if [[ ${ssx_registering:-0} == 1 ]]; then ssx_pending_signal=$1
 else exit "$1"; fi
}
ssx_acquire_lock() {
 local rc=0
 ssx_lock_claim=$(python3 -c 'import secrets,sys;print(sys.argv[1]+".claim."+secrets.token_hex(12))' "$(ssx_lock)") || return 1
 # A interrupted unpublished claim cannot block a later operation. Once its
 # identity is returned, cleanup can safely remove either name after rename.
 ssx_registering=1
 ssx_lock_id=$(ssx_fs lock-prepare "$ssx_lock_claim") || rc=$?
 ssx_registering=0
 [[ ${ssx_pending_signal:-0} == 0 ]] || exit "$ssx_pending_signal"
 [[ $rc == 0 && -n $ssx_lock_id ]] || { ssx_err "锁准备失败；未发布全局锁，请保留并检查 $ssx_lock_claim。"; return 1; }
 ssx_fs lock "$ssx_lock_claim" "$ssx_lock_id"
}
ssx_lock_check() { # the held lock must still be the recorded one before a commit
    [[ -n ${ssx_lock_id:-} ]] || return 1
    ssx_fs lock-check "$ssx_lock_id"
}
ssx_finish() {
    local rc=$?
    # Mask termination before removing EXIT; cleanup must not be interrupted.
    trap '' INT TERM HUP
    trap - EXIT
    if [[ ${ssx_writing:-0} == 1 && ${ssx_done:-0} != 1 ]]; then
        [[ $rc != 0 ]] || rc=1
        ssx_rollback || ssx_err "回滚未完成；请保留并人工检查 $(ssx_etc) 与对应 binary/unit。"
    fi
    ssx_stage_cleanup || rc=1
    if [[ -n ${ssx_lock_id:-} ]]; then ssx_fs unlock "$ssx_lock_id" "$ssx_lock_claim" || rc=1; fi
    exit "$rc"
}
ssx_install() (
 set +x +v; set +T; trap - DEBUG RETURN
 umask 077
 local host=${1:-} port=${2:-8388} listen=${TOOLBOX_SS_LISTEN:-0.0.0.0}
 local ssx_stage='' ssx_stage_id='' ssx_lock_id='' ssx_lock_claim='' ssx_registering=0 ssx_pending_signal=0 ssx_writing=0 ssx_done=0 ssx_started=0 parents before i good=0
 (( $# <= 2 )) || { ssx_err '用法：install [入口 [端口]]'; return 1; }
 ssx_require || return 1
 if [[ -z $host ]]; then
  printf '本服务器公网入口（IPv4 或解析至 IPv4 的域名）：'; IFS= read -r host || return 1
  printf 'TCP/UDP 端口 [8388]：'; IFS= read -r port || return 1; port=${port:-8388}
 fi
 ssx_valid_endpoint "$host" && ssx_valid_port "$port" || { ssx_err '入口或端口格式无效。'; return 1; }
 [[ $host != *:* ]] || { ssx_err 'IPv6 字面入口未经验证；请使用 IPv4 或解析至 IPv4 的域名。'; return 1; }
 python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$listen" || return 1
 parents=$(ssx_fs parents) || return 1
 ssx_conflict "$port" || return 1
 trap ssx_finish EXIT; trap 'ssx_signal 130' INT; trap 'ssx_signal 143' TERM HUP
  ssx_acquire_lock || return 1
 ssx_conflict "$port" || return 1
 ssx_err "预览：固定 Xray 26.10.31，Shadowsocks chacha20-ietf-poly1305；监听 IPv4 $listen 的 TCP/UDP $port，入口 $host。"
 ssx_err "新建 $(ssx_etc)、$(ssx_bin)、$(ssx_unit)；启动独立服务，不配置自动启动，不修改防火墙、其他服务或 DNS。"
 ssx_err '成功后在交互终端显示随机密码，请勿分享屏幕或终端日志；重定向时不显示。0600 私有文件包含密码。'
 ssx_err '上游将此 Shadowsocks 组合标记为弃用且无前向保密；速度不保证优于其他协议。服务默认使用 IPv4 通配监听；IPv6 入口未经验证。'
 ssx_confirm || return 1
 before=$(ssx_fs parents) || return 1
 [[ $before == "$parents" ]] || return 1
 ssx_conflict "$port" || return 1
 ssx_stage=$(mktemp -d "${TOOLBOX_SS_STAGE_DIR:-/root}/terry-shadowsocks-stage.XXXXXXXX") || return 1
 ssx_stage_id=$(stat -c '%d:%i' -- "$ssx_stage") || return 1
 ssx_fetch "$ssx_stage" || return 1
 ssx_write_configs "$ssx_stage" "$host" "$port" "$listen" || return 1
 ssx_conflict "$port" || return 1
 ssx_lock_check || return 1
 ssx_writing=1
 ssx_fs publish "$ssx_stage" "$parents" "$host" "$port" /ss "$listen" || return 1
 ssx_fs verify --complete "$ssx_stage" >/dev/null || return 1
 "$(ssx_bin)" run -test -config "$(ssx_etc)/config.json" >"$ssx_stage/validate.log" 2>&1 || { ssx_err 'Xray 配置校验失败。'; return 1; }
 ssx_lock_check || return 1
 if [[ ${SSX_BACKEND:-systemd} == systemd ]]; then
  systemctl daemon-reload || return 1
  ssx_service_read || return 1
  [[ $ssx_load == loaded && $ssx_fragment == "$(ssx_unit)" && $ssx_active == inactive && $ssx_sub == dead && $ssx_pid == 0 ]] || return 1
 fi
 ssx_fs verify --complete "$ssx_stage" >/dev/null || return 1
 ssx_lock_check || return 1
 ssx_started=1
 if [[ ${SSX_BACKEND:-systemd} == alpine ]]; then rc-service terry-toolbox-shadowsocks start || return 1
 else systemctl start terry-toolbox-shadowsocks.service || return 1; fi
 for i in {1..12}; do if ssx_running "$port" "$listen"; then good=1; break; fi; sleep 0.25 || return 1; done
 [[ $good == 1 ]] || { ssx_err '服务或 TCP/UDP 监听归属未通过。'; return 1; }
 ssx_fs verify --complete "$ssx_stage" >/dev/null || return 1
 ssx_running "$port" "$listen" || return 1
 ssx_lock_check || return 1
  ssx_done=1
 printf '安装完成；TCP/UDP 监听归属已验证，公网连接和手机导入尚需另验。\n'
 if [[ -t 0 && -t 1 ]]; then
  printf '请勿分享屏幕或终端日志；节点密码：'
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inbounds"][0]["settings"]["password"])' "$(ssx_etc)/config.json" || return 1
 else printf '非交互或重定向：密码不回显。\n'; fi
 printf '0600 客户端文件：%s/{shadowsocks.txt,mihomo.yaml,client.json}\n' "$(ssx_etc)"
 printf '需要自行放行 TCP 和 UDP %s；未启用开机自启。\n' "$port"
)
ssx_status() (
 local info host port path listen hasunit
 ssx_require || return 1
 info=$(ssx_fs verify --complete) || { ssx_err '资源不完整或归属未知。'; return 1; }
 read -r host port path listen hasunit <<< "$info"
 ssx_running "$port" "$listen" || { ssx_err '服务或 TCP/UDP 监听归属未知。'; return 1; }
 printf 'Shadowsocks active：%s:%s，客户端文件位于 %s。\n' "$listen" "$port" "$(ssx_etc)"
)
ssx_show() (
 set +x +v; set +T; trap - DEBUG RETURN
 ssx_require || return 1
 ssx_fs verify --complete >/dev/null || return 1
 [[ -t 0 && -t 1 ]] || { ssx_err '只在交互终端显示密码，重定向请安全读取 0600 导出文件。'; return 1; }
 printf '请勿分享屏幕或终端日志；节点密码：'
 python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["inbounds"][0]["settings"]["password"])' "$(ssx_etc)/config.json"
)
ssx_uninstall() (
 local ssx_lock_id='' ssx_lock_claim='' ssx_registering=0 ssx_pending_signal=0 ssx_started=0 ssx_stage='' ssx_stage_id='' ssx_writing=0 ssx_done=1
 local info host port path listen hasunit before
 ssx_require || return 1
 info=$(ssx_fs verify) || return 1
 trap ssx_finish EXIT; trap 'ssx_signal 130' INT; trap 'ssx_signal 143' TERM HUP
  ssx_acquire_lock || return 1
 before=$(ssx_fs verify) || return 1; [[ $info == "$before" ]] || return 1
 ssx_err "将停止独立服务并删除精确归属资源 $(ssx_etc)、$(ssx_bin)、$(ssx_unit)；不动其他服务。"
 ssx_confirm || return 1
 before=$(ssx_fs verify) || return 1; [[ $info == "$before" ]] || return 1
 read -r host port path listen hasunit <<< "$info"
 ssx_lock_check || return 1
 ssx_stop_gate "$port" "$hasunit" || { ssx_err '停止或监听状态未知，保留资源。'; return 1; }
 ssx_fs verify >/dev/null || return 1
 ssx_lock_check || return 1
 ssx_fs remove || return 1
 if [[ ${SSX_BACKEND:-systemd} == systemd ]]; then systemctl daemon-reload || return 1; fi
 ssx_removed "$port" || return 1
 printf '独立 Shadowsocks 服务已卸载。\n'
)
toolbox_shadowsocks() {
 local backend=${1:-} action=${2:-}; (( $# >= 2 )) || { ssx_err '用法：toolbox_shadowsocks alpine|systemd install|status|show|uninstall'; return 1; }
 shift 2
 case $backend in
  systemd) local SSX_BACKEND=systemd; case $action in
   install) ssx_install "$@";; status) (( $# == 0 )) && ssx_status;; show) (( $# == 0 )) && ssx_show;; uninstall) (( $# == 0 )) && ssx_uninstall;;
   *) ssx_err '未知动作。'; return 1;; esac;;
  alpine) local SSX_BACKEND=alpine; case $action in
   install) ssx_install "$@";; status) (( $# == 0 )) && ssx_status;; show) (( $# == 0 )) && ssx_show;; uninstall) (( $# == 0 )) && ssx_uninstall;;
   *) ssx_err '未知动作。'; return 1;; esac;;
  *) ssx_err '未知后端。'; return 1;;
 esac
}
if [[ ${BASH_SOURCE[0]:-} == "$0" && ${TOOLBOX_BUNDLED:-0} != 1 ]]; then toolbox_shadowsocks "$@"; fi
