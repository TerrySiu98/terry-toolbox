#!/usr/bin/env bash
# Source-only Certbot adapter. No ACME implementation, installer, firewall or DNS edits.
# One exclusive native Certbot lineage per owned root. Defaults use the source package,
# never a downloaded one-liner. Runtime/version hashes describe local bytes, not a
# claim that the host's package repository was independently authenticated.
# Overrides are isolated paths for fixtures; TEST_FIXTURE is a sealed, root-owned
# fixture.json under /root/.../tls-acme-fixture-* and permits only loopback HTTPS CA.

# Sourcing defines functions only; no path probes or commands, including stdin bundles.
tls_acme_err() { printf '%s\n' "$*" >&2; }
tls_acme_root() { printf '%s\n' "${TOOLBOX_TLS_ACME_ROOT:-/var/lib/terry-toolbox-acme}"; }
tls_acme_units() { printf '%s\n' "${TOOLBOX_TLS_ACME_UNIT_DIR:-/etc/systemd/system}"; }
tls_acme_valid() {
    [[ ${#1} -le 253 && $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
    [[ ${#2} -le 254 && $2 =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}
tls_acme_confirm() {
    local answer i
    for i in 1 2; do
        printf '第 %s 次确认：输入 YES（完整换行；空白/EOF 取消）：' "$i"
        IFS= read -r answer && [[ ${answer^^} == YES ]] || { tls_acme_err '已取消。'; return 1; }
    done
}
tls_acme_require() {
    local c id='' line
    [[ ${EUID:-1} == 0 ]] || { tls_acme_err '需要 root。'; return 1; }
    for c in python3 openssl certbot systemctl ss timeout; do
        command -v "$c" >/dev/null 2>&1 || { tls_acme_err "缺少必需命令：$c（请预先安装发行版 Certbot/依赖，模块不自动安装）"; return 1; }
    done
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in ID=*) [[ -z $id ]] || return 1; id=${line#ID=}; id=${id#\"}; id=${id%\"}; id=${id#\'}; id=${id%\'};; esac
    done < "${TOOLBOX_TLS_ACME_OS_RELEASE:-/etc/os-release}" || return 1
    [[ $id == debian || $id == ubuntu ]] || { tls_acme_err '仅支持 Debian/Ubuntu + 真正 systemd。'; return 1; }
    [[ -d ${TOOLBOX_TLS_ACME_SYSTEMD_RUN:-/run/systemd/system} ]] || { tls_acme_err 'systemd 未运行。'; return 1; }
    # A marker directory alone is insufficient: real PID1 is checked unless the
    # explicitly sealed fixture permits a mock service manager.
    tls_acme_fs platform "${TOOLBOX_TLS_ACME_OS_RELEASE:-/etc/os-release}" "${TOOLBOX_TLS_ACME_SYSTEMD_RUN:-/run/systemd/system}" || return 1
    tls_acme_version=$(certbot --version 2>/dev/null) || { tls_acme_err 'Certbot --version 失败。'; return 1; }
    [[ $tls_acme_version =~ ^certbot\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || { tls_acme_err '无法识别稳定 Certbot 版本。'; return 1; }
    tls_acme_binary=$(command -v certbot) || return 1
    [[ $tls_acme_binary == /* ]] || { tls_acme_err 'Certbot 必须是现有绝对路径程序。'; return 1; }
    tls_acme_fs program "$tls_acme_binary" || return 1
}
# Filesystem helper: sealed ownership, restrictive ancestry, native symlinks only,
# no eval/source of metadata or renewal hooks, no recursive cleanup on any failure.
tls_acme_fs() {
    python3 - "$1" "$(tls_acme_root)" "$(tls_acme_units)" "${TOOLBOX_TLS_ACME_TEST_FIXTURE:-}" "${@:2}" <<'PY'
import os, sys, stat, json, hashlib, re, socket, ipaddress, configparser, subprocess, tempfile, time
from urllib.parse import urlsplit
op, root, units, fixture, *args = sys.argv[1:]
CA='https://acme-v02.api.letsencrypt.org/directory'
SVC='terry-toolbox-acme.service'; TIMER='terry-toolbox-acme.timer'

def ident(s): return f'{s.st_dev}:{s.st_ino}'
def path(p,native=False):
    if any(x in ('','.','..') for x in p.split('/')[1:]): raise ValueError('unsafe absolute path')
    if re.fullmatch(r'/[A-Za-z0-9_./-]+',p): return
    # Only tree reads of native accounts may use the sealed CA's host:port.
    # Callers selecting root/unit/program/fixture paths keep the strict default.
    if native and p.startswith(root+'/') and account_rel(p[len(root)+1:]): return
    raise ValueError('unsafe absolute path')
def directory(p,native=False):
    if p != '/': path(p,native=native)
    fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
    try:
        for part in p.split('/')[1:]:
            s=os.fstat(fd)
            if s.st_uid != 0 or s.st_mode & 0o022: raise ValueError('non-root/writable ancestor')
            if not part: continue
            n=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            os.close(fd); fd=n
        s=os.fstat(fd)
        if s.st_uid != 0 or s.st_mode & 0o022: raise ValueError('non-root/writable directory')
        return fd
    except BaseException: os.close(fd); raise

def account_rel(rel):
    # Exact native Certbot account shape: <CA netloc>/<dir|directory>/<32 hex>/...
    # Empty directories are included because os.walk reports ancestors.
    if not F: return False
    m=re.fullmatch(r'config/accounts/([^/]+)/(dir|directory)(/[a-f0-9]{32}(/(meta|regr|private_key)\.json)?)?',rel)
    return bool(m) and m[1]==urlsplit(F['server']).netloc
def parent(p,native=False): path(p,native=native); return directory(os.path.dirname(p),native=native),os.path.basename(p)
def record(p,read=True,private=True,native=False):
    fd,n=parent(p,native=native)
    try: f=os.open(n,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=fd)
    finally: os.close(fd)
    try:
        s=os.fstat(f)
        if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or s.st_nlink!=1 or (s.st_mode & (0o077 if private else 0o022)): raise ValueError('unsafe file ownership/mode/link: '+p)
        data=b''
        while True:
            b=os.read(f,1048576)
            if not b: break
            data+=b
            if len(data)>16*1024*1024: raise ValueError('oversize file')
        return {'id':ident(s),'mode':stat.S_IMODE(s.st_mode),'sha256':hashlib.sha256(data).hexdigest()}, data
    finally: os.close(f)
def create(p,data,mode=0o600):
    fd,n=parent(p)
    try:
        f=os.open(n,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode,dir_fd=fd)
        try:
            view=memoryview(data)
            while view:
                k=os.write(f,view)
                if k<=0: raise OSError('short write')
                view=view[k:]
            os.fchmod(f,mode); os.fsync(f)
        finally: os.close(f)
    finally: os.close(fd)
def replace(p,data):
    before,_=record(p); fd,n=parent(p)
    try:
        if ident(os.stat(n,dir_fd=fd,follow_symlinks=False))!=before['id']: raise ValueError('file replaced')
        f=os.open(n,os.O_WRONLY|os.O_NOFOLLOW,dir_fd=fd)
        try:
            if ident(os.fstat(f))!=before['id']: raise ValueError('file replaced')
            os.ftruncate(f,0); view=memoryview(data)
            while view:
                k=os.write(f,view)
                if k<=0: raise OSError('short write')
                view=view[k:]
            os.fsync(f)
        finally: os.close(f)
    finally: os.close(fd)
def fixture_data():
    if not fixture: return None
    path(fixture)
    if not fixture.endswith('/fixture.json') or not any(x.startswith('tls-acme-fixture-') for x in fixture.split('/')) or not fixture.startswith('/root/'): raise ValueError('fixture must be an explicit /root/.../tls-acme-fixture-*/fixture.json')
    r,b=record(fixture); sr,s=record(fixture+'.sha256')
    if s != (r['sha256']+'\n').encode(): raise ValueError('fixture seal mismatch')
    d=json.loads(b)
    if set(d)!={'version','root','units','server','requests_ca','cert_ca','host','addresses','mock_systemd'} or d['version']!=1: raise ValueError('invalid fixture schema')
    base=os.path.dirname(fixture)
    if root!=d['root'] or units!=d['units'] or not root.startswith(base+'/') or not (units.startswith(base+'/') or (units=='/etc/systemd/system' and d['mock_systemd'] is False)): raise ValueError('fixture target escapes isolated root/systemd unit scope')
    from urllib.parse import urlsplit
    u=urlsplit(d['server'])
    if u.scheme!='https' or u.path!='/dir' or u.query or u.fragment or u.username or u.password or not u.port or not 1<=u.port<=65535: raise ValueError('only explicit HTTPS test CA directory permitted')
    if u.hostname not in ('127.0.0.1','localhost'):
        if not u.hostname or not re.fullmatch(r'[a-z0-9.-]+\.test',u.hostname): raise ValueError('CA override must be loopback or isolated .test hostname')
        # Resolution is checked by mutation preflight, never read-only status.

    d['_records']={'fixture':r,'seal':sr}
    for k in ('requests_ca','cert_ca'):
        if not d[k].startswith(base+'/'): raise ValueError('fixture CA outside fixture')
        d['_records'][k]=record(d[k])[0]
    if not isinstance(d['mock_systemd'],bool) or not re.fullmatch(r'[a-z0-9.-]+',d['host']): raise ValueError('invalid fixture values')
    for a in d['addresses']: ipaddress.ip_address(a)
    return d
F=fixture_data()
def parent_ids():
    out={}
    for p in (root, units+'/'+SVC, units+'/'+TIMER):
        fd,_=parent(p)
        try: out[os.path.dirname(p)]=ident(os.fstat(fd))
        finally: os.close(fd)
    if root.startswith(units+'/') or units.startswith(root+'/') or root==units: raise ValueError('overlapping paths')
    return out

def tree():
    out={}; inodes=set()
    fd=directory(root); os.close(fd)
    for here, dirs, files in os.walk(root,followlinks=False):
        for name in sorted(dirs+files):
            p=here+'/'+name; rel=os.path.relpath(p,root)
            if rel in ('metadata.json','metadata.sha256','.lock'): continue
            allowed = rel in ('config','work','logs','runtime.sh','cli.ini','vmess-source.sh','network-source.sh','vmess-hook.sh') or re.fullmatch(r'logs/(action-[0-9]+\.log|letsencrypt\.log(\.[0-9]+)?|\.certbot\.lock)',rel) or re.fullmatch(r'(work|config)/\.certbot\.lock',rel) or re.fullmatch(r'config/(accounts|archive|live|renewal|renewal-hooks)',rel) or re.fullmatch(r'config/renewal-hooks/(pre|deploy|post)',rel) or re.fullmatch(r'config/(live|archive)/[a-z0-9.-]+',rel) or re.fullmatch(r'config/live/(README|[a-z0-9.-]+/(README|cert\.pem|chain\.pem|fullchain\.pem|privkey\.pem))',rel) or re.fullmatch(r'config/archive/[a-z0-9.-]+/(cert|chain|fullchain|privkey)[1-9][0-9]*\.pem',rel) or re.fullmatch(r'config/renewal/[a-z0-9.-]+\.conf',rel) or re.fullmatch(r'config/accounts/[A-Za-z0-9_.:-]+(/dir(ectory)?(/[a-f0-9]{32}(/(meta|regr|private_key)\.json)?)?)?',rel)
            if not allowed: raise ValueError('unknown native resource: '+rel)
            s=os.lstat(p)
            native=rel.startswith('config/accounts/')
            if s.st_uid!=0: raise ValueError('foreign owner: '+rel)
            if stat.S_ISLNK(s.st_mode):
                # Exactly Certbot's live quartet, with one same generation.
                if not re.fullmatch(r'config/live/[a-z0-9.-]+/(cert|chain|fullchain|privkey)\.pem',rel): raise ValueError('foreign symlink: '+rel)
                target=os.readlink(p)
                if not re.fullmatch(r'../../archive/[a-z0-9.-]+/(cert|chain|fullchain|privkey)[1-9][0-9]*\.pem',target): raise ValueError('foreign symlink target')
                if target.split('/')[3]!=rel.split('/')[2] or not target.split('/')[-1].startswith(name[:-4]): raise ValueError('cross-lineage symlink')
                resolved=os.path.normpath(here+'/'+target)
                if not resolved.startswith(root+'/config/archive/'+rel.split('/')[2]+'/'): raise ValueError('symlink escape')
                rr,_=record(resolved,private=False)
                out[rel]={'id':ident(s),'target':target}
            elif stat.S_ISDIR(s.st_mode):
                if s.st_mode & 0o022: raise ValueError('writable directory: '+rel)
                out[rel]={'id':ident(s),'mode':stat.S_IMODE(s.st_mode)}
            elif stat.S_ISREG(s.st_mode):
                if s.st_nlink!=1 or (s.st_dev,s.st_ino) in inodes: raise ValueError('duplicate/hardlink file: '+rel)
                inodes.add((s.st_dev,s.st_ino))
                private=rel.startswith(('logs/','work/','config/accounts/')) or 'privkey' in rel or rel in ('runtime.sh','cli.ini')
                rr,_=record(p,private=private,native=native); out[rel]=rr
            else: raise ValueError('non-regular resource: '+rel)
    return out

def save(m):
    m['tree']=tree()
    mr,_=record(root+'/metadata.json'); sr,_=record(root+'/metadata.sha256')
    m['metadata_id']=mr['id']; m['seal_id']=sr['id']
    raw=(json.dumps(m,sort_keys=True,separators=(',',':'))+'\n').encode()
    replace(root+'/metadata.json',raw); replace(root+'/metadata.sha256',(hashlib.sha256(raw).hexdigest()+'\n').encode())

def verify(skip_tree=False):
    mr,raw=record(root+'/metadata.json'); sr,seal=record(root+'/metadata.sha256')
    if seal!=(mr['sha256']+'\n').encode(): raise ValueError('metadata seal mismatch')
    m=json.loads(raw)
    if set(m)!={'version','root_id','parents','metadata_id','seal_id','host','email','server','fixture','fixture_records','program','certbot_version','state','authorized','vmess','tree','units','link'} or m['version']!=1: raise ValueError('unknown metadata schema')
    fd=directory(root)
    try:
        s=os.fstat(fd)
        if m['root_id']!=ident(s) or stat.S_IMODE(s.st_mode)!=0o700: raise ValueError('root changed')
    finally: os.close(fd)
    if m['metadata_id']!=mr['id'] or m['seal_id']!=sr['id'] or m['parents']!=parent_ids(): raise ValueError('metadata/parent replaced')
    if m['fixture']!=fixture or m['server']!=(F['server'] if F else CA) or m['fixture_records']!=(F['_records'] if F else None): raise ValueError('CA/fixture/trust changed')
    if not re.fullmatch(r'([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}',m['host']) or len(m['host'])>253: raise ValueError('invalid host')
    if not isinstance(m['authorized'],bool) or not isinstance(m['vmess'],bool) or m['state'] not in ('pending','ready','renewing'): raise ValueError('invalid authorization/state')
    if not skip_tree and m['tree']!=tree(): raise ValueError('owned contents changed/unknown')
    expected=set(m['tree'])|{'metadata.json','metadata.sha256'}
    current=set()
    for h,ds,fs in os.walk(root,followlinks=False):
        current.update(os.path.relpath(h+'/'+n,root) for n in ds+fs if n!='.lock')
    if not skip_tree and current!=expected: raise ValueError('unknown/missing resource')
    if os.path.lexists(root+'/.lock'):
        fd=directory(root+'/.lock')
        try:
            if stat.S_IMODE(os.fstat(fd).st_mode)!=0o700 or os.listdir(fd): raise ValueError('untrusted lock')
        finally: os.close(fd)
    binary=m['program']['path']; rr,_=record(binary,private=False)
    if rr!=m['program']['record']: raise ValueError('Certbot executable changed; manual review required')
    if F and F['host']!=m['host']: raise ValueError('fixture hostname mismatch')
    return m

def renewal(m):
    h=m['host']; p=root+'/config/renewal/'+h+'.conf'
    _,b=record(p,private=False); cp=configparser.RawConfigParser(strict=True)
    # Certbot has five top-level entries before [renewalparams]. Treat as data.
    cp.read_string('[lineage]\n'+b.decode())
    top=cp['lineage']
    want={'archive_dir':root+'/config/archive/'+h,'cert':root+'/config/live/'+h+'/cert.pem','privkey':root+'/config/live/'+h+'/privkey.pem','chain':root+'/config/live/'+h+'/chain.pem','fullchain':root+'/config/live/'+h+'/fullchain.pem'}
    for k,v in want.items():
        if top.get(k)!=v: raise ValueError('foreign renewal path: '+k)
    rp=cp['renewalparams']
    if rp.get('authenticator')!='standalone' or rp.get('server')!=m['server'] or rp.get('installer','None') not in ('None','none',''): raise ValueError('foreign renewal plugin/server')
    for sec in cp.sections():
        for k,v in cp[sec].items():
            if 'hook' in k or k in ('webroot_path','webroot_map','config','https_port') or (k=='http01_port' and v!='80'): raise ValueError('arbitrary hook/port/config refused')
            if k in ('config_dir','work_dir','logs_dir') and v!=root+'/'+{'config_dir':'config','work_dir':'work','logs_dir':'logs'}[k]: raise ValueError('foreign Certbot directory')
            if k in ('reuse_key','allow_subset_of_names','no_verify_ssl') and v.lower()=='true': raise ValueError('unsafe renewal option')
    hooks=root+'/config/renewal-hooks'
    if os.path.isdir(hooks):
        for _,ds,fs in os.walk(hooks):
            if fs: raise ValueError('Certbot directory hooks forbidden')
    if set(os.listdir(root+'/config/renewal'))!={h+'.conf'}: raise ValueError('duplicate/foreign renewal lineage')
    if set(os.listdir(root+'/config/live'))!={h,'README'} and set(os.listdir(root+'/config/live'))!={h}: raise ValueError('duplicate live lineage')
    if set(os.listdir(root+'/config/archive'))!={h}: raise ValueError('duplicate archive lineage')
    live=root+'/config/live/'+h
    if set(os.listdir(live)) not in ({'cert.pem','chain.pem','fullchain.pem','privkey.pem'},{'cert.pem','chain.pem','fullchain.pem','privkey.pem','README'}): raise ValueError('unknown live files')
    gen=set()
    for name in ('cert','chain','fullchain','privkey'):
        p=live+'/'+name+'.pem'
        if not os.path.islink(p): raise ValueError('expected native Certbot symlink')
        t=os.readlink(p); match=re.fullmatch(r'../../archive/'+re.escape(h)+'/'+name+r'([1-9][0-9]*)\.pem',t)
        if not match: raise ValueError('foreign native chain')
        gen.add(match[1])
    if len(gen)!=1: raise ValueError('mixed native generations')
    generations={}
    for n in os.listdir(root+'/config/archive/'+h):
        match=re.fullmatch(r'(cert|chain|fullchain|privkey)([1-9][0-9]*)\.pem',n)
        if not match: raise ValueError('duplicate/foreign archive file')
        generations.setdefault(match[2],set()).add(match[1])
    if any(v!={'cert','chain','fullchain','privkey'} for v in generations.values()): raise ValueError('incomplete archive generation')

def certcheck(m):
    renewal(m); h=m['host']; live=root+'/config/live/'+h
    # openssl checks exact hostname, PKIX trust, notBefore/notAfter and key match.
    def cmd(a):
        r=subprocess.run(['openssl']+a,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
        if r.returncode: raise ValueError('certificate time/trust/hostname/keypair check failed')
        return r.stdout
    cert=os.path.realpath(live+'/cert.pem'); key=os.path.realpath(live+'/privkey.pem'); chain=os.path.realpath(live+'/chain.pem'); full=os.path.realpath(live+'/fullchain.pem')
    _,cb=record(cert,private=False); _,ch=record(chain,private=False); _,fb=record(full,private=False); record(key)
    if fb!=cb+ch: raise ValueError('fullchain is not exact cert+chain')
    if cb.count(b'-----BEGIN CERTIFICATE-----')!=1 or not ch.count(b'-----BEGIN CERTIFICATE-----'): raise ValueError('invalid leaf/intermediate chain')
    a=['verify','-purpose','sslserver','-verify_hostname',h]
    if F: a+=['-CAfile',F['cert_ca'],'-no-CApath','-no-CAstore']
    a+=['-untrusted',chain,cert]; cmd(a)
    cmd(['x509','-in',cert,'-checkend','3600','-noout'])
    pub=cmd(['x509','-in',cert,'-pubkey','-noout'])
    kp=cmd(['pkey','-in',key,'-passin','pass:','-pubout'])
    if pub!=kp: raise ValueError('certificate/private key mismatch')
    # DNS SAN must be exactly this lineage: no wildcard/other service names.
    san=cmd(['x509','-in',cert,'-noout','-ext','subjectAltName']).decode()
    names=re.findall(r'DNS:([^,\s]+)',san)
    if names!=[h] or 'IP Address:' in san: raise ValueError('SAN differs from owned hostname')
    return full,key

def unit_conflicts(m=None):
    paths={units,'/etc/systemd/system','/run/systemd/system','/usr/local/lib/systemd/system','/usr/lib/systemd/system','/lib/systemd/system'}
    expected=m['units'] if m else {}
    for u in paths:
        if not os.path.isdir(u): continue
        for n in (SVC,TIMER):
            p=u+'/'+n
            if os.path.lexists(p) and p not in expected: raise ValueError('foreign systemd unit')
        for n in (SVC+'.d',TIMER+'.d','service.d','timer.d','terry-.service.d','terry-toolbox-.service.d','terry-.timer.d','terry-toolbox-.timer.d'):
            if os.path.lexists(u+'/'+n): raise ValueError('systemd drop-in conflict')
        for ent in os.scandir(u):
            if ent.name.endswith(('.wants','.requires')) and ent.is_dir(follow_symlinks=False):
                for n in (SVC,TIMER):
                    p=ent.path+'/'+n
                    if os.path.lexists(p) and (not m or p!=units+'/timers.target.wants/'+TIMER or m['link'] is None): raise ValueError('foreign systemd dependency link')
    for p,r in expected.items():
        rr,_=record(p,private=False)
        if rr!=r: raise ValueError('unit content/inode changed')
    if m and m['link'] is not None:
        p=units+'/timers.target.wants/'+TIMER; s=os.lstat(p)
        if not stat.S_ISLNK(s.st_mode) or s.st_uid!=0 or ident(s)!=m['link']['id'] or os.readlink(p)!=units+'/'+TIMER: raise ValueError('timer link changed')
        fd=directory(os.path.dirname(p))
        try:
            if ident(os.fstat(fd))!=m['link']['parent']: raise ValueError('timer wants parent changed')
        finally: os.close(fd)

try:
    if op=='platform':
        for p in args:
            path(p)
        if not (F and F['mock_systemd']):
            if open('/proc/1/comm').read().strip()!='systemd': raise ValueError('PID1 is not systemd')
    elif op=='program':
        p=args[0]; rr,_=record(p,private=False)
        if not os.access(p,os.X_OK): raise ValueError('Certbot is not executable')
    elif op=='preflight':
        parent_ids()
        if os.path.lexists(root): raise ValueError('root exists; never adopt foreign/partial state')
        unit_conflicts()
    elif op=='fixture':
        if F:
            from urllib.parse import urlsplit
            u=urlsplit(F['server'])
            addresses={a[4][0] for a in socket.getaddrinfo(u.hostname,u.port,type=socket.SOCK_STREAM)}
            if not addresses or any(not ipaddress.ip_address(a).is_loopback for a in addresses): raise ValueError('test CA hostname must resolve ONLY to loopback')
        print(F['server'] if F else CA); print(F['requests_ca'] if F else ''); print(F['cert_ca'] if F else '')
    elif op=='dns':
        h=args[0]
        if F:
            if h!=F['host']: raise ValueError('fixture hostname mismatch')
            addresses=F['addresses']
        else:
            addresses=sorted({a[4][0] for a in socket.getaddrinfo(h,80,type=socket.SOCK_STREAM)})
            if not addresses or any(not ipaddress.ip_address(a).is_global for a in addresses): raise ValueError('hostname must resolve to public A/AAAA; DNS control not proven')
        if not addresses: raise ValueError('no A/AAAA')
        print('当前 A/AAAA: '+', '.join(addresses)+'（不证明域名控制权/公网可达性）')
    elif op=='init':
        h,email,binary,version=args; parent_ids(); unit_conflicts()
        fd,n=parent(root)
        try: os.mkdir(n,0o700,dir_fd=fd)
        finally: os.close(fd)
        for n in ('config','work','logs'): os.mkdir(root+'/'+n,0o700)
        create(root+'/metadata.json',b''); create(root+'/metadata.sha256',b'')
        create(root+'/cli.ini',b'# Exclusive empty Certbot configuration; no inherited hooks.\n')
        fd=directory(root)
        try: rid=ident(os.fstat(fd))
        finally: os.close(fd)
        rr,_=record(binary,private=False)
        m={'version':1,'root_id':rid,'parents':parent_ids(),'metadata_id':'','seal_id':'','host':h,'email':email,'server':F['server'] if F else CA,'fixture':fixture,'fixture_records':F['_records'] if F else None,'program':{'path':binary,'record':rr},'certbot_version':version,'state':'pending','authorized':False,'vmess':False,'tree':{},'units':{},'link':None}
        if F and h!=F['host']: raise ValueError('fixture mismatch')
        save(m)
    elif op=='binding':
        m=verify()
        if m['program']['path']!=args[0] or m['certbot_version']!=args[1]: raise ValueError('Certbot path/version differs from sealed source')
    elif op=='verify':
        m=verify()
        if args and args[0] and args[0]!=m['host']: raise ValueError('hostname differs from owned metadata')
        unit_conflicts(m)
        print(m['host']); print(m['email']); print(m['state']); print('yes' if m['authorized'] else 'no'); print('yes' if m['vmess'] else 'no')
    elif op=='lock':
        verify(); fd=directory(root)
        try:
            os.mkdir('.lock',0o700,dir_fd=fd); print(ident(os.stat('.lock',dir_fd=fd,follow_symlinks=False)))
        finally: os.close(fd)
    elif op=='unlock':
        fd=directory(root)
        try:
            if ident(os.stat('.lock',dir_fd=fd,follow_symlinks=False))!=args[0]: raise ValueError('lock changed; retained')
            os.rmdir('.lock',dir_fd=fd)
        finally: os.close(fd)
    elif op=='log':
        verify(); p=root+'/logs/action-'+str(time.time_ns())+'.log'; create(p,b''); m=verify(True); save(m); print(p)
    elif op=='runtime':
        m=verify(); data=sys.stdin.buffer.read() # Shell heredoc is Python code; runtime bytes supplied via argument instead.
        data=args[0].encode()
        create(root+'/runtime.sh',data); save(m)
    elif op=='begin':
        m=verify()
        if args[0]=='renew':
            if m['state']!='ready': raise ValueError('not ready; retain failed attempt for manual review')
            renewal(m)
        m['state']='renewing' if args[0]=='renew' else 'pending'; save(m)
    elif op=='finish':
        # Only under the exclusive caller lock, after successful Certbot. Existing
        # immutable ownership records must still match; only native config/work/log
        # contents may rotate. Failed writes leave old seal and thus fail closed.
        m=verify(True)
        before=m['tree']; after=tree()
        for n,r in before.items():
            if not n.startswith(('config/','work/','logs/')) and after.get(n)!=r: raise ValueError('immutable resource changed during Certbot')
            if n.startswith('config/archive/') and after.get(n)!=r: raise ValueError('old archive generation changed')
        certcheck(m); m['state']='ready'; save(m)
    elif op=='cert':
        m=verify()
        if m['state']!='ready': raise ValueError('certificate operation incomplete')
        for p in certcheck(m): print(p)
    elif op=='authorize':
        m=verify(); unit_conflicts(m)
        if m['state']!='ready': raise ValueError('not ready')
        certcheck(m)
        if not m['units']:
            service=('[Unit]\nDescription=Terry Toolbox controlled Certbot renewal\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash '+root+'/runtime.sh _renew '+m['host']+'\nTimeoutStartSec=600\n').encode()
            timer=('[Unit]\nDescription=Terry Toolbox authorized ACME timer\n[Timer]\nOnCalendar=*-*-* 03,15:00:00\nRandomizedDelaySec=1800\nPersistent=true\nUnit='+SVC+'\n').encode()
            # Intentionally no [Install]. Only the exact owned wants link is made.
            for n,b in ((SVC,service),(TIMER,timer)): create(units+'/'+n,b,0o644); m['units'][units+'/'+n]=record(units+'/'+n,private=False)[0]
            save(m)
        want=units+'/timers.target.wants'
        if not os.path.lexists(want): os.mkdir(want,0o755)
        fd=directory(want)
        try:
            if m['link'] is None:
                os.symlink(units+'/'+TIMER,TIMER,dir_fd=fd)
                m['link']={'id':ident(os.stat(TIMER,dir_fd=fd,follow_symlinks=False)),'parent':ident(os.fstat(fd))}
        finally: os.close(fd)
        m['authorized']=True; save(m); unit_conflicts(m)
    elif op=='unauthorize':
        m=verify(); unit_conflicts(m)
        m['authorized']=False; save(m) # revoke before stopping queued work
    elif op=='unlink':
        m=verify(); unit_conflicts(m)
        if m['authorized']: raise ValueError('authorization not revoked')
        if m['link'] is not None:
            fd=directory(units+'/timers.target.wants')
            try:
                if ident(os.stat(TIMER,dir_fd=fd,follow_symlinks=False))!=m['link']['id']: raise ValueError('timer link raced')
                os.unlink(TIMER,dir_fd=fd)
            finally: os.close(fd)
            m['link']=None; save(m)
    elif op=='hook-install':
        m=verify(); vm,net,hook=args
        for n,data in (('vmess-source.sh',vm),('network-source.sh',net)):
            create(root+'/'+n,data.encode())
        create(root+'/vmess-hook.sh',hook.encode()); save(m)
    elif op=='hook':
        m=verify()
        if not m['vmess']: raise ValueError('VMess renewal deployment not authorized')
        for n in ('vmess-source.sh','network-source.sh','vmess-hook.sh'): record(root+'/'+n)
        if not args or args[0] not in ('ready','renewing'): raise ValueError('invalid hook state')
        if m['state']!=args[0]: raise ValueError('hook state mismatch')
    elif op=='vmess':
        m=verify()
        for n in ('vmess-source.sh','network-source.sh','vmess-hook.sh'): record(root+'/'+n)
        m['vmess']=True; save(m)
    elif op=='status':
        if not os.path.lexists(root): print('TLS ACME: 未申请（不创建目录/不联网/不启动服务）。')
        else:
            m=verify(); unit_conflicts(m)
            if args and args[0] and args[0]!=m['host']: raise ValueError('hostname mismatch')
            print('TLS ACME: '+m['host']+' / '+m['state'])
            print('Certbot: '+m['certbot_version']+'; existing executable '+m['program']['path'])
            print('Executable SHA-256: '+m['program']['record']['sha256'])
            print('CA: '+m['server']+(' [ISOLATED TEST ONLY]' if F else ''))
            print('自动续期授权: '+str(m['authorized'])+'; VMess 自动同步授权: '+str(m['vmess']))
            print('私有数据/日志: '+root+'; 不使用 /etc/letsencrypt')
            if m['state']=='ready': certcheck(m); print('证书链/hostname/time/keypair: OK')
    else: raise ValueError('unknown filesystem operation')
except Exception as e:
    print('TLS ACME 拒绝: '+str(e),file=sys.stderr); sys.exit(1)
PY
}
tls_acme_port() {
    local out
    out=$(ss -ltnH 2>/dev/null) || { tls_acme_err 'ss 读取失败；端口 80 状态未知，拒绝。'; return 1; }
    python3 - "$out" <<'PY'
import sys
for line in sys.argv[1].splitlines():
    a=line.split()
    if len(a)<5 or a[0]!='LISTEN' or ':' not in a[3]:
        print('ss 输出格式未知，拒绝。',file=sys.stderr); sys.exit(1)
    p=a[3].rsplit(':',1)[1]
    if not p.isdigit(): sys.exit(1)
    if p=='80':
        print('TCP 80 已有 listener；不停止别人的服务。',file=sys.stderr); sys.exit(1)
PY
}
tls_acme_info() {
    local out
    out=$(tls_acme_fs verify "${1:-}") || return 1
    mapfile -t tls_acme_meta <<< "$out"
    [[ ${#tls_acme_meta[@]} == 5 ]] || return 1
    tls_acme_host=${tls_acme_meta[0]}; tls_acme_email=${tls_acme_meta[1]}
}
tls_acme_cleanup() {
    local rc=$?
    if [[ -n ${tls_acme_lock_id:-} ]]; then
        tls_acme_fs unlock "$tls_acme_lock_id" || rc=1
    fi
    return "$rc"
}
tls_acme_runtime() {
    local text f
    local -a funcs=()
    # Freeze only this adapter's functions. VMess integration is loaded from the
    # verified source package snapshot when automatic sync is explicitly authorized.
    while IFS= read -r f; do case $f in tls_acme_*|toolbox_tls_acme) funcs+=("$f");; esac; done < <(compgen -A function)
    text=$(declare -f "${funcs[@]}") || return 1
    text=$'#!/bin/bash\nset -u\n'"$text"$'\nTOOLBOX_TLS_ACME_ROOT='"$(tls_acme_root)"$'\nTOOLBOX_TLS_ACME_UNIT_DIR='"$(tls_acme_units)"$'\nTOOLBOX_TLS_ACME_TEST_FIXTURE='"${TOOLBOX_TLS_ACME_TEST_FIXTURE:-}"$'\nTOOLBOX_TLS_ACME_OS_RELEASE='"${TOOLBOX_TLS_ACME_OS_RELEASE:-/etc/os-release}"$'\nTOOLBOX_TLS_ACME_SYSTEMD_RUN='"${TOOLBOX_TLS_ACME_SYSTEMD_RUN:-/run/systemd/system}"$'\nif [[ ${BASH_SOURCE[0]} == "$0" ]]; then toolbox_tls_acme "$@"; fi\n'
    tls_acme_fs runtime "$text"
}
tls_acme_call() {
    local mode=$1 root log out server bundle
    tls_acme_fs binding "$tls_acme_binary" "$tls_acme_version" && tls_acme_port || return 1
    root=$(tls_acme_root) || return 1
    out=$(tls_acme_fs fixture) || return 1
    mapfile -t tls_acme_ca <<< "$out"
    server=${tls_acme_ca[0]}; bundle=${tls_acme_ca[1]:-}
    log=$(tls_acme_fs log) || return 1
    tls_acme_fs begin "$mode" || return 1
    tls_acme_err "Certbot 私有日志：$log（失败保留，不输出账户/私钥）。"
    local -a argv=(--config "$root/cli.ini" --config-dir "$root/config" --work-dir "$root/work" --logs-dir "$root/logs" --server "$server" --non-interactive --no-directory-hooks --standalone --preferred-challenges http --http-01-port 80 --cert-name "$tls_acme_host")
    if [[ $mode == issue ]]; then
        argv=(certonly "${argv[@]}" --agree-tos --email "$tls_acme_email" -d "$tls_acme_host")
    else
        argv=(renew "${argv[@]}" --no-random-sleep-on-renew)
        if [[ ${TOOLBOX_TLS_ACME_TEST_FORCE_RENEWAL:-0} == 1 ]]; then
            [[ -n ${TOOLBOX_TLS_ACME_TEST_FIXTURE:-} ]] && tls_acme_fs binding "$tls_acme_binary" "$tls_acme_version" || { tls_acme_err 'force renewal 只允许 sealed fixture。'; return 1; }
            argv+=(--force-renewal)
        fi
    fi
    # No --no-verify-ssl/insecure fallback. Neutralize inherited proxies/config CA.
    if [[ -n $bundle ]]; then
        ( umask 077; unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy CURL_CA_BUNDLE; export REQUESTS_CA_BUNDLE="$bundle"; timeout 540 "$tls_acme_binary" "${argv[@]}" ) >"$log" 2>&1 || { tls_acme_err 'Certbot 失败/超时；保留私有现场，未宣称申请成功。'; return 1; }
    else
        ( umask 077; unset REQUESTS_CA_BUNDLE CURL_CA_BUNDLE HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; timeout 540 "$tls_acme_binary" "${argv[@]}" ) >"$log" 2>&1 || { tls_acme_err 'Certbot 失败/超时；保留私有现场，未宣称申请成功。'; return 1; }
    fi
    tls_acme_fs finish || { tls_acme_err 'Certbot 返回成功但证书/ownership 验证失败；保留现场。'; return 1; }
    tls_acme_fs cert >/dev/null || return 1
}
tls_acme_issue() (
    local tls_acme_lock_id='' tls_acme_version='' tls_acme_binary='' tls_acme_host=${1:-} tls_acme_email=${2:-}
    [[ $# -le 2 ]] || return 2
    tls_acme_require || return 1
    if [[ -z $tls_acme_host ]]; then printf '域名（无通配符）：'; IFS= read -r tls_acme_host || return 1; fi
    if [[ -z $tls_acme_email ]]; then printf 'ACME 邮箱：'; IFS= read -r tls_acme_email || return 1; fi
    tls_acme_valid "$tls_acme_host" "$tls_acme_email" || { tls_acme_err 'hostname/email 格式不安全。'; return 1; }
    tls_acme_fs preflight || return 1
    tls_acme_fs dns "$tls_acme_host" || return 1
    tls_acme_port || return 1
    tls_acme_err "预览：现有 $tls_acme_version（不自动安装）；生产 CA https://acme-v02.api.letsencrypt.org/directory；同意 CA ToS https://letsencrypt.org/repository/。"
    tls_acme_err "仅 standalone HTTP-01 TCP 80；A/AAAA 必须指向可公网访问本机，包含 IPv6；本检查不证明 DNS 控制/公网可达。不会改 DNS/firewall/反代或停止其他服务。"
    tls_acme_err "创建独占私有 $(tls_acme_root)/{config,work,logs}；private key 位于 config/live/$tls_acme_host/privkey.pem；不采用 /etc/letsencrypt；不自动开启 timer/部署服务。"
    tls_acme_fs fixture || return 1
    tls_acme_confirm || return 1
    tls_acme_fs preflight && tls_acme_fs dns "$tls_acme_host" && tls_acme_port || return 1
    tls_acme_fs init "$tls_acme_host" "$tls_acme_email" "$tls_acme_binary" "$tls_acme_version" || return 1
    tls_acme_lock_id=$(tls_acme_fs lock) || return 1
    trap tls_acme_cleanup EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM HUP
    tls_acme_runtime || return 1
    tls_acme_call issue || return 1
    tls_acme_err 'Certbot 申请成功且本地 trust/time/hostname/keypair 与自有 native lineage 已验证。自动续期尚未授权。'
)
tls_acme_renew() (
    local background=$1 host=${2:-} tls_acme_lock_id='' tls_acme_version='' tls_acme_binary='' tls_acme_host='' tls_acme_email=''
    tls_acme_require && tls_acme_info "$host" || return 1
    [[ ${tls_acme_meta[2]} == ready ]] || { tls_acme_err '上次操作未完成，需检查私有日志；拒绝自动重试。'; return 1; }
    tls_acme_fs cert >/dev/null || return 1
    if [[ ${TOOLBOX_TLS_ACME_TEST_FORCE_RENEWAL:-0} == 1 && -z ${TOOLBOX_TLS_ACME_TEST_FIXTURE:-} ]]; then
        tls_acme_err 'force renewal 只允许 sealed fixture。'; return 1
    fi
    if [[ $background == yes ]]; then
        [[ ${tls_acme_meta[3]} == yes ]] || { tls_acme_err '未授权后台续期。'; return 1; }
        tls_acme_timer_read background || return 1
    else
        tls_acme_fs dns "$tls_acme_host" && tls_acme_port || return 1
        tls_acme_err '预览：仅更新 owned Certbot lineage；不停止其他服务/不改 firewall/DNS；若已授权 VMess，同步走 update-cert API。'
        tls_acme_confirm || return 1
    fi
    tls_acme_lock_id=$(tls_acme_fs lock) || return 1
    trap tls_acme_cleanup EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM HUP
    tls_acme_info "$host" || return 1
    [[ $background != yes || ${tls_acme_meta[3]} == yes ]] || return 1
    tls_acme_fs dns "$tls_acme_host" && tls_acme_port || return 1
    tls_acme_call renew || return 1
    if [[ ${tls_acme_meta[4]} == yes ]]; then tls_acme_deploy_internal authorized || return 1; fi
    tls_acme_err 'Certbot renew 成功，本地证书与归属 readback OK（未到期时 Certbot 可不 rotation）。'
)
# Exact systemd snapshots. Unknown states/jobs/drop-ins never mean success.
tls_acme_timer_read() {
    local expected=$1 n out line k v active load sub fragment drops job pid
    for n in terry-toolbox-acme.timer terry-toolbox-acme.service; do
        out=$(systemctl show "$n" -p LoadState -p ActiveState -p SubState -p FragmentPath -p DropInPaths -p Job -p MainPID 2>/dev/null) || return 1
        active='' load='' sub='' fragment='' drops='' job='' pid=''; local -A seen=()
        while IFS= read -r line; do
            k=${line%%=*}; v=${line#*=}; [[ $line == *=* && -z ${seen[$k]:-} ]] || return 1; seen[$k]=1
            case $k in LoadState) load=$v;; ActiveState) active=$v;; SubState) sub=$v;; FragmentPath) fragment=$v;; DropInPaths) drops=$v;; Job) job=$v;; MainPID) pid=$v;; *) return 1;; esac
        done <<< "$out"
        # systemd omits MainPID entirely for a never-loaded (not-found) unit;
        # loaded units always report it. Only that exact shape may lack it.
        # systemd omits MainPID for timer units and never-loaded units; a loaded
        # service always reports it. Only those two shapes may lack it.
        [[ ${#seen[@]} == 7 && $pid =~ ^[0-9]+$ || ${#seen[@]} == 6 && -z $pid && ( $load == not-found || $n == *.timer ) ]] || return 1
        if [[ $expected == background && $n == *.service && $active == activating && $sub == start ]]; then
            [[ $pid == "$$" ]] || { tls_acme_err '续期服务 MainPID 不属于本 owned runtime；拒绝。'; return 1; }
            [[ -z $job || $job =~ ^[1-9][0-9]*(\ /org/freedesktop/systemd1/job/[1-9][0-9]*)?$ ]] || return 1
        else
            [[ -z $job && ( $pid == 0 || -z $pid ) ]] || return 1
        fi
        if [[ $expected == absent ]]; then
            [[ $load == not-found && $active == inactive && $sub == dead && -z $fragment ]] || return 1
        else
            [[ $load == loaded && $fragment == "$(tls_acme_units)/$n" ]] || return 1
            if [[ $n == *.timer && ( $expected == active || $expected == background ) ]]; then
                [[ $active == active && $sub == waiting ]] || return 1
            elif [[ $n == *.service && $expected == background ]]; then
                [[ ( $active == activating && $sub == start ) || ( $active == inactive && $sub == dead ) ]] || return 1
            else
                [[ $active == inactive && $sub == dead ]] || return 1
            fi
        fi
    done
}
tls_acme_timer() (
    local action=$1 host=${2:-} tls_acme_lock_id='' tls_acme_version='' tls_acme_binary='' tls_acme_host='' tls_acme_email=''
    tls_acme_require && tls_acme_info "$host" || return 1
    [[ ${tls_acme_meta[2]} == ready ]] || return 1
    tls_acme_fs cert >/dev/null || return 1
    if [[ $action == enable-renewal ]]; then
        if [[ ${tls_acme_meta[3]} == yes ]]; then tls_acme_timer_read active && tls_acme_err '自动续期已授权且 timer readback OK。'; return; fi
        # No units on first enable; retained owned units after disable are supported.
        if [[ -e $(tls_acme_units)/terry-toolbox-acme.timer ]]; then tls_acme_timer_read inactive || return 1; else tls_acme_timer_read absent || return 1; fi
        tls_acme_err '预览：预授权每天 03/15 点 + 随机延迟自动 standalone HTTP-01；80 忙即失败，不停其他服务；只 owned unit/runtime/link。VMess 仅另行 deploy-vmess 授权后同步。'
    else
        tls_acme_timer_read active || { tls_acme_err 'timer/service 未处于明确受控静止/等待状态；保留。'; return 1; }
        tls_acme_err '预览：撤销自动续期授权；仅停止 owned timer，并移除精确 owned wants link；保留证书/日志/unit。'
    fi
    tls_acme_confirm || return 1
    tls_acme_lock_id=$(tls_acme_fs lock) || return 1
    trap tls_acme_cleanup EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM HUP
    tls_acme_info "$host" || return 1
    if [[ $action == enable-renewal ]]; then
        tls_acme_fs authorize || return 1
        systemctl daemon-reload && systemctl start terry-toolbox-acme.timer || { tls_acme_err '开启失败；保留 owned unit/link/授权现场，不宣称成功。'; return 1; }
        tls_acme_info "$host" && tls_acme_timer_read active || { tls_acme_err 'timer readback 失败，保留现场。'; return 1; }
    else
        tls_acme_timer_read active && tls_acme_fs unauthorize || return 1
        systemctl stop terry-toolbox-acme.timer || { tls_acme_err '停止失败；保留 link/unit（授权已撤销）。'; return 1; }
        tls_acme_timer_read inactive || { tls_acme_err '停止 readback 未确认；保留 link/unit。'; return 1; }
        tls_acme_fs unlink && systemctl daemon-reload && tls_acme_info "$host" && tls_acme_timer_read inactive || return 1
    fi
    tls_acme_err "$action: owned resources + systemd readback OK。"
)
tls_acme_deploy_internal() (
    local mode=$1 root info out
    root=$(tls_acme_root) || return 1
    if [[ $mode == authorized ]]; then
        tls_acme_fs hook ready || return 1
        # Fixed ownedhook, not a Certbot shell hook or external path. Check source
        # and old manifest again inside the isolated child before any service write.
        /bin/bash "$root/vmess-hook.sh" || return 1
    else
        declare -F toolbox_vmess >/dev/null && declare -F vmess_fs >/dev/null || { tls_acme_err 'VMess update-cert ownership API 尚未加载；不直接覆盖 cert/key/manifest。'; return 1; }
        info=$(vmess_fs verify --complete) || { tls_acme_err 'VMess 旧 manifest 验证失败。'; return 1; }
        local host _port _ws _listen hasunit cert key
        read -r host _port _ws _listen hasunit <<< "$info"
        [[ $host == "$tls_acme_host" && $hasunit == 1 ]] || { tls_acme_err 'VMess hostname/完整归属不匹配。'; return 1; }
        out=$(tls_acme_fs cert) || return 1
        mapfile -t tls_acme_cert <<< "$out"; cert=${tls_acme_cert[0]}; key=${tls_acme_cert[1]}
        toolbox_vmess update-cert "$cert" "$key" || return 1
        vmess_fs verify --complete >/dev/null || return 1
    fi
)
tls_acme_hook_install() {
    local hook line name value root vmess_source network_source f
    local -a vmess_functions=() network_functions=()
    root=$(tls_acme_root) || return 1
    # Freeze loaded functions from the actual source package/bundle; source path
    # does not exist for bash -s and is not needed. Names are allowlisted, values
    # are quoted shell data. Source SHA-256 is sealed in the owned tree.
    while IFS= read -r f; do
        case $f in
            vmess_*|toolbox_vmess) vmess_functions+=("$f");;
            net_err|net_die|net_check_cert|net_tls_verify|net_tls_trusted|net_a5_sha256|net_a5_zip_url|net_alpine_xray_sha256|net_xray_asset_arch) network_functions+=("$f");;
        esac
    done < <(compgen -A function)
    [[ ${#vmess_functions[@]} -gt 1 && ${#network_functions[@]} -gt 3 ]] || { tls_acme_err '缺少已加载 VMess/network source functions。'; return 1; }
    vmess_source=$(declare -f "${vmess_functions[@]}") || return 1
    network_source=$(declare -f "${network_functions[@]}") || return 1
    while IFS= read -r name; do
        case $name in NET_*|TOOLBOX_A5_SHA256|TOOLBOX_A5_SHA256_ARM64)
            # Preserve scalar constants referenced by shared functions; no arrays
            # and no export/readonly flags which might interfere with re-sourcing.
            value=${!name}; printf -v line '%s=%q\n' "$name" "$value"; network_source="$line$network_source";;
        esac
    done < <(compgen -A variable)
    hook=$'#!/bin/bash\nset -u\numask 077\n'
    printf -v line 'source %q\n' "$root/runtime.sh"; hook+="$line"
    hook+=$'tls_acme_fs hook ready || exit 1\ntls_acme_info || exit 1\n'
    # Allowlisted configuration is shell-quoted, never a command/hook argument.
    for name in TOOLBOX_VM_WS_ETC TOOLBOX_VM_WS_BIN_DIR TOOLBOX_VM_WS_UNIT_DIR TOOLBOX_VM_WS_LOCK TOOLBOX_VM_WS_OS_RELEASE TOOLBOX_VM_WS_SYSTEMD_RUN TOOLBOX_VM_WS_LISTEN TOOLBOX_NET_CAFILE TOOLBOX_NET_CAPATH TMPDIR; do
        if [[ ${!name+x} ]]; then value=${!name}; printf -v line '%s=%q\nexport %s\n' "$name" "$value" "$name"; hook+="$line"; fi
    done
    printf -v line 'source %q || exit 1\nsource %q || exit 1\n' "$root/network-source.sh" "$root/vmess-source.sh"; hook+="$line"
    hook+=$'info=$(vmess_fs verify --complete) || exit 1\nread -r host _port _ws _listen hasunit <<< "$info"\n[[ $host == "$tls_acme_host" && $hasunit == 1 ]] || exit 1\n'
    hook+=$'out=$(tls_acme_fs cert) || exit 1\nmapfile -t pair <<< "$out"\n'
    # VMess keeps its transaction and public API, including manifest/service/TLS
    # checks. Its consent callback is substituted ONLY in this fixed ownedhook
    # child after the TLS module's dual YES and sealed authorization readback.
    hook+=$'vmess_confirm() { tls_acme_fs hook ready; }\ntoolbox_vmess update-cert "${pair[0]}" "${pair[1]}" || exit 1\nvmess_fs verify --complete >/dev/null || exit 1\n'
    tls_acme_fs hook-install "$vmess_source" "$network_source" "$hook"
}
tls_acme_deploy() (
    local host=${1:-} tls_acme_lock_id='' tls_acme_version='' tls_acme_binary='' tls_acme_host='' tls_acme_email='' info vmhost _port _ws _listen hasunit
    tls_acme_require && tls_acme_info "$host" || return 1
    tls_acme_fs cert >/dev/null || return 1
    declare -F toolbox_vmess >/dev/null && declare -F vmess_fs >/dev/null || { tls_acme_err '缺少 VMess ownership update-cert API。'; return 1; }
    info=$(vmess_fs verify --complete) || return 1
    read -r vmhost _port _ws _listen hasunit <<< "$info"
    [[ $vmhost == "$tls_acme_host" && $hasunit == 1 ]] || { tls_acme_err 'VMess hostname/旧完整 manifest 不匹配。'; return 1; }
    tls_acme_err '预览：预授权现在及后续成功续期调用 VMess update-cert（短暂停服，旧 manifest/hostname/链/time/keypair/TLS+WS readback）；保存 source package snapshot 与固定 ownedhook；不传任意 shell hook，不直接覆盖 cert/key。'
    tls_acme_err 'A1/A3/A4 没有同等 certpair+sealed manifest+service rollback API，因此明确不自动部署。启用此授权不自动启用 timer；disable-renewal 撤销后台续期但保留此 VMess 同步策略。'
    tls_acme_confirm || return 1
    tls_acme_lock_id=$(tls_acme_fs lock) || return 1
    trap tls_acme_cleanup EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM HUP
    tls_acme_info "$host" || return 1
    if [[ ${tls_acme_meta[4]} != yes ]]; then
        tls_acme_hook_install && tls_acme_fs vmess || return 1
    fi
    tls_acme_deploy_internal authorized || { tls_acme_err 'VMess deployment 失败；保留授权/source/日志，VMess API 自行保守回滚。'; return 1; }
    tls_acme_info "$host" && tls_acme_fs hook ready || return 1
    tls_acme_err 'VMess 证书 update-cert API 完成；ownedhook/manifest readback OK，后续成功续期已预授权同步。'
)
toolbox_tls_acme() {
    local action=${1:-status}; if (( $# )); then shift; fi
    case $action in
        issue) tls_acme_issue "$@";;
        status) [[ $# -le 1 ]] || return 2; command -v python3 >/dev/null || { tls_acme_err '缺少必需命令：python3'; return 1; }; tls_acme_fs status "${1:-}";;
        renew) [[ $# -le 1 ]] || return 2; tls_acme_renew no "${1:-}";;
        _renew) [[ $# == 1 ]] || return 2; tls_acme_renew yes "$1";;
        enable-renewal|disable-renewal) [[ $# -le 1 ]] || return 2; tls_acme_timer "$action" "${1:-}";;
        deploy-vmess) [[ $# -le 1 ]] || return 2; tls_acme_deploy "${1:-}";;
        *) tls_acme_err '用法: toolbox_tls_acme issue [hostname] [email] | status [hostname] | renew [hostname] | enable-renewal [hostname] | disable-renewal [hostname] | deploy-vmess [hostname]'; return 2;;
    esac
}
