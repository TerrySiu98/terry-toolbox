#!/usr/bin/env bash
# Offline-only firmware fixtures; production helper/preflight, mocked host reads.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root" <<'PY'
import hashlib,json,os,pathlib,subprocess,sys,tempfile
repo=pathlib.Path(sys.argv[1]);base=pathlib.Path(tempfile.mkdtemp(prefix='secureboot-boundary-',dir=os.environ['TMPDIR']))
guid='8be4df61-93ca-11d2-aa0d-00e098032b8c';results=[]
shell=r'''
set -u
source "$REVIEW_REPO/modules/reinstall.sh"
_toolbox_reinstall_need() { return 0; }
_toolbox_reinstall_root() { return 0; }
_toolbox_reinstall_container() { return 1; }
_toolbox_reinstall_lsblk() { command cat "$REVIEW_CASE/inventory.json"; }
_toolbox_reinstall_mounts() { command cat "$REVIEW_CASE/mounts.json"; }
_toolbox_reinstall_efi() { command cat "$REVIEW_CASE/efi.txt"; }
uname() { [[ $1 == -m ]] && printf 'x86_64\n'; }
mokutil() {
 printf '%s\n' "$REVIEW_TEXT"
 return "${REVIEW_RC:-255}"
}
if [[ $REVIEW_MODE == readonly ]]; then readonly EFIVARFS_PATH=/untrusted; fi
if [[ $REVIEW_MODE == preflight ]]; then toolbox_reinstall preflight alpine
else _toolbox_reinstall_secure_boot "$TOOLBOX_REINSTALL_ROOT" "$(command cat "$REVIEW_CASE/mounts.json")"; fi
'''
def snapshot(root):
 return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
def run(variable=None,operation=None,number=2,mode='helper',kind='regular',text=None,rc=255):
 case=base/str(len(results));case.mkdir();root=case/'root';v=root/'sys/firmware/efi/efivars';v.mkdir(parents=True)
 for d in ('boot/efi/EFI/offline','proc/1','proc/sys/kernel/random'):(root/d).mkdir(parents=True)
 (root/'boot/efi/EFI/offline/grubx64.efi').write_bytes(b'offline non-executable fixture\n')
 (root/'proc/1/comm').write_text('systemd\n');(root/'proc/sys/kernel/random/boot_id').write_text('offline-boot\n')
 for name in ('BootCurrent','BootOrder'):(v/(name+'-'+guid)).write_bytes(b'\x06\0\0\0\0\0')
 mounts={'filesystems':[{'target':'/','source':'/dev/vda1','fstype':'ext4','options':'rw'},{'target':'/boot/efi','source':'/dev/vda1','fstype':'vfat','options':'rw'},{'target':'/sys/firmware/efi/efivars','source':'efivarfs','fstype':'efivarfs','options':'rw'}]}
 inventory={'blockdevices':[{'name':'/dev/vda','kname':'vda','type':'disk','pkname':None,'fstype':None,'size':2147483648,'model':'OFFLINE','serial':'fixture','wwn':'fixture','maj:min':'252:0','ro':False,'rm':False,'ptuuid':'12345678','children':[{'name':'/dev/vda1','kname':'vda1','type':'part','pkname':'vda','fstype':'ext4'}]}]}
 (case/'mounts.json').write_text(json.dumps(mounts));(case/'inventory.json').write_text(json.dumps(inventory));(case/'efi.txt').write_text('BootCurrent: 0000\nBootOrder: 0000\nBoot0000* original\n')
 if variable:
  p=v/(variable+'-'+guid)
  if kind=='symlink':p.symlink_to(v/'absent')
  elif kind=='fifo':os.mkfifo(p)
  else:p.write_bytes(b'\x06\0\0\0\x01' if kind=='regular' else b'')
 env={'PATH':os.defpath,'HOME':str(case),'TMPDIR':str(base),'REVIEW_REPO':str(repo),'REVIEW_CASE':str(case),'REVIEW_MODE':mode,'REVIEW_RC':str(rc),'TOOLBOX_REINSTALL_ROOT':str(root),'TOOLBOX_REINSTALL_STATE':str(case/'state'),'PYTHONDONTWRITEBYTECODE':'1','LC_ALL':'C'}
 env['REVIEW_TEXT']=text if text is not None else "This system doesn't support Secure Boot"
 if operation:
  fault=case/'fault';fault.mkdir();env['PYTHONPATH']=str(fault)
  (fault/'sitecustomize.py').write_text('''import os
original_open=os.open
original=os.%s
names={}
def opened(path,*a,**kw):
 fd=original_open(path,*a,**kw)
 if isinstance(path,str):names[fd]=path
 return fd
def injected(fd,*a,**kw):
 if names.get(fd,'').startswith(%r):
  if %r=='close':original(fd,*a,**kw)
  raise OSError(%d,'offline firmware boundary fault')
 return original(fd,*a,**kw)
os.open=opened
os.%s=injected
''' % (operation,variable+'-',operation,number,operation))
 before=snapshot(root)
 r=subprocess.run(['/bin/bash','--noprofile','--norc','-c',shell],env=env,input=b'',stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
 expected_reject=bool(variable) or mode=='readonly'
 ok=(r.returncode!=0 if expected_reject else r.returncode==0) and before==snapshot(root) and not (case/'state').exists()
 if expected_reject:ok=ok and (b'Secure Boot' in r.stderr or b'readonly' in r.stderr)
 else:ok=ok and not r.stderr and (b'unsupported' in r.stdout or '可读固件变量未提供'.encode() in r.stdout)
 record={'variable':variable,'operation':operation,'errno':number,'mode':mode,'kind':kind,'exit_code':r.returncode,'passed':ok,'case':str(case)};results.append(record)
 (case/'stdout').write_bytes(r.stdout);(case/'stderr').write_bytes(r.stderr)
 print(('PASS' if ok else 'FAIL')+' '+json.dumps(record),flush=True)
for text in ("This system doesn't support Secure Boot","This system does't support Secure Boot"):
 for mode in ('helper','preflight'):run(mode=mode,text=text)
for variable in ('SecureBoot','SetupMode'):
 for operation in ('read','fstat','close'):
  for number in (2,5,13):
   for mode in ('helper','preflight'):run(variable,operation,number,mode)
 for kind in ('regular','empty','symlink','fifo'):run(variable,kind=kind)
# Failure to clear inherited backend overrides must not proceed to mokutil.
run(mode='readonly',text='SecureBoot disabled',rc=0)
(base/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print('Secure Boot boundary:',sum(x['passed'] for x in results),'/',len(results),'passed; fixtures:',base)
sys.exit(0 if all(x['passed'] for x in results) else 1)
PY
