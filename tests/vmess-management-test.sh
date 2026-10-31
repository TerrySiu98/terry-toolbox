#!/usr/bin/env bash
# Privileged boundaries mocked; FS/inode/hash, /proc identity and cert checks real.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VMESS_FIXTURE_ONLY=1 source "$ROOT/tests/vmess-test.sh"
eval "$(declare -f systemctl | sed '1s/systemctl/vmess_fixture_systemctl/')"
eval "$(declare -f fixture | sed '1s/fixture/vmess_base_fixture/')"
eval "$(declare -f vmess_confirm | sed '1s/vmess_confirm/vmess_real_confirm/')"
eval "$(declare -f fail | sed '1s/fail/vmess_base_fail/')"
fail() {
    local file line
    for file in "$C/management-output" "$C/update-output" "$C/uninstall-output"; do
        [[ ! -f $file ]] || while IFS= read -r line; do printf '%s\n' "$line" >&2; done < "$file"
    done
    vmess_base_fail "$@"
}
fixture() {
    vmess_base_fixture "$1"
    # The real lock sits on tmpfs (/run): keep it under the fixture's /run stand-in
    # so a simulated reboot can change only its parent inode.
    export TOOLBOX_VM_WS_LOCK="$C/run/lock"
    unset BOOT_FAIL BOOT_STATE BOOT_SWAP BOOT_READBACK_FAIL BOOT_SIGNAL ROLLBACK_STOP_FAIL START_ONCE_FAIL TLS_ONCE_FAIL SIGNAL_ONCE_START SWAP_AT_START VMESS_MANAGEMENT_VALIDATE_FAIL DISABLE_FOREIGN SWAP_LOCK_AT
    rm -f "$T/inject/sitecustomize.py" "$T/inject/__pycache__/sitecustomize.cpython-313.pyc"
    vmess_confirm() { vmess_real_confirm; }
    vmess_certificate() { printf 'certificate-check\n' >> "$C/log"; [[ ${CERT_FAIL:-0} != 1 ]]; }
    vmess_tls_probe() { printf 'tls-ws-probe\n' >> "$C/log"; [[ ${TLS_FAIL:-0} != 1 && ! -e $C/tls-new-fail ]]; }
}
systemctl() {
    local dep f
    case $1 in
        enable|disable)
            printf 'systemctl %s\n' "$*" >> "$C/log"
            [[ ${BOOT_FAIL:-0} != 1 ]] || return 1
            if [[ $1 == disable ]]; then
                # Real `systemctl disable` unlinks EVERY link pointing at the unit.
                for dep in "$C"/units/*.wants "$C"/units/*.requires "$C"/units/*.upholds; do
                    [[ -d $dep ]] || continue
                    for f in "$dep"/*; do
                        [[ -L $f && $(readlink -- "$f") == "$(vmess_unit)" ]] && rm -f -- "$f"
                    done
                done
                if [[ ${DISABLE_FOREIGN:-0} == 1 ]]; then
                    ln -sfn "$(vmess_unit)" "$C/units/multi-user.target.wants/other.service"
                fi
            elif [[ ! -L $C/units/multi-user.target.wants/terry-toolbox-vmess.service ]]; then
                mkdir -p "$C/units/multi-user.target.wants"
                ln -s "$(vmess_unit)" "$C/units/multi-user.target.wants/terry-toolbox-vmess.service"
            fi
            if [[ ${BOOT_READBACK_FAIL:-0} == 1 ]]; then BOOT_STATE=enabled-runtime; fi
            if [[ ${BOOT_SIGNAL:-0} == 1 ]]; then kill -TERM "$BASHPID"; return 1; fi
            if [[ ${BOOT_SWAP:-0} == 1 ]]; then rm -f "$C/units/multi-user.target.wants/terry-toolbox-vmess.service"; ln -s /unknown "$C/units/multi-user.target.wants/terry-toolbox-vmess.service"; fi ;;
        show)
            if [[ $* == *UnitFileState* ]]; then
                if [[ -n ${BOOT_STATE:-} ]]; then printf 'UnitFileState=%s\n' "$BOOT_STATE"
                elif [[ -L $C/units/multi-user.target.wants/terry-toolbox-vmess.service ]]; then printf 'UnitFileState=enabled\n'
                elif grep -q '^\[Install\]' "$(vmess_unit)"; then printf 'UnitFileState=disabled\n'; else printf 'UnitFileState=static\n'; fi
            else vmess_fixture_systemctl "$@"; fi ;;
        start)
            if [[ ${SWAP_LOCK_AT:-} == start ]]; then swap_lock; fi
            if [[ ${START_ONCE_FAIL:-0} == 1 && ! -e $C/failed-once ]]; then
                [[ ${ROLLBACK_STOP_FAIL:-0} != 1 ]] || STOP_FAIL=1
                : > "$C/failed-once"; printf 'failed\n' > "$C/state"; printf 'systemctl start once-failed\n' >> "$C/log"; return 1
            fi
            if [[ ${SIGNAL_ONCE_START:-0} == 1 && ! -e $C/signalled ]]; then : > "$C/signalled"; kill -TERM "$BASHPID"; return 1; fi
            if [[ ${SWAP_AT_START:-0} == 1 ]]; then printf '\n' >> "$(vmess_etc)/key.pem"; fi
            if [[ ${TLS_ONCE_FAIL:-0} == 1 ]]; then
                if [[ ! -e $C/started-once ]]; then : > "$C/started-once"; : > "$C/tls-new-fail"; else rm -f "$C/tls-new-fail"; fi
            fi
            vmess_fixture_systemctl "$@" ;;
        stop)
            if [[ ${SWAP_LOCK_AT:-} == stop ]]; then swap_lock; fi
            vmess_fixture_systemctl "$@" ;;
        *) vmess_fixture_systemctl "$@" ;;
    esac
}
boot_yes() { toolbox_vmess "$1" <<< $'YES\nYES' > "$C/management-output" 2>&1; }
update_yes() { toolbox_vmess update-cert "$T/new.pem" "$T/new.key" <<< $'YES\nYES' > "$C/update-output" 2>&1; }
no_manage_mutation() { ! grep -Eq 'systemctl (enable|disable|start|stop|daemon-reload)' "$C/log" || fail 'cancellation/preflight mutation'; }
snapshot() { sha256sum "$(vmess_etc)/cert.pem" "$(vmess_etc)/key.pem" "$(vmess_etc)/config.json" "$(vmess_etc)/manifest.json" "$(vmess_etc)/manifest.sha256"; }
old_intact() { [[ $(snapshot) == "$old" ]] || fail 'old pair/config/ledger changed'; }
mkdir -m 700 "$T/inject"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=example.com -addext subjectAltName=DNS:example.com -keyout "$T/new.key" -out "$T/new.pem" >/dev/null 2>&1
fixture boot-happy
install_yes || fail 'boot setup'
: > "$C/log"; old=$(snapshot)
toolbox_vmess boot-status > "$C/management-output" 2>&1 || fail 'disabled boot status'
old_intact; no_manage_mutation
boot_yes enable-boot || fail "enable failed $C/management-output"
[[ -L $C/units/multi-user.target.wants/terry-toolbox-vmess.service ]] || fail 'missing owned link'
vmess_fs verify --complete >/dev/null || fail 'enabled ledger'
! grep -Eq 'systemctl (start|stop)' "$C/log" || fail 'boot mutation touched runtime'
boot_yes disable-boot || fail 'disable failed'
[[ ! -L $C/units/multi-user.target.wants/terry-toolbox-vmess.service ]] || fail 'owned link remained'
boot_yes enable-boot || fail 'reenable failed'
uninstall_yes || fail 'enabled uninstall failed'; empty_targets
pass 'boot explicit double-consent / read-only status / stop-disable-uninstall'
for action in enable-boot disable-boot update-cert; do
    fixture "cancel-$action"; install_yes || fail 'cancel setup'
    old=$(snapshot); : > "$C/log"
    for input in '' 'YES' $'YES\n' $'YES\nYES' $'YES\nno\n'; do
        if [[ $action == update-cert ]]; then
            reject toolbox_vmess "$action" "$T/new.pem" "$T/new.key" < <(printf '%s' "$input") > "$C/management-output" 2>&1
        else reject toolbox_vmess "$action" < <(printf '%s' "$input") > "$C/management-output" 2>&1; fi
        old_intact; no_manage_mutation
    done
    uninstall_yes || fail 'cancel teardown'
done
pass 'all management confirmations reject EOF including unterminated second YES'
for fault in foreign-link dropin inode enabled-state enable-fail swap-after-enable race-link wants-symlink enable-readback enable-signal; do
    fixture "boot-$fault"; install_yes || fail 'fault setup'; : > "$C/log"
    case $fault in
        foreign-link) mkdir "$C/units/multi-user.target.wants"; ln -s "$(vmess_unit)" "$C/units/multi-user.target.wants/terry-toolbox-vmess.service" ;;
        dropin) mkdir "$(vmess_unit).d" ;;
        inode) cp "$(vmess_unit)" "$C/replacement"; mv "$C/replacement" "$(vmess_unit)" ;;
        enabled-state) BOOT_STATE=enabled-runtime ;;
        enable-fail) BOOT_FAIL=1 ;;
        enable-readback) BOOT_READBACK_FAIL=1 ;;
        enable-signal) BOOT_SIGNAL=1 ;;
        wants-symlink) ln -s "$C/scratch" "$C/units/multi-user.target.wants" ;;
        swap-after-enable) BOOT_SWAP=1 ;;
        race-link) vmess_confirm() { mkdir "$C/units/multi-user.target.wants"; ln -s /unknown "$C/units/multi-user.target.wants/terry-toolbox-vmess.service"; } ;;
    esac
    reject boot_yes enable-boot
    [[ -f $(vmess_bin) && -f $(vmess_unit) ]] || fail 'boot failure deleted owned resources'
    ! grep -Eq 'systemctl (start|stop)' "$C/log" || fail 'boot failure touched runtime'
    if [[ $fault == enable-fail ]]; then vmess_fs verify --complete >/dev/null || fail 'failed enable must retain verifiable changed policy'; fi
done
pass 'unknown links/dropins/state/inode/race and failed enable retain resources'
fixture boot-link-tamper
install_yes || fail 'tamper setup'; boot_yes enable-boot || fail 'tamper enable'
rm "$C/units/multi-user.target.wants/terry-toolbox-vmess.service"; ln -s /unknown "$C/units/multi-user.target.wants/terry-toolbox-vmess.service"
: > "$C/log"; reject boot_yes disable-boot; reject uninstall_yes
[[ $(readlink "$C/units/multi-user.target.wants/terry-toolbox-vmess.service") == /unknown ]] || fail 'unknown link removed'; no_manage_mutation
pass 'changed enabled symlink is not disabled/deleted/adopted'
for fault in disable-fail disable-readback show-fail job-race; do
    fixture "boot-$fault"; install_yes || fail 'disable fault setup'; boot_yes enable-boot || fail 'disable fault enable'; : > "$C/log"
    case $fault in
        disable-fail) BOOT_FAIL=1 ;;
        disable-readback) BOOT_STATE=enabled ;;
        show-fail) SHOW_FAIL=1 ;;
        job-race) vmess_confirm() { EXTRA_JOB=92; } ;;
    esac
    reject boot_yes disable-boot
    [[ -f $(vmess_bin) && -f $(vmess_unit) ]] || fail 'disable failure deleted service'
    ! grep -Eq 'systemctl (start|stop)' "$C/log" || fail 'disable failure touched runtime'
    if [[ $fault == show-fail || $fault == job-race ]]; then no_manage_mutation; fi
done
pass 'disable failure/exact readback failure/unknown service/pending-job race reject safely'
# The lock lives on tmpfs: a reboot replaces its parent inode while the sealed
# etc/binary/unit parents persist. Only the lock directory itself is a gate.
reboot() { # a different directory object at the same path; inodes may be reused
    local old spare="$C/inode-spare-$RANDOM"
    old=$(stat -c %i -- "$1")
    mkdir -m 755 "$spare"
    rmdir "$1"; mv "$spare" "$1"
    [[ $(stat -c %i -- "$1") != "$old" ]] || fail "reboot simulation reused the inode of $1"
}
fixture reboot-lock-parent
install_yes || fail 'reboot setup'
reboot "$C/run"
vmess_fs verify --complete >/dev/null || fail 'boot-local lock parent inode broke the ledger'
boot_yes enable-boot || fail 'enable after reboot-like lock parent change'
boot_yes disable-boot || fail 'disable after reboot-like lock parent change'
toolbox_vmess status >/dev/null 2>&1 || fail 'status after reboot-like lock parent change'
uninstall_yes || fail 'uninstall after reboot-like lock parent change'; empty_targets
pass 'boot-local lock parent inode is not a persistent ledger gate'
fixture reboot-legacy-parents
install_yes || fail 'legacy parents setup'
# Older ledgers sealed the boot-local lock parent too; it must stay accepted.
python3 - "$(vmess_etc)" "$(dirname "$(vmess_lock)")" <<'PY'
import json, os, sys
etc, parent = sys.argv[1:]
path = etc + '/manifest.json'
m = json.load(open(path))
st = os.stat(parent)
m['parents'][parent] = f'{st.st_dev}:{st.st_ino}'
raw = (json.dumps(m, sort_keys=True) + '\n').encode()
open(path, 'wb').write(raw)
open(etc + '/manifest.sha256', 'w').write(__import__('hashlib').sha256(raw).hexdigest() + '\n')
PY
vmess_fs verify --complete >/dev/null || fail 'ledger carrying the lock parent rejected'
reboot "$C/run"
vmess_fs verify --complete >/dev/null || fail 'stale sealed lock parent broke a rebooted ledger'
uninstall_yes || fail 'legacy parents teardown'; empty_targets
pass 'ledgers sealed with the boot-local lock parent stay readable across reboot'
fixture reboot-parent-change
install_yes || fail 'persistent parent setup'
reboot "$C/run"
mv "$C/bin" "$C/bin.old"; mkdir -m 755 "$C/bin"
reject toolbox_vmess status >/dev/null 2>&1
mv "$C/bin.old" "$C/bin" 2>/dev/null || { rmdir "$C/bin"; mv "$C/bin.old" "$C/bin"; }
pass 'persistent binary parent change still refuses despite a rebooted lock parent'
# Foreign-named dependency links are accepted by systemd and deleted by disable.
fixture boot-dep-other
mkdir "$C/units/multi-user.target.wants"; ln -s /elsewhere-other.service "$C/units/multi-user.target.wants/other.service"
install_yes || fail 'unrelated dependency link blocked install'
boot_yes enable-boot || fail 'unrelated dependency link blocked enable'
boot_yes disable-boot || fail 'unrelated dependency link blocked disable'
[[ -L $C/units/multi-user.target.wants/other.service ]] || fail 'unrelated dependency link was deleted'
uninstall_yes || fail 'unrelated dependency teardown'; empty_targets
pass 'dependency links to other units are ignored and survive disable'
for kind in wants requires upholds; do
    fixture "boot-dep-$kind"; install_yes || fail "$kind setup"
    mkdir "$C/units/multi-user.target.$kind"; ln -s "$(vmess_unit)" "$C/units/multi-user.target.$kind/other-vmess.service"
    : > "$C/log"
    reject boot_yes enable-boot
    reject uninstall_yes
    [[ -L $C/units/multi-user.target.$kind/other-vmess.service ]] || fail "$kind foreign link deleted"
    [[ -f $(vmess_bin) && -f $(vmess_etc)/manifest.json ]] || fail "$kind foreign link deleted resources"
    no_manage_mutation
done
pass 'foreign-named .wants/.requires/.upholds links to this unit refuse enable and uninstall'
fixture boot-disable-foreign-race
install_yes || fail 'disable race setup'; boot_yes enable-boot || fail 'disable race enable'; : > "$C/log"
DISABLE_FOREIGN=1 reject boot_yes disable-boot
grep -q 'systemctl disable' "$C/log" || fail 'disable race never reached systemctl'
[[ -f $(vmess_bin) && -f $(vmess_etc)/manifest.json ]] || fail 'disable race deleted resources'
! grep -Eq 'systemctl (start|stop)' "$C/log" || fail 'disable race touched runtime'
[[ $(<"$C/management-output") == *'链接'* ]] || fail 'leftover link reason missing'
pass 'a link left behind by systemctl disable is detected, not assumed removed'
# A swapped lock inode must stop the transaction before the disruptive step.
swap_lock() { # a different directory object at the lock path (inodes get reused)
    local old spare="$C/lock-spare-$RANDOM"
    old=$(stat -c %i -- "$(vmess_lock)")
    mkdir -m 700 "$spare"; rmdir "$(vmess_lock)"; mv "$spare" "$(vmess_lock)"
    [[ $(stat -c %i -- "$(vmess_lock)") != "$old" ]] || fail 'lock swap reused the inode'
}
fixture lock-swap-install
vmess_confirm() { swap_lock; }
reject install_yes
[[ ! -e $(vmess_etc) ]] || fail 'install published after losing the lock'
pass 'lock swapped during install is refused before publication'
fixture lock-swap-boot
install_yes || fail 'lock boot setup'; : > "$C/log"
vmess_confirm() { swap_lock; }
reject boot_yes enable-boot
[[ ! -L $C/units/multi-user.target.wants/terry-toolbox-vmess.service ]] || fail 'boot committed without the lock'
no_manage_mutation
pass 'lock swapped before a boot change refuses to commit'
fixture lock-swap-uninstall
install_yes || fail 'lock uninstall setup'; : > "$C/log"
vmess_confirm() { swap_lock; }
reject uninstall_yes
[[ -f $(vmess_etc)/manifest.json ]] || fail 'uninstall deleted after losing the lock'
! grep -q 'systemctl stop' "$C/log" || fail 'uninstall stopped service without the lock'
pass 'lock swapped before uninstall refuses to stop'
fixture lock-swap-cert
install_yes || fail 'lock cert setup'; old=$(snapshot); : > "$C/log"
vmess_confirm() { swap_lock; }
reject update_yes
old_intact; no_manage_mutation
pass 'lock swapped before a certificate update refuses to stop/exchange'
for action in uninstall cert-stop cert-start; do
    fixture "lock-during-$action"
    install_yes || fail 'lock during lifecycle setup'; old=$(snapshot); : > "$C/log"
    SWAP_LOCK_AT=stop
    if [[ $action == cert-start ]]; then SWAP_LOCK_AT=start; fi
    if [[ $action == uninstall ]]; then reject uninstall_yes; else reject update_yes; fi
    [[ -f $(vmess_etc)/manifest.json && -f $(vmess_bin) && -d $(vmess_lock) ]] || fail 'lost lock discarded owned resources'
    if [[ $action != cert-start ]]; then
        old_intact
        ! grep -q 'systemctl start' "$C/log" || fail 'started service after losing the lock at stop'
    fi
done
pass 'lock replaced during service stop/start prevents deletion, exchange, or successful commit'
# boot-status is a read-only dispatch that consumes no confirmation input.
fixture boot-status-dispatch
install_yes || fail 'boot-status setup'; : > "$C/log"; old=$(snapshot)
printf 'unrelated\n' | toolbox_vmess boot-status >/dev/null 2>&1 || fail 'boot-status dispatch failed'
no_manage_mutation; old_intact
printf '6\n' | toolbox_vmess >/dev/null 2>&1 || fail 'menu boot-status dispatch failed'
no_manage_mutation; old_intact
reject toolbox_vmess boot-status extra >/dev/null 2>&1
pass 'boot-status dispatch is read-only and rejects unexpected arguments'
legacy_fixture() {
    python3 - "$(vmess_etc)" "$(vmess_unit)" <<'PY'
import sys,json,hashlib,os
etc,unit=sys.argv[1:]; data=open(unit,'rb').read().replace(b'[Install]\nWantedBy=multi-user.target\n',b'# Deliberately no [Install] section: no automatic boot enablement.\n')
with open(unit,'wb') as f:f.write(data)
m=json.load(open(etc+'/manifest.json'));m['version']=1;del m['boot'];m['entries'][unit]['sha256']=hashlib.sha256(data).hexdigest()
raw=(json.dumps(m,sort_keys=True)+'\n').encode()
with open(etc+'/manifest.json','wb') as f:f.write(raw)
with open(etc+'/manifest.sha256','w') as f:f.write(hashlib.sha256(raw).hexdigest()+'\n')
PY
}
fixture legacy
install_yes || fail 'legacy setup'; legacy_fixture; old=$(snapshot); : > "$C/log"
toolbox_vmess boot-status >/dev/null 2>&1 || fail 'legacy readonly status'; old_intact; no_manage_mutation
boot_yes enable-boot || fail 'legacy migration failed'
[[ $(vmess_fs boot-info) == '2 enabled' ]] || fail 'legacy not migrated'
uninstall_yes || fail 'legacy teardown'; empty_targets
fixture legacy-update
install_yes || fail 'legacy update setup'; legacy_fixture
update_yes || fail 'legacy controlled certificate update failed'
[[ $(vmess_fs boot-info) == '1 disabled' ]] || fail 'certificate update implicitly migrated boot policy'
uninstall_yes || fail 'legacy update teardown'; empty_targets
fixture legacy-tamper
install_yes || fail 'legacy tamper setup'; legacy_fixture; printf '\n' >> "$(vmess_etc)/config.json"; : > "$C/log"
reject boot_yes enable-boot; no_manage_mutation
pass 'legacy full inode/hash/resources verified before explicit migration; tamper refuses'
fixture cert-happy
install_yes || fail 'cert setup'; boot_yes enable-boot || fail 'cert boot setup'
config_before=$(sha256sum "$(vmess_etc)/config.json" "$(vmess_etc)/client.json" "$(vmess_etc)/vmess.txt")
update_yes || fail "update failed $C/update-output"
[[ $(sha256sum "$(vmess_etc)/config.json" "$(vmess_etc)/client.json" "$(vmess_etc)/vmess.txt") == "$config_before" ]] || fail 'update regenerated credentials/config'
cmp -s "$T/new.pem" "$(vmess_etc)/cert.pem" && cmp -s "$T/new.key" "$(vmess_etc)/key.pem" || fail 'new pair not installed'
vmess_fs verify --complete >/dev/null || fail 'updated ledger'; [[ $(vmess_fs boot-info) == '2 enabled' ]] || fail 'update changed boot'
uninstall_yes || fail 'cert teardown'; empty_targets
pass 'new pair + sealed ledger transaction preserves config/UUID/client/boot'
# Simulate elapsed validity after installation by resealing a fixture-only pair.
# Candidate verification stays real; service execution/transport remain mocked.
for old_kind in expired near-expiry; do
    fixture "cert-recovery-$old_kind"; install_yes || fail 'recovery install setup'
    python3 - "$ROOT/tests/certificate-fixture.py" "$C" "$old_kind" <<'PY'
import datetime,hashlib,json,subprocess,sys
script,p,kind=sys.argv[1:];now=datetime.datetime.now(datetime.timezone.utc)
end=now+datetime.timedelta(minutes=30) if kind=='near-expiry' else now-datetime.timedelta(days=1)
fmt=lambda v:v.strftime('%Y%m%d%H%M%SZ')
subprocess.run([sys.executable,script,p+'/old.pem',p+'/old.key',fmt(now-datetime.timedelta(days=3)),fmt(end)],check=True)
root=p+'/etc';m=json.load(open(root+'/manifest.json'))
for dest,src in [('cert.pem','old.pem'),('key.pem','old.key')]:
 data=open(p+'/'+src,'rb').read();path=root+'/'+dest
 with open(path,'wb') as f:f.write(data)
 m['entries'][path]['sha256']=hashlib.sha256(data).hexdigest()
raw=(json.dumps(m,sort_keys=True)+'\n').encode()
with open(root+'/manifest.json','wb') as f:f.write(raw)
with open(root+'/manifest.sha256','w') as f:f.write(hashlib.sha256(raw).hexdigest()+'\n')
with open(p+'/trust.pem','wb') as f:f.write(open(p+'/old.pem','rb').read()+open(sys.argv[2]+'/../new.pem','rb').read())
PY
    export TOOLBOX_NET_CAFILE="$C/trust.pem"
    vmess_certificate() { vmess_real_certificate "$@"; }
    vmess_existing_certificate || fail 'expired/near-expiry owned identity'
    old=$(snapshot); : > "$C/log"
    if [[ $old_kind == expired ]]; then
        reject toolbox_vmess update-cert "$C/old.pem" "$C/old.key" <<< $'YES\nYES' > "$C/update-output" 2>&1
        old_intact; no_manage_mutation
    fi
    update_yes || fail 'cannot replace expired/near-expiry owned pair'
    cmp -s "$T/new.pem" "$(vmess_etc)/cert.pem" || fail 'recovery did not deploy valid new pair'
    vmess_fs verify --complete >/dev/null || fail 'recovery ownership changed'
    uninstall_yes || fail 'recovery teardown'; empty_targets
    export TOOLBOX_NET_CAFILE="$T/cert.pem"
done
pass 'expired/near-expiry owned pair recovers via update-cert; expired new candidate still refuses before stop'
for fault in validation stop start tls signal start-stop-fail tamper-start race-confirm; do
    fixture "cert-$fault"; install_yes || fail 'fault cert setup'; old=$(snapshot); : > "$C/log"
    case $fault in validation) export VMESS_MANAGEMENT_VALIDATE_FAIL=1 ;; stop) STOP_FAIL=1 ;; start) START_ONCE_FAIL=1 ;; tls) TLS_ONCE_FAIL=1 ;;
        signal) SIGNAL_ONCE_START=1 ;; start-stop-fail) START_ONCE_FAIL=1 ROLLBACK_STOP_FAIL=1 ;; tamper-start) SWAP_AT_START=1 ;;
        race-confirm) vmess_confirm() { printf '\n' >> "$(vmess_etc)/key.pem"; } ;; esac
    reject update_yes
    [[ -f $(vmess_bin) && -f $(vmess_etc)/cert.pem && -f $(vmess_etc)/key.pem ]] || fail 'update failure deleted resources'
    case $fault in
        validation) old_intact; no_manage_mutation ;;
        start|tls|signal) old_intact; vmess_running 24443 127.0.0.1 || fail 'rollback did not restore running service'; vmess_fs verify --complete >/dev/null || fail 'restored ledger' ;;
        stop) old_intact ;;
        start-stop-fail) cmp -s "$T/new.pem" "$(vmess_etc)/cert.pem" || fail 'failed rollback stop must not swap back'; [[ $(<"$C/update-output") == *'保留'* ]] || fail 'failed rollback stop must preserve backup' ;;
        race-confirm) no_manage_mutation ;;
        tamper-start) [[ $(<"$C/update-output") == *'保留'* ]] || fail 'tamper must retain evidence' ;;
    esac
done
pass 'new config failure/stop/start/TLS/rollback/SIGTERM/tamper failure gates'
# Inject below the real FS transaction at atomic renameat2, without mocking the
# ledger verifier. Partial pair/manifest exchanges must recover or retain.
for fault in partial-io partial-signal backup-tamper staged-pair-tamper; do
    fixture "cert-$fault"; install_yes || fail 'atomic failure setup'; old=$(snapshot); : > "$C/log"
    if [[ $fault == staged-pair-tamper ]]; then
        vmess_certificate() {
            if [[ $1 == */new-cert.pem ]]; then printf '\n' >> "$1"; fi
            return 0
        }
        reject update_yes; old_intact; no_manage_mutation
        continue
    fi
    python3 - "$T/inject/sitecustomize.py" "$fault" <<'PY'
import sys
path,fault=sys.argv[1:]
code='''import ctypes,os,signal
old=ctypes.CDLL
class Wrapper:
    def __init__(self,*a,**kw):self.library=old(*a,**kw)
    def __getattr__(self,name):return getattr(self.library,name)
    def renameat2(self,a,an,b,bn,flags):
        result=self.library.renameat2(a,an,b,bn,flags)
        marker=os.environ['C']+'/atomic-fault'
        if an==b'cert.pem' and result==0 and not os.path.exists(marker):
            open(marker,'w').close()
            ACTION
        return result
ctypes.CDLL=Wrapper
'''
action={
'partial-io':"raise OSError('injected partial certificate exchange I/O failure')",
'partial-signal':"os.kill(os.getppid(),signal.SIGTERM)",
'backup-tamper':"fd=os.open(bn,os.O_WRONLY|os.O_APPEND,dir_fd=b);os.write(fd,b'\\n');os.close(fd);raise OSError('injected backup tamper')"
}[fault]
with open(path,'w') as f:f.write(code.replace('ACTION',action))
PY
    PYTHONPATH="$T/inject" PYTHONDONTWRITEBYTECODE=1 reject update_yes
    [[ -f $C/atomic-fault ]] || fail 'fault did not reach atomic exchange'
    if [[ $fault == backup-tamper ]]; then
        [[ $(<"$C/update-output") == *'保留'* ]] || fail 'untrusted backup not retained'
    else old_intact; vmess_running 24443 127.0.0.1 || fail 'partial rollback did not restart original'; fi
done
pass 'partial atomic exchange I/O + SIGTERM restore; changed backup/new pair retain/refuse'
fixture boot-atomic-race
install_yes || fail 'boot atomic setup'; : > "$C/log"
python3 - "$T/inject/sitecustomize.py" <<'PY'
import sys
with open(sys.argv[1],'w') as f:f.write('''import os
old=os.link
def race(src,dst,*args,**kw):
    if dst=='terry-toolbox-vmess.service':
        os.symlink('/unknown',dst,dir_fd=kw['dst_dir_fd'])
    return old(src,dst,*args,**kw)
os.link=race
''')
PY
PYTHONPATH="$T/inject" PYTHONDONTWRITEBYTECODE=1 reject boot_yes enable-boot
[[ $(readlink "$C/units/multi-user.target.wants/terry-toolbox-vmess.service") == /unknown ]] || fail 'atomic race adopted unknown link'
no_manage_mutation
pass 'exclusive boot-link publication refuses actual linkat race'
# Actual new certificate failures, not a mock checker always returning false.
fixture real-new-inputs
install_yes || fail 'real-input setup'; old=$(snapshot); : > "$C/log"
vmess_certificate() { vmess_real_certificate "$@"; }
command cat "$T/cert.pem" "$T/new.pem" > "$T/trust.pem"
export TOOLBOX_NET_CAFILE="$T/trust.pem"
for kind in hostname key trust expired future encrypted; do
    cert="$T/new.pem"; key="$T/new.key"
    case $kind in
        hostname) openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=other.example.com -addext subjectAltName=DNS:other.example.com -keyout "$C/wrong.key" -out "$C/wrong.pem" >/dev/null 2>&1; cert="$C/wrong.pem"; key="$C/wrong.key" ;;
        key) key="$T/key.pem" ;;
        trust) TOOLBOX_NET_CAFILE="$T/cert.pem" ;;
        expired|future) if [[ $kind == expired ]]; then start=20200101000000Z; end=20200102000000Z; else start=20990101000000Z; end=20990102000000Z; fi
            python3 "$ROOT/tests/certificate-fixture.py" "$C/$kind.pem" "$C/$kind.key" "$start" "$end"; cert="$C/$kind.pem"; key="$C/$kind.key" ;;
        encrypted) openssl pkey -in "$T/new.key" -aes-256-cbc -passout pass:test-only -out "$C/encrypted.key" >/dev/null 2>&1; key="$C/encrypted.key" ;;
    esac
    reject toolbox_vmess update-cert "$cert" "$key" <<< $'YES\nYES' > "$C/update-output" 2>&1
    old_intact; no_manage_mutation; TOOLBOX_NET_CAFILE="$T/trust.pem"
done
update_yes || fail 'real trusted new pair positive control'
pass 'real new cert hostname/key/trust/expiry/not-before/encryption rejects + positive control'
printf 'VMess management suite complete; systemd/transport mocked, host unmodified.\n'
