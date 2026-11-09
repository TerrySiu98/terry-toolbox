#!/usr/bin/env bash
# BBR regression tests: scratch-only fixtures and denied host boundaries.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/scratch-root.sh"
toolbox_test_scratch
R=$(mktemp -d "$TMPDIR/toolbox-bbr.XXXXXXXX")
printf 'toolbox-bbr-fixture\n' > "$R/.fixture"
guard_log=$R/guard.log
: > "$guard_log"
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -s $guard_log ]]; then
        printf 'FAIL: an unmocked host command was attempted\n' >&2
        /bin/cat "$guard_log" >&2
        rc=1
    fi
    if [[ $R == "$TMPDIR"/toolbox-bbr.* && -d $R && ! -L $R && -O $R && -f $R/.fixture ]] &&
       [[ $(<"$R/.fixture") == toolbox-bbr-fixture ]]; then
        /bin/rm -rf -- "$R"
    else
        printf 'FAIL: fixture ownership changed; retained %s\n' "$R" >&2
        rc=1
    fi
    exit "$rc"
}
trap cleanup EXIT
mkdir -p "$R/deny" "$R/state" "$R/sysctl.d"
export PATH="$R/deny:/usr/bin:/bin"
export TOOLBOX_SYSTEM_STATE="$R/state" TOOLBOX_SYSTEM_SYSCTL_DIR="$R/sysctl.d"
# Physical guards also cover child Bash and env -i, where function mocks vanish.
guard_commands=(sudo doas apt apt-get apt-cache aptitude apk dpkg dpkg-query dpkg-deb
    modprobe modinfo insmod rmmod depmod sysctl uname readlink
    systemctl service rc-service reboot shutdown mount umount tc ip iptables ip6tables nft
    curl wget install tee)
for command_name in "${guard_commands[@]}"; do
    {
        printf '#!/bin/bash\n'
        printf 'printf "%%s\\n" "$0 $*" >> %q\n' "$guard_log"
        printf 'printf "UNMOCKED host boundary: %%s\\n" "$0" >&2\nexit 99\n'
    } > "$R/deny/$command_name"
    chmod 0755 "$R/deny/$command_name"
done
guard_probe='deny=$1; shift; for name in "$@"; do [[ $(command -v "$name") == "$deny/$name" ]] || exit 1; rc=0; "$name" --fixture-probe || rc=$?; [[ $rc == 99 ]] || exit 1; done'
bash --noprofile --norc -c "$guard_probe" guard "$R/deny" "${guard_commands[@]}" >/dev/null 2>&1
env -i PATH="$PATH" bash --noprofile --norc -c "$guard_probe" guard "$R/deny" "${guard_commands[@]}" >/dev/null 2>&1
[[ $(wc -l < "$guard_log") == $(( ${#guard_commands[@]} * 2 )) ]]
: > "$guard_log"

# Loading the source itself must do no privileged work.
source "${SYSTEM_MODULE_UNDER_TEST:-$ROOT/modules/system.sh}"
[[ ! -s $guard_log ]]
pass_count=0
case_name=''
case_root=''
trace=''
out=''
rc=0
fail() {
    printf 'FAIL [%s]: %s\n' "$case_name" "$*" >&2
    [[ ! -f $out ]] || /bin/cat "$out" >&2
    [[ ! -f $trace ]] || /bin/cat "$trace" >&2
    exit 1
}
boundary_error() {
    printf '%s\n' "$*" >> "$guard_log"
    fail "$*"
}
bump() {
    local file=$case_root/$1 value
    value=$(<"$file")
    value=$((value + 1))
    printf '%s\n' "$value" > "$file"
    printf '%s\n' "$value"
}
_toolbox_system_root() {
    [[ $ROOT_ALLOWED == 1 ]] || { printf 'fixture: root required\n' >&2; return 1; }
}
_toolbox_system_need_tools() {
    local name
    printf 'need %s\n' "$*" >> "$trace"
    for name in "$@"; do
        case $name in sysctl|uname|readlink|modinfo|modprobe) ;; *) boundary_error "unexpected dependency $name";; esac
        case " $MISSING_TOOLS " in *" $name "*) return 1;; esac
    done
}
# Default helper calls are also mocked; neither discovers the host's kernel.
uname() {
    [[ $* == -r ]] || boundary_error 'unexpected uname arguments'
    printf '%s\n' "$KERNEL"
}
_toolbox_system_bbr_kernel() {
    local count
    count=$(bump kernel_reads)
    if [[ $KERNEL_CHANGE == 1 && $count -gt 1 ]]; then printf 'other-kernel\n'
    else uname -r; fi
}
_toolbox_system_bbr_module_root() { printf '%s\n' "$case_root/modules"; }
readlink() {
    local path=${!#} count
    [[ $* == "-f -- $path" && $path == "$case_root/"* ]] || boundary_error 'readlink escaped fixture'
    [[ $REALPATH_FAIL != 1 ]] || return 1
    if [[ $path == "$MODULE_FILE" ]]; then
        count=$(bump path_reads)
        if [[ $PATH_CHANGE == 1 && $count -gt 1 ]]; then
            printf '%s/changed.ko\n' "$case_root"
            return
        fi
    fi
    /usr/bin/readlink "$@"
}
sysctl() {
    local count
    case "$*" in
        '-n net.ipv4.tcp_available_congestion_control')
            count=$(bump available_reads)
            printf 'read available %s\n' "$count" >> "$trace"
            [[ $count != "$FAIL_AVAILABLE_AT" ]] || return 1
            if [[ $count == "$DROP_AVAILABLE_AT" ]]; then printf 'cubic\n' > "$case_root/available"; fi
            /bin/cat "$case_root/available";;
        '-n net.ipv4.tcp_congestion_control')
            count=$(bump current_reads)
            printf 'read current %s\n' "$count" >> "$trace"
            [[ $count != "$FAIL_CURRENT_AT" ]] || return 1
            if [[ $count == "$CHANGE_CURRENT_AT" ]]; then printf 'reno\n' > "$case_root/current"; fi
            /bin/cat "$case_root/current";;
        '-w net.ipv4.tcp_congestion_control=bbr')
            printf 'write bbr\n' >> "$trace"
            [[ $WRITE_FAIL != 1 ]] || { printf 'fixture: permission denied\n' >&2; return 1; }
            [[ $WRITE_LIES != 1 ]] || return 0
            printf 'bbr\n' > "$case_root/current";;
        *) boundary_error "unexpected sysctl arguments: $*";;
    esac
}
modinfo() {
    [[ $* == '-F filename tcp_bbr' ]] || boundary_error "unexpected modinfo arguments: $*"
    printf 'modinfo\n' >> "$trace"
    case $MODINFO_MODE in
        valid) printf '%s\n' "$MODULE_FILE";;
        empty) return 0;;
        failure) printf 'modinfo: modules.dep index missing\n' >&2; return 1;;
        path_failure) printf '%s\n' "$MODULE_FILE"; return 1;;
        warning) printf '%s\n' "$MODULE_FILE"; printf 'modinfo: index warning\n' >&2;;
        stderr_filename) printf '%s\n' "$MODULE_FILE" >&2;;
        multiline) printf '%s\n%s\n' "$MODULE_FILE" "$MODULE_FILE";;
        relative) printf 'kernel/net/ipv4/tcp_bbr.ko\n';;
        missing_file) printf '%s/missing.ko\n' "$MODULE_DIR";;
        outside) printf '%s/other/tcp_bbr.ko\n' "$case_root";;
        symlink_outside) printf '%s/escape.ko\n' "$MODULE_DIR";;
        builtin) printf '(builtin)\n';;
        *) boundary_error "unknown modinfo fixture: $MODINFO_MODE";;
    esac
}
modprobe() {
    local unexpected
    [[ $* == '-- tcp_bbr' ]] || boundary_error "unexpected modprobe arguments: $*"
    printf 'modprobe\n' >> "$trace"
    if IFS= read -r unexpected; then boundary_error 'module loader inherited confirmation input'; fi
    [[ $MODPROBE_FAIL != 1 ]] || { printf 'fixture: Operation not permitted\n' >&2; return 1; }
    : > "$case_root/loaded"
    [[ $MODPROBE_UNREGISTERED != 1 ]] || return 0
    printf 'cubic bbr\n' > "$case_root/available"
}
fixture() {
    case_name=$1
    case_root=$R/case-$((pass_count + 1))
    mkdir -p "$case_root"
    trace=$case_root/trace
    out=$case_root/out
    : > "$trace"
    KERNEL=6.18.58-0-virt
    MODULE_DIR=$case_root/modules/$KERNEL
    MODULE_FILE=$MODULE_DIR/kernel/net/ipv4/tcp_bbr.ko
    mkdir -p "${MODULE_FILE%/*}" "$case_root/other"
    : > "$MODULE_FILE"
    # Binary-only module indexes are valid; do not require modules.dep text.
    : > "$MODULE_DIR/modules.dep.bin"
    : > "$case_root/other/tcp_bbr.ko"
    ln -s "$case_root/other/tcp_bbr.ko" "$MODULE_DIR/escape.ko"
    printf 'cubic\n' > "$case_root/current"
    printf 'cubic bbr\n' > "$case_root/available"
    for counter in available_reads current_reads kernel_reads path_reads; do printf '0\n' > "$case_root/$counter"; done
    ROOT_ALLOWED=1 MISSING_TOOLS='' KERNEL_CHANGE=0 PATH_CHANGE=0 REALPATH_FAIL=0
    FAIL_AVAILABLE_AT=0 DROP_AVAILABLE_AT=0 FAIL_CURRENT_AT=0 CHANGE_CURRENT_AT=0
    WRITE_FAIL=0 WRITE_LIES=0 MODINFO_MODE=valid MODPROBE_FAIL=0 MODPROBE_UNREGISTERED=0
    [[ ${2:-registered} != module ]] || printf 'cubic\n' > "$case_root/available"
}
run_bbr() {
    local expected=$1 input=$2
    printf '%s' "$input" > "$case_root/input"
    rc=0
    ( _toolbox_system_bbr ) < "$case_root/input" > "$out" 2>&1 || rc=$?
    [[ ! -s $guard_log ]] || fail 'physical host guard was reached'
    if [[ $expected == success ]]; then [[ $rc == 0 ]] || fail "returned $rc"
    else
        [[ $rc != 0 ]] || fail 'unexpected success'
        [[ $(<"$out") != *'BBR 已启用'* ]] || fail 'failure reported enabled'
    fi
}
seen() { grep -qxF -- "$1" "$trace" || fail "missing trace: $1"; }
absent() { if grep -qxF -- "$1" "$trace"; then fail "unexpected trace: $1"; fi; }
untouched() {
    absent modprobe
    absent 'write bbr'
    [[ $(<"$case_root/current") == cubic && ! -e $case_root/loaded ]] || fail 'refused operation changed fixture'
}
pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS %s\n' "$case_name"
}
two_yes=$'YES\nYES\n'
four_yes=$'YES\nYES\nYES\nYES\n'

fixture 'registered BBR switches with only algorithm consent'
run_bbr success "$two_yes"; seen 'write bbr'; absent modinfo; absent modprobe
[[ $(<"$case_root/current") == bbr && $(<"$case_root/kernel_reads") == 0 ]] || fail 'registered path needed module discovery'
[[ $(<"$out") == *'仅当前运行期'* ]] || fail 'temporary scope missing'
pass

fixture 'already enabled returns without consent or writes'
printf 'bbr\n' > "$case_root/current"
run_bbr success ''; absent modinfo; absent modprobe; absent 'write bbr'; pass

fixture 'root refusal precedes sysctl'
ROOT_ALLOWED=0
run_bbr failure "$four_yes"; [[ ! -s $trace ]] || fail 'root refusal performed work'; pass

fixture 'missing sysctl stops before host reads'
MISSING_TOOLS=sysctl
run_bbr failure "$four_yes"; absent 'read available 1'; untouched; pass

fixture 'initial sysctl read failure is not success'
FAIL_AVAILABLE_AT=1
run_bbr failure "$four_yes"; untouched; pass

for initial_current in '' 'cubic invalid'; do
    fixture 'invalid current algorithm refuses writes'
    printf '%s\n' "$initial_current" > "$case_root/current"
    run_bbr failure "$four_yes"; absent modprobe; absent 'write bbr'; pass
done

fixture 'module load and algorithm switch require four YES answers' module
run_bbr success "$four_yes"; seen modinfo; seen modprobe; seen 'write bbr'
[[ -e $case_root/loaded && $(<"$case_root/current") == bbr ]] || fail 'module success not verified'
[[ $(grep -o '输入 YES 确认' "$out" | wc -l) == 4 ]] || fail 'separate double confirmations missing'
pass

for answer in NO '' $'YES\n'; do
    fixture 'module refusal or EOF never loads' module
    run_bbr failure "$answer"; untouched; pass
done

for answer in NO '' $'YES\n'; do
    fixture 'cancelling after loading retains module and original algorithm' module
    run_bbr failure "$two_yes$answer"; seen modprobe; absent 'write bbr'
    [[ -e $case_root/loaded && $(<"$case_root/current") == cubic ]] || fail 'cancel after loading changed algorithm'
    pass
done

for missing_dir in root kernel; do
    fixture 'missing running-kernel directory gives a precise refusal' module
    if [[ $missing_dir == root ]]; then rm -rf -- "$case_root/modules"; else rm -rf -- "$MODULE_DIR"; fi
    run_bbr failure "$four_yes"; untouched; absent modinfo; absent 'need modinfo modprobe'
    [[ $(<"$out") == *"$KERNEL"* && $(<"$out") == *'模块目录'* ]] || fail 'missing directory diagnosis omitted kernel'
    pass
done

for invalid_kernel in '' .. '../wrong' $'kernel\nextra'; do
    fixture 'invalid kernel release cannot select another module tree' module
    KERNEL=$invalid_kernel
    run_bbr failure "$four_yes"; untouched; absent modinfo; pass
done

fixture 'missing module tools never invoke a package manager' module
MISSING_TOOLS=modinfo
run_bbr failure "$four_yes"; untouched; absent modinfo; pass

for mode in empty failure path_failure warning multiline relative missing_file outside symlink_outside builtin; do
    fixture "invalid modinfo result: $mode" module
    MODINFO_MODE=$mode
    run_bbr failure "$four_yes"; untouched; pass
done

fixture 'missing module index is reported without invoking depmod' module
rm -f -- "$MODULE_DIR/modules.dep.bin"
MODINFO_MODE=failure
run_bbr failure "$four_yes"; untouched
[[ $(<"$out") == *'索引'* ]] || fail 'module index diagnosis missing'
pass

fixture 'module realpath failure refuses loading' module
REALPATH_FAIL=1
run_bbr failure "$four_yes"; untouched; pass

fixture 'kernel changes while confirming module load' module
KERNEL_CHANGE=1
run_bbr failure "$four_yes"; untouched; pass

fixture 'module path changes while confirming module load' module
PATH_CHANGE=1
run_bbr failure "$four_yes"; untouched; pass

fixture 'modprobe failure cannot switch congestion control' module
MODPROBE_FAIL=1
run_bbr failure "$four_yes"; seen modprobe; absent 'write bbr'
[[ $(<"$case_root/current") == cubic ]] || fail 'failed load changed algorithm'
pass

fixture 'modprobe exit zero without registration is rejected' module
MODPROBE_UNREGISTERED=1
run_bbr failure "$four_yes"; seen modprobe; absent 'write bbr'; pass

fixture 'registered-list read failure after load is rejected' module
FAIL_AVAILABLE_AT=2
run_bbr failure "$four_yes"; seen modprobe; absent 'write bbr'; pass

for failed_at in 1 2 3; do
    fixture 'current algorithm read failure never reaches a write'
    FAIL_CURRENT_AT=$failed_at
    run_bbr failure "$two_yes"; untouched; pass
done

fixture 'available-list read failure before write is rejected'
FAIL_AVAILABLE_AT=2
run_bbr failure "$two_yes"; untouched; pass

for changed_at in 2 3; do
    fixture 'concurrent algorithm change is preserved'
    CHANGE_CURRENT_AT=$changed_at
    run_bbr failure "$two_yes"; absent 'write bbr'
    [[ $(<"$case_root/current") == reno ]] || fail 'concurrent value overwritten'
    pass
done

fixture 'BBR disappears during algorithm confirmation'
DROP_AVAILABLE_AT=2
run_bbr failure "$two_yes"; untouched; pass

fixture 'sysctl write permission failure is not reported as enabled'
WRITE_FAIL=1
run_bbr failure "$two_yes"; seen 'write bbr'
[[ $(<"$case_root/current") == cubic ]] || fail 'failed write changed algorithm'
pass

fixture 'sysctl exit zero with unchanged readback is rejected'
WRITE_LIES=1
run_bbr failure "$two_yes"; seen 'write bbr'; pass

fixture 'sysctl readback error after write is not success'
FAIL_CURRENT_AT=4
run_bbr failure "$two_yes"; seen 'write bbr'; pass

fixture 'stderr alone cannot masquerade as a valid module filename' module
MODINFO_MODE=stderr_filename
run_bbr failure "$four_yes"; untouched; pass

# These entries must stay temporary: no persistence file may be created.
[[ -z $(find "$R/state" "$R/sysctl.d" -type f -print -quit) ]] || fail 'BBR wrote persistent configuration'
[[ ! -s $guard_log ]] || fail 'unmocked host operation attempted'
printf 'PASS BBR: %s isolated cases; host guards clear; scratch cleanup armed\n' "$pass_count"
