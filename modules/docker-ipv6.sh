#!/usr/bin/env bash
# B1 source-only: toolbox_docker_ipv6 apply [fd00:1234::/64] | status | restore
# Independent implementation of the reference's default-bridge IPv6 intent.
# Sources: https://docs.docker.com/engine/daemon/ipv6/
#          https://docs.docker.com/reference/cli/dockerd/
# Missing dependencies use the shared consent flow before the engine runs.
# No image pulls or container/network creation/deletion; the IPv6 engine
# writes no sysctl itself (dockerd may set IPv6 forwarding/FORWARD once started).
# Debian/Ubuntu systemd and booted Alpine OpenRC are implementation targets, NOT
# real-distro/data-plane acceptance claims. Rootless/custom/Swarm daemons refused.
# The ONLY path override is TOOLBOX_DOCKER_IPV6_TEST_ROOT, restricted to private
# root-owned docker-ipv6-* trees with protected parents; it is NOT daemon isolation.
# Dirfd anchoring, protected parents, exact inode/content records and flock defend
# against unprivileged races. Concurrent hostile root is outside the guarantee.
# Failed attempts retain private evidence; never silently adopt/reuse that state.
# Remember only the source directory; dependency work remains lazy. Bundles
# already contain the core and must never look beside the downloaded script.
_TOOLBOX_DOCKER_IPV6_MODULE_DIR=''
if [[ ${TOOLBOX_BUNDLED:-0} != 1 ]]; then
    case ${BASH_SOURCE[0]} in
        */*) _TOOLBOX_DOCKER_IPV6_MODULE_DIR=${BASH_SOURCE[0]%/*};;
        *) _TOOLBOX_DOCKER_IPV6_MODULE_DIR=.;;
    esac
    _TOOLBOX_DOCKER_IPV6_MODULE_DIR=$(CDPATH= builtin cd -- "$_TOOLBOX_DOCKER_IPV6_MODULE_DIR" && builtin pwd -P) || _TOOLBOX_DOCKER_IPV6_MODULE_DIR=''
fi

toolbox_docker_ipv6() (
    local engine dependency
    local -a dependencies=(python3 cat)
    # Status never needs Docker or networking tools. The engine still validates
    # all arguments, platform, command provenance and existing daemon ownership.
    if [[ ${1-} == apply && $# -ge 1 && $# -le 2 || ${1-} == restore && $# == 1 ]]; then
        if ! command -v docker >/dev/null 2>&1; then
            declare -F toolbox_require_docker >/dev/null || { [[ -n ${_TOOLBOX_DOCKER_IPV6_MODULE_DIR:-} ]] && source "$_TOOLBOX_DOCKER_IPV6_MODULE_DIR/dependencies.sh"; } || return 1
            toolbox_require_docker 'B1 Docker IPv6' || return 1
        fi
        dependencies+=(docker dockerd ip ss iptables ip6tables)
    fi
    for dependency in "${dependencies[@]}"; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            declare -F toolbox_require_commands >/dev/null || { [[ -n ${_TOOLBOX_DOCKER_IPV6_MODULE_DIR:-} ]] && source "$_TOOLBOX_DOCKER_IPV6_MODULE_DIR/dependencies.sh"; } || return 1
            toolbox_require_commands 'B1 Docker IPv6' "${dependencies[@]}" || return 1
            break
        fi
    done
    # An empty generator must not become a silently successful `python3 -c ''`.
    engine=$( _toolbox_docker_ipv6_engine ) || { printf 'B1 内嵌引擎生成失败（cat/heredoc）；未执行任何操作。\n' >&2; return 1; }
    case $engine in 'import base64'*) ;; *) printf 'B1 内嵌引擎生成不完整；未执行任何操作。\n' >&2; return 1;; esac
    python3 -c "$engine" "$@"
)
_toolbox_docker_ipv6_engine() {
    cat <<'PY'
import base64
import fcntl
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import shutil
import shlex
import signal
import stat
import subprocess
import sys
import uuid

NAME = 'terry-toolbox-docker-ipv6'
TEST = os.environ.get('TOOLBOX_DOCKER_IPV6_TEST_ROOT', '')
C = dict(config='/etc/docker/daemon.json', state='/var/lib/'+NAME,
         lock='/run/'+NAME+'.lock', os='/etc/os-release', pid='/run/docker.pid',
         openrc='/run/openrc', script='/etc/init.d/docker', conf='/etc/conf.d/docker',
         disable='/proc/sys/net/ipv6/conf/all/disable_ipv6')
if TEST:
    C = dict(config=TEST+'/etc/docker/daemon.json', state=TEST+'/state', lock=TEST+'/lock',
             os=TEST+'/etc/os-release', pid=TEST+'/pid', openrc=TEST+'/openrc',
             script=TEST+'/init.d/docker', conf=TEST+'/conf.d/docker', disable=TEST+'/disable_ipv6')
CMDS = {}
LOG = None
M = None
MSNAP = None
PUBLISHED = False
ATTEMPTED = False
LOCK = None

class Refusal(Exception):
    pass

def need(ok, message):
    if not ok:
        raise Refusal(message)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def pairs(items):
    d = {}
    for k, v in items:
        need(k not in d, 'JSON duplicate key: '+k)
        d[k] = v
    return d

def parse(data):
    try:
        return json.loads(data, object_pairs_hook=pairs,
                          parse_constant=lambda x: (_ for _ in ()).throw(Refusal('JSON 非有限数值')))
    except (ValueError, UnicodeError) as e:
        raise Refusal('JSON 无效: '+str(e))

def encode(obj):
    return (json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False)+'\n').encode()

def attrs(s):
    return dict(dev=s.st_dev, ino=s.st_ino, mode=stat.S_IMODE(s.st_mode), uid=s.st_uid,
                gid=s.st_gid, nlink=s.st_nlink, size=s.st_size)

def pathchain(path, missing=False, openrc=False):
    need(isinstance(path, str) and path.startswith('/') and os.path.normpath(path) == path
         and not any(x in path for x in ('\n', '\r', '\x00')), '父路径不规范')
    out = []
    current = ''
    for p in path.split('/')[1:]:
        current += '/'+p
        try:
            s = os.lstat(current)
        except FileNotFoundError:
            need(missing, '父路径缺失: '+current)
            break
        exception = openrc and current == C['openrc'] and s.st_gid == 0
        need(stat.S_ISDIR(s.st_mode) and s.st_uid == 0 and
             (not s.st_mode & 0o022 or exception and not s.st_mode & 0o002),
             '父路径不可信或 symlink: '+current)
        # Directory size/link count legitimately change during this transaction.
        out.append([current, s.st_dev, s.st_ino, stat.S_IMODE(s.st_mode), s.st_uid, s.st_gid])
    return out

class Leaf:
    def __init__(self, path):
        self.path = path
        self.parent = os.path.dirname(path)
        self.name = os.path.basename(path)
        self.chain = pathchain(self.parent)
        self.fd = os.open(self.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        need([os.fstat(self.fd).st_dev, os.fstat(self.fd).st_ino] == self.chain[-1][1:3], '父路径竞争')
    def close(self):
        os.close(self.fd)
    def stable(self):
        need(pathchain(self.parent) == self.chain, '父路径已改变；保留证据')
    def read(self):
        self.stable()
        try:
            fd = os.open(self.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
        except FileNotFoundError:
            return dict(exists=False), b''
        try:
            s = os.fstat(fd)
            need(stat.S_ISREG(s.st_mode) and s.st_uid == 0 and not s.st_mode & 0o022 and s.st_nlink == 1,
                 '配置/记录不是可信单链接普通文件: '+self.path)
            need(s.st_size <= 2*1024*1024, '配置/记录过大')
            with os.fdopen(os.dup(fd), 'rb') as f:
                data = f.read(2*1024*1024+1)
            t = os.fstat(fd)
            need(attrs(s) == attrs(t) and len(data) == s.st_size, '文件读取竞争')
            return dict(exists=True, **attrs(s), sha256=sha(data)), data
        finally:
            os.close(fd)
    def replace(self, expected, data, mode=0o600, uid=0, gid=0):
        self.stable()
        need(self.read()[0] == expected, '配置/inode/内容已改变；拒绝覆盖')
        name = '.'+self.name+'.b1-'+uuid.uuid4().hex
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
        try:
            with os.fdopen(os.dup(fd), 'wb') as f:
                f.write(data); f.flush(); os.fsync(f.fileno())
            os.fchown(fd, uid, gid); os.fchmod(fd, mode); os.fsync(fd)
            self.stable()
            need(self.read()[0] == expected, '发布前配置竞争；拒绝覆盖')
            if expected['exists']:
                os.replace(name, self.name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
            else:
                os.link(name, self.name, src_dir_fd=self.fd, dst_dir_fd=self.fd, follow_symlinks=False)
                os.unlink(name, dir_fd=self.fd)
            os.fsync(self.fd)
            result = self.read()[0]
            need(result['sha256'] == sha(data) and result['mode'] == mode and
                 result['uid'] == uid and result['gid'] == gid, '发布 readback 失败')
            return result
        finally:
            os.close(fd)
            try:
                os.unlink(name, dir_fd=self.fd)
            except FileNotFoundError:
                pass
    def remove(self, expected):
        need(self.read()[0] == expected, '删除前 owned 配置改变；保留')
        self.stable(); os.unlink(self.name, dir_fd=self.fd); os.fsync(self.fd)
        need(not self.read()[0]['exists'], '删除 readback 失败')
        return dict(exists=False)

def readleaf(path):
    l = Leaf(path)
    try:
        return l.read()
    finally:
        l.close()

def lock_check():
    # A flock only protects its inode. Replacing the name would let a second
    # controller acquire a different lock, so re-prove fd/name/parent identity
    # immediately before configuration or service mutations, including rollback.
    need(LOCK is not None, '事务独占锁未持有')
    leaf, fd, expected = LOCK
    leaf.stable()
    actual=attrs(os.fstat(fd))
    need(actual == {k:expected[k] for k in actual}
         and leaf.read()[0] == expected, '锁 inode/内容已改变；拒绝变更并保留证据')

def config_snapshot():
    parent = os.path.dirname(C['config'])
    chain = pathchain(parent, missing=True)
    if not os.path.exists(parent):
        need(chain and chain[-1][0] == os.path.dirname(parent), '仅允许创建缺失的 /etc/docker 叶目录')
        return dict(exists=False), b'', chain
    s, data = readleaf(C['config'])
    return s, data, chain

def os_identity():
    path = C['os']
    # Native Alpine and systemd distros can ship this exact standard symlink.
    if os.path.islink(path):
        target = os.readlink(path)
        need(not TEST and target in ('../usr/lib/os-release', '/usr/lib/os-release'), 'os-release symlink 不可信')
        path = '/usr/lib/os-release'
    s, data = readleaf(path)
    need(s['exists'], '缺少 os-release')
    vals = {}
    for line in data.decode().splitlines():
        if re.fullmatch(r'ID=[A-Za-z0-9_"\'-]+', line):
            vals['ID'] = line.split('=', 1)[1].strip('"\'')
    distro = vals.get('ID')
    need(distro in ('debian', 'ubuntu', 'alpine'), '仅支持 Debian/Ubuntu 或 Alpine')
    if TEST:
        init = readleaf(TEST+'/init')[1].decode().strip()
    else:
        init = pathlib.Path('/proc/1/comm').read_text().strip()
    if distro == 'alpine':
        need(init in ('init', 'openrc-init', 'openrc'), 'Alpine 必须是 booted OpenRC')
        pathchain(C['openrc'], openrc=True)
        need(os.path.isfile(C['openrc']+'/softlevel'), 'OpenRC 未引导；拒绝 chroot/未 booted 环境')
        level = pathlib.Path(C['openrc']+'/softlevel').read_text().strip()
        need(level not in ('', 'sysinit', 'single', 'shutdown'), 'OpenRC runlevel 不安全')
        return dict(distro=distro, init='openrc', os=s)
    need(init == 'systemd', 'Debian/Ubuntu 必须由 systemd 引导')
    return dict(distro=distro, init='systemd', os=s)

def commands(init):
    for cmd in ('docker', 'dockerd', 'ip', 'ss', 'iptables', 'ip6tables',
                'systemctl' if init == 'systemd' else 'rc-service'):
        p = shutil.which(cmd)
        need(p, '依赖预检后仍缺少命令 '+cmd+'；请检查安装结果；不会切换 init 或接管既有 Docker')
        p = os.path.realpath(p)
        pathchain(os.path.dirname(p))
        s = os.stat(p)
        need(stat.S_ISREG(s.st_mode) and s.st_uid == 0 and not s.st_mode & 0o022,
             '命令来源/权限不可信: '+cmd)
        CMDS[cmd] = p

def run(cmd, *args, codes=(0,)):
    p = subprocess.Popen([CMDS.get(cmd, cmd), *args], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = p.communicate(timeout=25)
    except BaseException:
        p.kill(); p.wait(); raise
    if LOG:
        if os.path.lexists(C['state']):
            need(pathchain(C['state'])==M['state_parents'], '事务证据父路径已改变')
        log_fd=os.open(LOG,os.O_WRONLY|os.O_APPEND|os.O_NOFOLLOW)
        try:
            s=os.fstat(log_fd)
            need(stat.S_ISREG(s.st_mode) and s.st_uid==0 and stat.S_IMODE(s.st_mode)==0o600 and s.st_nlink==1,
                 '操作证据权限/链接不可信')
            with os.fdopen(os.dup(log_fd),'ab') as f:
                # Configuration contents and daemon credentials stay private.
                f.write(encode(dict(command=cmd, args=list(args), rc=p.returncode,
                                    stdout=out.decode(errors='replace'), stderr=err.decode(errors='replace'))))
                f.flush(); os.fsync(f.fileno())
        finally:
            os.close(log_fd)
    need(p.returncode in codes, '命令失败: '+cmd+' '+(' '.join(args[:2])))
    return out.decode().strip(), p.returncode

def docker(*args):
    return run('docker', '--host', 'unix:///var/run/docker.sock', *args)[0]

def local_target():
    need(not any(k.startswith('DOCKER_') for k in os.environ), 'DOCKER_* 环境造成 context/remote 歧义；请清除')
    need(run('docker', 'context', 'show')[0] == 'default', 'remote/context 已拒绝：只支持 default')
    need(run('docker', 'context', 'inspect', 'default', '--format', '{{.Endpoints.docker.Host}}')[0]
         == 'unix:///var/run/docker.sock', 'remote endpoint 已拒绝：必须默认 local Unix socket')
    version = docker('version', '--format', '{{.Server.Version}}')
    m = re.fullmatch(r'([0-9]{1,3})\.([0-9]+)\.([0-9]+)(?:\+[A-Za-z0-9.+_-]+)?', version)
    need(m and int(m[1]) >= 28, '需要 stable Engine >=28；prerelease/未知版本已拒绝')
    info = parse(docker('info', '--format', '{{json .}}'))
    need(isinstance(info, dict) and isinstance(info.get('ID'), str) and info['ID'], 'Engine ID 读取失败')
    need(info.get('Swarm', {}).get('LocalNodeState') == 'inactive', 'Swarm daemon 不支持安全重启')
    need(isinstance(info.get('SecurityOptions'), list) and
         not any('rootless' in str(x) for x in info['SecurityOptions']), 'rootless daemon 不支持')
    return dict(version=version, id=info['ID'])

def no_containers():
    text = docker('container', 'ls', '--no-trunc', '--format', '{{.ID}}')
    need(not text, '有运行 container/容器或读取不明；拒绝重启以避免业务中断')

def socket_pids():
    text = run('ss', '-H', '-xlpn')[0]
    rows = [x for x in text.splitlines() if re.search(r'(?:^|\s)/(?:var/)?run/docker\.sock(?:\s|$)', x)]
    result = []
    for row in rows:
        need('LISTEN' in row, 'socket 状态不明')
        ps = re.findall(r'pid=(\d+)', row)
        need(ps, '默认 socket 无可核验 PID')
        result.extend(int(x) for x in ps)
    return set(result)

def executable(pid):
    need(isinstance(pid, int) and pid > 1, 'dockerd PID 无效')
    proc = '/proc/'+str(pid)
    exe = os.readlink(proc+'/exe')
    need(exe == CMDS['dockerd'] and not exe.endswith(' (deleted)'), 'dockerd actual executable 不匹配')
    status = pathlib.Path(proc+'/status').read_text()
    uid = re.search(r'^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)', status, re.M)
    need(uid and all(int(x) == 0 for x in uid.groups()), 'dockerd 不是 root daemon')
    raw = pathlib.Path(proc+'/cmdline').read_bytes()
    need(raw.endswith(b'\0'), 'dockerd argv 不完整')
    argv = [x.decode() for x in raw[:-1].split(b'\0')]
    need(argv and os.path.realpath(argv[0]) == exe, 'dockerd argv/executable 不一致')
    # bind PID to its start time, preventing stale PID-only ownership assumptions.
    start = pathlib.Path(proc+'/stat').read_text().rsplit(')', 1)[1].split()[19]
    l = Leaf(exe)
    fd = os.open(l.name, os.O_RDONLY|os.O_NOFOLLOW, dir_fd=l.fd)
    try:
        before = os.fstat(fd)
        need(stat.S_ISREG(before.st_mode) and before.st_uid==0 and not before.st_mode & 0o022
             and before.st_nlink==1, 'dockerd binary 权限不可信')
        h=hashlib.sha256()
        with os.fdopen(os.dup(fd),'rb') as f:
            for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
        need(attrs(os.fstat(fd))==attrs(before), 'dockerd executable 读取竞争')
        l.stable()
        s=dict(exists=True, **attrs(before), sha256=h.hexdigest())
    finally:
        os.close(fd); l.close()
    return dict(pid=pid, start=start, exe=s, argv=argv)

def systemd_properties(unit):
    text = run('systemctl', 'show', unit, '--no-pager', '--all',
               '--property=LoadState,ActiveState,SubState,MainPID,FragmentPath,DropInPaths,Job')[0]
    vals = {}
    for row in text.splitlines():
        need('=' in row, unit+' readback 无效')
        k, v = row.split('=', 1)
        need(k not in vals, unit+' duplicate property')
        vals[k] = v
    required=('LoadState','ActiveState','SubState','FragmentPath','DropInPaths','Job')
    if unit.endswith('.service'): required+=('MainPID',)
    need(all(k in vals for k in required),
         unit+' readback 缺字段')
    return vals

def service(init, running=True, before_stop=False, probe=False):
    if init == 'systemd':
        vals = systemd_properties('docker.service')
        need(vals['LoadState'] == 'loaded' and vals['Job'] == '' and vals['DropInPaths'] == '',
             'systemd 未 loaded/pending job/drop-in 冲突')
        fragment = vals['FragmentPath']
        need(fragment.endswith('/docker.service') or TEST and fragment == TEST+'/unit', 'docker.service FragmentPath 不可信')
        if not TEST:
            fragment = os.path.realpath(fragment)
            need(fragment in ('/usr/lib/systemd/system/docker.service','/etc/systemd/system/docker.service'),
                 'custom systemd fragment 不支持')
        snap, data = readleaf(fragment)
        need(snap['exists'], 'systemd fragment 缺失')
        need(re.fullmatch(r'\d+', vals['MainPID']), 'systemd MainPID 无效')
        active = vals['ActiveState'] == 'active' and vals['SubState'] == 'running'
        socket_fragment = None
        # The upstream unit uses socket activation. PID 1 also owns its fd;
        # rollback must quiesce that exact socket unit before stopped readback.
        activation = active and b'fd://' in pathlib.Path('/proc/'+vals['MainPID']+'/cmdline').read_bytes()
        activation = activation or not active and M is not None and 'socket' in M['init']['resources']
        if activation:
            sv=systemd_properties('docker.socket')
            socket_active=sv.get('ActiveState')=='active' and sv.get('SubState') in ('listening','running')
            socket_stopped=sv.get('ActiveState')=='inactive' and sv.get('SubState')=='dead'
            need(sv.get('LoadState')=='loaded' and sv.get('DropInPaths')=='' and sv.get('Job')==''
                 and (socket_active if active else socket_stopped or before_stop and socket_active),
                 'docker.socket pending/状态/drop-in 冲突')
            socket_fragment=sv.get('FragmentPath','')
            if not TEST:
                socket_fragment=os.path.realpath(socket_fragment)
                need(socket_fragment in ('/usr/lib/systemd/system/docker.socket','/etc/systemd/system/docker.socket'),
                     'custom docker.socket 不支持')
            socket_snap,socket_data=readleaf(socket_fragment)
            need(socket_snap['exists'],'docker.socket fragment 缺失')
            streams=re.findall(rb'^ListenStream=(.*)$',socket_data,re.M)
            need(streams in ([b'/run/docker.sock'],[b'/var/run/docker.sock']), 'docker.socket 非默认 Unix listener')
        stopped = vals['ActiveState'] == 'inactive' and vals['SubState'] == 'dead' and vals['MainPID'] == '0'
        need(active if running else active or stopped, 'systemd 状态不是明确 running/stopped')
        need(re.fullmatch(r'\d+', vals['MainPID']), 'systemd MainPID 无效')
        pid = int(vals['MainPID'])
        resources = dict(fragment=fragment, fragment_snapshot=snap)
        if socket_fragment:
            resources.update(socket=socket_fragment, socket_snapshot=socket_snap)
    else:
        resolved = run('rc-service', '--resolve', 'docker')[0]
        need(resolved == C['script'], 'OpenRC 服务 resolve 不是确切 docker script')
        script, data = readleaf(C['script']); conf, unused = readleaf(C['conf'])
        need(script['exists'], 'OpenRC init script 缺失')
        text, rc = run('rc-service', 'docker', 'status', codes=(0,3,4,8,16,32))
        active = rc == 0 and re.search(r'\bstatus:\s+started\b', text) is not None
        stopped = rc == 3 and re.search(r'\bstatus:\s+stopped\b', text) is not None
        need(active if running else active or stopped, 'OpenRC status/退出码不是明确 started/stopped')
        pid = 0
        if active:
            # Modern Alpine uses supervise-daemon without dockerd.pid. Correlate
            # the local listener to a native root executable; pidfile is optional
            # additional evidence, never an assumed distro invariant.
            listeners=socket_pids()
            need(len(listeners)==1,'OpenRC 默认 socket listener PID 不唯一')
            pid=next(iter(listeners))
            ps, raw = readleaf(C['pid'])
            if ps['exists']:
                need(re.fullmatch(rb'[0-9]+\n?', raw) and int(raw)==pid,
                     'OpenRC docker pidfile/listener 不一致')
        resources = dict(script=script, conf=conf, resolved=resolved)
    result = dict(resources=resources, active=active, pid=pid)
    if active:
        result['process'] = executable(pid)
        need(pid in socket_pids(), 'local socket listener 不属于实际 dockerd PID；代理已拒绝')
        need(socket_pids() <= ({pid,1} if 'socket' in resources else {pid}), 'local socket 存在未知 proxy PID')
    else:
        listeners=socket_pids()
        # `probe` is the stopped preflight read: the caller decides whether a
        # leftover listener (socket activation pending) is acceptable.
        need(not listeners or probe or before_stop and 'socket' in resources and listeners=={1},
             'stopped 后 socket 仍有未知 listener；保留证据')
    return result

def flags(argv, config):
    names = []
    kept = []
    aliases = dict(H='hosts', host='hosts', D='debug', b='bridge', p='pidfile',
                   s='storage-driver', G='group', **{'registry-mirror':'registry-mirrors',
                   'default-address-pool':'default-address-pools', 'label':'labels', 'feature':'features'})
    i = 1
    while i < len(argv):
        a = argv[i]; need(a.startswith('-'), 'dockerd flags 含未知位置参数')
        key, equal, value = a.lstrip('-').partition('=')
        if len(key) > 1 and key[0] in aliases and not a.startswith('--'):
            value = key[1:]; key = key[0]; equal = '='
        key = aliases.get(key, key)
        end = i+1
        if not equal and end < len(argv) and not argv[end].startswith('-'):
            value = argv[end]; end += 1
        need(key not in ('ipv6','fixed-cidr-v6','ip6tables','bip6','default-gateway-v6','experimental','rootless'),
             'dockerd flags 冲突: '+key)
        need(key not in ('bridge',), 'custom bridge flags 不支持')
        if key in ('iptables','ip-forward','ip-masq','icc'):
            need(value in ('','true'), '安全 flags 已禁用: '+key)
        if key == 'firewall-backend':
            need(value == 'iptables', 'firewall-backend flags 未验收')
        if key == 'config-file':
            need(value == '/etc/docker/daemon.json', '非默认 config-file flags 已拒绝')
        else:
            need(key not in config, 'JSON/flags duplicate 配置: '+key)
            if key == 'hosts':
                need(value in ('unix:///var/run/docker.sock','unix:///run/docker.sock','fd://'), 'remote dockerd host flags 不支持')
            names.append(key); kept.extend(argv[i:end])
        i = end
    need(config.get('hosts', ['unix:///var/run/docker.sock']) in
         (['unix:///var/run/docker.sock'], ['unix:///run/docker.sock']), 'remote JSON hosts 已拒绝')
    need(config.get('iptables', True) is True and config.get('ip6tables', True) is True,
         'iptables/ip6tables 安全禁用冲突；不会接管')
    need(config.get('experimental', False) is False, 'experimental 现有配置不支持；不会开启')
    need(config.get('firewall-backend','iptables') == 'iptables', '仅实现 iptables 后端，nftables 未验收')
    # Same safety switches the flag parser rejects must be gated in JSON too.
    for key in ('ip-forward', 'ip-masq', 'icc'):
        need(config.get(key, True) is True, 'JSON 安全开关已禁用: '+key)
    need('bridge' not in config and 'bip6' not in config and 'default-gateway-v6' not in config,
         'custom bridge/IPv6 gateway 配置不支持')
    return kept

def ula(value):
    try:
        net = ipaddress.IPv6Network(value, strict=True)
    except ValueError:
        raise Refusal('IPv6 必须为无 host bits 的 ULA /64')
    need(net.prefixlen == 64 and net.subnet_of(ipaddress.IPv6Network('fd00::/8')),
         'IPv6 必须为 fd00::/8 locally-assigned ULA /64')
    return str(net)

def topology(subnet, owned=False):
    ids = docker('network', 'ls', '--no-trunc', '--format', '{{.ID}}').splitlines()
    need(ids and len(ids) == len(set(ids)) and all(re.fullmatch(r'[a-f0-9]{64}', x) for x in ids),
         'Docker network 列表不完整/无效')
    networks = parse(docker('network', 'inspect', *ids))
    need(isinstance(networks, list) and len(networks) == len(ids) and
         {x.get('Id') for x in networks if isinstance(x,dict)} == set(ids), 'network readback 不完整')
    net = ipaddress.IPv6Network(subnet)
    bridge = None
    for n in networks:
        need(isinstance(n.get('IPAM'), dict), 'network IPAM 无效')
        configs = n['IPAM'].get('Config')
        if n.get('Driver') in ('host','null') and n.get('Name') in ('host','none'):
            need(configs in (None,[]), '内置 host/none 意外 IPAM 配置')
            continue
        need(isinstance(configs,list), 'network IPAM Config 无效')
        isbridge = n.get('Name') == 'bridge' and n.get('Driver') == 'bridge'
        if isbridge:
            need(bridge is None, '多个 default bridge'); bridge = n
        for c in n['IPAM']['Config']:
            need(isinstance(c,dict) and isinstance(c.get('Subnet'),str), 'network subnet 无效')
            other = ipaddress.ip_network(c['Subnet'])
            if other.version == 6 and net.overlaps(other):
                need(owned and isbridge and str(other) == subnet and n.get('EnableIPv6') is True,
                     'IPv6 network 子网冲突')
    need(bridge is not None, '缺少 default bridge')
    if not owned:
        need(bridge.get('EnableIPv6') is False, '既有 bridge IPv6 不接管')
    routes = parse(run('ip', '-j', '-6', 'route', 'show', 'table', 'all')[0])
    addrs = parse(run('ip', '-j', '-6', 'addr', 'show')[0])
    need(isinstance(routes,list) and isinstance(addrs,list), 'IPv6 路由/地址读取不完整')
    for row in routes:
        need(isinstance(row,dict) and isinstance(row.get('dst'),str), 'IPv6 route 数据无效')
        # RA expiry is a kernel countdown, not route identity. Keep its
        # presence in the fingerprint but not its naturally changing value;
        # every probe still checks the actual destination for overlap below.
        if 'expires' in row:
            need(type(row['expires']) is int and row['expires'] >= 0, 'IPv6 route expires 无效')
            row['expires'] = None
        dst = row['dst']
        if dst in ('default','::/0'): continue
        other = ipaddress.IPv6Network(dst, strict=False)
        need(not net.overlaps(other) or owned and row.get('dev') == 'docker0', 'IPv6 route 路由冲突')
    for row in addrs:
        need(isinstance(row,dict) and isinstance(row.get('addr_info'),list), 'IPv6 addr 数据无效')
        for a in row['addr_info']:
            if a.get('family') != 'inet6': continue
            other = ipaddress.IPv6Network(str(a.get('local'))+'/'+str(a.get('prefixlen')), strict=False)
            need(not net.overlaps(other) or owned and row.get('ifname') == 'docker0', 'IPv6 host 地址冲突')
            for key in ('valid_life_time','preferred_life_time'):
                if key in a:
                    need(type(a[key]) is int and a[key] >= 0, 'IPv6 地址 lifetime 无效')
                    a[key] = None
    return dict(networks=networks, routes=routes, addrs=addrs)

def preflight(subnet, owned=False):
    need(os.geteuid() == 0, 'apply/restore 需要 root')
    identity = os_identity(); commands(identity['init'])
    need(pathlib.Path(C['disable']).read_text().strip() == '0', '内核 IPv6 不可用；本模块不写 sysctl')
    # Service state is read WITHOUT any Docker API call. The upstream unit is
    # socket-activated, so `docker version|info` on a stopped daemon would START
    # it via docker.socket and silently break the "does not start" contract.
    svc = service(identity['init'], running=False, probe=True)
    if not svc['active']:
        need(not socket_pids(), 'docker 服务已停但默认 socket 仍在监听；调用 Docker API 会激活 daemon'
             ' 启动（不承接启动语义）；请先自行启动 docker')
        need(False, 'docker 服务未运行（socket 也未监听）；本模块不启动服务，请先自行启动 docker')
    # Proven running + listener owned by this exact dockerd: now the API is safe.
    engine = local_target(); no_containers()
    snap, data, chain = config_snapshot()
    config = parse(data) if snap['exists'] else {}
    need(isinstance(config,dict), 'daemon JSON 顶层必须为 object')
    if not owned:
        need('ipv6' not in config and 'fixed-cidr-v6' not in config, '既有 ipv6/fixed-cidr-v6 不接管')
    validateflags = flags(svc['process']['argv'], config)
    return dict(identity=identity, engine=engine, service=svc, snapshot=snap,
                original=data, parents=chain, config=config, flags=validateflags,
                topology=topology(subnet, owned))

def stable_identity(p):
    return dict(identity=p['identity'], engine=p['engine'], resources=p['service']['resources'],
                exe=p['service']['process']['exe'], flags=p['flags'])

def confirm(action, subnet, p):
    print('B1 Docker IPv6 本地模块：Debian/Ubuntu systemd、booted Alpine OpenRC 尚未真实验收。')
    print('操作: '+action+'；配置: '+C['config'])
    print('仅变更 default bridge 的 ipv6=true / fixed-cidr-v6='+subnet+' / ip6tables=true；保留无关 JSON，不开启 experimental。'
          if action == 'apply' else '恢复原始配置字节/权限，原本不存在则仅删除 precise owned daemon.json。')
    print('服务: '+p['identity']['init']+' docker；将重启现有 dockerd，不安装/升级/启动未运行服务。')
    print('dockerd actual executable: '+CMDS['dockerd']+'；PID '+str(p['service']['pid']))
    print('validate: '+shlex.join([CMDS['dockerd'],'--validate','--config-file=<私有候选>'])
          +'；保留 '+str(len(p['flags']))+' 个已核验实际 argv token（不展示可能含凭据的参数）。')
    print('JSON 精确预览：只展示本模块触及的三个键；无关原始字节及权限备份在私有记录。')
    if action=='apply':
        print(json.dumps({'ipv6':True,'fixed-cidr-v6':subnet,'ip6tables':True},ensure_ascii=False,indent=2))
    else:
        m_preview,unused=load_record()
        old=parse(base64.b64decode(m_preview['original_b64'],validate=True)) if m_preview['original']['exists'] else {}
        print(json.dumps({k:old[k] for k in ('ipv6','fixed-cidr-v6','ip6tables') if k in old},ensure_ascii=False,indent=2))
    print('网络影响: default bridge 地址与 IPv6 firewall/端口发布规则会变化；服务可能中断；无运行容器才允许。')
    print('ULA 不提供公网 IPv6；不创建/删除容器或网络，本模块不写 sysctl（重启后 dockerd 会自行设置'
          ' IPv6 forwarding 与 FORWARD 规则），不宣称公网或容器通信通过。')
    print('私有原始备份/事务证据: '+C['state']+'；失败保守保留，未知改变不覆盖。')
    for n in (1,2):
        print('完整换行输入 YES 确认 ('+str(n)+'/2): ', end='', flush=True)
        line = sys.stdin.readline()
        need(line.endswith('\n') and line[:-1].lower() == 'yes', '取消：必须完整换行双 YES；EOF 取消')
    print()

def mkdir_safe(path):
    parent = pathchain(os.path.dirname(path))
    fd = os.open(os.path.dirname(path), os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        need(pathchain(os.path.dirname(path)) == parent, 'mkdir 父路径竞争')
        os.mkdir(os.path.basename(path), 0o700, dir_fd=fd); os.fsync(fd)
    finally:
        os.close(fd)
    return pathchain(path)

def record():
    global MSNAP
    leaf = Leaf(C['state']+'/record.json')
    try:
        MSNAP = leaf.replace(MSNAP or dict(exists=False), encode(M))
    finally:
        leaf.close()

def load_record():
    chain = pathchain(C['state'])
    need(chain[-1][3] == 0o700, '初始化记录目录权限不可信')
    s, raw = readleaf(C['state']+'/record.json')
    need(s['exists'] and s['mode'] == 0o600, '初始化记录缺失/权限不可信')
    m = parse(raw)
    need(isinstance(m,dict) and m.get('schema') == 1 and m.get('config_path') == C['config']
         and m.get('state_parents') == chain and m.get('phase') in
         ('prepared','published','applied','restore-published','restored','rolled-back','retained'), '初始化记录结构不可信')
    original = base64.b64decode(m['original_b64'], validate=True)
    need(m['original_sha256'] == sha(original), '原始备份内容不可信')
    old = parse(original) if m['original']['exists'] else {}
    need(isinstance(old,dict) and 'ipv6' not in old and 'fixed-cidr-v6' not in old, '原始配置不是模块初始化状态')
    if m['original']['exists']:
        need(m['original']['sha256'] == sha(original) and m['original']['uid'] == 0 and
             m['original']['nlink'] == 1 and not m['original']['mode'] & 0o022, '原始权限/inode 记录不可信')
    else:
        need(original == b'', '不存在的原始配置不能有内容')
    expected = dict(old, ipv6=True, **{'fixed-cidr-v6':ula(m['subnet']), 'ip6tables':True})
    need(m['candidate_sha256'] == sha(encode(expected)), '候选配置初始化摘要不可信')
    owned = m.get('owned')
    need(isinstance(owned,dict), 'owned 记录无效')
    if owned:
        need(owned.get('sha256') == m['candidate_sha256'] and owned.get('nlink') == 1,
             'precise owned 配置记录不可信')
    else:
        need(m['phase'] in ('prepared','retained') and m.get('current') == m['original'],
             '缺少 precise owned 配置记录')
    if m['phase'] == 'applied':
        need(m.get('current') == owned and m.get('config_parents') == pathchain(os.path.dirname(C['config'])),
             'owned 父路径/当前记录已改变')
    return m, s

def validate(data, p):
    path = C['state']+'/validate-'+uuid.uuid4().hex+'.json'
    l = Leaf(path)
    try:
        snap = l.replace(dict(exists=False), data)
        run(CMDS['dockerd'], '--validate', '--config-file='+path, *p['flags'])
        need(l.read()[0] == snap, 'validate 候选内容改变')
    finally:
        l.close()

def resources_match(m, svc):
    need(svc['resources'] == m['init']['resources'], 'init/service 资源已改变；拒绝操作')
    if svc['active']:
        need(svc['process']['exe'] == m['init']['exe'], 'dockerd executable 已改变；拒绝操作')

def verify_runtime(p, svc, phase):
    """Full post-(re)start recheck.

    /proc argv is re-read here on purpose: service()/flags() re-prove the
    default Unix listener and the executable identity, and any flag injected by
    a changed unit or wrapper (e.g. --host=tcp://...) must fail, not pass on a
    stale pre-restart snapshot.
    """
    lock_check()
    need(svc['active'], phase+' 后服务不是 running')
    resources_match(M, svc)
    snap, data, unused = config_snapshot()
    need(snap == M['current'], phase+' 后配置 readback 不匹配')
    try:
        again = flags(svc['process']['argv'], parse(data) if snap['exists'] else {})
    except Refusal as e:
        raise Refusal(phase+' 后 dockerd actual argv/flags 复验失败: '+str(e))
    need(again == p['flags'], phase+' 后 dockerd actual argv/flags 已改变（默认 Unix list/目标身份复验）')
    need(svc['pid'] in socket_pids() and socket_pids() <= {svc['pid'], 1},
         phase+' 后默认 Unix socket listener 不属于实际 dockerd')
    need(local_target() == p['engine'], phase+' 后 Engine ID/version 改变')

def restart_and_verify(p, target):
    global ATTEMPTED
    no_containers()
    resources_match(M, service(p['identity']['init']))
    need(config_snapshot()[0] == M['current'], 'restart 前 precise owned 配置已改变')
    lock_check()
    ATTEMPTED = True
    if p['identity']['init'] == 'systemd': run('systemctl', 'restart', 'docker.service')
    else: run('rc-service', 'docker', 'restart')
    verify_runtime(p, service(p['identity']['init']), 'restart')
    no_containers()
    bridge = parse(docker('network', 'inspect', 'bridge'))
    need(isinstance(bridge,list) and len(bridge)==1 and bridge[0].get('Name')=='bridge'
         and bridge[0].get('Driver')=='bridge', 'bridge readback 无效')
    b = bridge[0]
    if target == 'apply':
        need(b.get('EnableIPv6') is True and any(x.get('Subnet') == M['subnet']
             for x in b.get('IPAM',{}).get('Config',[])), 'bridge IPv6/subnet readback 失败')
    else:
        need(b.get('EnableIPv6') is False, '原始 bridge readback 未恢复')
    lock_check()

def rollback(p, previous, data, phase):
    # Never stop or restore when either the exact target or trusted init changed.
    global ATTEMPTED
    lock_check()
    need(config_snapshot()[0] == M['current'], 'rollback：未知配置改变；不 stop、不覆盖')
    svc = service(p['identity']['init'], running=False, before_stop=True); resources_match(M, svc)
    if svc['active']: no_containers()
    validate(data if previous['exists'] else b'{}\n', p)
    need(config_snapshot()[0] == M['current'], 'rollback validate 后未知配置改变')
    lock_check()
    if ATTEMPTED:
        if p['identity']['init'] == 'systemd':
            targets=['docker.service']+(['docker.socket'] if 'socket' in M['init']['resources'] else [])
            run('systemctl', 'stop', *targets)
        else: run('rc-service', 'docker', 'stop')
        stopped = service(p['identity']['init'], running=False); resources_match(M, stopped)
        need(not stopped['active'], 'rollback stop readback 未 stopped；保留')
    leaf = Leaf(C['config'])
    try:
        lock_check()
        if previous['exists']:
            M['current'] = leaf.replace(M['current'], data, previous['mode'], previous['uid'], previous['gid'])
        else:
            M['current'] = leaf.remove(M['current'])
    finally:
        leaf.close()
    record()
    if ATTEMPTED:
        # Original daemon was running; successful stop is a prerequisite to start.
        lock_check()
        if p['identity']['init'] == 'systemd': run('systemctl', 'start', 'docker.service')
        else: run('rc-service', 'docker', 'start')
        verify_runtime(p, service(p['identity']['init']), 'rollback start')
        no_containers()
        bridge = parse(docker('network', 'inspect', 'bridge'))
        expect = phase == 'applied'
        need(isinstance(bridge,list) and len(bridge)==1 and bridge[0].get('EnableIPv6') is expect,
             'rollback bridge readback 失败')
    lock_check()
    M['phase'] = phase
    if phase == 'applied': M['owned'] = M['current']
    M['rollback'] = dict(configuration=True, service_readback=ATTEMPTED, target_phase=phase)
    record()

def transaction(action, subnet, p):
    global M, MSNAP, LOG, PUBLISHED
    before = p['snapshot']; olddata = p['original']
    lock_check()
    if action == 'apply':
        need(not os.path.lexists(C['state']), '已有事务/证据目录；不会接管或覆盖，请人工检查')
        parents = mkdir_safe(C['state'])
        LOG = C['state']+'/operations.log'
        with open(LOG, 'xb') as f: os.chmod(LOG,0o600)
        candidate = encode(dict(p['config'], ipv6=True, **{'fixed-cidr-v6':subnet, 'ip6tables':True}))
        M = dict(schema=1, phase='prepared', config_path=C['config'], state_parents=parents,
                 original=before, original_b64=base64.b64encode(olddata).decode(), original_sha256=sha(olddata),
                 original_parents=p['parents'], init=stable_identity(p), subnet=subnet,
                 candidate_sha256=sha(candidate), current=before, owned={})
        record()
    else:
        M, MSNAP = load_record()
        LOG = C['state']+'/operations.log'
        s, unused = readleaf(LOG); need(s['exists'] and s['mode']==0o600, '操作证据不可信')
        need(M['phase'] == 'applied' and before == M['owned'] and stable_identity(p) == M['init'],
             'restore 必须当前 precise owned 配置及可信 init；拒绝未知改变')
        candidate = base64.b64decode(M['original_b64'],validate=True)
    try:
        validate(candidate if candidate else b'{}\n', p)
        # This full recheck catches service/config/topology/container races inside lock.
        check = preflight(subnet, owned=action=='restore')
        need(check == p, '锁内 validate 后复检发现 race/配置/网络/服务改变')
        lock_check()
        parent = os.path.dirname(C['config'])
        if not os.path.exists(parent):
            M['created_config_parent'] = mkdir_safe(parent)
            record()
        leaf = Leaf(C['config'])
        try:
            lock_check()
            if action=='restore' and not M['original']['exists']:
                M['current'] = leaf.remove(before)
            else:
                meta = before if action=='apply' else M['original']
                M['current'] = leaf.replace(before, candidate, meta.get('mode',0o644), meta.get('uid',0), meta.get('gid',0))
        finally:
            leaf.close()
        PUBLISHED = True
        M['config_parents'] = pathchain(parent)
        M['phase'] = 'published' if action=='apply' else 'restore-published'
        if action=='apply': M['owned'] = M['current']
        record()
        restart_and_verify(p, action)
        M['phase'] = 'applied' if action=='apply' else 'restored'; record()
        print('B1 '+action+' 完成：配置、service/Engine/default bridge 已回读；不代表真实 IPv6 容器通信。')
    except BaseException as e:
        if PUBLISHED:
            try:
                rollback(p, before, olddata, 'rolled-back' if action=='apply' else 'applied')
                print('操作失败；已回滚并回读，私有证据保留。', file=sys.stderr)
            except BaseException as rb:
                M['phase'] = 'retained'; M['failure'] = str(e); M['rollback_failure'] = str(rb)
                try: record()
                except BaseException: pass
                print('rollback 保守保留：'+str(rb)+'；证据 '+C['state'], file=sys.stderr)
        else:
            M['failure'] = str(e)
            try: record()
            except BaseException: pass
        raise

def status():
    print('B1 Docker IPv6 本地模块；Debian/Ubuntu systemd、booted Alpine OpenRC 尚未真实验收。')
    snap, data, unused = config_snapshot()
    if snap['exists']:
        config = parse(data); need(isinstance(config,dict), 'daemon JSON 顶层无效')
        print('配置: '+json.dumps({k:config[k] for k in ('ipv6','fixed-cidr-v6','ip6tables') if k in config},ensure_ascii=False))
    else: print('未配置：daemon.json 不存在。')
    if os.path.lexists(C['state']):
        m, unused = load_record()
        print('事务阶段: '+m['phase']+'；证据: '+C['state'])
        if m['phase']=='applied': need(snap==m['owned'], 'precise owned 配置已改变；不能 restore')
    else: print('无模块初始化记录；既有 IPv6 不接管。')
    print('只读；不联网、不写文件、不查询 Docker、不启动 daemon。')

def main():
    global LOCK
    if TEST:
        need(os.path.normpath(TEST)==TEST and TEST.startswith('/')
             and re.fullmatch(r'docker-ipv6-[A-Za-z0-9_-]+', os.path.basename(TEST)),
             '测试路径只允许 private scratch docker-ipv6-*')
        chain = pathchain(TEST)
        need(chain[-1][3] == 0o700, '测试 root 必须 root-owned 0700')
    need(not any(k.startswith('TOOLBOX_DOCKER_IPV6_') and k!='TOOLBOX_DOCKER_IPV6_TEST_ROOT' for k in os.environ),
         '拒绝额外路径/命令覆盖；仅支持 private scratch TEST_ROOT')
    args = sys.argv[1:]
    need(args and args[0] in ('apply','status','restore') and
         len(args) in ((1,2) if args[0]=='apply' else (1,)),
         '用法: toolbox_docker_ipv6 apply [ULA_/64] | status | restore')
    if args[0]=='status': status(); return
    action=args[0]
    if action=='restore':
        m, unused = load_record(); need(m['phase']=='applied', 'restore：初始化记录不是 applied；保留证据')
        subnet=ula(m['subnet'])
    else: subnet=ula(args[1] if len(args)==2 else 'fd00:1234::/64')
    p=preflight(subnet, owned=action=='restore')
    if action=='apply': need(not os.path.lexists(C['state']), '已有事务证据，不接管')
    else:
        need(p['snapshot']==m['owned'] and stable_identity(p)==m['init'], 'restore precise owned/init 已改变')
    confirm(action,subnet,p)
    lock=Leaf(C['lock'])
    try:
        lock.stable()
        fd=os.open(lock.name, os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW|os.O_NONBLOCK,0o600,dir_fd=lock.fd)
        try:
            s=os.fstat(fd)
            need(stat.S_ISREG(s.st_mode) and s.st_uid==0 and stat.S_IMODE(s.st_mode)==0o600 and s.st_nlink==1,
                 '独占锁不可信')
            try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError: raise Refusal('concurrent：另一事务持有独占锁')
            lock.stable()
            expected=lock.read()[0]
            need(expected['dev']==s.st_dev and expected['ino']==s.st_ino, '锁 inode 已改变')
            LOCK=(lock,fd,expected)
            lock_check()
            need(preflight(subnet, owned=action=='restore')==p, '锁内复检发现 race；未变更')
            transaction(action,subnet,p)
        finally:
            LOCK=None
            os.close(fd)
    finally: lock.close()

def interrupt(signum, frame):
    raise Refusal('收到 signal '+str(signum)+'；取消并保守回滚')

signal.signal(signal.SIGTERM,interrupt)
signal.signal(signal.SIGINT,interrupt)
try:
    main()
except (Refusal, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as e:
    print('B1 拒绝/失败: '+str(e),file=sys.stderr)
    sys.exit(1)
PY
}
