#!/usr/bin/env bash
# A5: independent VMess + WebSocket + TLS; source-only, Debian/systemd only.
# Requires modules/network.sh (certificate checks and pinned Xray release table).
# Test/path overrides (defaults are the real host paths):
# TOOLBOX_VM_WS_ETC=/etc/terry-toolbox-vmess (the entire directory, not its parent)
# TOOLBOX_VM_WS_BIN_DIR=/usr/local/bin
# TOOLBOX_VM_WS_UNIT_DIR=/etc/systemd/system
# TOOLBOX_VM_WS_LOCK=/run/terry-toolbox-vmess.lock (exclusive directory lock; the
#   lock is on tmpfs, so only its own inode is a gate, never its parent's inode)
# TOOLBOX_VM_WS_OS_RELEASE=/etc/os-release
# TOOLBOX_VM_WS_SYSTEMD_RUN=/run/systemd/system
# TOOLBOX_VM_WS_LISTEN=0.0.0.0 (IPv4 only)
# TOOLBOX_VM_WS_ZIP_SRC= (optional local zip; still checked against pinned SHA-256)
# Trust anchors: shared TOOLBOX_NET_CAFILE / TOOLBOX_NET_CAPATH, never insecure.
# SHA test overrides are inherited from net_a5_sha256; no VMess-specific bypass.

# Remember only the source directory; dependency work remains lazy. Bundles
# already contain the core and must never look beside the downloaded script.
_TOOLBOX_VMESS_MODULE_DIR=''
if [[ ${TOOLBOX_BUNDLED:-0} != 1 ]]; then
    case ${BASH_SOURCE[0]} in
        */*) _TOOLBOX_VMESS_MODULE_DIR=${BASH_SOURCE[0]%/*};;
        *) _TOOLBOX_VMESS_MODULE_DIR=.;;
    esac
    _TOOLBOX_VMESS_MODULE_DIR=$(CDPATH= builtin cd -- "$_TOOLBOX_VMESS_MODULE_DIR" && builtin pwd -P) || _TOOLBOX_VMESS_MODULE_DIR=''
fi

vmess_err() { printf '%s\n' "$*" >&2; }
vmess_etc() { printf '%s\n' "${TOOLBOX_VM_WS_ETC:-/etc/terry-toolbox-vmess}"; }
vmess_bin() { printf '%s/terry-toolbox-vmess\n' "${TOOLBOX_VM_WS_BIN_DIR:-/usr/local/bin}"; }
vmess_unit() { printf '%s/terry-toolbox-vmess.service\n' "${TOOLBOX_VM_WS_UNIT_DIR:-/etc/systemd/system}"; }
vmess_lock() { printf '%s\n' "${TOOLBOX_VM_WS_LOCK:-/run/terry-toolbox-vmess.lock}"; }
vmess_valid_input() {
    [[ ${#1} -le 253 && $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
    [[ $2 =~ ^[1-9][0-9]{0,4}$ ]] && (( $2 <= 65535 )) || return 1
    [[ ${#3} -le 128 && $3 =~ ^/[A-Za-z0-9_/-]*$ && $3 != *//* ]] || return 1
}
vmess_confirm() {
    local answer i
    for i in 1 2; do
        printf '第 %s 次确认：输入 YES 继续（空白/EOF 取消）：' "$i"
        IFS= read -r answer && [[ ${answer^^} == YES ]] || { vmess_err '已取消。'; return 1; }
    done
}
vmess_dependencies() {
    local dependency
    for dependency in "$@"; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            declare -F toolbox_require_commands >/dev/null || { [[ -n ${_TOOLBOX_VMESS_MODULE_DIR:-} ]] && source "$_TOOLBOX_VMESS_MODULE_DIR/dependencies.sh"; } || return 1
            toolbox_require_commands 'A5 VMess' "$@" || return 1
            return 0
        fi
    done
}
vmess_require() {
    local c id='' line
    [[ ${EUID:-1} == 0 ]] || { vmess_err '需要 root。'; return 1; }
    vmess_dependencies python3 systemctl ss openssl curl mktemp uname stat date cut grep sleep || return 1
    for c in net_check_cert net_tls_trusted net_a5_zip_url net_a5_sha256; do
        declare -F "$c" >/dev/null || { vmess_err "缺少共享函数：$c"; return 1; }
    done
    [[ -r ${TOOLBOX_VM_WS_OS_RELEASE:-/etc/os-release} ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in ID=*) [[ -z $id ]] || return 1; id=${line#ID=}; id=${id#\"}; id=${id%\"}; id=${id#\'}; id=${id%\'} ;; esac
    done < "${TOOLBOX_VM_WS_OS_RELEASE:-/etc/os-release}"
    [[ $id == debian ]] || { vmess_err 'VMess 仅支持 ID=debian。'; return 1; }
    [[ -d ${TOOLBOX_VM_WS_SYSTEMD_RUN:-/run/systemd/system} ]] || { vmess_err 'systemd 未运行。'; return 1; }
    python3 -c 'import ssl, zipfile, hashlib, json, ipaddress' || return 1
    vmess_arch >/dev/null || return 1
}
vmess_arch() {
    case $(uname -m) in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) vmess_err "不支持的 CPU 架构：$(uname -m)（仅 amd64/arm64）。"; return 1 ;;
    esac
}

# Anchored openat(O_NOFOLLOW) paths, exclusive writes and an exact inode/hash ledger.
# Persistent parents (etc/binary/unit) are sealed; the boot-local lock parent is
# revalidated for safety but the held lock's own inode is what gates a commit.
# A failure before a sealed ledger is available is deliberately retained, never guessed.
# No recursive removal, manifest path evaluation, symlink traversal or overwrite.
vmess_fs() {
    python3 - "$1" "$(vmess_etc)" "$(vmess_bin)" "$(vmess_unit)" "$(vmess_lock)" "${@:2}" <<'PY'
import os, sys, stat, json, hashlib, re, ipaddress, uuid
op, etc, binary, unit, lock, *args = sys.argv[1:]
NAME = 'terry-toolbox-vmess.service'
LEAVES = ('cert.pem', 'key.pem', 'config.json', 'client.json', 'vmess.txt')
allowed = {os.path.join(etc, n): 0o600 for n in LEAVES}
allowed.update({binary: 0o755, unit: 0o644})
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
    tmp = '.terry-vmess-' + uuid.uuid4().hex
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
    if not isinstance(meta['host'], str) or not re.fullmatch(r'[a-z0-9.-]{1,253}', meta['host']): raise ValueError('invalid host')
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
            fd = directory(BOOTDIR); tmp = '.terry-vmess-link-' + uuid.uuid4().hex; owned = None
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
    elif op == 'lock':
        fd, name = parent(lock)
        try:
            os.mkdir(name, 0o700, dir_fd=fd)
            print(ident(os.stat(name, dir_fd=fd, follow_symlinks=False)))
        finally: os.close(fd)
    elif op == 'unlock':
        fd, name = parent(lock)
        try:
            if ident(os.stat(name, dir_fd=fd, follow_symlinks=False)) != args[0]: raise ValueError('lock replaced; retained')
            os.rmdir(name, dir_fd=fd)
        finally: os.close(fd)
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
    print('VMess 文件安全检查失败: ' + str(exc), file=sys.stderr); sys.exit(1)
PY
}

# Read one coherent systemd property snapshot. Unreadable/missing/duplicate facts
# are unknown, never a claim of an absent or stopped service.
vmess_service_read() {
    local output line key value
    local -A seen=()
    output=$(systemctl show terry-toolbox-vmess.service --no-pager --all \
        -p LoadState -p ActiveState -p SubState -p MainPID -p FragmentPath -p DropInPaths -p Job 2>/dev/null) || return 1
    vmess_load='' vmess_active='' vmess_sub='' vmess_pid='' vmess_fragment='' vmess_dropins='' vmess_job=''
    while IFS= read -r line; do
        [[ $line == *=* ]] || return 1
        key=${line%%=*}; value=${line#*=}
        [[ ! ${seen[$key]+x} ]] || return 1
        seen[$key]=1
        case $key in
            LoadState) vmess_load=$value ;; ActiveState) vmess_active=$value ;; SubState) vmess_sub=$value ;;
            MainPID) vmess_pid=$value ;; FragmentPath) vmess_fragment=$value ;; DropInPaths) vmess_dropins=$value ;; Job) vmess_job=$value ;;
            *) return 1 ;;
        esac
    done <<< "$output"
    [[ ${#seen[@]} == 7 && $vmess_pid =~ ^[0-9]+$ ]] || return 1
    [[ -z $vmess_dropins && ( -z $vmess_job || $vmess_job == 0 ) ]] || return 1
}
vmess_absent_service() {
    vmess_service_read || return 1
    [[ $vmess_load == not-found && $vmess_active == inactive && $vmess_sub == dead && $vmess_pid == 0 && -z $vmess_fragment ]]
}
vmess_port_lines() {
    local output
    output=$(ss -ltnpH 2>/dev/null) || { vmess_err 'ss 读取失败，端口状态未知。'; return 1; }
    VMESS_SS="$output" python3 - "$1" <<'PY'
import os, sys
port = sys.argv[1]
for line in os.environ['VMESS_SS'].splitlines():
    fields = line.split()
    if len(fields) < 5 or fields[0] != 'LISTEN': sys.exit('unparseable TCP listener table')
    if fields[3].rsplit(':', 1)[-1] == port: print(line)
PY
}
vmess_port_free() {
    local lines
    lines=$(vmess_port_lines "$1") || return 1
    [[ -z $lines ]] || { vmess_err "TCP $1 已有监听；未接管。"; return 1; }
}
vmess_socket_owned() { # port MainPID listen binary; real /proc identity, no name fallback
    local lines
    lines=$(vmess_port_lines "$1") || return 1
    VMESS_SS="$lines" python3 - "$2" "$3" "$4" <<'PY'
import os, sys, re
pid, listen, binary = sys.argv[1:]
try:
    if not re.fullmatch(r'[1-9][0-9]*', pid): raise ValueError()
    if os.readlink('/proc/' + pid + '/exe') != binary: raise ValueError()
    actual, wanted = os.stat('/proc/' + pid + '/exe'), os.stat(binary)
    if (actual.st_dev, actual.st_ino) != (wanted.st_dev, wanted.st_ino): raise ValueError()
    lines = os.environ['VMESS_SS'].splitlines()
    if not lines: raise ValueError()
    for line in lines:
        fields = line.split(); address = fields[3].rsplit(':', 1)[0]
        if address != listen or set(re.findall(r'pid=([0-9]+)', line)) != {pid}: raise ValueError()
except (ValueError, OSError): sys.exit(1)
PY
}
vmess_running() {
    vmess_service_read || return 1
    [[ $vmess_load == loaded && $vmess_active == active && $vmess_sub == running && $vmess_fragment == "$(vmess_unit)" ]] || return 1
    vmess_socket_owned "$1" "$vmess_pid" "$2" "$(vmess_bin)" || return 1
}
vmess_conflict() {
    vmess_fs conflict || return 1
    vmess_absent_service || { vmess_err 'systemd 已加载/状态未知/存在任务或 drop-in；拒绝接管。'; return 1; }
    vmess_port_free "$1" || return 1
}
vmess_certificate() {
    local start now epoch
    # Reject encrypted keys without prompting or consuming confirmation input.
    openssl pkey -in "$2" -passin pass: -noout >/dev/null 2>&1 || return 1
    net_check_cert "$1" "$2" "$3" || return 1
    # Also explicitly propagate date-read failures (the shared legacy helper can
    # mask a pipeline error when called from a conditional menu).
    start=$(openssl x509 -in "$1" -noout -startdate 2>/dev/null) || return 1
    [[ $start == notBefore=* ]] || return 1
    epoch=$(date -d "${start#notBefore=}" +%s) || return 1
    now=$(date +%s) || return 1
    [[ $epoch =~ ^-?[0-9]+$ && $now =~ ^[0-9]+$ ]] && (( epoch <= now )) || return 1
    net_tls_trusted "$1" || { vmess_err '证书链不被信任；没有 insecure 降级。'; return 1; }
}
vmess_existing_certificate() {
    # Only the exact sealed installed pair can use expiry-independent recovery.
    # This helper is never used for a candidate pair or the post-start TLS probe.
    local info host port path listen hasunit cert key pub keypub start epoch now help
    local cafile=${TOOLBOX_NET_CAFILE-/etc/ssl/certs/ca-certificates.crt}
    local capath=${TOOLBOX_NET_CAPATH-/etc/ssl/certs}
    local -a trust=()
    info=$(vmess_fs verify --complete) || return 1
    read -r host port path listen hasunit <<< "$info"
    cert=$(vmess_etc)/cert.pem; key=$(vmess_etc)/key.pem
    pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) || return 1
    keypub=$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null) || return 1
    [[ $pub == "$keypub" ]] || return 1
    start=$(openssl x509 -in "$cert" -startdate -noout 2>/dev/null) || return 1
    [[ $start == notBefore=* ]] || return 1
    epoch=$(date -d "${start#notBefore=}" +%s) || return 1
    now=$(date +%s) || return 1
    [[ $epoch =~ ^-?[0-9]+$ && $now =~ ^[0-9]+$ ]] && (( epoch <= now )) || return 1
    [[ ! ${TOOLBOX_NET_CAFILE+x} || -n $cafile ]] || return 1
    [[ ${TOOLBOX_NET_CAFILE+x} || -r $cafile ]] || cafile=''
    if [[ -n $cafile ]]; then
        [[ -f $cafile && -r $cafile && -s $cafile ]] || return 1
        trust=(-CAfile "$cafile" -no-CApath)
    else
        [[ -n $capath && -d $capath ]] || return 1
        trust=(-CApath "$capath" -no-CAfile)
    fi
    help=$(openssl verify -help 2>&1) || :
    if [[ $help == *-no-CAstore* ]]; then trust+=(-no-CAstore); fi
    openssl verify "${trust[@]}" -no_check_time -purpose sslserver -verify_hostname "$host" -untrusted "$cert" "$cert" >/dev/null 2>&1
}
vmess_fetch() { # stage: fixed official URL and whitelist, local archive is not trusted
    local arch url hash
    arch=$(vmess_arch) || return 1
    url=$(net_a5_zip_url "$arch") || { vmess_err "无法构造 $arch 的 Xray 下载地址。"; return 1; }
    hash=$(net_a5_sha256 "$arch") || { vmess_err "没有 $arch 的固定校验值。"; return 1; }
    [[ $hash =~ ^[0-9a-f]{64}$ && $url == https://github.com/XTLS/Xray-core/releases/download/v26.10.29/Xray-linux-*.zip ]] \
        || { vmess_err "固定版本/校验值/下载地址不一致：$url"; return 1; }
    if [[ -n ${TOOLBOX_VM_WS_ZIP_SRC:-} ]]; then
        python3 - "$TOOLBOX_VM_WS_ZIP_SRC" "$1/xray.zip" <<'PY'
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
vmess_write_configs() { # stage cert key hostname port ws_path listen
    python3 - "$@" "$(vmess_etc)" "$(vmess_bin)" <<'PY'
import os, sys, json, uuid, base64, ipaddress
stage, cert, key, host, port, path, listen, etc, binary = sys.argv[1:]
ipaddress.IPv4Address(listen); port = int(port); uid = str(uuid.uuid4())
for src, dest in ((cert, 'cert.pem'), (key, 'key.pem')):
    with open(src, 'rb') as f: data = f.read()
    with open(stage + '/' + dest, 'xb') as f: f.write(data)
    os.chmod(stage + '/' + dest, 0o600)
transport = {'network':'ws','security':'tls','tlsSettings':{'serverName':host,'alpn':['http/1.1'],'minVersion':'1.2',
            'certificates':[{'certificateFile':etc+'/cert.pem','keyFile':etc+'/key.pem'}]}, 'wsSettings':{'path':path,'host':host,'acceptProxyProtocol':False}}
config = {'log':{'loglevel':'warning'}, 'inbounds':[{'tag':'vmess-ws-tls','listen':listen,'port':port,'protocol':'vmess',
          'settings':{'clients':[{'id':uid,'alterId':0}]},'streamSettings':transport}], 'outbounds':[{'protocol':'freedom','tag':'direct'}]}
client = {'log':{'loglevel':'warning'}, 'inbounds':[{'listen':'127.0.0.1','port':1080,'protocol':'socks','settings':{'auth':'noauth','udp':False}}],
          'outbounds':[{'protocol':'vmess','settings':{'vnext':[{'address':host,'port':port,'users':[{'id':uid,'alterId':0,'security':'auto'}]}]},
          'streamSettings':{'network':'ws','security':'tls','tlsSettings':{'serverName':host,'allowInsecure':False,'alpn':['http/1.1']},
                            'wsSettings':{'path':path,'host':host}}}]}
for name, data in (('config.json', config), ('client.json', client)):
    with open(stage + '/' + name, 'x') as f: json.dump(data, f, indent=2); f.write('\n')
    os.chmod(stage + '/' + name, 0o600)
share = {'v':'2','ps':'Terry VMess WS TLS','add':host,'port':str(port),'id':uid,'aid':'0','scy':'auto','net':'ws','type':'none','host':host,'path':path,'tls':'tls','sni':host,'alpn':'http/1.1'}
with open(stage + '/vmess.txt', 'x') as f: f.write('vmess://' + base64.b64encode(json.dumps(share).encode()).decode() + '\n')
os.chmod(stage + '/vmess.txt', 0o600)
text = f'''[Unit]
Description=Terry Toolbox VMess WebSocket TLS server
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
'''
with open(stage + '/unit', 'x') as f: f.write(text)
os.chmod(stage + '/unit', 0o644)
PY
}
vmess_tls_probe() { # cert hostname port listen [ws_path]; exact TLS leaf + WS upgrade
    local cafile=${TOOLBOX_NET_CAFILE-/etc/ssl/certs/ca-certificates.crt}
    local capath=${TOOLBOX_NET_CAPATH-/etc/ssl/certs}
    [[ ! ${TOOLBOX_NET_CAFILE+x} || -n $cafile ]] || return 1
    [[ ${TOOLBOX_NET_CAFILE+x} || -r $cafile ]] || cafile=''
    TOOLBOX_NET_CAFILE="$cafile" TOOLBOX_NET_CAPATH="$capath" python3 - "$@" <<'PY'
import os, sys, ssl, socket, re, base64, hashlib
cert, host, port, listen, *paths = sys.argv[1:]
path = paths[0] if paths else '/vmess'
if not re.fullmatch(r'/[A-Za-z0-9_/-]{0,127}', path): sys.exit('invalid WS path')
cafile = os.environ.get('TOOLBOX_NET_CAFILE', '/etc/ssl/certs/ca-certificates.crt')
capath = os.environ.get('TOOLBOX_NET_CAPATH', '/etc/ssl/certs')
if 'TOOLBOX_NET_CAFILE' not in os.environ and not os.path.isfile(cafile): cafile = None
ctx = ssl.create_default_context(cafile=cafile or None, capath=None if cafile else capath)
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.set_alpn_protocols(['http/1.1'])
with open(cert) as f: leaf = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', f.read(), re.S).group()
expected = ssl.PEM_cert_to_DER_cert(leaf)
with socket.create_connection(('127.0.0.1' if listen == '0.0.0.0' else listen, int(port)), timeout=3) as raw:
    with ctx.wrap_socket(raw, server_hostname=host) as tls:
        if tls.getpeercert(binary_form=True) != expected: sys.exit('wrong TLS leaf')
        key = base64.b64encode(os.urandom(16)).decode()
        request = f'GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n'
        tls.sendall(request.encode('ascii'))
        response = b''
        while b'\r\n\r\n' not in response and len(response) < 16384:
            chunk = tls.recv(4096)
            if not chunk: break
            response += chunk
        lines = response.split(b'\r\n')
        if not lines[0].startswith(b'HTTP/1.1 101 '): sys.exit('WebSocket upgrade failed')
        headers = {}
        for line in lines[1:]:
            if not line: break
            name, value = line.split(b':', 1); headers[name.lower()] = value.strip()
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        if headers.get(b'sec-websocket-accept') != accept or headers.get(b'upgrade', b'').lower() != b'websocket' or headers.get(b'connection', b'').lower() != b'upgrade':
            sys.exit('invalid WebSocket response')
PY
}

# Authentication/data-plane acceptance is intentionally external (see
# tests/vmess-protocol-test.py). Xray blocks private destinations by default;
# installation must not weaken that policy merely to probe a loopback target.
vmess_stop_gate() { # port has_owned_unit
    if [[ $2 == 1 ]]; then
        vmess_service_read || return 1
        if [[ $vmess_load == not-found && $vmess_active == inactive && $vmess_sub == dead && $vmess_pid == 0 && -z $vmess_fragment && ${vmess_started:-0} == 0 ]]; then
            # Published, daemon-reload or the first reload failed, and start was
            # never attempted. verify() already proved the unit file is ours.
            vmess_port_free "$1" || return 1
            return 0
        fi
        [[ $vmess_fragment == "$(vmess_unit)" && $vmess_load == loaded ]] || return 1
        case $vmess_active:$vmess_sub in active:running|inactive:dead|failed:failed) ;; *) return 1 ;; esac
        if [[ $vmess_pid != 0 ]]; then
            python3 - "$vmess_pid" "$(vmess_bin)" <<'PY'
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
        [[ $vmess_active == inactive && ${vmess_started:-0} == 0 ]] \
            || systemctl stop terry-toolbox-vmess.service || return 1
        vmess_service_read || return 1
        [[ $vmess_load == loaded && $vmess_fragment == "$(vmess_unit)" && $vmess_pid == 0 ]] || return 1
        [[ $vmess_active == inactive && $vmess_sub == dead || $vmess_active == failed && $vmess_sub == failed ]] || return 1
    else
        vmess_absent_service || return 1
    fi
    vmess_port_free "$1" || return 1
}
vmess_removed() { # exact readback after deletion + daemon-reload
    vmess_fs conflict || return 1
    vmess_service_read || return 1
    [[ $vmess_load == not-found && -z $vmess_fragment && $vmess_pid == 0 ]] || return 1
    [[ $vmess_active == inactive && $vmess_sub == dead || $vmess_active == failed && $vmess_sub == failed ]] || return 1
    vmess_port_free "$1" || return 1
}
vmess_rollback() {
    local info host port path listen hasunit
    info=$(vmess_fs verify "$vmess_stage") || { vmess_err '没有本次创建的完整可信归属清单，保留现场。'; return 1; }
    read -r host port path listen hasunit <<< "$info"
    vmess_lock_check || return 1
    vmess_stop_gate "$port" "$hasunit" || { vmess_err '停止未确认（未知状态/任务/监听亦拒绝删除）；保留全部文件。'; return 1; }
    vmess_lock_check || return 1
    vmess_fs remove || return 1
    systemctl daemon-reload || return 1
    vmess_removed "$port" || return 1
}
vmess_stage_cleanup() {
    [[ -n ${vmess_stage:-} ]] || return 0
    python3 - "$vmess_stage" "${vmess_stage_id:-}" <<'PY'
import os, sys
p, expected = sys.argv[1:]
st = os.lstat(p)
if f'{st.st_dev}:{st.st_ino}' != expected: sys.exit('staging directory replaced; retained')
allowed = {'cert.pem','key.pem','config.json','client.json','vmess.txt','xray','xray.zip','unit','validate.log','owned.json',
           'new-cert.pem','new-key.pem','new-unit','new-manifest.json','new-manifest.sha256','old-cert.pem','old-key.pem','old-unit',
           'old-manifest.json','old-manifest.sha256','transaction.json','old-boot-link'}
if os.path.islink(p) or set(os.listdir(p)) - allowed: sys.exit('unknown staging content retained')
for name in os.listdir(p): os.unlink(os.path.join(p, name))
os.rmdir(p)
PY
}
vmess_lock_check() { # the held lock must still be the recorded one before a commit
    [[ -n ${vmess_lock_id:-} ]] || return 1
    vmess_fs lock-check "$vmess_lock_id"
}
vmess_finish() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if [[ ${vmess_writing:-0} == 1 && ${vmess_done:-0} != 1 ]]; then
        [[ $rc != 0 ]] || rc=1
        vmess_rollback || vmess_err "回滚未完成；请保留并人工检查 $(vmess_etc) 与对应 binary/unit。"
    fi
    vmess_stage_cleanup || rc=1
    if [[ -n ${vmess_lock_id:-} ]]; then vmess_fs unlock "$vmess_lock_id" || rc=1; fi
    exit "$rc"
}
vmess_install() (
    umask 077
    local cert=${1:-} key=${2:-} host=${3:-} port=${4:-443} path=${5:-/vmess} listen=${TOOLBOX_VM_WS_LISTEN:-0.0.0.0}
    local vmess_stage='' vmess_stage_id='' vmess_lock_id='' vmess_writing=0 vmess_done=0 vmess_started=0 parents before i good=0
    (( $# == 0 || $# >= 3 && $# <= 5 )) || { vmess_err '用法: toolbox_vmess install [cert key hostname [port] [ws_path]]'; return 2; }
    vmess_require || return 1
    if (( $# == 0 )); then
        printf '已有 PEM 完整证书链绝对路径：'; IFS= read -r cert || return 1
        printf '已有 PEM 私钥绝对路径：'; IFS= read -r key || return 1
        printf '证书覆盖的域名：'; IFS= read -r host || return 1
        printf 'TCP 端口 [443]：'; IFS= read -r port || return 1; port=${port:-443}
        printf 'WebSocket 路径 [/vmess]：'; IFS= read -r path || return 1; path=${path:-/vmess}
    fi
    vmess_valid_input "$host" "$port" "$path" || { vmess_err '域名/端口/WS 路径不安全或格式错误。'; return 1; }
    [[ $cert =~ ^/[A-Za-z0-9_./-]+$ ]] \
        || { vmess_err "证书路径须为绝对路径，只含字母/数字/_ . / -（不含空格）：$cert"; return 1; }
    [[ $key =~ ^/[A-Za-z0-9_./-]+$ ]] \
        || { vmess_err "私钥路径须为绝对路径，只含字母/数字/_ . / -（不含空格）：$key"; return 1; }
    [[ /$cert/ != */../* && /$cert/ != */./* && /$key/ != */../* && /$key/ != */./* ]] \
        || { vmess_err '证书/私钥路径不能含 . 或 .. 段。'; return 1; }
    python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$listen" \
        || { vmess_err "监听地址不是 IPv4：$listen"; return 1; }
    parents=$(vmess_fs parents) || { vmess_err '目标路径不安全（需 root 所有且不可被组/其他人写）。'; return 1; }
    vmess_certificate "$cert" "$key" "$host" || { vmess_err '证书/私钥检查未通过（见上）；未改动。'; return 1; }
    vmess_conflict "$port" || return 1
    vmess_lock_id=$(vmess_fs lock) || { vmess_err '无法取得安装锁（可能已有安装/卸载在进行）。'; return 1; }
    trap vmess_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    vmess_conflict "$port" || return 1
    vmess_err "预览：Xray v26.10.29，VMess + WS + TLS，IPv4 $listen:$port，域名 $host，路径 $path。"
    vmess_err "新建 $(vmess_etc)（证书/私钥/config.json/client.json/vmess.txt/归属清单），$(vmess_bin)，$(vmess_unit)。"
    vmess_err '兼容用途：固定版上游已弃用 VMess（无前向保密）与 WS（特征明显）；新部署不优先推荐此协议组合。'
    vmess_err '将启动独立服务并执行 TLS/WS 握手自检（不代表 VMess 认证或公网数据面验收）；不动 REALITY/已有服务，不配置 ACME/防火墙，不设开机自启。'
    vmess_confirm || return 1
    before=$(vmess_fs parents) || return 1
    [[ $before == "$parents" ]] || { vmess_err '父目录已更换。'; return 1; }
    vmess_conflict "$port" || return 1
    vmess_certificate "$cert" "$key" "$host" || return 1
    vmess_stage=$(mktemp -d "${TMPDIR:-/run}/terry-vmess-stage.XXXXXXXX") || return 1
    vmess_stage_id=$(stat -c '%d:%i' -- "$vmess_stage") || return 1
    vmess_fetch "$vmess_stage" || return 1
    vmess_write_configs "$vmess_stage" "$cert" "$key" "$host" "$port" "$path" "$listen" || return 1
    vmess_certificate "$vmess_stage/cert.pem" "$vmess_stage/key.pem" "$host" || return 1
    vmess_conflict "$port" || return 1
    vmess_lock_check || { vmess_err '安装锁已被替换（可能另有实例）；未发布。'; return 1; }
    vmess_writing=1
    vmess_fs publish "$vmess_stage" "$parents" "$host" "$port" "$path" "$listen" || return 1
    vmess_fs verify --complete "$vmess_stage" >/dev/null || return 1
    "$(vmess_bin)" run -test -config "$(vmess_etc)/config.json" >"$vmess_stage/validate.log" 2>&1 || { vmess_err 'Xray 配置校验失败。'; return 1; }
    vmess_lock_check || return 1
    systemctl daemon-reload || return 1
    vmess_service_read || return 1
    [[ $vmess_load == loaded && $vmess_fragment == "$(vmess_unit)" && $vmess_active == inactive && $vmess_sub == dead && $vmess_pid == 0 ]] || return 1
    vmess_fs verify --complete "$vmess_stage" >/dev/null || return 1
    vmess_lock_check || return 1
    vmess_started=1
    systemctl start terry-toolbox-vmess.service || return 1
    for i in {1..12}; do
        if vmess_running "$port" "$listen" && vmess_tls_probe "$(vmess_etc)/cert.pem" "$host" "$port" "$listen" "$path" >/dev/null 2>&1; then good=1; break; fi
        sleep 0.25 || return 1
    done
    [[ $good == 1 ]] || { vmess_err 'service/socket/TLS 验证未通过。'; return 1; }
    vmess_fs verify --complete "$vmess_stage" >/dev/null || return 1
    vmess_running "$port" "$listen" || return 1
    vmess_lock_check || return 1
    vmess_done=1
    vmess_err "服务状态、TCP 归属及 TLS/WS 握手已验证；VMess 认证/公网连通仍需外部验收。客户端 Xray 配置：$(vmess_etc)/client.json（本地 SOCKS 127.0.0.1:1080）；导入链接：$(vmess_etc)/vmess.txt。"
    vmess_err '凭据文件均 0600，未打印 UUID。域名需由您指向服务器；证书续期/防火墙需人工管理；自启默认关闭，可显式 enable-boot。'
)
vmess_status() (
    local info host port path listen hasunit
    vmess_require || return 1
    info=$(vmess_fs verify --complete) || { vmess_err 'VMess 未安装或资源归属/完整性未知。'; return 1; }
    read -r host port path listen hasunit <<< "$info"
    [[ $hasunit == 1 ]] || return 1
    vmess_running "$port" "$listen" || { vmess_err 'VMess 未运行或 service/socket 归属未知。'; return 1; }
    vmess_certificate "$(vmess_etc)/cert.pem" "$(vmess_etc)/key.pem" "$host" || return 1
    vmess_tls_probe "$(vmess_etc)/cert.pem" "$host" "$port" "$listen" "$path" || return 1
    vmess_err "VMess active：TLS/端口归属通过，$listen:$port；客户端文件位于 $(vmess_etc)（凭据未显示）。"
)
vmess_uninstall() (
    local vmess_stage='' vmess_stage_id='' vmess_lock_id='' vmess_token='' vmess_changing=0 vmess_done=0 vmess_mode=boot
    local info host port path listen hasunit before bootinfo
    vmess_require || return 1
    info=$(vmess_fs verify) || return 1
    vmess_lock_id=$(vmess_fs lock) || return 1
    trap vmess_manage_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    before=$(vmess_fs verify) || return 1
    [[ $info == "$before" ]] || return 1
    vmess_err "预览：停止 terry-toolbox-vmess.service；仅删除清单中 inode/SHA-256 未改变的 $(vmess_etc)、$(vmess_bin)、$(vmess_unit)。不动原始证书和其他服务。"
    vmess_confirm || return 1
    before=$(vmess_fs verify) || return 1
    [[ $info == "$before" ]] || return 1
    read -r host port path listen hasunit <<< "$info"
    vmess_lock_check || { vmess_err '安装锁已被替换；未停止。'; return 1; }
    vmess_stop_gate "$port" "$hasunit" || { vmess_err '停止/状态/任务/端口尚未确认；未删除任何资源。'; return 1; }
    bootinfo=$(vmess_fs boot-info) || return 1
    if [[ $bootinfo == '2 enabled' ]]; then
        vmess_boot_readback || return 1
        vmess_boot_change_locked disable-boot || return 1
        vmess_fs transaction-clean "$vmess_stage" "$vmess_token" || return 1
        vmess_stage=''; vmess_token=''; vmess_changing=0; vmess_done=0
    fi
    vmess_fs verify >/dev/null || return 1
    vmess_lock_check || return 1
    vmess_fs remove || return 1
    systemctl daemon-reload || return 1
    vmess_removed "$port" || return 1
    vmess_done=1
    vmess_err 'VMess 独立资源已卸载（原始证书/私钥未删除）。'
)
# Management never adopts a systemd-created link: create the one exact link
# ourselves with O_EXCL semantics, then ask systemd to enable and read back both.
vmess_boot_readback() {
    local info version state result want
    info=$(vmess_fs boot-info) || return 1
    read -r version state <<< "$info"
    result=$(systemctl show terry-toolbox-vmess.service --no-pager -p UnitFileState 2>/dev/null) || return 1
    want=$state
    [[ $version != 1 || $state != disabled ]] || want=static
    [[ $result == "UnitFileState=$want" ]] || { vmess_err 'systemd 自启状态与已验证清单不一致；未作推断。'; return 1; }
}
vmess_boot_status() (
    local info
    vmess_require || return 1
    vmess_fs verify --complete >/dev/null || return 1
    vmess_boot_readback || return 1
    vmess_service_read || return 1
    [[ $vmess_load == loaded && $vmess_fragment == "$(vmess_unit)" ]] || return 1
    info=$(vmess_fs boot-info) || return 1
    vmess_err "VMess boot：${info#* }（只读，未迁移/启停服务）。"
)
vmess_manage_stage() {
    # Pair/ledger exchanges require the same filesystem, including /etc on a
    # separate mount. Do not stage in generic /run or system /tmp.
    vmess_stage=$(mktemp -d "$(dirname -- "$(vmess_etc)")/.terry-vmess-manage.XXXXXXXX") || return 1
    vmess_stage_id=$(stat -c '%d:%i' -- "$vmess_stage") || return 1
}
vmess_start_probe() {
    local i good=0
    vmess_started=1
    systemctl start terry-toolbox-vmess.service || return 1
    for i in {1..12}; do
        if vmess_running "$port" "$listen" && vmess_tls_probe "$(vmess_etc)/cert.pem" "$host" "$port" "$listen" "$path" >/dev/null 2>&1; then good=1; break; fi
        sleep 0.25 || return 1
    done
    [[ $good == 1 ]] || return 1
    vmess_fs verify --complete >/dev/null && vmess_running "$port" "$listen"
}
vmess_cert_recover() {
    [[ -n $vmess_token && ${vmess_stop_attempted:-0} == 1 ]] || return 1
    vmess_fs transaction-check "$vmess_stage" "$vmess_token" || return 1
    vmess_lock_check || return 1
    vmess_stop_gate "$port" 1 || return 1
    vmess_fs transaction-check "$vmess_stage" "$vmess_token" || return 1
    vmess_lock_check || return 1
    vmess_fs restore "$vmess_stage" "$vmess_token" || return 1
    vmess_certificate "$(vmess_etc)/cert.pem" "$(vmess_etc)/key.pem" "$host" || return 1
    vmess_fs verify --complete >/dev/null || return 1
    vmess_manage_service_gate || return 1
    vmess_lock_check || return 1
    vmess_start_probe || return 1
    vmess_err '新证书事务未完成；旧证书/私钥及原清单已恢复，原服务 TLS/WS 已复验。'
}
vmess_manage_finish() {
    local rc=$? keep=0
    trap - EXIT INT TERM HUP
    if [[ ${vmess_changing:-0} == 1 && ${vmess_done:-0} != 1 ]]; then
        [[ $rc != 0 ]] || rc=1
        if [[ ${vmess_mode:-} == cert ]] && vmess_cert_recover; then :; else keep=1; fi
    fi
    if [[ $keep == 1 ]]; then
        vmess_err "管理事务存在失败/不确定状态；未删除或覆盖未知资源，私密备份/事务记录保留于 $vmess_stage。请人工检查，勿自动重试。"
    else
        if [[ -n ${vmess_token:-} && -n ${vmess_stage:-} ]]; then
            if vmess_fs transaction-clean "$vmess_stage" "$vmess_token"; then :;
            else vmess_err "备份完整性未知；保留 $vmess_stage"; rc=1; fi
        else vmess_stage_cleanup || rc=1; fi
    fi
    if [[ -n ${vmess_lock_id:-} ]]; then vmess_fs unlock "$vmess_lock_id" || rc=1; fi
    exit "$rc"
}
vmess_manage_service_gate() {
    vmess_service_read || return 1
    [[ $vmess_load == loaded && $vmess_fragment == "$(vmess_unit)" ]]
}
vmess_boot_change_locked() { # enable-boot | disable-boot; caller owns lock+consent
    local action=$1 info version state expected=0
    vmess_manage_service_gate || return 1
    info=$(vmess_fs boot-info --complete) || return 1
    read -r version state <<< "$info"
    if [[ $version == 1 ]]; then
        vmess_lock_check || return 1
        vmess_manage_stage || return 1
        vmess_changing=1; vmess_mode=migrate
        vmess_token=$(vmess_fs prepare "$vmess_stage" migrate) || return 1
        vmess_lock_check || return 1
        vmess_fs apply "$vmess_stage" "$vmess_token" || return 1
        systemctl daemon-reload || return 1
        vmess_service_read || return 1
        [[ $vmess_load == loaded && $vmess_fragment == "$(vmess_unit)" ]] || return 1
        vmess_boot_readback || return 1
        vmess_fs transaction-clean "$vmess_stage" "$vmess_token" || return 1
        vmess_stage=''; vmess_changing=0; vmess_token=''
    fi
    vmess_boot_readback || return 1
    if [[ $action == enable-boot && $state == enabled || $action == disable-boot && $state == disabled ]]; then return 0; fi
    vmess_manage_service_gate || return 1
    vmess_manage_stage || return 1
    vmess_changing=1; vmess_mode=boot
    # Exactly our own recorded link may exist here: enable starts from none and
    # disable only from the owned record, otherwise disable would lose links.
    [[ $action != disable-boot ]] || expected=1
    [[ $(vmess_fs links) == "$expected" ]] || { vmess_err '依赖链接数量与清单/动作不一致；未提交。'; return 1; }
    vmess_lock_check || { vmess_err '安装锁已被替换；未提交。'; return 1; }
    if [[ $action == enable-boot ]]; then
        vmess_token=$(vmess_fs prepare "$vmess_stage" boot-on) || return 1
    else vmess_token=$(vmess_fs prepare "$vmess_stage" boot-off) || return 1; fi
    vmess_fs apply "$vmess_stage" "$vmess_token" || return 1
    vmess_fs verify --complete >/dev/null || return 1
    vmess_manage_service_gate || return 1
    vmess_lock_check || return 1
    # No --now: changing boot policy never starts/stops the running service.
    systemctl "${action%-boot}" terry-toolbox-vmess.service || return 1
    if [[ $action == disable-boot ]]; then
        # disable unlinks every link to the unit: a leftover one means a foreign
        # caller re-added it, so the unit is still boot-enabled.
        [[ $(vmess_fs links) == 0 ]] || { vmess_err 'systemctl disable 后仍有指向本 unit 的链接；保留事务记录。'; return 1; }
    fi
    vmess_boot_readback || return 1
    vmess_service_read || return 1
    [[ $vmess_load == loaded && $vmess_fragment == "$(vmess_unit)" ]] || return 1
    vmess_fs transaction-check "$vmess_stage" "$vmess_token" || return 1
    vmess_lock_check || return 1
    vmess_done=1
}
vmess_boot_manage() (
    umask 077
    local action=$1 info before host port path listen hasunit
    local vmess_stage='' vmess_stage_id='' vmess_lock_id='' vmess_token='' vmess_changing=0 vmess_done=0 vmess_mode=boot
    vmess_require || return 1
    info=$(vmess_fs verify --complete) || return 1
    vmess_boot_readback || return 1
    vmess_service_read || return 1
    [[ $vmess_load == loaded && $vmess_fragment == "$(vmess_unit)" ]] || return 1
    vmess_lock_id=$(vmess_fs lock) || return 1
    trap vmess_manage_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    vmess_err "预览：$action terry-toolbox-vmess.service；仅管理本工具独占创建并记录 inode/目标的 multi-user.target.wants 链接；不启停当前服务。"
    vmess_err '旧版完整安装在双确认后迁移 unit [Install]/清单；未知链接、drop-in、内容或 inode 改动拒绝。'
    vmess_confirm || return 1
    before=$(vmess_fs verify --complete) || return 1
    [[ $before == "$info" ]] || return 1
    vmess_boot_readback || return 1
    vmess_boot_change_locked "$action" || return 1
    vmess_done=1
    vmess_err '自启策略已由 systemd 与精确链接/完整清单读回复验。'
)
vmess_update_cert() (
    umask 077
    local cert=${1:-} key=${2:-} info before host port path listen hasunit vmess_pair_token
    local vmess_stage='' vmess_stage_id='' vmess_lock_id='' vmess_token='' vmess_changing=0 vmess_done=0 vmess_mode=cert vmess_started=0 vmess_stop_attempted=0
    (( $# == 0 || $# == 2 )) || { vmess_err '用法: toolbox_vmess update-cert [cert key]（路径，不接受命令/hook）'; return 2; }
    vmess_require || return 1
    info=$(vmess_fs verify --complete) || return 1
    read -r host port path listen hasunit <<< "$info"
    if (( $# == 0 )); then
        printf '新 PEM 完整证书链绝对路径：'; IFS= read -r cert || return 1
        printf '新非加密 PEM 私钥绝对路径：'; IFS= read -r key || return 1
    fi
    vmess_fs pair-check "$cert" "$key" || return 1
    vmess_existing_certificate || return 1
    vmess_certificate "$cert" "$key" "$host" || return 1
    vmess_running "$port" "$listen" || return 1
    vmess_lock_id=$(vmess_fs lock) || return 1
    trap vmess_manage_finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    vmess_err "预览：验证新完整证书链/域名/可信 CA/时间及非加密配对私钥；短暂停止 terry-toolbox-vmess.service 后，仅交换 $(vmess_etc)/cert.pem、key.pem 与封闭清单。"
    vmess_err 'UUID/config/client/自启策略不变；保留旧 pair，重启后验证 exact service/socket/TLS leaf+WS；失败仅在全部归属与停止可证时恢复，否则保留现场。无 ACME/hook。'
    vmess_confirm || return 1
    before=$(vmess_fs verify --complete) || return 1
    [[ $info == "$before" ]] || return 1
    vmess_existing_certificate || return 1
    vmess_manage_stage || return 1
    vmess_changing=1
    vmess_pair_token=$(vmess_fs snapshot-pair "$vmess_stage" "$cert" "$key") || return 1
    vmess_certificate "$vmess_stage/new-cert.pem" "$vmess_stage/new-key.pem" "$host" || return 1
    "$(vmess_bin)" run -test -config "$vmess_stage/config.json" >"$vmess_stage/validate.log" 2>&1 || { vmess_err '新证书 Xray 配置验证失败；未停止/替换。'; return 1; }
    vmess_fs verify --complete >/dev/null || return 1
    vmess_running "$port" "$listen" || return 1
    # Keep pre-commit failures as private evidence as well: a failed preparation
    # can mean the stage was raced/tampered, not merely an ordinary I/O error.
    vmess_changing=1
    vmess_token=$(vmess_fs prepare "$vmess_stage" cert "$vmess_pair_token") || return 1
    vmess_fs transaction-check "$vmess_stage" "$vmess_token" || return 1
    vmess_lock_check || { vmess_err '安装锁已被替换；未停止/交换。'; return 1; }
    vmess_stop_attempted=1
    vmess_stop_gate "$port" 1 || { vmess_err '停止未确认；原 pair 未替换。'; return 1; }
    vmess_fs transaction-check "$vmess_stage" "$vmess_token" || return 1
    vmess_lock_check || return 1
    vmess_fs apply "$vmess_stage" "$vmess_token" || return 1
    vmess_certificate "$(vmess_etc)/cert.pem" "$(vmess_etc)/key.pem" "$host" || return 1
    vmess_fs verify --complete >/dev/null || return 1
    vmess_manage_service_gate || return 1
    vmess_lock_check || return 1
    vmess_start_probe || return 1
    vmess_boot_readback || return 1
    vmess_fs transaction-check "$vmess_stage" "$vmess_token" || return 1
    vmess_lock_check || return 1
    vmess_done=1
    vmess_err '新证书/私钥及封闭清单已更新；exact service/socket/TLS leaf+WS 复验通过，凭据未显示。'
)

toolbox_vmess() {
    local action=${1:-} choice
    if (( $# > 0 )); then shift; fi
    case $action in
        install) vmess_install "$@" ;;
        status) (( $# == 0 )) || return 2; vmess_status ;;
        boot-status) (( $# == 0 )) || return 2; vmess_boot_status ;;
        enable-boot|disable-boot) (( $# == 0 )) || return 2; vmess_boot_manage "$action" ;;
        update-cert) vmess_update_cert "$@" ;;
        uninstall) (( $# == 0 )) || return 2; vmess_uninstall ;;
        '')
            printf 'VMess + WebSocket + TLS\n1 安装\n2 卸载\n3 状态\n4 启用开机自启\n5 禁用开机自启\n6 自启状态（只读）\n7 更新证书\n0 返回\n'
            IFS= read -r choice || return 1
            case $choice in 1) vmess_install ;; 2) vmess_uninstall ;; 3) vmess_status ;; 4) vmess_boot_manage enable-boot ;; 5) vmess_boot_manage disable-boot ;; 6) vmess_boot_status ;; 7) vmess_update_cert ;; 0) return 0 ;; *) return 2 ;; esac ;;
        *) vmess_err '用法: toolbox_vmess install [cert key hostname [port] [ws_path]] | status | uninstall | enable-boot | disable-boot | boot-status | update-cert [cert key]'; return 2 ;;
    esac
}
