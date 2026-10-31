#!/usr/bin/env bash
# Isolated B19 contract + failure tests. All privileged tools are DENY shims;
# swapon/swapoff/mkswap/OpenRC are fixture simulations, NEVER real kernel calls.
# Real dd writes only an already-open fixture fd. No namespaces pretend to isolate
# swap. Evidence is retained; fixture data is removed after each individual case.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scratch-root.sh"
toolbox_test_scratch
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export ALPINE_SWAP_TEST_REPO=$ROOT
python3 - <<'PY'
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

repo = Path(os.environ['ALPINE_SWAP_TEST_REPO'])
module = repo/'modules/alpine-swap.sh'
work = Path(tempfile.mkdtemp(prefix='alpine-swap-test.', dir=os.environ.get('TMPDIR','/root/.cache/terry-toolbox-tests')))
os.chmod(work, 0o700)
print('EVIDENCE='+str(work), flush=True)
results = work/'results.log'
if not module.is_file():
    results.write_text('interface exit=1\n')
    print('FAIL interface: toolbox_alpine_swap missing')
    sys.exit(1)
python = shutil.which('python3')
bash = shutil.which('bash')
real_dd = shutil.which('dd')
real_flock = shutil.which('flock')
real_cat = shutil.which('cat')
assert os.geteuid() == 0, 'root-owned path fixtures require root'

shim = r'''#!PYTHON
import os, pathlib, subprocess, sys, struct, signal, uuid
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
f = pathlib.Path(os.environ['FIXTURE'])
mode = os.environ.get('MODE','')
root = f/'data'/'terry-toolbox-alpine-swap'
swap = root/'swapfile'
service = f/'init.d'/'terry-toolbox-alpine-swap'
table = f/'swaps'
header = 'Filename\tType\tSize\tUsed\tPriority\n'
def denied():
    with (f/'DENIED').open('a') as log: log.write(name+' '+repr(args)+'\n')
    sys.exit(99)
def active():
    size=(swap.stat().st_size-os.sysconf('SC_PAGE_SIZE'))//1024
    if mode=='wrong-size': size+=os.sysconf('SC_PAGE_SIZE')//1024  # impossible: exceeds file minus header
    if mode=='ext4-capacity': size=131048  # real 128 MiB ext4/KVM sample, five extent alignment losses
    if mode=='reduced-capacity': size-=os.sysconf('SC_PAGE_SIZE')//1024
    table.write_text(header+str(swap)+' file '+str(size)+' 0 -2\n')
with (f/'calls').open('a') as log: log.write(name+' '+repr(args)+'\n')
if name == 'dd':
    dest = os.readlink('/proc/self/fd/1')
    if dest != str(swap) or not args[0:2] == ['if=/dev/zero','bs=1048576']: denied()
    if mode == 'dd-fail': os.write(1,b'partial'); sys.exit(1)
    if mode == 'dd-signal': os.kill(os.getppid(),signal.SIGTERM); sys.exit(1)
    if mode == 'claim-replace':
        swap.rename(root/'foreign-original')
        swap.write_bytes(b'foreign')
        sys.exit(1)
    p = subprocess.run([REAL_DD,*args],stdout=1,stderr=subprocess.DEVNULL)
    sys.exit(p.returncode)
elif name == 'mkswap':
    if args != [str(swap)]: denied()
    if mode == 'mkswap-fail': sys.exit(1)
    page=os.sysconf('SC_PAGE_SIZE'); data=bytearray(page)
    data[1024:1036]=struct.pack('=III',1,swap.stat().st_size//page-1,0)
    data[1036:1052]=uuid.uuid4().bytes; data[-10:]=b'SWAPSPACE2'
    with swap.open('r+b') as out: out.write(data)
    sys.exit(0)
elif name in ('swapon','swapoff'):
    if args != [str(swap)] or not swap.is_file() or not str(swap).startswith(str(f)+'/'): denied()
    if name == 'swapon':
        if mode == 'swapon-fail': sys.exit(1)
        active()
    else:
        if mode == 'swapoff-fail': sys.exit(1)
        if mode != 'kernel-remains': table.write_text(header)
    sys.exit(0)
elif name == 'rc-service':
    if args == ['-e','terry-toolbox-alpine-swap']:
        sys.exit(0 if service.exists() else 1)
    if args == ['-r','terry-toolbox-alpine-swap']:
        print('/foreign/service' if mode=='resolve-changed' else str(service))
        sys.exit(0 if service.exists() else 1)
    if len(args)!=3 or args[:2]!=['-D','terry-toolbox-alpine-swap']: denied()
    action=args[2]
    if action == 'status':
        status=(f/'status').read_text().strip() if (f/'status').exists() else 'stopped'
        if mode.startswith('status-'): status=mode[7:]
        if mode == 'stopped-lie' and (f/'did-stop').exists(): status='started'
        if mode.startswith('poststop-') and (f/'did-stop').exists(): status=mode[9:]
        print(' * status: '+status)
        sys.exit({'started':0,'stopped':3,'starting':8,'stopping':4,'inactive':16,'crashed':32}.get(status,1))
    if action not in ('start','stop'): denied()
    if action == 'start' and mode == 'start-fail': sys.exit(1)
    if action == 'stop':
        (f/'did-stop').touch()
        if mode in ('stop-fail','start-and-stop-fail','signal-and-stop-fail'): sys.exit(1)
        if mode == 'stopped-lie': sys.exit(0)
    # Execute actual generated shell start/stop functions (not a parallel model).
    p=subprocess.run(['/bin/sh','-c','. "$1"; "$2"','shim',str(service),action])
    if p.returncode: sys.exit(p.returncode)
    (f/'status').write_text('started' if action=='start' else 'stopped')
    if action=='start' and mode=='start-partial-fail': sys.exit(1)
    if action=='start' and mode=='start-and-stop-fail': sys.exit(1)
    if action=='start' and mode in ('start-signal','signal-and-stop-fail'): os.kill(os.getppid(),signal.SIGTERM); sys.exit(1)
    if action=='start' and mode=='rollback-claim':
        p=root/'manifest'; import json
        m=json.loads(p.read_text()); m['directory']['ino']+=1; p.write_text(json.dumps(m))
        sys.exit(1)
    if action=='start' and mode=='claim-valid-foreign':
        original=root/'swapfile'; old=root/'old-swap'
        original.rename(old)
        import shutil,json
        shutil.copyfile(old,original); original.chmod(0o600); old.unlink()
        m=json.loads((root/'manifest').read_text()); m['files'][str(original)]['identity']['ino']=original.stat().st_ino
        for _ in range(4):
            data=json.dumps(m,sort_keys=True).encode()+b'\n'
            m['manifest_identity']['size']=len(data)
        (root/'manifest').write_bytes(json.dumps(m,sort_keys=True).encode()+b'\n')
        sys.exit(1)
    sys.exit(0)
else: denied()
'''.replace('PYTHON',python).replace('REAL_DD',repr(real_dd))

# Narrow fault injection, limited to task-owned absolute target paths. No fake
# responses replace real swap evidence: this whole suite is explicitly a mock.
sitecustomize = r'''
import os
from pathlib import Path
mode=os.environ.get('MODE',''); fixture=os.environ.get('FIXTURE','')
if fixture:
    root=fixture+'/data/terry-toolbox-alpine-swap'
    # Keep the happy path's real fsync; failure matrix tests simulate I/O at
    # selected boundaries and skip unrelated physical durability waits.
    if Path(fixture).name != 'happy':
        os.fsync=lambda fd: None
    if mode == 'space-low':
        original=os.statvfs
        def low(path):
            v=original(path)
            if str(path).startswith(fixture):
                values=list(v); values[4]=0; return os.statvfs_result(values)
            return v
        os.statvfs=low
    if mode == 'autostart-fail':
        original_link=os.symlink
        def link(src,dst,*a,**kw):
            if str(dst).startswith(fixture+'/runlevels/'):
                raise OSError('injected autostart I/O')
            return original_link(src,dst,*a,**kw)
        os.symlink=link
    if mode in ('helper-io','manifest-io','service-io'):
        original_open=os.open
        target={'helper-io':root+'/runtime.py','manifest-io':root+'/manifest',
                'service-io':fixture+'/init.d/terry-toolbox-alpine-swap'}[mode]
        def opened(path,flags,*a,**kw):
            if str(path)==target and flags & os.O_CREAT: raise OSError('injected create I/O')
            return original_open(path,flags,*a,**kw)
        os.open=opened
    if mode == 'manifest-write-io':
        original_write=os.write
        def write(fd,data):
            if os.readlink('/proc/self/fd/'+str(fd))==root+'/manifest':
                raise OSError('injected seal write I/O')
            return original_write(fd,data)
        os.write=write
'''

host_paths = ['/proc/swaps','/etc/fstab','/etc/sysctl.conf']
host_targets = ['/var/lib/terry-toolbox-alpine-swap','/etc/init.d/terry-toolbox-alpine-swap',
                '/etc/runlevels/default/terry-toolbox-alpine-swap','/run/terry-toolbox-alpine-swap.lock']

def host_swap_entries(raw):
    # Only Used is volatile. Preserve row order and every other field exactly;
    # reject unknown formats rather than dropping a row or guessing its identity.
    if not isinstance(raw, bytes) or not raw.endswith(b'\n'):
        raise ValueError('host /proc/swaps missing or unterminated')
    text=raw.decode('ascii')
    if any(c not in '\t\n' and not 32 <= ord(c) <= 126 for c in text):
        raise ValueError('host /proc/swaps contains unknown control characters')
    lines=text.split('\n')[:-1]
    if not lines or lines[0].split() != ['Filename','Type','Size','Used','Priority']:
        raise ValueError('host /proc/swaps has unknown header')
    entries=[]; paths=set()
    for line in lines[1:]:
        fields=line.split()
        if len(fields) != 5:
            raise ValueError('host /proc/swaps has an unknown row')
        path,kind,size,used,priority=fields
        if not re.fullmatch(r'/(?:[^\x00-\x20\x7f\\]|\\(?:040|011|012|134))+',path):
            raise ValueError('host /proc/swaps has an invalid/unknown escaped path')
        decoded=re.sub(r'\\([0-7]{3})',lambda m:chr(int(m[1],8)),path)
        if decoded in paths or kind not in ('file','partition'):
            raise ValueError('host /proc/swaps has duplicate paths or unknown Type')
        if not re.fullmatch(r'[1-9][0-9]*',size) or not re.fullmatch(r'0|[1-9][0-9]*',used) \
                or not re.fullmatch(r'0|-?[1-9][0-9]*',priority) or int(used)>int(size):
            raise ValueError('host /proc/swaps has invalid Size/Used/Priority')
        paths.add(decoded)
        entries.append((path,kind,size,priority))
    return tuple(entries)

def host_swap_parser_check():
    header=b'Filename\tType\tSize\tUsed\tPriority\n'
    base=header+b'/swapfile file 4096 0 -2\n/dev/zram0 partition 8192 12 100\n'
    expected=host_swap_entries(base)
    assert expected==host_swap_entries(base.replace(b'4096 0 -2',b'4096 4096 -2'))
    assert expected==host_swap_entries(base.replace(b'8192 12 100',b'8192 0 100'))
    for changed in (base.replace(b'/swapfile',b'/other'),base.replace(b'file 4096',b'partition 4096'),
                    base.replace(b'4096 0',b'8192 0'),base.replace(b'0 -2',b'0 -3'),
                    header,base+ b'/new file 4096 0 -4\n',
                    header+b'/dev/zram0 partition 8192 12 100\n/swapfile file 4096 0 -2\n'):
        assert expected!=host_swap_entries(changed), 'changed host swap identity accepted'
    assert host_swap_entries(header)==()
    assert host_swap_entries(header+br'/swap\040space file 4096 0 -2'+b'\n')[0][0]==r'/swap\040space'
    for malformed in (None,b'',base[:-1],base.replace(b'Filename',b'File'),base+b'\n',
                      base.replace(b' 0 -2',b' 0 -2 extra'),base.replace(b'/swapfile',b'relative'),
                      base.replace(b'/swapfile',br'/bad\999'),base.replace(b'file 4096',b'unknown 4096'),
                      base.replace(b'4096 0',b'0 0'),base.replace(b'4096 0',b'4096 -1'),
                      base.replace(b'4096 0',b'4096 4097'),base.replace(b'0 -2',b'0 unknown'),
                      base.replace(b'4096 0',b'4096\x0b0'),base+b'/swapfile file 4096 0 -3\n'):
        try: host_swap_entries(malformed)
        except (ValueError,UnicodeError): pass
        else: raise AssertionError('malformed host swap evidence accepted: '+repr(malformed))

host_swap_parser_check()
print('HOST_SWAP_PARSER_CHECK=PASS (Used-only changes accepted; identities/formats strict)',flush=True)

def host_snapshot(label):
    directory=work/('host-state-'+label)
    directory.mkdir(mode=0o700)
    raw={p:Path(p).read_bytes() if Path(p).exists() else None for p in host_paths}
    targets={p:os.lstat(p) if os.path.lexists(p) else None for p in host_targets}
    manifest={'files':{},'targets':{}}
    for path,data in raw.items():
        name=path.strip('/').replace('/','-')+'.raw'
        if data is not None:
            leaf=directory/name; leaf.write_bytes(data); leaf.chmod(0o600)
        manifest['files'][path]={'present':data is not None,'raw_file':name if data is not None else None,
                                'sha256':hashlib.sha256(data).hexdigest() if data is not None else None}
    for path,info in targets.items():
        manifest['targets'][path]=None if info is None else {
            key:getattr(info,key) for key in ('st_dev','st_ino','st_mode','st_nlink','st_uid','st_gid',
                                             'st_size','st_atime_ns','st_mtime_ns','st_ctime_ns')}
    leaf=directory/'manifest.json'
    leaf.write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n'); leaf.chmod(0o600)
    # Raw bytes are already retained if strict parsing rejects the evidence.
    entries=host_swap_entries(raw['/proc/swaps'])
    leaf=directory/'proc-swaps.entries.json'
    leaf.write_text(json.dumps(entries,indent=2)+'\n'); leaf.chmod(0o600)
    return raw,targets,entries

host_before,host_target_before,host_swaps_before=host_snapshot('before')

def fixture(name):
    f=work/name
    f.mkdir(mode=0o700)
    for directory in ('bin','data','init.d','conf.d','runlevels','runlevels/default','run','openrc','inject'):
        (f/directory).mkdir(mode=0o700)
    (f/'os-release').write_text('ID=alpine\n')
    (f/'openrc/softlevel').write_text('default\n')
    (f/'swaps').write_text('Filename\tType\tSize\tUsed\tPriority\n')
    dev=f.stat().st_dev
    (f/'mountinfo').write_text('42 1 '+str(os.major(dev))+':'+str(os.minor(dev))+' / '+str(f)+' rw - ext4 /dev/fixture rw\n')
    (f/'unrelated').write_text('DO NOT CHANGE\n')
    (f/'bin/shim').write_text(shim)
    (f/'bin/shim').chmod(0o700)
    for name in ('dd','mkswap','swapon','swapoff','rc-service','rc-update','apk','systemctl','mount','umount','unshare','losetup','truncate','fallocate','mkfs','mke2fs','sysctl','openrc-run','sudo'):
        (f/'bin'/name).symlink_to('shim')
    for name in ('apt','apt-get','apt-cache','aptitude','dpkg','dpkg-query','dpkg-deb','dnf','yum','rpm'):
        (f/'bin'/name).symlink_to('shim')
    for name,path in (('python3',python),('bash',bash),('flock',real_flock),('cat',real_cat)):
        (f/'bin'/name).symlink_to(path)
    (f/'inject/sitecustomize.py').write_text(sitecustomize)
    env={**os.environ,'FIXTURE':str(f),'PATH':str(f/'bin'),'MODE':'',
         'PYTHONPATH':str(f/'inject')}
    mapping={'ROOT':'data/terry-toolbox-alpine-swap','INITD':'init.d','CONFD':'conf.d',
             'RUNLEVELS':'runlevels','LOCK':'run/terry-toolbox-alpine-swap.lock',
             'OS_RELEASE':'os-release','OPENRC_RUN':'openrc','SWAPS':'swaps','MOUNTINFO':'mountinfo'}
    for key,value in mapping.items(): env['TOOLBOX_ALPINE_SWAP_'+key]=str(f/value)
    if f.name == cases[0][0]:
        for probe_env in (env, {'PATH':env['PATH'],'FIXTURE':str(f)}):
            probe=subprocess.run([bash,'--noprofile','--norc','-c','apt-get --fixture-guard-probe'],env=probe_env,capture_output=True)
            assert probe.returncode==99,probe
        assert len((f/'DENIED').read_text().splitlines())==2
        (f/'DENIED').unlink()
        (f/'calls').unlink()
    return f,env

def invoke(f,env,args=('install','128'),input='YES\nYES\n',mode='',expected=0,caller='if',tag='action'):
    e={**env,'MODE':mode}
    if caller=='if':
        script='source "$1"; shift; if toolbox_alpine_swap "$@"; then exit 0; else exit 23; fi'
    else:
        script='source "$1"; shift; toolbox_alpine_swap "$@" || exit 23'
    if e.get('FIXTURE_DECLINE_DEPENDENCIES') == '1':
        script='source "${1%/*}/dependencies.sh"; _toolbox_deps_os() { printf "alpine\\n"; }; _toolbox_deps_confirm() { return 1; }; '+script
    p=subprocess.run([bash,'-c',script,'test',str(module),*args],input=input,text=True,
                     stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=e,timeout=15)
    (work/(f.name+'-'+tag+'.log')).write_text(p.stdout+'\nexit='+str(p.returncode)+'\n')
    assert (p.returncode==0)==(expected==0), (args,mode,p.returncode,p.stdout)
    assert not (f/'DENIED').exists(), (f/'DENIED').read_text() if (f/'DENIED').exists() else ''
    assert (f/'unrelated').read_text()=='DO NOT CHANGE\n'
    return p.stdout

def installed(f):
    return f/'data/terry-toolbox-alpine-swap'

def absent(f,lock=False):
    assert not installed(f).exists()
    assert not (f/'init.d/terry-toolbox-alpine-swap').exists()
    assert not (f/'runlevels/default/terry-toolbox-alpine-swap').exists()
    assert len((f/'swaps').read_text().splitlines())==1
    if not lock: assert not (f/'run/terry-toolbox-alpine-swap.lock').exists()

def runtime(f,env,action,expected=0):
    p=subprocess.run([python,str(installed(f)/'runtime.py'),'runtime',action],env=env,
                     stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=10)
    with (work/(f.name+'-runtime.log')).open('a') as log:
        log.write(action+' exit='+str(p.returncode)+'\n'+p.stdout)
    assert (p.returncode==0)==(expected==0),p.stdout
    assert not (f/'DENIED').exists()

def happy(f,e):
    invoke(f,e,('status',),input='')
    absent(f)
    invoke(f,e)
    root=installed(f)
    assert root.stat().st_mode & 0o777 == 0o700
    assert (root/'swapfile').stat().st_mode & 0o777 == 0o600
    assert os.readlink(f/'runlevels/default/terry-toolbox-alpine-swap')==str(f/'init.d/terry-toolbox-alpine-swap')
    invoke(f,e,('status',),input='',tag='status')
    runtime(f,e,'stop'); runtime(f,e,'start')
    # Real kernel writes mutate the payload, not the first header page.
    with (root/'swapfile').open('r+b') as out: out.seek(8192); out.write(b'kernel payload changed')
    runtime(f,e,'stop'); runtime(f,e,'start')
    invoke(f,e,('uninstall',),caller='or',tag='uninstall')
    absent(f,True)
    invoke(f,e,('status',),input='',tag='absent-status')

def kernel_capacity(f,e,kind):
    mode={'ext4':'ext4-capacity','reduced':'reduced-capacity'}.get(kind,'')
    invoke(f,e,mode=mode)
    root=installed(f)
    page=os.sysconf('SC_PAGE_SIZE')
    maximum=((root/'swapfile').stat().st_size-page)//1024
    values={'ext4':('file',131048),'reduced':('file',maximum-page//1024),
            'one-page':('file',page//1024),'zero':('file',0),
            'negative':('file',-page//1024),'nonpage':('file',maximum-1),
            'oversized':('file',maximum+page//1024),'wrong-type':('partition',maximum),
            'wrong-path':('file',maximum),'duplicate':('file',maximum),
            'unknown-table':('file',maximum)}
    valid=kind in ('ext4','reduced','one-page')
    type_,size=values[kind]
    path=str(root/'swapfile')+('.foreign' if kind=='wrong-path' else '')
    header='Filename\tType\tSize\tUsed\tPriority\n'
    row=path+' '+type_+' '+str(size)+' 0 -2\n'
    (f/'swaps').write_text('unknown table\n' if kind=='unknown-table' else
                          header+row+(row if kind=='duplicate' else ''))
    # Exercise the production parser and kernel guard, not a copied size formula.
    script='import runpy; n=runpy.run_path(__import__("sys").argv[1]); n["kernel"](__import__("os").stat(n["SWAP"]).st_size)'
    p=subprocess.run([python,'-c',script,str(root/'runtime.py')],env=e,
                     stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=10)
    (work/(f.name+'-kernel.log')).write_text(p.stdout+'\nexit='+str(p.returncode)+'\n')
    assert (p.returncode==0)==valid, (kind,p.returncode,p.stdout)
    if valid:
        runtime(f,e,'start')  # already-active path must accept reduced capacity
        runtime(f,e,'stop')
        assert len((f/'swaps').read_text().splitlines())==1
        runtime(f,{**e,'MODE':mode},'start')
        invoke(f,e,('status',),input='',mode=mode,tag='status')
        invoke(f,e,('uninstall',),mode=mode,tag='uninstall')
        absent(f,True)
    elif kind not in ('wrong-path','duplicate','unknown-table'):
        calls=(f/'calls').read_text()
        runtime(f,e,'start',expected=1); runtime(f,e,'stop',expected=1)
        assert (f/'calls').read_text()==calls, 'invalid target must not call swap tools'
        assert root.exists() and not (f/'did-stop').exists()

def cancelled(f,e,input):
    invoke(f,e,input=input,expected=1)
    absent(f)
    assert not (f/'calls').exists() or 'dd ' not in (f/'calls').read_text()

def early_failure(f,e,mode,retained=False):
    invoke(f,e,mode=mode,expected=1)
    if retained: assert installed(f).exists()
    else: absent(f,True)

def bad_status(f,e,status):
    invoke(f,e)
    before=(installed(f)/'manifest').read_bytes()
    invoke(f,e,('uninstall',),mode='status-'+status,expected=1,tag='uninstall')
    assert (installed(f)/'manifest').read_bytes()==before
    assert not (f/'did-stop').exists()

def stop_failure(f,e,mode):
    invoke(f,e)
    invoke(f,e,('uninstall',),mode=mode,expected=1,tag='uninstall')
    assert installed(f).exists()
    assert (f/'runlevels/default/terry-toolbox-alpine-swap').is_symlink()
    assert (f/'init.d/terry-toolbox-alpine-swap').exists()
    runtime(f,e,'start',expected=1)  # retiring latch defeats queued/external starts

def tamper(f,e,kind):
    invoke(f,e)
    root=installed(f)
    if kind=='inode':
        (root/'swapfile').rename(root/'old-swap')
        shutil.copyfile(root/'old-swap',root/'swapfile')
        (root/'swapfile').chmod(0o600)
        (root/'old-swap').unlink()
    elif kind=='script':
        with (root/'runtime.py').open('a') as out: out.write('\n# external change\n')
    elif kind=='extra': (root/'unknown').write_text('foreign')
    elif kind=='link':
        (f/'runlevels/default/terry-toolbox-alpine-swap').unlink()
        (f/'runlevels/default/terry-toolbox-alpine-swap').symlink_to('/foreign')
    elif kind=='confd': (f/'conf.d/terry-toolbox-alpine-swap.default').write_text('foreign')
    elif kind=='directory':
        root.rename(root.with_name('original'))
        shutil.copytree(root.with_name('original'),root)
    elif kind=='table': (f/'swaps').write_text('unknown table\n')
    elif kind=='header':
        with (root/'swapfile').open('r+b') as out: out.seek(1036); out.write(b'changed uuid!!!!!')
    elif kind=='hardlink': os.link(root/'swapfile',f/'foreign-link')
    elif kind=='manifest':
        value=json.loads((root/'manifest').read_text()); value['directory']['ino']+=1
        (root/'manifest').write_text(json.dumps(value))
    before=(f/'calls').read_text()
    runtime(f,e,'stop',expected=1)
    runtime(f,e,'start',expected=1)
    invoke(f,e,('uninstall',),expected=1,tag='uninstall')
    assert (f/'calls').read_text()==before, 'tampered ownership must not call service/swap tools'
    assert root.exists()

def concurrent(f,e):
    import fcntl
    path=f/'run/terry-toolbox-alpine-swap.lock'
    fd=os.open(path,os.O_RDWR|os.O_CREAT,0o600)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        invoke(f,e,expected=1)
        absent(f,True)
    finally: os.close(fd)

def runtime_concurrent(f,e):
    import fcntl
    invoke(f,e)
    fd=os.open(installed(f)/'runtime.lock',os.O_RDWR)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        runtime(f,e,'stop',expected=1)
        invoke(f,e,('uninstall',),expected=1,tag='uninstall')
        assert not (f/'did-stop').exists()
    finally: os.close(fd)

def confirm_race(f,e):
    script='source "$1"; if toolbox_alpine_swap install 128; then exit 0; else exit 23; fi'
    p=subprocess.Popen([bash,'-c',script,'test',str(module)],env=e,stdin=subprocess.PIPE,
                       stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    output=''
    while '第一次确认' not in output:
        char=p.stdout.read(1); assert char,output; output+=char
    p.stdin.write('YES\n'); p.stdin.flush()
    while '第二次确认' not in output:
        char=p.stdout.read(1); assert char,output; output+=char
    installed(f).mkdir()
    (installed(f)/'foreign').write_text('foreign')
    p.stdin.write('YES\n'); p.stdin.flush()
    rest,_=p.communicate(timeout=10)
    (work/(f.name+'-action.log')).write_text(output+rest+'\nexit='+str(p.returncode))
    assert p.returncode!=0
    assert (installed(f)/'foreign').read_text()=='foreign'
    assert 'dd ' not in (f/'calls').read_text()

def uninstall_cancel(f,e,input):
    invoke(f,e)
    before=(installed(f)/'manifest').read_bytes()
    invoke(f,e,('uninstall',),input=input,expected=1,tag='uninstall')
    assert (installed(f)/'manifest').read_bytes()==before
    assert not (f/'did-stop').exists()

def resolve_changed(f,e):
    invoke(f,e)
    invoke(f,e,('uninstall',),mode='resolve-changed',expected=1,tag='uninstall')
    assert not (f/'did-stop').exists()

def stopped_success(f,e):
    invoke(f,e)
    runtime(f,e,'stop')
    (f/'status').write_text('stopped')
    invoke(f,e,('status',),input='',tag='status')
    invoke(f,e,('uninstall',),tag='uninstall')
    absent(f,True)

def retained_rollback(f,e,mode):
    early_failure(f,e,mode,True)
    assert (f/'did-stop').exists()
    assert len((f/'swaps').read_text().splitlines())==2
    assert installed(f).is_dir()

def os_release_link(f,e,kind):
    # Model the canonical etc + usr/lib tree without following a host symlink.
    (f/'etc').mkdir()
    (f/'usr/lib').mkdir(parents=True)
    target=f/'usr/lib/os-release'
    target.write_text('ID=alpine\n')
    target.chmod(0o644)
    link=f/'etc/os-release'
    link.symlink_to('/usr/lib/os-release' if kind=='absolute' else '../usr/lib/os-release')
    e['TOOLBOX_ALPINE_SWAP_OS_RELEASE']=str(link)
    if kind=='wrong-target':
        link.unlink(); link.symlink_to('../usr/lib/./os-release')
    elif kind=='wrong-location':
        e['TOOLBOX_ALPINE_SWAP_OS_RELEASE']=str(f/'other-release')
        (f/'other-release').symlink_to('usr/lib/os-release')
    elif kind=='link-owner': os.lchown(link,65534,65534)
    elif kind=='target-owner': os.chown(target,65534,65534)
    elif kind=='target-writable': target.chmod(0o666)
    elif kind=='target-link':
        target.unlink(); target.symlink_to(f/'os-release')
    elif kind=='target-directory':
        target.unlink(); target.mkdir()
    elif kind=='etc-writable': (f/'etc').chmod(0o777)
    elif kind=='usr-writable': (f/'usr').chmod(0o777)
    elif kind=='usr-link':
        (f/'usr').rename(f/'real-usr'); (f/'usr').symlink_to('real-usr')
    elif kind=='etc-link':
        (f/'etc').rename(f/'real-etc'); (f/'etc').symlink_to('real-etc')
    elif kind=='other-read-link':
        (f/'swaps').rename(f/'real-swaps'); (f/'swaps').symlink_to('real-swaps')
    elif kind=='write-link':
        (f/'init.d').rename(f/'real-init.d'); (f/'init.d').symlink_to('real-init.d')
    success=kind in ('relative','absolute')
    output=invoke(f,e,('status',),input='',expected=0 if success else 1)
    if success: assert '未安装 B19' in output
    absent(f)
    assert not (f/'calls').exists(), 'OS metadata check must not execute service/swap tools'
    if success: happy(f,e)

def openrc_permissions(f,e,kind):
    directory=f/'openrc'
    directory.chmod(0o775)
    (directory/'softlevel').chmod(0o644)
    if kind=='group': os.chown(directory,0,65534)
    elif kind=='owner': os.chown(directory,65534,0)
    elif kind=='other-write': directory.chmod(0o777)
    elif kind=='link':
        directory.rename(f/'real-openrc'); directory.symlink_to('real-openrc')
    elif kind=='ancestor-write': f.chmod(0o775)
    elif kind=='state-write': (directory/'softlevel').chmod(0o664)
    elif kind=='state-link':
        (directory/'softlevel').rename(directory/'real-softlevel')
        (directory/'softlevel').symlink_to('real-softlevel')
    elif kind=='write-path': (f/'init.d').chmod(0o775)
    if kind=='root-group':
        happy(f,e)
    else:
        invoke(f,e,('status',),input='',expected=1)
        absent(f)
        assert not (f/'calls').exists()

cases=[('happy',happy)]
for kind in ('ext4','reduced','one-page','zero','negative','nonpage','oversized','wrong-type','wrong-path','duplicate','unknown-table'):
    cases.append(('kernel-capacity-'+kind,lambda f,e,kind=kind:kernel_capacity(f,e,kind)))
for kind in ('root-group','group','owner','other-write','link','ancestor-write','state-write','state-link','write-path'):
    cases.append(('openrc-permissions-'+kind,lambda f,e,kind=kind:openrc_permissions(f,e,kind)))
for kind in ('relative','absolute','wrong-target','wrong-location','link-owner','target-owner',
             'target-writable','target-link','target-directory','etc-writable','usr-writable',
             'usr-link','etc-link','other-read-link','write-link'):
    cases.append(('os-release-'+kind,lambda f,e,kind=kind:os_release_link(f,e,kind)))
cases += [('cancel-first-unterminated',lambda f,e:cancelled(f,e,'YES')),
          ('cancel-second-unterminated',lambda f,e:cancelled(f,e,'YES\nYES')),
          ('uninstall-cancel-second-unterminated',lambda f,e:uninstall_cancel(f,e,'YES\nYES')),
          ('confirm-crlf',lambda f,e:invoke(f,e,input='yEs\r\nYeS\r\n'))]
for name,input in [('cancel-first','NO\nYES\n'),('cancel-second','YES\nno\n'),('cancel-eof',''),('cancel-second-eof','YES\n'),('cancel-blank','\nYES\n'),('cancel-space',' YES\nYES\n')]:
    cases.append((name,lambda f,e,input=input:cancelled(f,e,input)))
cases.append(('interactive-size-cancel',lambda f,e:invoke(f,e,('install',),input='\nYES\nYES\n',expected=1)))
cases.append(('interactive-action-cancel',lambda f,e:invoke(f,e,(),input='\n',expected=1)))
for token in ('0128','127','8193','1;touch /oops','-1','128.0',''):
    cases.append(('size-'+str(len(cases)),lambda f,e,token=token:invoke(f,e,('install',token),expected=1)))
for dependency in ('python3','cat','flock','dd','mkswap','swapon','swapoff','rc-service','openrc-run'):
    def missing(f,e,d=dependency):
        (f/'bin'/d).unlink()
        e['FIXTURE_DECLINE_DEPENDENCIES']='1'
        output=invoke(f,e,expected=1)
        assert d in output
        absent(f)
    cases.append(('missing-'+dependency,missing))
for name,change in [
    ('not-alpine',lambda f:(f/'os-release').write_text('ID=debian\n')),
    ('no-openrc',lambda f:(f/'openrc/softlevel').unlink()),
    ('existing-target',lambda f:installed(f).mkdir()),
    ('symlink-target',lambda f:installed(f).symlink_to(f/'unrelated')),
    ('existing-service',lambda f:(f/'init.d/terry-toolbox-alpine-swap').write_text('foreign')),
    ('confd-conflict',lambda f:(f/'conf.d/terry-toolbox-alpine-swap.boot').write_text('foreign')),
    ('runlevel-conflict',lambda f:(f/'runlevels/default/terry-toolbox-alpine-swap').symlink_to('/foreign')),
    ('active-conflict',lambda f:((f/'openrc/started').mkdir(),(f/'openrc/started/terry-toolbox-alpine-swap').touch())),
    ('kernel-conflict',lambda f:(f/'swaps').write_text('Filename Type Size Used Priority\n'+str(installed(f)/'swapfile')+' file 131068 0 -2\n')),
]:
    def rejected(f,e,change=change):
        change(f); invoke(f,e,expected=1)
        assert not (f/'run/terry-toolbox-alpine-swap.lock').exists()
    cases.append((name,rejected))
for fs in ('overlay','tmpfs','btrfs','nfs'):
    def badfs(f,e,fs=fs):
        p=f/'mountinfo'; p.write_text(p.read_text().replace(' ext4 ',' '+fs+' '))
        invoke(f,e,expected=1); absent(f)
    cases.append(('filesystem-'+fs,badfs))
cases.append(('space-low',lambda f,e:early_failure(f,e,'space-low')))
for mode in ('dd-fail','dd-signal','mkswap-fail','helper-io','manifest-io','start-fail','start-partial-fail','start-signal','swapon-fail','autostart-fail'):
    cases.append((mode,lambda f,e,mode=mode:early_failure(f,e,mode)))
for mode in ('claim-replace','service-io','manifest-write-io','rollback-claim','claim-valid-foreign','wrong-size'):
    cases.append((mode,lambda f,e,mode=mode:early_failure(f,e,mode,True)))
for mode in ('start-and-stop-fail','signal-and-stop-fail'):
    cases.append((mode,lambda f,e,mode=mode:retained_rollback(f,e,mode)))
for mode in ('stop-fail','swapoff-fail','stopped-lie','kernel-remains','poststop-unknown','poststop-starting','poststop-stopping','poststop-inactive','poststop-crashed'):
    cases.append((mode,lambda f,e,mode=mode:stop_failure(f,e,mode)))
for status in ('starting','stopping','inactive','crashed','unknown'):
    cases.append(('status-'+status,lambda f,e,status=status:bad_status(f,e,status)))
for kind in ('inode','script','extra','link','confd','directory','table','header','hardlink','manifest'):
    cases.append(('tamper-'+kind,lambda f,e,kind=kind:tamper(f,e,kind)))
cases += [('stopped-success',stopped_success),('concurrent-installer',concurrent),('concurrent-runtime',runtime_concurrent),
          ('confirm-race',confirm_race),('resolve-changed',resolve_changed),
          ('uninstall-cancel-first',lambda f,e:uninstall_cancel(f,e,'no\nYES\n')),
          ('uninstall-cancel-second',lambda f,e:uninstall_cancel(f,e,'YES\nno\n'))]

selected=os.environ.get('ALPINE_SWAP_TEST_CASES')
if selected:
    names=set(selected.split(','))
    assert names <= {name for name,_ in cases}, 'unknown focused case'
    cases=[(name,test) for name,test in cases if name in names]

failures=[]
start=time.monotonic()
for name,test in cases:
    f,e=fixture(name)
    t=time.monotonic()
    try:
        test(f,e)
        assert not (f/'DENIED').exists(), 'DENY shim fired'
        assert (f/'unrelated').read_text()=='DO NOT CHANGE\n'
        result='exit=0'
    except Exception as error:
        failures.append(name)
        result='exit=1 '+repr(error)
    with results.open('a') as log: log.write(name+' '+result+' seconds=%.3f\n'%(time.monotonic()-t))
    print(name+' '+result,flush=True)
    # This is the only recursive deletion, explicitly task-owned fixture only.
    assert f.parent==work and f.name==name
    shutil.rmtree(f)
host_after,host_target_after,host_swaps_after=host_snapshot('after')
assert {p:host_after[p] for p in host_paths if p!='/proc/swaps'}=={p:host_before[p] for p in host_paths if p!='/proc/swaps'}, 'HOST CONFIG BYTES CHANGED; inspect host-state-before/after'
assert host_swaps_after==host_swaps_before, 'HOST SWAP IDENTITIES CHANGED; inspect host-state-before/after'
assert host_target_after==host_target_before, 'HOST TARGETS CHANGED; inspect host-state-before/after'
print('HOST_STATE=PASS (config bytes/targets/swap identities unchanged; Used may vary)',flush=True)
print('TOTAL=%d FAIL=%d SECONDS=%.3f RESULTS=%s'%(len(cases),len(failures),time.monotonic()-start,results),flush=True)
sys.exit(bool(failures))
PY
