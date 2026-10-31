#!/usr/bin/env bash
# Source-only M3 adapter; REAL bin456789/reinstall owns installation.
# This adapter never calls reboot. Upstream's initrd DOES reboot itself once the
# install finishes (default hold semantics); no --hold is passed (no re-review).
# Parent build must load reinstall-provenance.sh before this module.
_toolbox_reinstall_error() { printf '%s\n' "$*" >&2; }
_toolbox_reinstall_has() { command -v "$1" >/dev/null 2>&1; }
_toolbox_reinstall_root() { [[ $(id -u) == 0 ]] || { _toolbox_reinstall_error '需要 root；未执行。'; return 1; }; }
_toolbox_reinstall_state_dir() { printf '%s\n' "${TOOLBOX_REINSTALL_STATE:-/var/lib/terry-toolbox/reinstall}"; }
_toolbox_reinstall_host_root() { printf '%s\n' "${TOOLBOX_REINSTALL_ROOT:-/}"; }
_toolbox_reinstall_need() {
    local c missing=()
    for c in "$@"; do _toolbox_reinstall_has "$c" || missing+=("$c"); done
    (( ${#missing[@]} == 0 )) || { _toolbox_reinstall_error "缺少依赖：${missing[*]}；不会自动安装。"; return 1; }
}
_toolbox_reinstall_container() {
    local r rc=0 out line
    r=$(_toolbox_reinstall_host_root)
    [[ ! -e $r/.dockerenv && ! -e $r/run/.containerenv && ! -d $r/proc/vz ]] || return 0
    # systemd-detect-virt is NOT required: Alpine/musl hosts normally lack it.
    # Fall back to virt-what (already a prepare dependency) and DMI evidence, so a
    # plain OpenRC VM is not misread as "container state unknown".
    if _toolbox_reinstall_has systemd-detect-virt; then
        systemd-detect-virt --container --quiet || rc=$?
        case $rc in 0) return 0;; 1) return 1;; esac
    elif _toolbox_reinstall_has virt-what; then
        out=$(virt-what 2>/dev/null) || return 2
        while IFS= read -r line; do
            case $line in
                docker|podman|lxc|openvz|systemd-nspawn*|container*) return 0;;
                kvm|vmware|virtualbox|xen|hyperv|qemu|microsoft|amazon|google|bhyve|parallels|oracle) return 1;;
            esac
        done <<<"$out"
    fi
    python3 - "$r" <<'PY'
import os, sys
r=sys.argv[1]
try:
    c=open(r+'/proc/1/cgroup').read()
    if any(x in c.lower() for x in ('docker','kubepods','containerd','lxc','libpod')): sys.exit(0)
except OSError: pass
# Firmware/DMI presence is real bare-metal/VM evidence; absence stays unknown.
try:
    if open(r+'/sys/class/dmi/id/product_name').read().strip(): sys.exit(1)
except OSError: pass
sys.exit(2)
PY
}
_toolbox_reinstall_init() {
    # PID1 identity decides the supported init, never detector presence.
    # systemd => Debian/Ubuntu only; OpenRC => Alpine only; anything else unknown.
    local r comm=''
    r=$(_toolbox_reinstall_host_root)
    comm=$(command cat "$r/proc/1/comm" 2>/dev/null) || comm=''
    comm=${comm%%$'\n'*}
    case $comm in
        systemd) printf 'systemd\n';;
        init|openrc-init|busybox)
            # OpenRC needs positive state, not just a generic "init" comm
            # (sysvinit Debian is also "init" and stays unsupported).
            [[ -e $r/run/openrc && -e $r/sbin/openrc ]] || { _toolbox_reinstall_error "PID1=$comm 但无 OpenRC 状态；init 未审定"; return 1; }
            printf 'openrc\n';;
        '') _toolbox_reinstall_error 'PID1 init 未知（/proc/1/comm）；未执行。'; return 1;;
        *) _toolbox_reinstall_error "PID1 init 未审定: $comm（仅 systemd/OpenRC）"; return 1;;
    esac
}
_toolbox_reinstall_lsblk() {
    local output
    output=$(lsblk --json --bytes --paths --output NAME,KNAME,TYPE,PKNAME,FSTYPE,MOUNTPOINTS,SIZE,MODEL,SERIAL,WWN,MAJ:MIN,RO,RM,PTUUID) || return
    python3 - "$output" <<'PY'
import json,os,stat,sys
for d in json.loads(sys.argv[1])['blockdevices']:
 if d['type']!='disk':continue
 p=d['name'];k=d['kname'].removeprefix('/dev/')
 if not stat.S_ISBLK(os.stat(p).st_mode) or not os.path.exists('/sys/class/block/'+k+'/device'):sys.exit('whole physical disk/sysfs 身份未验证')
 if os.listdir('/sys/class/block/'+k+'/holders'):sys.exit('disk 有 RAID/LVM/crypt/multipath holder')
print(sys.argv[1])
PY
}
_toolbox_reinstall_mounts() { findmnt --json --output TARGET,SOURCE,FSTYPE,OPTIONS; }
_toolbox_reinstall_efi() { efibootmgr -v; }
_toolbox_reinstall_boot_id() { local r; r=$(_toolbox_reinstall_host_root); command cat "$r/proc/sys/kernel/random/boot_id"; }
# python is data/ledger handling ONLY: no partitioning or alternate installation.
_toolbox_reinstall_data() {
    python3 - "$@" <<'PY'
import hashlib,hmac,json,os,re,stat,sys,time
op,r,state,*args=sys.argv[1:]; r=r.rstrip('/') or '/'
def path(p): return os.path.join(r,p.lstrip('/'))
def fail(s): sys.exit(s)
def read(p):
    with open(p,'rb') as f:return f.read()
def regular(p):
    s=os.lstat(p)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:fail('非独占普通文件: '+p)
    return s
def anchor(p):
    p=os.path.abspath(p)
    for i in range(1,len(p.split('/'))+1):
        q='/'.join(p.split('/')[:i]) or '/'
        if os.path.lexists(q) and stat.S_ISLNK(os.lstat(q).st_mode):fail('路径祖先为 symlink: '+q)
def stamp(p):
    s=os.lstat(p); z={'dev':s.st_dev,'ino':s.st_ino,'mode':s.st_mode,'uid':s.st_uid,'gid':s.st_gid,'links':s.st_nlink}
    if stat.S_ISREG(s.st_mode):z['sha']=hashlib.sha256(read(p)).hexdigest();z['size']=s.st_size
    elif stat.S_ISLNK(s.st_mode):z['link']=os.readlink(p)
    elif stat.S_ISCHR(s.st_mode) or stat.S_ISBLK(s.st_mode):
        if not p.startswith(path('/reinstall-tmp')+'/'):fail('启动范围特殊文件: '+p)
        z['rdev']=s.st_rdev
    elif not stat.S_ISDIR(s.st_mode):fail('启动范围特殊文件: '+p)
    return z
roots=['/boot','/efi','/reinstall-tmp','/etc/grub.d']
leaves=['/reinstall-vmlinuz','/reinstall-initrd','/reinstall-firmware','/etc/default/kexec','/etc/default/grub','/etc/update-extlinux.conf']
def snapshot():
    out={}
    for base in roots+leaves:
        p=path(base);anchor(os.path.dirname(p))
        if not os.path.lexists(p):continue
        out[base]=stamp(p)
        if stat.S_ISDIR(os.lstat(p).st_mode):
            for d,ds,fs in os.walk(p,followlinks=False):
                for n in ds+fs:
                    q=os.path.join(d,n);out[base+'/'+os.path.relpath(q,p)]=stamp(q)
    return out
def canonical(x):return json.dumps(x,sort_keys=True,separators=(',',':')).encode()
def statecheck():
    anchor(state);s=os.lstat(state)
    if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)!=0o700:fail('state 目录身份/权限不可信')
def load():
    statecheck();p=state+'/active';anchor(p)
    s=os.lstat(p)
    if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)!=0o700:fail('owned plan 目录权限不可信')
    for f in ('metadata.json','seal.key','seal'):
        s=regular(p+'/'+f)
        if s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)!=0o600:fail('owned plan 文件权限不可信')
    b=read(p+'/metadata.json');key=read(p+'/seal.key')
    if len(key)!=32 or not hmac.compare_digest(read(p+'/seal').decode(),hmac.new(key,b,hashlib.sha256).hexdigest()):fail('owned plan seal 不匹配；保留现场')
    m=json.loads(b)
    if m['state_identity']!=[os.lstat(state).st_dev,os.lstat(state).st_ino] or m['plan_identity']!=[os.lstat(p).st_dev,os.lstat(p).st_ino]:fail('owned plan 目录身份变更')
    for f,z in m['private'].items():
        if stamp(p+'/'+f)!=z:fail('owned plan 私有文件变更: '+f)
    return m
def store(m):
    p=state+'/active';m['updated']=int(time.time())
    for f,b in [('metadata.json',canonical(m)),('seal',hmac.new(read(p+'/seal.key'),canonical(m),hashlib.sha256).hexdigest().encode())]:
        q=p+'/'+f+'.new';fd=os.open(q,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as o:o.write(b)
        os.replace(q,p+'/'+f)
def efi():return args[-1] if args else ''
def efi_entries(s):return sorted(x for x in s.splitlines() if re.match(r'^Boot[0-9a-fA-F]{4}',x))
def allowed(k):
    return k=='/reinstall-tmp' or k.startswith('/reinstall-tmp/') or k in ('/reinstall-vmlinuz','/reinstall-initrd','/reinstall-firmware','/etc/default/kexec','/boot/grub/custom.cfg','/boot/grub/grub.cfg','/boot/grub/grubenv','/boot/grub2/custom.cfg','/boot/grub2/grub.cfg','/boot/grub2/grubenv') or re.match(r'^/(boot/efi|efi|boot)/EFI/reinstall(/.*)?$',k)
def checkdiff(before,after):
    for k in set(before)|set(after):
        b,a=before.get(k),after.get(k)
        if b!=a and not allowed(k):
            # Creating/removing owned children changes ONLY parent link count;
            # never accept replaced parent inode/mode/owner/symlink.
            if b and a and stat.S_ISDIR(b['mode']) and stat.S_ISDIR(a['mode']) and {x:v for x,v in b.items() if x!='links'}=={x:v for x,v in a.items() if x!='links'}:continue
            fail('上游触碰未审定范围: '+k)
if op=='inventory':
    d=json.loads(args[0]);mount=json.loads(args[1]);arch=args[2]
    if arch not in ('x86_64','aarch64'):fail('仅 AMD64/ARM64')
    nodes=[]
    def walk(ns):
        for n in ns:nodes.append(n);walk(n.get('children',[]))
    walk(d['blockdevices'])
    for n in nodes:
        if n['type'] not in ('disk','part','rom','loop'):fail('拒绝 RAID/LVM/crypt/未知 block 类型: '+n['type'])
        if n.get('fstype') in ('LVM2_member','linux_raid_member','crypto_LUKS','zfs_member','btrfs'):fail('拒绝 RAID/LVM/crypt/多设备文件系统')
    disks=[n for n in nodes if n['type']=='disk']
    if len(disks)!=1:fail('拒绝多磁盘/无法唯一识别 whole physical disk')
    if any(n['type']=='loop' and n.get('mountpoints') and any(n['mountpoints']) for n in nodes):fail('拒绝活动 loop/snap boot 未审定状态')
    disk=disks[0]
    if disk.get('ro') not in (False,0) or disk.get('rm') not in (False,0) or not disk.get('maj:min') or int(disk.get('size',0))<1073741824:fail('系统 disk 只读/可移动/编号/容量未知')
    # Upstream keys the destructive target off ptuuid only; demand a real one.
    ptuuid=str(disk.get('ptuuid') or '').lower().removeprefix('0x')
    if not re.fullmatch(r'[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?',ptuuid):fail('whole disk PTUUID 缺失/非法；不写 state/不下载')
    if ptuuid in ('00000000','00000000-0000-0000-0000-000000000000'):fail('whole disk PTUUID 全零（无有效分区表）；不写 state/不下载')
    if not re.fullmatch(r'/dev/(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+)',disk['name']):fail('未支持的 whole disk 名称')
    byname={n['name']:n for n in nodes}
    for n in nodes:byname['/dev/'+n['kname'].removeprefix('/dev/')]=n
    allmount=[]
    def mw(ns):
        for n in ns:allmount.append(n);mw(n.get('children',[]))
    mw(mount['filesystems'])
    rootsm=[n for n in allmount if n['target']=='/']
    if len(rootsm)!=1 or rootsm[0]['fstype'] not in ('ext4','ext3','ext2','xfs'):fail('container/Live/unknown root filesystem')
    if 'rw' not in rootsm[0]['options'].split(','):fail('root 只读挂载（ro）；事务无法一致回读')
    rootdev=rootsm[0]['source']
    if rootdev not in byname:fail('root device 不可识别')
    n=byname[rootdev]
    while n['type']=='part':
        pk=n.get('pkname');pk=pk if pk and pk.startswith('/dev/') else '/dev/'+str(pk)
        if pk not in byname:fail('root ancestry 未知')
        n=byname[pk]
    if n!=disk:fail('root 不属于唯一 whole disk')
    for m in allmount:
        if m['target'].startswith('/reinstall-tmp'):fail('reinstall-tmp 内已有挂载')
        if m['target'] in ('/boot','/boot/efi','/efi'):
            if m['source'] not in byname or m['fstype'] not in ('ext4','ext3','ext2','xfs','fat','vfat') or 'rw' not in m['options'].split(','):fail('boot mount device/filesystem 未知/只读')
            n=byname[m['source']]
            if n['type']=='part':n=byname.get('/dev/'+str(n.get('pkname')).removeprefix('/dev/'))
            if n!=disk:fail('boot 不属于唯一 whole disk')
    out={k:disk.get(k) for k in ('name','kname','size','model','serial','wwn','maj:min','ptuuid')};out['arch']=arch
    print(json.dumps(out,sort_keys=True))
elif op=='clean':
    for k in ('/boot/grub/custom.cfg','/boot/grub2/custom.cfg'):
        if os.path.lexists(path(k)):fail('已有 custom.cfg（包括非 reinstall 自定义引导）；上游会覆盖，拒绝接管: '+k)
    # Upstream overwrites these names / recursively removes its fixed workspace.
    # Refuse symlinks, hardlinks and changed ancestors BEFORE giving it control.
    for k in leaves+['/boot/grub/custom.cfg','/boot/grub/grub.cfg','/boot/grub/grubenv','/boot/grub2/custom.cfg','/boot/grub2/grub.cfg','/boot/grub2/grubenv']:
        p=path(k);anchor(p)
        if os.path.exists(p):regular(p)
    s=snapshot()
    for k,z in s.items():
        if k.startswith('/reinstall-') or '/reinstall' in k.lower():fail('已有/他人 reinstall 状态: '+k)
        if k.endswith(('.cfg','.conf')) and 'sha' in z and b'reinstall' in read(path(k)).lower():fail('已有 reinstall 启动项: '+k)
    if 'BootNext:' in efi() or 'reinstall' in efi().lower():fail('已有 BootNext/reinstall EFI；不接管')
    for k in ('/boot/grub/grubenv','/boot/grub2/grubenv'):
        if os.path.exists(path(k)) and re.search(rb'next_entry=[^\n\x00]+',read(path(k))):fail('已有 GRUB next_entry；不接管')
    print(json.dumps(s,sort_keys=True))
elif op=='init':
    statecheck();p=state+'/active';anchor(p)
    before=snapshot();baseline_efi=args[4]
    m={'schema':1,'phase':'preparing','target':args[0],'disk':json.loads(args[1]),'boot_id':args[2],'commit':args[3],'before':before,'before_efi':baseline_efi,'state_identity':[os.lstat(state).st_dev,os.lstat(state).st_ino],'plan_identity':[os.lstat(p).st_dev,os.lstat(p).st_ino],'private':{},'backups':{}}
    fd=os.open(p+'/seal.key',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as f:f.write(os.urandom(32))
    for k,z in before.items():
        if allowed(k) and 'sha' in z:
            name='backup-'+hashlib.sha256(k.encode()).hexdigest();b=read(path(k))
            with open(p+'/'+name,'xb') as f:f.write(b)
            os.chmod(p+'/'+name,0o600);m['backups'][k]=name
    for f in os.listdir(p):
        if f not in ('metadata.json','seal','prepare.log','cancel.log'):m['private'][f]=stamp(p+'/'+f)
    store(m)
elif op=='phase':
    m=load();m['phase']=args[0];m['detail']=args[1];store(m)
elif op=='prepared':
    m=load();s=snapshot();checkdiff(m['before'],s)
    for k,z in s.items():
        if allowed(k) and not k.startswith('/reinstall-tmp'):
            anchor(path(k))
            if not stat.S_ISDIR(z['mode']):regular(path(k))
    target=m['target'];cfgs=[k for k in s if k.endswith(('/custom.cfg','/EFI/reinstall/grub.cfg')) and b'### BEGIN reinstall.sh ###' in read(path(k))]
    if len(cfgs)!=1:fail('无法验证唯一 prepared boot cfg')
    cfg=read(path(cfgs[0])).decode();commit=m['commit']
    if 'reinstall ('+target+')' not in cfg or 'extra_confhome=\'https://raw.githubusercontent.com/bin456789/reinstall/'+commit+"'" not in cfg:fail('prepared target/runtime pin 不匹配')
    if 'extra_main_disk='+m['disk']['ptuuid'].removeprefix('0x').lower() not in cfg.lower():fail('prepared destructive disk ID 不匹配')
    for f,digest in [('trans.sh','d8f34529c0a706b17d67965b99a107f8299a30d5303744a20f0fb96556365bf7'),('initrd-network.sh','78fd74716b236d0e41e4f5c4034d45db8bcc47fba2d53c4a19a0d21ef60510bc')]:
        expected=read(state+'/active/expected-debian-trans.sh') if f=='trans.sh' and target=='debian 13' else read(state+'/active/'+f)
        if read(path('/reinstall-tmp/initrd/'+f))!=expected:fail('initrd runtime helper pin SHA 不匹配: '+f)
    if read(path('/reinstall-tmp/initrd/configs/ssh_keys')).strip()!=read(state+'/active/key.pub').strip():fail('initrd SSH 公钥不匹配')
    if not os.path.isfile(path('/reinstall-vmlinuz')) or not os.path.getsize(path('/reinstall-initrd')):fail('prepared 内核/initrd 缺失')
    # Read the FINAL repacked newc archive, not only upstream's work directory.
    # No extraction/mount/exec. The WHOLE stream is walked: Linux concatenates
    # archive/gzip members, so stopping at TRAILER!!! would accept a second
    # appended member that later overrides a verified one.
    import gzip
    wanted={'trans.sh':read(state+'/active/expected-debian-trans.sh') if target=='debian 13' else read(state+'/active/trans.sh'),'initrd-network.sh':read(state+'/active/initrd-network.sh'),'configs/ssh_keys':read(state+'/active/key.pub')}
    found={};seen=set();consumed=0;limit=2147483648
    kinds={0o040000:'dir',0o100000:'file',0o120000:'symlink',0o020000:'chr',0o060000:'blk',0o010000:'fifo',0o140000:'sock'}
    def take(g,n):
        global consumed
        consumed+=n
        if consumed>limit:fail('initrd archive 超出验证上限')
        b=g.read(n)
        if len(b)!=n:fail('initrd archive 截断')
        return b
    def pad(g,n,what):
        if n and take(g,n).strip(b'\0'):fail('initrd '+what+' 填充非零')
    try:
        with gzip.open(path('/reinstall-initrd'),'rb') as g:
            while True:
                h=take(g,110)
                if h[:6] not in (b'070701',b'070702'):fail('initrd archive 不是 newc')
                try:
                    mode=int(h[14:22],16);size=int(h[54:62],16);namesize=int(h[94:102],16)
                except ValueError:fail('initrd header 字段非十六进制')
                if namesize<1 or namesize>4096:fail('initrd filename 长度无效')
                raw=take(g,namesize)
                if not raw.endswith(b'\0'):fail('initrd filename 未 NUL 终止')
                try:name=raw.rstrip(b'\0').decode()
                except UnicodeDecodeError:fail('initrd filename 非 UTF-8')
                pad(g,-(110+namesize)%4,'filename')
                while name.startswith('./'):name=name[2:]
                if name=='TRAILER!!!':
                    if size:fail('initrd TRAILER 携带数据')
                    pad(g,-size%4,'TRAILER')
                    break
                kind=kinds.get(mode&0o170000)
                if kind is None:fail('initrd member 类型未审定: '+name)
                if not name or name.startswith('/') or name.endswith('/') or any(p in ('','.','..') for p in name.split('/')):fail('initrd member 路径非法: '+name)
                if name in seen:fail('initrd member 重复（后者会静默覆盖）: '+name)
                seen.add(name)
                if name in wanted:
                    if kind!='file':fail('initrd 受检 member 非普通文件('+kind+'): '+name)
                    if size>1048576:fail('initrd member 过大: '+name)
                    found[name]=take(g,size)
                else:
                    left=size
                    while left:n=min(left,65536);take(g,n);left-=n
                pad(g,-size%4,'数据')
            # Already past TRAILER: only NUL padding may follow. A second gzip
            # member or further archive bytes here are unverified overrides.
            while True:
                b=g.read(65536)
                if not b:break
                consumed+=len(b)
                if consumed>limit:fail('initrd archive 超出验证上限')
                if b.strip(b'\0'):fail('initrd TRAILER 后仍有非零尾部（追加 archive/member 未审定）')
    except (OSError,EOFError,gzip.BadGzipFile) as e:fail('initrd gzip 流损坏/截断: '+str(e))
    if not consumed:fail('initrd 为空')
    for name,b in wanted.items():
        if found.get(name)!=b and not (name=='configs/ssh_keys' and found.get(name,b'').strip()==b.strip()):fail('最终 initrd runtime/key pin 不匹配: '+name)
    current_efi=args[0]
    if current_efi:
        new=set(efi_entries(current_efi))-set(efi_entries(m['before_efi']))
        if len(new)!=1 or 'reinstall ('+target+')' not in next(iter(new)):fail('EFI plan 身份未知')
        entry=next(iter(new));idx=entry[4:8]
        if 'BootNext: '+idx not in current_efi or '\\EFI\\reinstall\\' not in entry:fail('EFI BootNext 不属于本 plan')
    else:
        env=path(os.path.dirname(cfgs[0])+'/grubenv')
        if ('next_entry=reinstall ('+target+')').encode() not in read(env):fail('GRUB next_entry 未准备')
    m['phase']='prepared';m['after']=s;m['after_efi']=current_efi;store(m)
elif op in ('status','verify'):
    if not os.path.lexists(state+'/active'):
        print('没有本工具 owned plan；未调用上游。');sys.exit(0 if op=='status' else 1)
    m=load()
    if m['phase']=='prepared':
        if args[0]!=m['boot_id']:fail('boot_id 已变；不得在重启后 reset')
        if snapshot()!=m['after'] or args[1]!=m['after_efi']:fail('prepared boot/ledger 身份变化；保留现场，拒绝 reset')
        if op=='verify':
            if len(args)!=4 or json.loads(args[2])!=m['disk']:fail('cancel 当前 whole disk 身份/拓扑变化')
            if args[3]!=('openrc' if m['target'].startswith('alpine') else 'systemd'):fail('cancel PID1 init 与 plan target 不一致: '+args[3])
    elif op=='verify':fail('非可验证 prepared 状态: '+m['phase']+'；'+m.get('detail',''))
    print('M3 phase='+m['phase']+' target='+m['target']+' disk='+m['disk']['name']+' commit='+m['commit'])
    if m.get('detail'):print(m['detail'])
elif op=='restore':
    m=load();s=snapshot();checkdiff(m['after'],s)
    # Reset must have actually removed owned entry and next boot state BEFORE
    # restoring exact old bytes. Failure retains the sealed report, no guessing.
    for k,z in s.items():
        if k.endswith(('.cfg','.conf')) and 'sha' in z and b'reinstall' in read(path(k)).lower():fail('reset 后仍有 reinstall 启动项')
    if 'BootNext:' in args[0] or efi_entries(args[0])!=efi_entries(m['before_efi']):fail('reset 后 EFI 回读不等于原 entries')
    for k in ('/boot/grub/grubenv','/boot/grub2/grubenv'):
        if os.path.exists(path(k)) and re.search(rb'next_entry=[^\n\x00]+',read(path(k))):fail('reset 后 next_entry 未清空')
    # reset may recreate config files. Only allow reviewed leaves to be restored;
    # ensure every before-existing file outside those leaves is still identical.
    for k,name in m['backups'].items():
        anchor(path(k));z=m['before'][k]
        if os.path.lexists(path(k)) and not stat.S_ISREG(os.lstat(path(k)).st_mode):fail('restore leaf 非普通文件')
        q=path(k)+'.terry-restore';fd=os.open(q,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,stat.S_IMODE(z['mode']))
        with os.fdopen(fd,'wb') as f:f.write(read(state+'/active/'+name))
        os.chown(q,z['uid'],z['gid']);os.chmod(q,stat.S_IMODE(z['mode']));os.replace(q,path(k))
    for k in sorted(set(s)-set(m['before']),key=lambda x:(x.count('/'),x),reverse=True):
        if not allowed(k):fail('reset/restore 未审定新文件: '+k)
        anchor(os.path.dirname(path(k)))
        # reset leftovers must still have their originally sealed leaf identity.
        # Upstream BIOS reset uses sed -i and leaves its exclusively-created
        # custom.cfg EMPTY (new inode). Accept only that exact reviewed result,
        # never arbitrary reset residue; all other leftovers require full stamp.
        empty_custom=k in ('/boot/grub/custom.cfg','/boot/grub2/custom.cfg') and 'sha' in s[k] and read(path(k))==b'' and {x:s[k][x] for x in ('mode','uid','gid','links')}=={x:m['after'][k][x] for x in ('mode','uid','gid','links')}
        if s[k]!=m['after'].get(k) and not empty_custom:fail('reset 残留身份变化: '+k)
        if stat.S_ISDIR(os.lstat(path(k)).st_mode):os.rmdir(path(k))
        else:os.unlink(path(k))
    now=snapshot()
    if set(now)!=set(m['before']):fail('恢复后路径集合变化')
    for k,z in m['before'].items():
        current=now[k]
        if k in m['backups']:
            if {a:v for a,v in current.items() if a not in ('ino','dev')}!={a:v for a,v in z.items() if a not in ('ino','dev')}:fail('恢复 bytes/mode 回读失败: '+k)
        elif current!=z:fail('原始非 owned 文件变化: '+k)
    m['phase']='cancelled';m['detail']='上游 reset 成功；bootstate 与精确原文件回读通过；reset 本身不重启。';store(m)
else:fail('未知 data operation')
PY
}
_toolbox_reinstall_preflight() {
    # Optional target lets prepare prove PID1 init and distribution agree.
    local rc=0 arch inventory mounts efi='' r disk secure init want=${1:-}
    case $want in ''|debian|ubuntu|alpine) ;; *) _toolbox_reinstall_error "preflight 目标未审定: $want"; return 1;; esac
    _toolbox_reinstall_root || return
    _toolbox_reinstall_need bash python3 curl sha256sum ssh-keygen lsblk findmnt flock uname stat cp mv rm mkdir rmdir env cat id \
        grep sed awk sort head tail wc cut tr xargs find readlink fdisk gzip cpio lsmem dmidecode virt-what || return
    # Init is decided from PID1, not from an optional detector; unknown refuses.
    init=$(_toolbox_reinstall_init) || return 1
    case $init:$want in
        systemd:alpine|openrc:debian|openrc:ubuntu)
            _toolbox_reinstall_error "PID1 init=$init 与 target=$want 不一致；未执行。"; return 1;;
    esac
    _toolbox_reinstall_container || rc=$?
    case $rc in 1) ;; 0) _toolbox_reinstall_error '拒绝 container；未执行。'; return 1;; *) _toolbox_reinstall_error 'container 状态未知；未执行。'; return 1;; esac
    r=$(_toolbox_reinstall_host_root)
    arch=$(uname -m) || return
    inventory=$(_toolbox_reinstall_lsblk) || { _toolbox_reinstall_error 'lsblk 回读失败'; return 1; }
    mounts=$(_toolbox_reinstall_mounts) || { _toolbox_reinstall_error 'mount 回读失败'; return 1; }
    disk=$(_toolbox_reinstall_data inventory "$r" "$(_toolbox_reinstall_state_dir)" "$inventory" "$mounts" "$arch") || return
    if [[ -d $r/sys/firmware/efi ]]; then
        _toolbox_reinstall_need efibootmgr mokutil || return
        secure=$(mokutil --sb-state) || { _toolbox_reinstall_error 'Secure Boot 状态未知'; return 1; }
        [[ $secure == *'SecureBoot disabled'* ]] || { _toolbox_reinstall_error '要求 Secure Boot 明确 disabled'; return 1; }
        efi=$(_toolbox_reinstall_efi) || return
        [[ $efi == *BootCurrent:* && $efi == *BootOrder:* ]] || { _toolbox_reinstall_error 'EFI 状态未知'; return 1; }
        # Upstream selects first FAT mount. Require one exact recognized ESP.
        python3 - "$mounts" "$r" <<'PY' || return
import json,os,sys
n=[]
def walk(xs):
 for x in xs:n.append(x);walk(x.get('children',[]))
walk(json.loads(sys.argv[1])['filesystems'])
a=[x for x in n if x['fstype'] in ('fat','vfat') and x['target'] in ('/efi','/boot/efi','/boot')]
if len(a)!=1 or 'rw' not in a[0]['options'].split(','):sys.exit('要求唯一可写已挂载 ESP；不自动 mount')
p=os.path.join(sys.argv[2],a[0]['target'].lstrip('/'))
if not any(f.lower().endswith('.efi') for _,_,fs in os.walk(p) for f in fs):sys.exit('ESP 未找到现有 EFI loader')
PY
        printf 'Boot mode: UEFI（Secure Boot disabled）\n'
    else
        # Upstream BIOS extlinux mutates MENU HIDDEN/TIMEOUT and opaque --once.
        # Refuse it rather than inventing a reversible cancellation path.
        _toolbox_reinstall_need grub-mkconfig grub-editenv grub-reboot update-grub || return
        local grub='' f
        for f in /boot/grub /boot/grub2; do
            [[ ! -f $r$f/grub.cfg ]] || { [[ -z $grub ]] || { _toolbox_reinstall_error 'GRUB 布局不唯一'; return 1; }; grub=$f; }
        done
        [[ -n $grub && -f $r$grub/grubenv && ! -L $r$grub/grub.cfg && ! -L $r$grub/grubenv ]] || { _toolbox_reinstall_error '仅审定 BIOS GRUB；extlinux/unknown boot 禁用'; return 1; }
        _toolbox_reinstall_mbr_grub "$disk" || { _toolbox_reinstall_error 'MBR 未验证 GRUB；未执行'; return 1; }
        printf 'Boot mode: BIOS GRUB\n'
    fi
    _toolbox_reinstall_data clean "$r" "$(_toolbox_reinstall_state_dir)" "$efi" >/dev/null || return
    _toolbox_reinstall_boot_id >/dev/null || return
    printf 'Init: %s（PID1 审定）\n' "$init"
    printf 'Exact whole physical disk destructive scope（所有分区/全部数据）: %s\n' "$disk"
    printf 'preflight 只读通过；不等于安装验收。上游可能补装 runtime 包、修改 boot 文件与 kexec。本阶段不重启；重启进 initrd 后由上游自动 reboot。\n'
    _toolbox_reinstall_disk=$disk
    _toolbox_reinstall_efi_before=$efi
}
_toolbox_reinstall_mbr_grub() {
    local name
    name=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["name"])' "$1") || return
    [[ -b $name ]] || return 1
    head -c 440 "$name" | grep -aiq GRUB
}
_toolbox_reinstall_pubkey() {
    python3 - "$1" <<'PY' || return
import base64,os,stat,struct,sys
p=sys.argv[1]
if not p.startswith('/') or not p.endswith('.pub'):sys.exit('SSH 公钥必须是本地绝对路径 .pub 文件')
s=os.lstat(p)
if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1 or s.st_size>16384 or s.st_size<1:sys.exit('SSH 公钥必须是普通本地文件；拒绝 symlink/private key')
b=open(p,'rb').read()
if not b.endswith(b'\n') or b.count(b'\n')!=1:sys.exit('只接受一个完整 newline 的 SSH 公钥')
a=b.split()
if len(a)<2 or a[0]!=b'ssh-ed25519':sys.exit('M3 仅接受优先推荐的 ssh-ed25519 公钥；拒绝私钥/选项/URL')
try:
 raw=base64.b64decode(a[1],validate=True)
 n=struct.unpack('>I',raw[:4])[0]
 if raw[4:4+n]!=b'ssh-ed25519' or struct.unpack('>I',raw[4+n:8+n])[0]!=32 or len(raw)!=8+n+32:raise ValueError()
except Exception:sys.exit('SSH 公钥 wire 格式无效')
PY
    ssh-keygen -lf "$1" || return
}
_toolbox_reinstall_run_upstream() {
    # A fixture root must NEVER be paired with actual destructive execution.
    [[ $(_toolbox_reinstall_host_root) == / ]] || { _toolbox_reinstall_error '非真实 root override；拒绝执行上游（仅 mock boundary 可用）'; return 99; }
    # env -i avoids inherited password/debug/shell hooks. Do not log password argv.
    env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C TERM="${TERM:-dumb}" bash "$1" "${@:2}" </dev/null
}
_toolbox_reinstall_confirm() {
    local answer
    printf '确认已在此磁盘之外验证备份，且拥有可用 rescue/serial/VNC 控制台。输入 YES: ' >&2
    if ! IFS= read -r answer || [[ ${answer^^} != YES ]]; then _toolbox_reinstall_error '已取消/EOF（必须完整 newline）'; return 1; fi
    printf '确认下一次人工重启会清除上述整个磁盘；再次输入 YES: ' >&2
    if ! IFS= read -r answer || [[ ${answer^^} != YES ]]; then _toolbox_reinstall_error '已取消/EOF（必须完整 newline）'; return 1; fi
    printf '逐字输入 whole physical disk 路径 %s: ' "$1" >&2
    if ! IFS= read -r answer || [[ $answer != "$1" ]]; then _toolbox_reinstall_error 'disk exact typed confirm 不匹配/EOF；取消'; return 1; fi
}
_toolbox_reinstall_prepare() (
    umask 077
    local distro=${1:-debian} version=${2:-} key state r name target first efi boot rc=0 lockfd
    case $distro in
        debian) version=${version:-13}; [[ $version == 13 ]] || return 1;;
        ubuntu) version=${version:-24.04}; [[ $version == 24.04 ]] || return 1;;
        alpine) version=${version:-3.24}; [[ $version == 3.24 ]] || return 1;;
        *) _toolbox_reinstall_error '仅固定 debian 13 / ubuntu 24.04 LTS / alpine 3.24'; return 1;;
    esac
    [[ $# -le 2 ]] || return 1
    _toolbox_reinstall_preflight "$distro" || return
    state=$(_toolbox_reinstall_state_dir);r=$(_toolbox_reinstall_host_root)
    [[ ! -e $state/active ]] || { _toolbox_reinstall_error '已有 owned/unknown plan；请 status；不接管、不重复 prepare'; return 1; }
    key=${TOOLBOX_REINSTALL_SSH_KEY_FILE:-}
    if [[ -z $key ]]; then
        printf '本地 ssh-ed25519 公钥绝对路径 (.pub): ' >&2
        IFS= read -r key || { _toolbox_reinstall_error 'SSH 公钥未输入/EOF'; return 1; }
    fi
    _toolbox_reinstall_pubkey "$key" || return
    name=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["name"])' "$_toolbox_reinstall_disk") || return
    target="$distro $version";first=$_toolbox_reinstall_disk
    printf 'Target: %s；上游 commit: %s\n' "$target" "$_TOOLBOX_REINSTALL_COMMIT"
    printf '精确 boot 范围: /reinstall-{vmlinuz,initrd,firmware}, /reinstall-tmp, BIOS /boot/grub{,2}/{custom.cfg,grub.cfg,grubenv} 或唯一 ESP/EFI/reinstall；/etc/default/kexec。\n'
    printf '上游 runtime 可能仅补缺 curl/grep/fdisk/lsblk/findmnt/gzip/cpio/dmidecode/virt-what 等（UEFI efibootmgr、Debian ar/dpkg/xz 等）；包仓库/镜像不是内容 pin，cancel 不卸载包。\n'
    _toolbox_reinstall_confirm "$name" || return
    # Recheck topology AND boot conflicts after consent, before writes/fetch.
    _toolbox_reinstall_preflight "$distro" || return
    [[ $first == "$_toolbox_reinstall_disk" ]] || { _toolbox_reinstall_error '确认后 disk 身份变化；未执行'; return 1; }
    python3 - "$state" <<'PY' || return
import os,stat,sys
p=sys.argv[1]
for i in range(1,len(p.split('/'))+1):
 q='/'.join(p.split('/')[:i]) or '/'
 if os.path.lexists(q) and stat.S_ISLNK(os.lstat(q).st_mode):sys.exit('state 路径 symlink；拒绝')
os.makedirs(p,mode=0o700,exist_ok=True)
s=os.lstat(p)
if s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)!=0o700:sys.exit('state 权限必须 owned 0700')
PY
    python3 - "$state/lock" <<'PY' || return
import os,stat,sys
p=sys.argv[1]
try:
 s=os.lstat(p)
 if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1 or s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)!=0o600:sys.exit('lock 身份不可信')
except FileNotFoundError:
 fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600);os.close(fd)
PY
    exec {lockfd}<"$state/lock" || return
    flock -n "$lockfd" || { _toolbox_reinstall_error 'concurrent reinstall 操作；拒绝'; return 1; }
    mkdir "$state/active" || { _toolbox_reinstall_error '已有 plan（竞争）；拒绝'; return 1; }
    # Keep failures/signals with reports. NEVER auto-reset an uncertain plan.
    trap '_toolbox_reinstall_error "收到信号；保留 report，本工具不自动 reset/reboot"; if [[ -f $state/active/seal ]]; then _toolbox_reinstall_data phase "$r" "$state" interrupted "信号中断；人工检查 boot 与日志"; fi; exit 130' INT TERM HUP
    cp -- "$key" "$state/active/key.pub" || return
    _toolbox_reinstall_pubkey "$state/active/key.pub" || return
    _toolbox_reinstall_fetch "$state/active" || { _toolbox_reinstall_error "provenance 失败；保留 $state/active；未执行上游"; return 1; }
    # Downloads can take time. Do not adopt boot files or topology that raced in.
    _toolbox_reinstall_preflight "$distro" || return
    [[ $first == "$_toolbox_reinstall_disk" ]] || { _toolbox_reinstall_error '下载后 disk 身份变化；拒绝上游'; return 1; }
    boot=$(_toolbox_reinstall_boot_id) || return
    _toolbox_reinstall_data init "$r" "$state" "$target" "$_toolbox_reinstall_disk" "$boot" "$_TOOLBOX_REINSTALL_COMMIT" "$_toolbox_reinstall_efi_before" || return
    # Print real errors to stderr as well as retain the private log, preserving rc.
    _toolbox_reinstall_run_upstream "$state/active/reinstall.sh" "$distro" "$version" \
        --username root --ssh-key "$state/active/key.pub" --target-disk "$name" \
        >"$state/active/prepare.log" 2>&1 || rc=$?
    command cat "$state/active/prepare.log" >&2
    if (( rc != 0 )); then
        _toolbox_reinstall_data phase "$r" "$state" failed "上游 prepare exit=$rc；不宣称 done；保留日志与现场" || return
        return "$rc"
    fi
    efi='';[[ ! -d $r/sys/firmware/efi ]] || efi=$(_toolbox_reinstall_efi) || return
    _toolbox_reinstall_data prepared "$r" "$state" "$efi" || {
        _toolbox_reinstall_data phase "$r" "$state" failed '上游返回 0 但 prepared/readback 验证失败；不可自动 reset' || return; return 1; }
    printf '仅 prepare 完成并回读；尚未安装，本阶段不会重启。重启交接：先 toolbox_reinstall status，核实备份/rescue 后由操作者重启；进入 initrd 后上游安装完成会自行 reboot（未用 --hold），需自行观察第二次重启结果——本工具从不执行 reboot。\n'
)
_toolbox_reinstall_status() {
    local r state efi='' boot
    _toolbox_reinstall_need python3 || return
    r=$(_toolbox_reinstall_host_root);state=$(_toolbox_reinstall_state_dir)
    [[ -e $state/active || -L $state/active ]] || { printf '没有本工具 owned plan；只读，未调用上游。\n'; return 0; }
    [[ -f $state/active/seal && ! -L $state/active ]] || { _toolbox_reinstall_error "blocking: unsealed/unknown plan $state/active；下载/准备中断；保留 report，禁止 reset"; return 1; }
    boot=$(_toolbox_reinstall_boot_id) || return
    [[ ! -d $r/sys/firmware/efi ]] || efi=$(_toolbox_reinstall_efi) || return
    _toolbox_reinstall_data status "$r" "$state" "$boot" "$efi"
}
_toolbox_reinstall_cancel() (
    umask 077
    local r state efi='' boot rc=0 lockfd init
    _toolbox_reinstall_root || return
    _toolbox_reinstall_need python3 flock uname lsblk findmnt bash sha256sum || return
    init=$(_toolbox_reinstall_init) || return 1
    local container_rc=0
    _toolbox_reinstall_container || container_rc=$?
    [[ $container_rc == 1 ]] || { _toolbox_reinstall_error 'cancel container/unknown state；拒绝 reset'; return 1; }
    r=$(_toolbox_reinstall_host_root);state=$(_toolbox_reinstall_state_dir)
    [[ -e $state/active/seal && -f $state/lock && ! -L $state/lock ]] || { _toolbox_reinstall_error '没有可验证 owned plan；拒绝调用上游 reset'; return 1; }
    python3 - "$state/lock" <<'PY' || return
import os,stat,sys
s=os.lstat(sys.argv[1])
if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1 or s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)!=0o600:sys.exit('cancel lock 身份不可信')
PY
    exec {lockfd}<"$state/lock" || return
    flock -n "$lockfd" || { _toolbox_reinstall_error 'concurrent 操作；拒绝 reset'; return 1; }
    boot=$(_toolbox_reinstall_boot_id) || return
    [[ ! -d $r/sys/firmware/efi ]] || efi=$(_toolbox_reinstall_efi) || return
    local current_disk inventory mounts arch
    inventory=$(_toolbox_reinstall_lsblk) || return
    mounts=$(_toolbox_reinstall_mounts) || return
    arch=$(uname -m) || return
    current_disk=$(_toolbox_reinstall_data inventory "$r" "$state" "$inventory" "$mounts" "$arch") || return
    _toolbox_reinstall_data verify "$r" "$state" "$boot" "$efi" "$current_disk" "$init" || return
    # Refuse reset if a mount appeared inside its rm -rf workspace.
    _toolbox_reinstall_mounts | python3 -c 'import json,sys;d=json.load(sys.stdin);q=list(d["filesystems"])
while q:
 n=q.pop();q+=n.get("children",[])
 if n["target"].startswith("/reinstall-tmp"):sys.exit("workspace 新增 mount；拒绝 reset")' || return
    trap '_toolbox_reinstall_data phase "$r" "$state" cancel-interrupted "reset 信号中断；保留现场"; exit 130' INT TERM HUP
    _toolbox_reinstall_data phase "$r" "$state" cancelling '即将仅 reset 已验证 owned plan' || return
    _toolbox_reinstall_run_upstream "$state/active/reinstall.sh" reset >"$state/active/cancel.log" 2>&1 || rc=$?
    command cat "$state/active/cancel.log" >&2
    if (( rc != 0 )); then
        _toolbox_reinstall_data phase "$r" "$state" reset-failed "上游 reset exit=$rc；不恢复/删除；保留 report" || return
        return "$rc"
    fi
    efi='';[[ ! -d $r/sys/firmware/efi ]] || efi=$(_toolbox_reinstall_efi) || return
    _toolbox_reinstall_data restore "$r" "$state" "$efi" || {
        _toolbox_reinstall_data phase "$r" "$state" restore-failed 'reset 后 bootstate/精确恢复回读失败；保留 report' || return; return 1; }
    _toolbox_reinstall_status
)
toolbox_reinstall() {
    case ${1:-preflight} in
        preflight) [[ $# -le 2 ]] || return 1; _toolbox_reinstall_preflight "${2:-}";;
        prepare) shift; _toolbox_reinstall_prepare "$@";;
        status) [[ $# == 1 ]] || return 1; _toolbox_reinstall_status;;
        cancel) [[ $# == 1 ]] || return 1; _toolbox_reinstall_cancel;;
        *) _toolbox_reinstall_error '用法: toolbox_reinstall preflight [debian|ubuntu|alpine] | prepare [debian|ubuntu|alpine] [version] | status | cancel'; return 1;;
    esac
}
