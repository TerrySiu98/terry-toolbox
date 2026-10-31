#!/usr/bin/env bash
# Runs real pinned upstream prepare/reset ONLY in an explicitly marked disposable
# whole VM. Never reboots; the controller keeps evidence before choosing reboot.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# == 5 ]] || { printf 'Usage: %s cycle|arm debian|ubuntu|alpine version absolute-key.pub guest-id\n' "$0" >&2; exit 2; }
action=$1 distro=$2 version=$3 key=$4 guest_id=$5
[[ $action == cycle || $action == arm ]] || exit 2
[[ $(id -u) == 0 ]] || { printf 'Disposable VM root required\n' >&2; exit 2; }
[[ ${TOOLBOX_REINSTALL_ROOT+x} != x && ${TOOLBOX_REINSTALL_STATE+x} != x ]] || { printf 'Native run refuses path overrides\n' >&2; exit 2; }
source "$ROOT/modules/reinstall-provenance.sh"
source "$ROOT/modules/reinstall.sh"
toolbox_reinstall preflight "$distro"
_toolbox_reinstall_pubkey "$key"
# Provision this marker when creating a NEW VM, binding its unique disk serial
# and machine-id. A cloud/controller host cannot opt in with only an env flag.
python3 - "$guest_id" "$_toolbox_reinstall_disk" <<'PY'
import json,os,stat,sys
p='/etc/terry-toolbox-disposable-vm.json';s=os.lstat(p)
assert stat.S_ISREG(s.st_mode) and s.st_uid==0 and s.st_nlink==1 and stat.S_IMODE(s.st_mode)==0o600, 'unsafe VM marker'
m=json.load(open(p));disk=json.loads(sys.argv[2])
assert m.get('purpose')=='terry-toolbox-disposable-reinstall' and m.get('guest_id')==sys.argv[1], 'not this disposable reinstall VM'
assert m.get('machine_id')==open('/etc/machine-id').read().strip(), 'VM machine identity mismatch'
assert m.get('disk')==disk['name'] and m.get('disk_serial') and m['disk_serial']==disk['serial'], 'VM disk identity mismatch'
dmi=' '.join(open('/sys/class/dmi/id/'+n).read().lower() for n in ('product_name','sys_vendor'))
assert 'qemu' in dmi or 'kvm' in dmi, 'not an isolated QEMU/KVM guest'
assert disk['size']<=64*1024**3, 'unexpected disk size'
PY
evidence=$(mktemp -d /root/reinstall-native-evidence.XXXXXX)
chmod 0700 "$evidence"
sha256sum "$ROOT/modules/reinstall.sh" "$ROOT/modules/reinstall-provenance.sh" "$0" >"$evidence/source-hashes.txt"
cp /etc/terry-toolbox-disposable-vm.json "$evidence/disposable-vm.json"
printf 'Native evidence=%s\n' "$evidence"
export TOOLBOX_REINSTALL_SSH_KEY_FILE=$key
python3 - "$evidence/before.json" "$guest_id" "$distro" "$version" "$key" "$_toolbox_reinstall_disk" <<'PY'
import hashlib,json,os,sys,uuid
p,guest,distro,version,key,disk=sys.argv[1:]
nonce=uuid.uuid4().hex
with open('/root/.terry-toolbox-old-system-nonce','x') as f:f.write(nonce+'\n')
os.chmod('/root/.terry-toolbox-old-system-nonce',0o600)
m={'guest_id':guest,'target':distro,'version':version,'old_boot_id':open('/proc/sys/kernel/random/boot_id').read().strip(),'old_machine_id':open('/etc/machine-id').read().strip(),'old_nonce':nonce,'key_sha256':hashlib.sha256(open(key,'rb').read()).hexdigest(),'disk':json.loads(disk)}
with open(p,'x') as f:json.dump(m,f,sort_keys=True,indent=2);f.write('\n')
PY
name=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["name"])' "$_toolbox_reinstall_disk")
printf 'YES\nYES\n%s\n' "$name" | toolbox_reinstall prepare "$distro" "$version" >"$evidence/prepare.log" 2>&1 || { cat "$evidence/prepare.log"; printf 'FAILED evidence=%s\n' "$evidence"; exit 1; }
toolbox_reinstall status >"$evidence/prepared-status.log"
cp /var/lib/terry-toolbox/reinstall/active/metadata.json "$evidence/prepared-metadata.json"
sha256sum "$ROOT/modules/reinstall.sh" "$ROOT/modules/reinstall-provenance.sh" /reinstall-vmlinuz /reinstall-initrd >"$evidence/hashes.txt"
if [[ $action == cycle ]]; then
    toolbox_reinstall cancel >"$evidence/cancel.log" 2>&1 || { cat "$evidence/cancel.log"; printf 'FAILED evidence=%s\n' "$evidence"; exit 1; }
    toolbox_reinstall status >"$evidence/cancelled-status.log"
    grep -q 'phase=cancelled' "$evidence/cancelled-status.log"
    rm /root/.terry-toolbox-old-system-nonce
    printf 'PASS real prepare/status/reset and exact boot restore; evidence=%s\n' "$evidence"
else
    printf 'ARMED; no reboot performed. Copy evidence=%s and before.json off this disk BEFORE the controller reboots.\n' "$evidence"
fi
