#!/usr/bin/env bash
# Real code and pinned source, MOCKED destructive entry; no host boot writes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if (( BASH_VERSINFO[0] < 4 )); then
    printf 'reinstall fixtures require Bash 4+ and Linux /proc; no host mutation performed.\n' >&2; exit 99
fi
case_root=$(mktemp -d "${TMPDIR:-/tmp}/reinstall-tests.XXXXXX")
chmod 0700 "$case_root"
export HOME="$case_root/home"
mkdir -p "$HOME" "$case_root/deny"
for c in reboot shutdown poweroff halt mount umount dd mkfs parted sfdisk fdisk \
         grub-reboot grub-editenv update-grub efibootmgr apk apt-get systemctl rc-service wget curl; do
    printf '#!/usr/bin/env bash\nprintf "FORBIDDEN boundary: %s\\n" >&2\nexit 99\n' "$c" > "$case_root/deny/$c"
    chmod 0755 "$case_root/deny/$c"
done
real_curl=$(command -v curl)
export PATH="$case_root/deny:$PATH"
if [[ ! -f "$ROOT/modules/reinstall.sh" ]]; then
    printf 'FAIL: M3 toolbox_reinstall interface absent\n' >&2; exit 1
fi
source "$ROOT/modules/reinstall-provenance.sh"
source "$ROOT/modules/reinstall.sh"
# Exercise the real shared dependency interaction with only package execution
# mocked. No fixture may invoke the host package manager or change boot state.
source "$ROOT/modules/dependencies.sh"
declare -F toolbox_reinstall >/dev/null || { printf 'FAIL: M3 interface absent\n' >&2; exit 1; }
# Upstream fixtures must be REAL downloaded bytes, explicitly verified by the
# production fetch/derive helper. Default cached evidence; override for CI cache.
upstream=${REINSTALL_TEST_UPSTREAM:-$case_root/upstream}
python3 - "$upstream" <<'PY'
import os,stat,sys
p=os.path.abspath(sys.argv[1])
for i in range(1,len(p.split('/'))+1):
 q='/'.join(p.split('/')[:i]) or '/'
 if os.path.lexists(q) and stat.S_ISLNK(os.lstat(q).st_mode):sys.exit('fixture cache symlink refused')
if os.path.exists(p):
 s=os.lstat(p)
 if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.geteuid() or s.st_mode&0o022:sys.exit('fixture cache directory ownership/mode refused')
else:os.makedirs(p,mode=0o700)
PY
for f in reinstall.sh trans.sh initrd-network.sh; do
    # Download REAL immutable fixtures on cache miss, with normal TLS; never run
    # upstream --help/entry. Cached files still pass production SHA verification.
    if [[ ! -f $upstream/$f ]]; then
        mkdir -p "$upstream"
        "$real_curl" --proto '=https' --proto-redir '=https' --tlsv1.2 -fL \
            --connect-timeout 15 --max-time 120 \
            "https://raw.githubusercontent.com/bin456789/reinstall/$_TOOLBOX_REINSTALL_COMMIT/$f" \
            -o "$upstream/$f" || exit 1
    fi
done
_toolbox_reinstall_download() { cp "$upstream/$1" "$2"; }
real_fetch=$(declare -f _toolbox_reinstall_fetch)
count=0
pass() { count=$((count+1)); printf 'PASS %02d %s\n' "$count" "$1"; }
fail() { printf 'FAIL: %s; evidence=%s\n' "$*" "$case_root" >&2; exit 1; }
_toolbox_reinstall_derive "$upstream/reinstall.sh" "$case_root/derived-reviewed.sh" || fail 'reviewed derivation'
python3 - "$case_root/derived-reviewed.sh" <<'PY' || fail 'boot executable transport'
import sys
s=open(sys.argv[1]).read()
assert 'mirror=http://mirror.nju.edu.cn/alpine/v$releasever' not in s
assert 'mirror=http://dl-cdn.alpinelinux.org/alpine/v$releasever' not in s
assert 'local url=http://$mirror/dists/$nextos_codename/' not in s
assert 'curl -Lo $tmp/tmp.deb http://$mirror/' not in s
assert 'is_in_china && mirror=http://mirror.nju.edu.cn/alpine' not in s
assert 'command curl --insecure --connect-timeout' not in s
PY
pass 'reviewed source digest and HTTPS boot images/injected packages'
_toolbox_reinstall_root() { return 0; }
_toolbox_reinstall_has() {
    [[ $1 != "${MISSING:-}" && $1 != "${MISSING2:-}" ]] || [[ -e $fixture/deps-installed/$1 ]]
}
_toolbox_deps_has() { _toolbox_reinstall_has "$@"; }
_toolbox_deps_os() { printf 'debian\n'; }
_toolbox_deps_root() { return 0; }
apt-get() {
    local c stolen
    printf '%s\n' "$*" >> "$fixture/package-calls"
    # The real core must disconnect the package command from menu/confirmation
    # stdin; a package helper must never consume the next destructive answer.
    if IFS= read -r stolen; then
        printf 'package manager consumed confirmation input\n' >&2; return 99
    fi
    case ${1:-} in
        update) [[ ${DEPS_INSTALL_MODE:-ok} != update-fail ]] || return 71;;
        install)
            [[ ${DEPS_INSTALL_MODE:-ok} != install-fail ]] || return 72
            if [[ ${DEPS_INSTALL_MODE:-ok} != still-missing ]]; then
                for c in "${MISSING:-}" "${MISSING2:-}"; do [[ -z $c ]] || : > "$fixture/deps-installed/$c"; done
            fi;;
        *) printf 'unexpected package operation\n' >&2; return 99;;
    esac
    printf 'MOCK PACKAGE STDOUT\n'
}
# Capture the production detector BEFORE mocking it (Alpine/musl path is real).
real_container=$(declare -f _toolbox_reinstall_container)
_toolbox_reinstall_container() { return "${CONTAINER_RC:-1}"; }
virt-what() { printf '%s\n' "${VIRTWHAT-kvm}"; }
_toolbox_reinstall_mbr_grub() { [[ ${MBR:-grub} == grub ]]; }
_toolbox_reinstall_boot_id() { printf '%s\n' "${BOOT_ID:-fixture-boot-identity}"; }
uname() { [[ $1 != -m ]] || { printf '%s\n' "${MOCK_ARCH:-x86_64}"; return; }; command uname "$@"; }
_toolbox_reinstall_lsblk() { command cat "$fixture/lsblk.json"; }
_toolbox_reinstall_mounts() { command cat "$fixture/mounts.json"; }
_toolbox_reinstall_efi() { command cat "$fixture/efi"; }
mokutil() { printf 'SecureBoot disabled\n'; }
setup() {
    # Consume case knobs from the prefix, then clear them so nothing leaks.
    local want_init=${INIT_MODE:-systemd} want_archive=${ARCHIVE_MODE:-plain}
    unset MISSING MISSING2 DEPS_INSTALL_MODE CONTAINER_RC MOCK_FAIL RUNTIME_BAD CFG_BAD RESET_FAIL RESET_BAD BOOT_ID MBR ARCHIVE_BAD MOCK_ARCH INIT_MODE ARCHIVE_MODE VIRTWHAT
    fixture=$(mktemp -d "$case_root/case.XXXXXX")
    export TOOLBOX_REINSTALL_ROOT="$fixture/root" TOOLBOX_REINSTALL_STATE="$fixture/state"
    mkdir -p "$fixture/root/boot/grub" "$fixture/root/proc/sys/kernel/random" "$fixture/root/proc/1" \
        "$fixture/root/sys/class/dmi/id" "$fixture/deps-installed"
    printf 'Mock Product\n' > "$fixture/root/sys/class/dmi/id/product_name"
    # PID1 identification fixture: systemd default, OpenRC on demand.
    case $want_init in
        systemd) printf 'systemd\n' > "$fixture/root/proc/1/comm";;
        openrc) printf 'init\n' > "$fixture/root/proc/1/comm"
                mkdir -p "$fixture/root/run/openrc" "$fixture/root/sbin"; : > "$fixture/root/sbin/openrc";;
        *) printf '%s\n' "$want_init" > "$fixture/root/proc/1/comm";;
    esac
    fixture_archive=$want_archive
    printf 'menuentry original {}\n' > "$fixture/root/boot/grub/grub.cfg"
    printf 'saved_entry=original\n' > "$fixture/root/boot/grub/grubenv"
    printf '{"blockdevices":[{"name":"/dev/vda","kname":"vda","type":"disk","pkname":null,"fstype":null,"size":2147483648,"model":"MOCK KVM","serial":"fixture-owned","wwn":"fixture","maj:min":"252:0","ro":false,"rm":false,"ptuuid":"12345678","children":[{"name":"/dev/vda1","kname":"vda1","type":"part","pkname":"vda","fstype":"ext4"}]}]}\n' > "$fixture/lsblk.json"
    printf '{"filesystems":[{"target":"/","source":"/dev/vda1","fstype":"ext4","options":"rw"}]}\n' > "$fixture/mounts.json"
    : > "$fixture/calls"
    : > "$fixture/package-calls"
    export TOOLBOX_REINSTALL_SSH_KEY_FILE="$case_root/key.pub"
    eval "$real_fetch"
}
# Only task-owned local key creation, no password/default credentials anywhere.
ssh-keygen -q -t ed25519 -N '' -f "$case_root/key"
ssh-keygen -q -t ed25519 -N '' -f "$case_root/other-key"
_toolbox_reinstall_run_upstream() {
    printf '%q ' "$@" >> "$fixture/calls"; printf '\n' >> "$fixture/calls"
    [[ $1 == "$fixture/state/active/reinstall.sh" ]] || return 99
    shift
    if [[ $1 == reset ]]; then
        [[ ${RESET_FAIL:-0} != 1 ]] || { printf 'actual fixture reset failure\n' >&2; return 23; }
        [[ ${RESET_BAD:-0} != 1 ]] || return 0
        rm -f "$fixture/root/reinstall-vmlinuz" "$fixture/root/reinstall-initrd"
        rm -rf "$fixture/root/reinstall-tmp"
        # Real upstream reset removes marker block with sed -i, leaving an empty
        # exclusively-created custom.cfg under a different inode.
        if [[ ! -d $fixture/root/sys/firmware/efi ]]; then
            printf '' > "$fixture/root/boot/grub/custom.cfg.reset"
            chmod 0600 "$fixture/root/boot/grub/custom.cfg.reset"
            mv "$fixture/root/boot/grub/custom.cfg.reset" "$fixture/root/boot/grub/custom.cfg"
        fi
        printf 'menuentry original {}\n' > "$fixture/root/boot/grub/grub.cfg"
        printf 'saved_entry=original\n' > "$fixture/root/boot/grub/grubenv"
        if [[ -d $fixture/root/sys/firmware/efi ]]; then
            rm -rf "$fixture/root/boot/efi/EFI/reinstall"
            printf 'BootCurrent: 0000\nBootOrder: 0000\nBoot0000* original HD(...)\\EFI\\debian\\grubx64.efi\n' > "$fixture/efi"
        fi
        return 0
    fi
    [[ ${MOCK_FAIL:-0} != 1 ]] || { printf 'actual fixture upstream failure\n' >&2; return 17; }
    [[ $3 == --username && $4 == root && $5 == --ssh-key && $6 == "$fixture/state/active/key.pub" && $7 == --target-disk && $8 == /dev/vda ]] || return 99
    local cfg="$fixture/root/boot/grub/custom.cfg" pin=$_TOOLBOX_REINSTALL_COMMIT
    if [[ -d $fixture/root/sys/firmware/efi ]]; then
        mkdir -p "$fixture/root/boot/efi/EFI/reinstall"
        cfg="$fixture/root/boot/efi/EFI/reinstall/grub.cfg"
        printf 'owned-fixture-efi\n' > "$fixture/root/boot/efi/EFI/reinstall/grubx64.efi"
        # Pinned upstream uses --create-only, so BootOrder stays unchanged.
        printf 'BootCurrent: 0000\nBootOrder: 0000\nBootNext: 0001\nBoot0000* original HD(...)\\EFI\\debian\\grubx64.efi\nBoot0001* reinstall (%s %s) HD(...)\\EFI\\reinstall\\grubx64.efi\n' "$1" "$2" > "$fixture/efi"
    fi
    [[ ${CFG_BAD:-0} != 1 ]] || pin=main
    printf "### BEGIN reinstall.sh ###\nmenuentry 'reinstall (%s %s)' {\nlinux /reinstall-vmlinuz extra_confhome='https://raw.githubusercontent.com/bin456789/reinstall/%s' extra_main_disk=12345678\n}\n### END reinstall.sh ###\n" "$1" "$2" "$pin" > "$cfg"
    if [[ ! -d $fixture/root/sys/firmware/efi ]]; then
        printf 'next_entry=reinstall (%s %s)\n' "$1" "$2" > "$fixture/root/boot/grub/grubenv"
    fi
    printf 'fixture kernel\n' > "$fixture/root/reinstall-vmlinuz"
    printf 'fixture initrd (MOCK, not an actual install)\n' > "$fixture/root/reinstall-initrd"
    mkdir -p "$fixture/root/reinstall-tmp/initrd/configs"
    local trans=trans.sh
    [[ $1 != debian ]] || trans=expected-debian-trans.sh
    cp "$fixture/state/active/$trans" "$fixture/root/reinstall-tmp/initrd/trans.sh"
    cp "$fixture/state/active/initrd-network.sh" "$fixture/root/reinstall-tmp/initrd/initrd-network.sh"
    cp "$fixture/state/active/key.pub" "$fixture/root/reinstall-tmp/initrd/configs/ssh_keys"
    [[ ${RUNTIME_BAD:-0} != 1 ]] || printf 'tamper\n' >> "$fixture/root/reinstall-tmp/initrd/trans.sh"
    # Synthetic newc container around REAL upstream bytes. Explicitly not an OS
    # image; production's final archive parser executes unchanged.
    python3 - "$fixture/root" "${fixture_archive:-plain}" <<'PY'
import gzip,sys
p,mode=sys.argv[1:]
def member(b,name,data,kind=0o100644,links=1):
 n=name.encode()+b'\0';fields=[1,kind,0,0,links,0,len(data),0,0,0,0,len(n),0]
 b.extend(b'070701'+b''.join(('%08x'%v).encode() for v in fields));b.extend(n);b.extend(b'\0'*(-len(b)%4));b.extend(data);b.extend(b'\0'*(-len(b)%4))
def body(extra=()):
 b=bytearray()
 if mode in ('rootdir','rootfile','duproot'):
  member(b,'.',b'',0o040755 if mode!='rootfile' else 0o100644)
  if mode=='duproot':member(b,'.',b'',0o040755)
 for n in ('trans.sh','initrd-network.sh','configs/ssh_keys'):
  data=open(p+'/reinstall-tmp/initrd/'+n,'rb').read()
  member(b,n,data,0o040000 if (n=='trans.sh' and mode=='dirwanted') else 0o100644,2 if (n=='trans.sh' and mode=='hardwanted') else 1)
  if n=='trans.sh' and mode=='dup':member(b,n,data)
 for kind,name in extra:member(b,name,b'x',kind)
 member(b,'TRAILER!!!',b'')
 return bytes(b)
extra=((0o010000,'weird'),) if mode=='fifo' else ((0o150000,'weird'),) if mode=='badtype' else ((0o100644,'../evil'),) if mode=='dotdot' else ()
raw=body(extra)
out=gzip.compress(raw)
if mode=='zero_tail':out+=b'\0'*512
elif mode=='junk_tail':out+=b'junk'
elif mode=='second_archive':out+=gzip.compress(body())
open(p+'/reinstall-initrd','wb').write(out)
PY
    [[ ${ARCHIVE_BAD:-0} != 1 ]] || printf 'invalid archive\n' > "$fixture/root/reinstall-initrd"
}
prep() { printf 'YES\nyes\n/dev/vda\n' | toolbox_reinstall prepare "${1:-debian}" "${2:-13}" > "$fixture/output" 2>&1; }
reject() { if "$@" </dev/null > "$fixture/output" 2>&1; then fail 'unexpected success'; fi; }
no_calls() { [[ ! -s $fixture/calls ]] || fail 'unexpected upstream mutation boundary'; }
setup
reject toolbox_reinstall prepare windows 11; no_calls; pass 'fixed target rejects unsupported'
for input in 'NO\n' 'YES\nNO\n' 'YES' 'YES\nYES' 'YES\nYES\n/dev/vda' 'YES\nYES\n/dev/vdb\n'; do
    setup
    if printf '%b' "$input" | toolbox_reinstall prepare > "$fixture/output" 2>&1; then fail 'cancel/EOF accepted'; fi
    no_calls; [[ ! -e $fixture/state ]] || fail 'consent refusal wrote state'
done
pass 'cancel, both EOF confirmations, unterminated disk and exact typed mismatch'
setup; toolbox_reinstall preflight > "$fixture/output" 2> "$fixture/errors" || fail 'complete dependency preflight'
[[ ! -s $fixture/package-calls && ! -s $fixture/errors ]] || fail 'complete dependencies prompted/installed'
pass 'complete dependencies continue without prompt or package operation'
for source_mode in absolute relative basename; do
    setup
    (
        unset -f toolbox_require_commands
        case $source_mode in
            absolute) source "$ROOT/modules/reinstall.sh";;
            relative) cd "$ROOT"; source modules/reinstall.sh;;
            basename) cd "$ROOT/modules"; source reinstall.sh;;
        esac
        cd "$fixture"
        _toolbox_reinstall_has() { [[ $1 != toolbox-m3-fixture-unmapped ]]; }
        if _toolbox_reinstall_need toolbox-m3-fixture-unmapped </dev/null > "$fixture/output" 2> "$fixture/errors"; then exit 1; fi
        declare -F toolbox_require_commands >/dev/null
    ) || fail "standalone $source_mode source did not load sibling dependency core after cd"
    [[ ! -s $fixture/package-calls && ! -e $fixture/state ]] || fail 'standalone dependency probe mutated state'
done
pass 'absolute/relative/basename module sources lazily load sibling core after cwd changes'
setup; MISSING=virt-what
if ! printf 'y\n' | toolbox_reinstall preflight alpine > "$fixture/output" 2> "$fixture/errors"; then fail 'same-call dependency preflight'; fi
no_calls
[[ ! -e $fixture/state && -e $fixture/deps-installed/virt-what ]] || fail 'preflight dependency install wrote plan state or did not install'
command grep -q 'preflight 磁盘/引导只读检查通过' "$fixture/output" || fail 'preflight did not continue after installation'
command grep -q '依赖已按确认安装' "$fixture/errors" || fail 'preflight package mutation not explained'
pass 'virt-what installation resumes same preflight with readonly disk/boot checks'
setup; MISSING=virt-what; MISSING2=cpio
if ! printf 'y\nYES\nyes\n/dev/vda\n' | toolbox_reinstall prepare alpine 3.24 > "$fixture/output" 2> "$fixture/errors"; then
    fail 'same-call Alpine prepare after dependency confirmation'
fi
[[ -e $fixture/deps-installed/virt-what && -e $fixture/deps-installed/cpio ]] || fail 'missing commands not installed'
[[ $(command grep -c '^install ' "$fixture/package-calls") == 1 && $(command grep -c '^update\( \|$\)' "$fixture/package-calls") == 1 ]] || fail 'dependency request not batched exactly once'
command grep '^install ' "$fixture/package-calls" | command grep -q 'virt-what' || fail 'virt-what package missing'
command grep '^install ' "$fixture/package-calls" | command grep -q 'cpio' || fail 'cpio package missing'
command grep -q '仅 prepare 完成并回读' "$fixture/output" || fail 'dependency success did not continue prepare'
[[ $(command wc -l < "$fixture/calls") == 1 ]] || fail 'same call executed wrong upstream count'
command grep -q '依赖已按确认安装' "$fixture/errors" || fail 'package mutation not explained'
command grep -q 'MOCK PACKAGE STDOUT' "$fixture/errors" || fail 'package stdout not captured on stderr'
if command grep -q 'MOCK PACKAGE STDOUT\|依赖已按确认安装' "$fixture/output"; then fail 'dependency output contaminated stdout'; fi
pass 'virt-what + cpio install once on y and same Alpine call completes prepare'
for input in 'n\nYES\nyes\n/dev/vda\n' '\nYES\nyes\n/dev/vda\n' '' 'y'; do
    setup; MISSING=virt-what
    if printf '%b' "$input" | toolbox_reinstall prepare alpine 3.24 > "$fixture/output" 2>&1; then fail 'dependency refusal/EOF accepted'; fi
    no_calls
    [[ ! -e $fixture/state && ! -s $fixture/package-calls ]] || fail 'dependency refusal/EOF changed state/packages'
done
pass 'dependency refusal, default N, EOF and unterminated y refuse before state and upstream'
for mode in update-fail install-fail still-missing; do
    setup; MISSING=virt-what; DEPS_INSTALL_MODE=$mode
    if printf 'y\nYES\nyes\n/dev/vda\n' | toolbox_reinstall prepare alpine 3.24 > "$fixture/output" 2>&1; then fail "dependency $mode accepted"; fi
    no_calls
    [[ ! -e $fixture/state ]] || fail "dependency $mode created plan state"
done
pass 'update/install failure and absent command after success refuse before prepare'
setup; MISSING=grub-reboot
if printf 'y\nYES\nyes\n/dev/vda\n' | toolbox_reinstall prepare alpine 3.24 > "$fixture/output" 2>&1; then fail 'missing bootloader accepted'; fi
no_calls
[[ ! -e $fixture/state && ! -s $fixture/package-calls ]] || fail 'bootloader dependency installed or plan created'
command grep -q '不会自动安装或转换引导器/init' "$fixture/output" || fail 'missing bootloader refusal unclear'
pass 'missing GRUB refuses without installing or converting bootloader/init'
setup; MISSING=cpio; reject toolbox_reinstall preflight; no_calls; pass 'preflight missing dependency EOF refuses'
setup; CONTAINER_RC=0; reject toolbox_reinstall preflight; no_calls
CONTAINER_RC=2; reject toolbox_reinstall preflight; no_calls; pass 'container and unknown detector'
# Container classification must not depend on systemd-detect-virt (absent on Alpine).
setup; eval "$real_container"; MISSING=systemd-detect-virt; VIRTWHAT=docker; reject toolbox_reinstall preflight; no_calls
pass 'container refused via virt-what without systemd-detect-virt'
setup; eval "$real_container"; MISSING=systemd-detect-virt; VIRTWHAT=$'kvm\nlxc'; reject toolbox_reinstall preflight; no_calls
pass 'nested container evidence wins over earlier hypervisor line'
setup; eval "$real_container"; MISSING=systemd-detect-virt; VIRTWHAT=kvm; toolbox_reinstall preflight > "$fixture/output" 2>&1 || fail 'VM without detector'
pass 'VM accepted via virt-what fallback'
setup; eval "$real_container"; MISSING=systemd-detect-virt; VIRTWHAT=''
toolbox_reinstall preflight > "$fixture/output" 2>&1 || fail 'bare-metal DMI fallback'
pass 'bare metal accepted from DMI when virt-what is silent'
setup; eval "$real_container"; MISSING=systemd-detect-virt; VIRTWHAT=''; rm -rf "$fixture/root/sys/class"; reject toolbox_reinstall preflight; no_calls
pass 'no detector + silent virt-what + no DMI stays unknown'
_toolbox_reinstall_container() { return "${CONTAINER_RC:-1}"; }
# PID1 init gate reviews the existing host, independent of the target system.
INIT_MODE=runit setup; reject toolbox_reinstall preflight; no_calls
[[ ! -e $fixture/state ]] || fail 'unknown init wrote state'
pass 'unknown PID1 init refuses before any write'
INIT_MODE=openrc setup; toolbox_reinstall preflight > "$fixture/output" 2>&1 || fail 'OpenRC host rejected'
pass 'OpenRC/Alpine PID1 accepted on bare metal regardless of detector'
INIT_MODE=openrc setup; prep debian 13 || fail 'OpenRC to Debian prepare'
toolbox_reinstall cancel > "$fixture/cancel" 2>&1 || fail 'OpenRC to Debian cancel'
pass 'OpenRC host prepares/cancels Debian using sealed host init'
setup; prep alpine 3.24 || fail 'systemd to Alpine prepare'
toolbox_reinstall cancel > "$fixture/cancel" 2>&1 || fail 'systemd to Alpine cancel'
pass 'systemd host prepares/cancels Alpine using sealed host init'
INIT_MODE=openrc setup; prep alpine 3.24 || fail 'alpine on openrc'
pass 'openrc host + alpine target accepted'
# ptuuid / read-only root are named refusals before state, downloads and upstream.
setblk() { python3 - "$fixture/lsblk.json" "$1" "$2" <<'PY'
import json,sys
p,k,v=sys.argv[1:];d=json.load(open(p));d['blockdevices'][0][k]=v;json.dump(d,open(p,'w'))
PY
}
setup; setblk ptuuid ''; reject toolbox_reinstall preflight
command grep -q PTUUID "$fixture/output" || fail 'ptuuid refusal unnamed'; no_calls
pass 'empty ptuuid refused by name'
setup; setblk ptuuid 'zzzzzzzz'; reject toolbox_reinstall preflight; no_calls
pass 'malformed ptuuid refused'
setup; setblk ptuuid '00000000-0000-0000-0000-000000000000'; reject toolbox_reinstall preflight
command grep -q PTUUID "$fixture/output" || fail 'zero ptuuid unnamed'
pass 'all-zero ptuuid refused'
setup; setblk ptuuid 'ABCD1234-0000-4000-8000-000000000000'; toolbox_reinstall preflight > "$fixture/output" 2>&1 || fail 'GUID ptuuid'
pass 'GPT-style uppercase ptuuid accepted'
setup; printf '{"filesystems":[{"target":"/","source":"/dev/vda1","fstype":"ext4","options":"ro"}]}\n' > "$fixture/mounts.json"
reject toolbox_reinstall preflight; command grep -q '只读' "$fixture/output" || fail 'root ro unnamed'; no_calls
pass 'read-only root refused by name'
# The final initrd archive is validated as a WHOLE stream, not up to TRAILER.
ARCHIVE_MODE=zero_tail setup; prep || fail 'zero tail archive'
pass 'NUL padded tail after TRAILER accepted'
ARCHIVE_MODE=fifo setup; prep || fail 'fifo member'
pass 'valid extra member type (fifo) accepted'
ARCHIVE_MODE=rootdir setup; prep || fail 'real cpio root directory'
pass 'real upstream find-dot cpio root directory accepted'
for mode in junk_tail second_archive dup dotdot badtype dirwanted rootfile duproot hardwanted; do
    ARCHIVE_MODE=$mode setup; reject prep; pass "archive $mode refused"
done
# Reboot semantics must be stated exactly: adapter never reboots, upstream does.
setup; prep || fail prepare
command grep -q '上游.*initrd.*自动 reboot\|自动 reboot' "$fixture/output" || fail 'reboot wording'
pass 'prepare output states upstream initrd auto-reboot explicitly'
setup
python3 - "$fixture/lsblk.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['blockdevices'].append(dict(d['blockdevices'][0],name='/dev/vdb',kname='vdb'));json.dump(d,open(p,'w'))
PY
reject toolbox_reinstall preflight; no_calls; pass 'multiple physical disk ambiguity'
setup
python3 - "$fixture/lsblk.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['blockdevices'][0]['children'][0]['type']='crypt';json.dump(d,open(p,'w'))
PY
reject toolbox_reinstall preflight; no_calls; pass 'crypt/unsupported topology'
setup; TOOLBOX_REINSTALL_SSH_KEY_FILE="$case_root/key"; reject prep; no_calls; pass 'private key rejected'
setup; printf 'ssh-ed25519 AAAA\n' > "$fixture/bad.pub"; TOOLBOX_REINSTALL_SSH_KEY_FILE="$fixture/bad.pub"; reject prep; no_calls; pass 'pubkey wire format validation'
setup; cp "$case_root/key.pub" "$fixture/input.pub"; TOOLBOX_REINSTALL_SSH_KEY_FILE="$fixture/input.pub"
real_confirm=$(declare -f _toolbox_reinstall_confirm)
_toolbox_reinstall_confirm() {
    eval "$real_confirm"; _toolbox_reinstall_confirm "$@" || return
    cp "$case_root/other-key.pub" "$fixture/input.pub"
}
reject prep; no_calls; pass 'SSH public key changed after confirmation refuses before upstream'
eval "$real_confirm"
setup
# shellcheck disable=SC2317 # Invoked indirectly by production fetch helper.
_toolbox_reinstall_download() { cp "$upstream/$1" "$2"; [[ $1 != reinstall.sh ]] || printf 'tamper\n' >> "$2"; }
reject prep; no_calls; pass 'raw pin SHA tampering'
_toolbox_reinstall_download() { cp "$upstream/$1" "$2"; }
setup; RUNTIME_BAD=1; reject prep; [[ -s $fixture/calls ]] || fail 'mock not reached'; pass 'unpacked runtime helper pin tamper'
setup; CFG_BAD=1; reject prep; pass 'mutable main runtime cfg rejected'
setup; ARCHIVE_BAD=1; reject prep; pass 'final repacked initrd is parsed, not only workspace'
setup; MOCK_ARCH=aarch64; toolbox_reinstall preflight > "$fixture/output" 2>&1 || fail 'ARM64 preflight'; pass 'ARM64 readonly preflight with BIOS GRUB fixture'
setup; MOCK_FAIL=1; reject prep
[[ $(toolbox_reinstall status) == *phase=failed* ]] || fail 'upstream failure not preserved'
command grep -q 'actual fixture upstream failure' "$fixture/output" || fail 'real error suppressed'
pass 'upstream nonzero propagates + failed status'
for pair in 'debian 13' 'ubuntu 24.04' 'alpine 3.24'; do
    read -r ds ver <<< "$pair"
    case $ds in alpine) INIT_MODE=openrc setup;; *) setup;; esac
    prep "$ds" "$ver" || fail 'positive prepare'
    before=$(sha256sum "$fixture/calls")
    toolbox_reinstall status > "$fixture/status" || fail 'prepared status'
    [[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'status mutates'
    command grep -q phase=prepared "$fixture/status" || fail 'not prepared'
    reject prep "$ds" "$ver"
    toolbox_reinstall cancel > "$fixture/cancel" 2>&1 || fail 'positive cancel'
    command grep -q phase=cancelled "$fixture/cancel" || fail 'cancel readback missing'
    reject toolbox_reinstall cancel
    [[ $(command cat "$fixture/root/boot/grub/grub.cfg") == 'menuentry original {}' ]] || fail 'boot original differs'
done
pass 'all fixed target prepare -> readonly status -> owned reset -> exact restore'
setup; prep || fail prepare; toolbox_reinstall cancel > "$fixture/cancel" 2>&1 || fail cancel
old_plan=$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_ino)' "$fixture/state/active")
prep ubuntu 24.04 || fail 'prepare after verified cancel'
python3 - "$fixture/state" "$old_plan" <<'PY' || fail 'cancelled report not preserved'
import json,os,sys
p,ino=sys.argv[1:];names=[x for x in os.listdir(p) if x.startswith('cancelled-')]
assert len(names)==1
q=p+'/'+names[0]
assert os.stat(q).st_ino==int(ino)
assert json.load(open(q+'/metadata.json'))['phase']=='cancelled'
assert json.load(open(p+'/active/metadata.json'))['target']=='ubuntu 24.04'
PY
pass 'new prepare after cancelled preserves sealed history without deleting files'
setup; prep || fail prepare; toolbox_reinstall cancel > "$fixture/cancel" 2>&1 || fail cancel
printf 'foreign kernel after cancel\n' > "$fixture/root/reinstall-vmlinuz"
before=$(sha256sum "$fixture/calls"); reject toolbox_reinstall status
[[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'cancelled status invoked upstream'
command grep -q 'cancelled plan 后 boot 路径集合变化' "$fixture/output" || fail 'cancelled new boot path not named'
pass 'cancelled status rejects newly armed boot path without invoking upstream'
setup; prep || fail prepare; toolbox_reinstall cancel > "$fixture/cancel" 2>&1 || fail cancel
printf '# changed after cancel\n' >> "$fixture/root/boot/grub/grub.cfg"
before=$(sha256sum "$fixture/calls"); reject toolbox_reinstall status
command grep -q 'cancelled plan 后原 boot 文件变化' "$fixture/output" || fail 'cancelled boot bytes not checked'
[[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'changed cancelled status ran upstream'
reject prep
[[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'changed cancelled baseline ran upstream'
pass 'changed cancelled boot baseline refuses status and recycling'
setup; prep || fail prepare; printf '# boot tamper\n' >> "$fixture/root/boot/grub/custom.cfg"
before=$(sha256sum "$fixture/calls"); reject toolbox_reinstall cancel
[[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'tamper called reset'; pass 'boot identity tamper rejects cancel'
setup; prep || fail prepare; printf 'tamper' >> "$fixture/state/active/metadata.json"
before=$(sha256sum "$fixture/calls"); reject toolbox_reinstall cancel
[[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'ledger tamper called reset'; pass 'seal tamper rejects cancel'
setup; prep || fail prepare; BOOT_ID=after-reboot; reject toolbox_reinstall cancel; pass 'boot id change rejects reset'
setup; prep || fail prepare; MISSING=flock; before=$(sha256sum "$fixture/calls"); reject toolbox_reinstall cancel
[[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'missing dep called reset'; pass 'cancel missing deps before mutation'
setup; prep || fail prepare; RESET_FAIL=1; reject toolbox_reinstall cancel
[[ $(toolbox_reinstall status) == *reset-failed* && -f $fixture/root/reinstall-initrd ]] || fail 'reset failure not retained'; pass 'reset failure retains boot files/report'
setup; prep || fail prepare; RESET_BAD=1; reject toolbox_reinstall cancel
[[ $(toolbox_reinstall status) == *restore-failed* ]] || fail 'failed reset readback not reported'; pass 'reset exit0 with pending boot state is NOT success'
setup; mkdir -m 0700 "$fixture/state"; touch "$fixture/state/lock"; chmod 0600 "$fixture/state/lock"
exec {held}>"$fixture/state/lock"; flock -n "$held"; reject prep; no_calls; exec {held}>&-; pass 'concurrent prepare lock'
setup; mkdir -p "$fixture/root/boot/efi/EFI/debian" "$fixture/root/sys/firmware/efi"
printf 'original EFI\n' > "$fixture/root/boot/efi/EFI/debian/grubx64.efi"
printf 'BootCurrent: 0000\nBootOrder: 0000\nBoot0000* original HD(...)\\EFI\\debian\\grubx64.efi\n' > "$fixture/efi"
printf '{"filesystems":[{"target":"/","source":"/dev/vda1","fstype":"ext4","options":"rw"},{"target":"/boot/efi","source":"/dev/vda1","fstype":"vfat","options":"rw"}]}\n' > "$fixture/mounts.json"
MISSING=virt-what; MISSING2=efibootmgr
if ! printf 'y\nYES\nyes\n/dev/vda\n' | toolbox_reinstall prepare ubuntu 24.04 > "$fixture/output" 2>&1; then fail 'UEFI prepare after dependency confirmation'; fi
[[ $(command grep -c '^install ' "$fixture/package-calls") == 1 ]] || fail 'UEFI dependency installation not batched'
command grep '^install ' "$fixture/package-calls" | command grep -q 'efibootmgr' || fail 'EFI inspection package missing'
command grep '^install ' "$fixture/package-calls" | command grep -q 'virt-what' || fail 'ordinary package missing from EFI request'
toolbox_reinstall cancel > "$fixture/cancel" 2>&1 || fail 'UEFI cancel'; pass 'UEFI inspection and ordinary tools install once, then BootNext/entry identity + restore'
before=$(sha256sum "$fixture/calls")
printf 'BootCurrent: 0000\nBootOrder: 0002,0000\nBoot0000* original HD(...)\\EFI\\debian\\grubx64.efi\n' > "$fixture/efi"
reject toolbox_reinstall status
[[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'cancelled EFI status ran upstream'
command grep -q 'cancelled plan 后 EFI 状态变化' "$fixture/output" || fail 'cancelled EFI comparison not enforced'
pass 'cancelled status rejects later EFI BootOrder change without invoking upstream'
# --create-only must never silently reorder persistent boot entries.
setup; mkdir -p "$fixture/root/boot/efi/EFI/debian" "$fixture/root/sys/firmware/efi"
printf 'original EFI\n' > "$fixture/root/boot/efi/EFI/debian/grubx64.efi"
printf 'BootCurrent: 0000\nBootOrder: 0000\nBoot0000* original HD(...)\\EFI\\debian\\grubx64.efi\n' > "$fixture/efi"
printf '{"filesystems":[{"target":"/","source":"/dev/vda1","fstype":"ext4","options":"rw"},{"target":"/boot/efi","source":"/dev/vda1","fstype":"vfat","options":"rw"}]}\n' > "$fixture/mounts.json"
real_runner=$(declare -f _toolbox_reinstall_run_upstream)
_toolbox_reinstall_run_upstream() {
    eval "$real_runner"; _toolbox_reinstall_run_upstream "$@" || return
    sed -i 's/BootOrder: 0000/BootOrder: 0001,0000/' "$fixture/efi"
}
reject prep ubuntu 24.04
[[ $(toolbox_reinstall status) == *phase=failed* ]] || fail 'EFI prepare order regression not retained'
pass 'UEFI create-only changed BootOrder rejects prepared success'
eval "$real_runner"
# Even with matching entry text, reset may not silently reorder unrelated EFI
# entries. Run the real fixture reset, then inject a firmware-order regression.
setup; mkdir -p "$fixture/root/boot/efi/EFI/debian" "$fixture/root/sys/firmware/efi"
printf 'original EFI\n' > "$fixture/root/boot/efi/EFI/debian/grubx64.efi"
printf 'BootCurrent: 0000\nBootOrder: 0000\nBoot0000* original HD(...)\\EFI\\debian\\grubx64.efi\n' > "$fixture/efi"
printf '{"filesystems":[{"target":"/","source":"/dev/vda1","fstype":"ext4","options":"rw"},{"target":"/boot/efi","source":"/dev/vda1","fstype":"vfat","options":"rw"}]}\n' > "$fixture/mounts.json"
prep ubuntu 24.04 || fail 'UEFI prepare for order test'
real_runner=$(declare -f _toolbox_reinstall_run_upstream)
_toolbox_reinstall_run_upstream() {
    eval "$real_runner"; _toolbox_reinstall_run_upstream "$@" || return
    sed -i 's/BootOrder: 0000/BootOrder: 0002,0000/' "$fixture/efi"
}
reject toolbox_reinstall cancel
[[ $(toolbox_reinstall status) == *restore-failed* ]] || fail 'EFI order regression not retained'
pass 'UEFI reset changed BootOrder rejects success and preserves evidence'
eval "$real_runner"
setup; printf 'foreign kernel\n' > "$fixture/root/reinstall-vmlinuz"
reject toolbox_reinstall preflight; no_calls; reject toolbox_reinstall cancel; no_calls; pass 'foreign upstream plan never adopted/reset'
setup; printf 'menuentry user-custom {}\n' > "$fixture/root/boot/grub/custom.cfg"
reject toolbox_reinstall preflight; no_calls; pass 'existing user custom.cfg refused, never overwritten'
setup; ln -s "$fixture/root/boot/grub/grub.cfg" "$fixture/root/boot/grub/custom.cfg"
reject toolbox_reinstall preflight; no_calls; pass 'boot symlink refused before upstream'
setup; prep || fail prepare
python3 - "$fixture/lsblk.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['blockdevices'][0]['ptuuid']='abcdef01';json.dump(d,open(p,'w'))
PY
before=$(sha256sum "$fixture/calls"); reject toolbox_reinstall cancel
[[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'changed disk called reset'; pass 'cancel rechecks physical disk identity'
setup; prep || fail prepare
exec {held}<"$fixture/state/lock"; flock -n "$held"; before=$(sha256sum "$fixture/calls"); reject toolbox_reinstall cancel
[[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'concurrent reset entered'; exec {held}>&-; pass 'concurrent cancel lock'
real_guard=$(declare -f _toolbox_reinstall_lock_guard)
setup
_toolbox_reinstall_lock_guard() {
    if [[ -n ${3:-} ]]; then mv "$1/lock" "$1/lock-moved"; touch "$1/lock"; chmod 0600 "$1/lock"; fi
    eval "$real_guard"; _toolbox_reinstall_lock_guard "$@"
}
reject prep; no_calls; pass 'prepare refuses inode replacement of held flock before upstream'
eval "$real_guard"
setup; prep || fail prepare; before=$(sha256sum "$fixture/calls")
_toolbox_reinstall_lock_guard() {
    if [[ -n ${3:-} ]]; then mv "$1/lock" "$1/lock-moved"; touch "$1/lock"; chmod 0600 "$1/lock"; fi
    eval "$real_guard"; _toolbox_reinstall_lock_guard "$@"
}
reject toolbox_reinstall cancel
[[ $before == "$(sha256sum "$fixture/calls")" ]] || fail 'swapped cancel lock called reset'
pass 'cancel refuses inode replacement of held flock before reset'
eval "$real_guard"
setup
# A real signal is sent to the adapter subshell; destructive execution still mocked.
_toolbox_reinstall_run_upstream() { printf '%s\n' "$BASHPID" > "$fixture/runner.pid"; sleep 1; kill -TERM "$BASHPID"; sleep 1; }
reject prep
[[ $(toolbox_reinstall status) == *interrupted* ]] || fail 'signal not preserved'; pass 'real TERM retains interrupted report; no automatic reset'
printf 'All %s local mocked-boundary checks passed; NOT real installer acceptance. evidence=%s\n' "$count" "$case_root"
