#!/usr/bin/env bash
# Run only in a marked disposable Debian/systemd VM. Reboots are performed by
# the external controller, which copies evidence off the guest before each boot.
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
phase=${1:?prepare|after-enable|after-disable|uninstall}
state=${2:?fresh /root/vmess-native-NAME directory}
python3 - "$state" <<'PY'
import os,re,stat,sys
p='/run/terry-toolbox-vmess-acceptance'
s=os.lstat(p)
assert os.geteuid()==0 and stat.S_ISREG(s.st_mode) and s.st_uid==0 and s.st_nlink==1
assert stat.S_IMODE(s.st_mode)==0o600 and open(p).read()=='vmess-native\n'
assert re.fullmatch(r'/root/vmess-native-[A-Za-z0-9_-]+',sys.argv[1])
assert open('/proc/1/comm').read().strip()=='systemd'
PY
source "$ROOT/modules/network.sh"
source "$ROOT/modules/vmess.sh"
export TOOLBOX_VM_WS_LISTEN=127.0.0.1 TOOLBOX_VM_WS_ZIP_SRC=/root/xray-linux-64.zip
export TOOLBOX_NET_CAFILE="$state/cert.pem" TOOLBOX_NET_CAPATH=''
export TMPDIR="$state/scratch"
boot_id() { cat /proc/sys/kernel/random/boot_id; }
verify_sources() {
    python3 - "$ROOT" "$state" <<'PY'
import hashlib,json,pathlib,sys
root,state=map(pathlib.Path,sys.argv[1:])
expected=json.loads((state/'source.json').read_text())['source_sha256']
for name,want in expected.items():
 assert hashlib.sha256((root/name).read_bytes()).hexdigest()==want,'native candidate changed: '+name
PY
}
snapshot() {
    python3 - "$ROOT" "$state" "$1" <<'PY'
import hashlib,json,pathlib,subprocess,sys
root,state,name=map(pathlib.Path,sys.argv[1:])
files=['modules/vmess.sh','modules/network.sh','tests/vmess-native.sh','tests/vmess-native-probe.py']
d={'source_sha256':{f:hashlib.sha256((root/f).read_bytes()).hexdigest() for f in files},
   'boot_id':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
   'os_release':pathlib.Path('/etc/os-release').read_text(),
   'kernel':subprocess.check_output(['uname','-r'],text=True).strip()}
for p in ('/etc/terry-toolbox-vmess/config.json','/etc/terry-toolbox-vmess/cert.pem','/usr/local/bin/terry-toolbox-vmess'):
 if pathlib.Path(p).is_file():d[p]=hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
(state/(str(name)+'.json')).write_text(json.dumps(d,indent=2)+'\n')
PY
}
if [[ $phase != prepare ]]; then verify_sources; fi
case $phase in
    prepare)
        mkdir -m 700 "$state"; mkdir -m 700 "$TMPDIR"
        snapshot source
        openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj /CN=vmess.example.test \
            -addext subjectAltName=DNS:vmess.example.test -keyout "$state/key.pem" -out "$state/cert.pem" >"$state/cert-create.log" 2>&1
        printf 'YES\nYES\n' | toolbox_vmess install "$state/cert.pem" "$state/key.pem" vmess.example.test 24443 /toolbox-ws >"$state/install.log" 2>&1
        toolbox_vmess status >"$state/status.log" 2>&1
        [[ $(vmess_fs boot-info) == '2 disabled' ]]
        python3 "$ROOT/tests/vmess-native-probe.py" "$state" "$state/cert.pem"
        printf 'YES\nYES\n' | toolbox_vmess enable-boot >"$state/enable.log" 2>&1
        [[ $(vmess_fs boot-info) == '2 enabled' ]]
        boot_id > "$state/boot-before-enable"
        snapshot prepared
        printf 'PASS prepare: installed real Xray, authenticated transport, enabled boot; controller must reboot this VM.\n'
        ;;
    after-enable)
        [[ $(boot_id) != "$(<"$state/boot-before-enable")" ]]
        toolbox_vmess status >"$state/after-enable.log" 2>&1
        [[ $(vmess_fs boot-info) == '2 enabled' ]]
        python3 "$ROOT/tests/vmess-native-probe.py" "$state" "$state/cert.pem" after-enable
        printf 'YES\nYES\n' | toolbox_vmess disable-boot >"$state/disable.log" 2>&1
        toolbox_vmess status >>"$state/disable.log" 2>&1
        [[ $(vmess_fs boot-info) == '2 disabled' ]]
        boot_id > "$state/boot-before-disable"
        snapshot after-enable
        printf 'PASS enabled after whole reboot; disabled boot without stopping service; controller must reboot this VM.\n'
        ;;
    after-disable)
        [[ $(boot_id) != "$(<"$state/boot-before-disable")" ]]
        [[ $(vmess_fs boot-info) == '2 disabled' ]]
        vmess_service_read
        [[ $vmess_load == loaded && $vmess_active == inactive && $vmess_sub == dead && $vmess_pid == 0 ]]
        vmess_port_free 24443
        snapshot after-disable
        systemctl start terry-toolbox-vmess.service
        ready=0
        for ((i=0;i<30;i++)); do
            if toolbox_vmess status >"$state/manual-start.log" 2>&1; then ready=1; break; fi
            sleep 1
        done
        [[ $ready == 1 ]]
        printf 'PASS disabled after second whole reboot; service started explicitly for certificate acceptance.\n'
        ;;
    uninstall)
        printf 'YES\nYES\n' | toolbox_vmess uninstall >"$state/uninstall.log" 2>&1
        [[ ! -e /etc/terry-toolbox-vmess && ! -e /usr/local/bin/terry-toolbox-vmess && ! -e /etc/systemd/system/terry-toolbox-vmess.service ]]
        [[ -s $state/key.pem && -s $state/cert.pem ]]
        snapshot uninstalled
        printf 'PASS native uninstall and original certificate retention.\n'
        ;;
    *) exit 2;;
esac
