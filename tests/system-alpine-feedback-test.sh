#!/usr/bin/env bash
# Mock regressions, NOT a real Alpine/OpenRC/Docker integration test.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export TMPDIR=${TMPDIR:-/root/.hermes/cache/scratch}
mkdir -p -- "$TMPDIR"
TMPDIR=$(cd -- "$TMPDIR" && pwd -P)
case $TMPDIR in /root/.hermes/cache/scratch|/root/.hermes/cache/scratch/*) ;; *) printf 'unsafe TMPDIR\n' >&2; exit 1;; esac
R=$(mktemp -d "$TMPDIR/toolbox-system-alpine-feedback.XXXXXXXX")
trap 'if [[ ${SYSTEM_ALPINE_KEEP:-0} == 1 ]]; then printf "Mock evidence: %s\n" "$R"; else rm -rf -- "$R"; fi' EXIT
export HOME="$R/home" PATH="$R/deny:/usr/bin:/bin"
mkdir -p -- "$HOME" "$R/deny"
# Any unmocked privileged boundary fails rather than reaching the host.
for cmd in apk docker dockerd containerd runc apt-get systemctl rc-service rc-status rc-update \
           sysctl reboot passwd mount umount chroot iptables ip6tables curl wget; do
    printf '#!/usr/bin/env bash\nprintf "UNMOCKED boundary: %s\\n" >&2\nexit 99\n' "$cmd" > "$R/deny/$cmd"
    chmod 0755 -- "$R/deny/$cmd"
done
# shellcheck disable=SC1090
source "${SYSTEM_MODULE_UNDER_TEST:-$ROOT/modules/system.sh}"
_toolbox_system_root() { return 0; }
_toolbox_system_os() { printf 'alpine\n'; }
fail() {
    printf 'FAIL %s: %s\n' "$CASE" "$*" >&2
    for file in "$F/out" "$LOG"; do [[ ! -f $file ]] || /usr/bin/cat -- "$file" >&2; done
    exit 1
}
has_token() {
    local token
    local -a tokens=()
    while read -r -a tokens; do
        for token in "${tokens[@]}"; do [[ $token != "$2" ]] || return 0; done
    done < "$1"
    return 1
}
setup() {
    CASE=$1; F="$R/$CASE"; LOG="$F/commands.log"
    export HOME="$F/home"
    export TOOLBOX_DOCKER_DATA_ROOT="$F/data" TOOLBOX_DOCKER_ETC_DIR="$F/etc/docker"
    export TOOLBOX_SYSTEM_STATE="$F/state"
    export TOOLBOX_DOCKER_CONTAINERD_ETC_DIR="$F/etc/containerd"
    export TOOLBOX_DOCKER_OPENRC_INIT_DIR="$F/etc/init.d" TOOLBOX_DOCKER_OPENRC_CONF_DIR="$F/etc/conf.d"
    export TOOLBOX_DOCKER_RUN_DIR="$F/run" TOOLBOX_DOCKER_OPENRC_RUN="$F/run/openrc"
    export TOOLBOX_DOCKER_OPENRC_RUNLEVEL_DIR="$F/etc/runlevels"
    mkdir -p -- "$HOME" "$TOOLBOX_DOCKER_DATA_ROOT" "$TOOLBOX_DOCKER_OPENRC_INIT_DIR" \
        "$TOOLBOX_DOCKER_OPENRC_CONF_DIR" "$TOOLBOX_DOCKER_OPENRC_RUN" "$TOOLBOX_DOCKER_OPENRC_RUNLEVEL_DIR/default"
    printf 'default\n' > "$TOOLBOX_DOCKER_OPENRC_RUN/softlevel"
    : > "$LOG"; : > "$F/packages"; : > "$F/commands"; : > "$F/out"
    unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_CONFIG
    MISSING='' FAIL_APK='' FAIL_START=0 FAIL_STATUS=0 BAD_OWNER=0 BAD_VERSION='' READ_FAIL=0
    NOT_READY=0 NO_TOOLS='' NO_DEPS_READBACK=0 START_CALLS=0
    _toolbox_system_has() {
        local c=$1
        case " $NO_TOOLS " in *" $c "*) return 1;; esac
        case $c in
            curl|socat|wget|sudo|nano|iptables|ss)
                case " $MISSING " in *" $c "*) has_token "$F/commands" "$c";; *) return 0;; esac;;
            docker|dockerd|containerd|runc) has_token "$F/commands" "$c";;
            *) return 0;;
        esac
    }
    apk() {
        printf 'apk %s\n' "$*" >> "$LOG"
        local p c
        case $1 in
            info)
                case $2 in
                    -e|--exists)
                        [[ ${PACKAGE_READ_FAIL:-0} == 0 ]] || return 2
                        shift 2
                        for p in "$@"; do has_token "$F/packages" "$p" || return 1; done;;
                    --who-owns|-W)
                        [[ $BAD_OWNER == 0 ]] || { printf '%s is owned by foreign-1.0-r0\n' "$3"; return 0; }
                        printf '%s is owned by docker-openrc-29.9.2-r0\n' "$3";;
                    *) return 99;;
                esac;;
            update) [[ $FAIL_APK != update ]];;
            add)
                if [[ $FAIL_APK == add ]]; then printf 'docker-engine\n' >> "$F/packages"; return 9; fi
                for p in "$@"; do
                    case $p in
                        add|--no-cache) continue;;
                        docker)
                            printf 'docker docker-engine docker-cli containerd runc\n' >> "$F/packages"
                            printf 'docker dockerd containerd runc\n' >> "$F/commands";;
                        docker-openrc)
                            printf '%s\n' "$p" >> "$F/packages"
                            printf '#!/sbin/openrc-run\n# fixture, never executed\n' > "$TOOLBOX_DOCKER_OPENRC_INIT_DIR/docker"
                            chmod 0755 -- "$TOOLBOX_DOCKER_OPENRC_INIT_DIR/docker"
                            printf '# package default config fixture\n' > "$TOOLBOX_DOCKER_OPENRC_CONF_DIR/docker";;
                        docker-cli-compose) printf '%s\n' "$p" >> "$F/packages";;
                        iproute2-ss) c=ss; [[ $NO_DEPS_READBACK != 1 ]] || continue; printf '%s\n' "$c" >> "$F/commands";;
                        *) [[ $NO_DEPS_READBACK != 1 ]] || continue; printf '%s\n' "$p" >> "$F/commands";;
                    esac
                done
                [[ -z ${POST_INSTALL_FOREIGN:-} ]] || printf 'foreign' > "$POST_INSTALL_FOREIGN"
                return 0;;
            *) return 99;;
        esac
    }
    rc-status() { printf 'rc-status %s\n' "$*" >> "$LOG"; [[ ${OPENRC_READ_FAIL:-0} == 0 ]]; }
    rc-service() {
        printf 'rc-service %s\n' "$*" >> "$LOG"
        case "$*" in
            'docker start')
                START_CALLS=$((START_CALLS + 1))
                [[ $FAIL_START == 0 ]] || { printf 'mock start failed\n' >&2; return 9; }
                : > "$F/started";;
            'docker status') [[ $FAIL_STATUS == 0 && -e $F/started ]];;
            *) return 99;;
        esac
    }
    rc-update() { printf 'UNEXPECTED rc-update %s\n' "$*" >> "$LOG"; return 99; }
    docker() {
        printf 'docker %s\n' "$*" >> "$LOG"
        [[ -e $F/started && $READ_FAIL == 0 ]] || return 1
        if (( NOT_READY > 0 )); then
            # File-backed retry counter survives command substitution.
            local left=${NOT_READY}
            [[ ! -f $F/retries ]] || left=$(<"$F/retries")
            if (( left > 0 )); then printf '%s\n' "$((left - 1))" > "$F/retries"; return 1; fi
        fi
        printf '%s\n' "${BAD_VERSION:-29.9.2}"
    }
    sleep() { printf 'sleep %s\n' "$*" >> "$LOG"; }
}
writes() {
    local line
    while IFS= read -r line; do
        case $line in 'apk add '*|'apk update'|'rc-service docker start'|UNEXPECTED*) printf '%s\n' "$line";; esac
    done < "$LOG"
}
run_action() {
    local input=$1
    shift
    printf '%s' "$input" > "$F/input"
    # The conditional caller mirrors menu || error handling (errexit is disabled).
    local rc=0
    "$@" < "$F/input" > "$F/out" 2>&1 || rc=$?
    return "$rc"
}
assert_refused_without_write() {
    if run_action $'YES\nYES\n' toolbox_system B1; then fail 'unsafe installation accepted'; fi
    [[ -z $(writes) ]] || fail 'refusal performed package/service writes'
}
case_test() (
    setup "$1"
    case $CASE in
        confirm)
            for input in $'yes\nyes\n' $'YeS\nyEs\n' $'YES\nYES\n'; do
                run_action "$input" _toolbox_system_confirm preview || fail 'case-insensitive double confirmation rejected'
                [[ $(<"$F/out") == *'再次输入 YES'* ]] || fail 'second confirmation absent'
            done
            for input in '' $'yes\n' $'yes\nyes' $'yes\nNO\n' $'NO\nyes\n' $'y\ny\n' $' yes\nyes\n' $'yes \nyes\n'; do
                if run_action "$input" _toolbox_system_confirm preview; then fail 'invalid/EOF confirmation accepted'; fi
            done;;
        deps)
            MISSING='socat nano ss'
            run_action $'yes\nYeS\n' toolbox_system MAIN_DEPS || fail 'Alpine missing commands could not be installed'
            [[ $(writes) == 'apk add --no-cache socat nano iproute2-ss' ]] || fail 'not missing-only or incorrect ss package'
            [[ $(<"$F/out") == *'回读'* ]] || fail 'no post-install command verification reported'
            : > "$LOG"
            run_action '' toolbox_system MAIN_DEPS || fail 'satisfied dependencies asked for confirmation'
            [[ -z $(writes) ]] || fail 'satisfied dependencies changed packages';;
        deps_failure)
            MISSING='ss'; NO_DEPS_READBACK=1
            if run_action $'YES\nYES\n' toolbox_system MAIN_DEPS; then fail 'apk success masked absent ss'; fi
            [[ $(<"$F/out") == *'ss'* && $(<"$F/out") != *'回读通过'* ]] || fail 'missing command readback not surfaced'
            : > "$LOG"; FAIL_APK=add
            if run_action $'YES\nYES\n' toolbox_system MAIN_DEPS; then fail 'apk failure swallowed'; fi
            : > "$LOG"; FAIL_APK=''
            for input in '' $'yes\n' $'yes\nno\n'; do
                if run_action "$input" toolbox_system MAIN_DEPS; then fail 'dependency confirmation failed open'; fi
                [[ -z $(writes) ]] || fail 'cancelled dependency action wrote packages'
            done;;
        docker)
            NOT_READY=2
            run_action $'YES\nYES\n' toolbox_system B1 || fail 'fresh Alpine Docker never started/read back Engine'
            [[ $(writes) == $'apk update\napk add --no-cache docker docker-cli-compose docker-openrc\nrc-service docker start' ]] || fail 'Docker package/start ordering changed'
            [[ $START_CALLS == 1 ]] || fail 'daemon started more than once'
            [[ $(<"$LOG") == *'docker --host unix:///var/run/docker.sock version --format {{.Server.Version}}'* ]] || fail 'verified wrong/default Docker endpoint'
            [[ $(<"$LOG") == *'rc-service docker status'* ]] || fail 'OpenRC service status not read back'
            [[ $(<"$F/out") == *'≥28'* && $(<"$F/out") == *'防火墙'* && $(<"$F/out") == *'不设置开机自启'* ]] || fail 'impact/boot scope not stated'
            : > "$LOG"
            assert_refused_without_write;;
        portable_log)
            # Match BusyBox mktemp's template contract, while keeping package
            # and daemon operations mocked. GNU mktemp accepts a suffix that
            # real Alpine rejects before any APK transaction can begin.
            mktemp() {
                [[ $# == 1 && $1 == *XXXXXX ]] || {
                    printf 'mktemp: Invalid argument (BusyBox template contract)\n' >&2
                    return 1
                }
                command mktemp "$@"
            }
            run_action $'yes\nYeS\n' toolbox_system B1 || fail 'Alpine-compatible log creation failed'
            logs=("$TOOLBOX_SYSTEM_STATE"/docker-alpine.log.*)
            [[ ${#logs[@]} == 1 && -f ${logs[0]} && $(stat -c '%a' -- "${logs[0]}") == 600 ]] || fail 'portable log is not private and unique'
            [[ $(<"${logs[0]}") == *'rc-service docker start'* ]] || fail 'portable log did not capture actual start boundary';;
        existing)
            printf 'docker\n' > "$F/commands"
            assert_refused_without_write
            [[ $(<"$F/out") == *'已存在'* ]] || fail 'existing gate lost';;
        conflicts)
            for target in "$TOOLBOX_DOCKER_DATA_ROOT/docker" "$TOOLBOX_DOCKER_DATA_ROOT/containerd" \
                "$TOOLBOX_DOCKER_ETC_DIR" "$F/etc/containerd" "$TOOLBOX_DOCKER_OPENRC_INIT_DIR/docker" \
                "$TOOLBOX_DOCKER_OPENRC_CONF_DIR/docker" "$TOOLBOX_DOCKER_OPENRC_INIT_DIR/containerd" \
                "$TOOLBOX_DOCKER_OPENRC_CONF_DIR/containerd" "$TOOLBOX_DOCKER_RUN_DIR/docker.sock" \
                "$TOOLBOX_DOCKER_RUN_DIR/containerd" "$TOOLBOX_DOCKER_OPENRC_RUNLEVEL_DIR/default/docker"; do
                printf 'foreign\n' > "$target"; : > "$LOG"
                assert_refused_without_write
                [[ $(<"$target") == foreign ]] || fail "foreign file changed: $target"
                rm -f -- "$target"
                ln -s -- "$F/nonexistent" "$target"; : > "$LOG"
                assert_refused_without_write
                [[ -L $target ]] || fail 'foreign dangling symlink changed'
                rm -f -- "$target"
            done
            for pkg in docker-engine docker-openrc docker-cli containerd containerd-openrc runc; do
                printf '%s\n' "$pkg" > "$F/packages"; : > "$LOG"
                assert_refused_without_write
            done;;
        prerequisites)
            for tool in apk rc-service rc-status; do
                NO_TOOLS=$tool; : > "$LOG"
                assert_refused_without_write
            done
            NO_TOOLS=''; rm -f -- "$TOOLBOX_DOCKER_OPENRC_RUN/softlevel"; : > "$LOG"
            assert_refused_without_write
            printf 'default\n' > "$TOOLBOX_DOCKER_OPENRC_RUN/softlevel"
            OPENRC_READ_FAIL=1; : > "$LOG"; assert_refused_without_write
            unset OPENRC_READ_FAIL
            PACKAGE_READ_FAIL=1; : > "$LOG"; assert_refused_without_write
            unset PACKAGE_READ_FAIL
            for env in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
                export "$env=foreign"; : > "$LOG"
                assert_refused_without_write
                unset "$env"
            done;;
        docker_failure)
            FAIL_START=1
            if run_action $'YES\nYES\n' toolbox_system B1; then fail 'failed daemon start claimed success'; fi
            [[ $(<"$F/out") == *'安装/启动记录：'* ]] || fail 'no retained install/start log path'
            logs=("$TOOLBOX_SYSTEM_STATE"/docker-alpine.log.*)
            [[ -f ${logs[0]} && $(stat -c '%a' -- "${logs[0]}") == 600 ]] || fail 'no private retained failure log'
            [[ $(<"${logs[0]}") == *'mock start failed'* ]] || fail 'failure log omitted command output'
            [[ $(<"$F/out") == *'保留'* && $(<"$F/out") == *'rc-service docker status'* && $(<"$F/out") == *'/var/log/docker.log'* ]] || fail 'no failure recovery evidence'
            [[ -f $TOOLBOX_DOCKER_OPENRC_INIT_DIR/docker && $(<"$F/packages") == *docker-engine* ]] || fail 'failed install removed packages/service files'
            [[ $(<"$LOG") != *'apk del'* && $(<"$LOG") != *'docker stop'* && $(<"$LOG") != *'rc-service docker stop'* ]] || fail 'automatic destructive rollback'
            : > "$LOG"; assert_refused_without_write;;
        install_failure)
            FAIL_APK=add
            if run_action $'YES\nYES\n' toolbox_system B1; then fail 'partial package failure claimed success'; fi
            [[ $(<"$F/out") == *'保留'* && $(<"$LOG") != *'rc-service docker start'* ]] || fail 'partial install not preserved or daemon started'
            : > "$LOG"; assert_refused_without_write;;
        update_failure)
            FAIL_APK=update
            if run_action $'YES\nYES\n' toolbox_system B1; then fail 'update failure ignored'; fi
            [[ $(writes) == 'apk update' ]] || fail 'update failure still installed/started';;
        bad_owner)
            BAD_OWNER=1
            if run_action $'YES\nYES\n' toolbox_system B1; then fail 'foreign service accepted'; fi
            [[ $(<"$LOG") != *'rc-service docker start'* && $(<"$F/out") == *'保留'* ]] || fail 'service ownership not enforced';;
        status_failure)
            FAIL_STATUS=1
            if run_action $'YES\nYES\n' toolbox_system B1; then fail 'unconfirmed service status accepted'; fi
            [[ $(<"$F/out") == *'保留'* ]] || fail 'unknown status not preserved';;
        engine_failure)
            READ_FAIL=1
            if run_action $'YES\nYES\n' toolbox_system B1; then fail 'unreachable Engine accepted'; fi
            [[ $START_CALLS == 1 && $(<"$F/out") == *'保留'* ]] || fail 'failed readiness restarted/deleted daemon';;
        version_failure)
            BAD_VERSION=${SYSTEM_ALPINE_BAD_VERSION:-27.9.9}
            if run_action $'YES\nYES\n' toolbox_system B1; then fail "unsafe Engine accepted: $BAD_VERSION"; fi
            [[ $(<"$F/out") != *'Docker Engine 已安装'* && $(<"$F/out") == *'保留'* ]] || fail 'failed Engine acceptance claimed success';;
        cancel)
            for input in '' $'YES\n' $'YES\nNO\n'; do
                : > "$LOG"
                if run_action "$input" toolbox_system B1; then fail 'cancelled install accepted'; fi
                [[ -z $(writes) ]] || fail 'confirmation cancelled after writes'
            done;;
        post_install_conflict)
            POST_INSTALL_FOREIGN="$TOOLBOX_DOCKER_DATA_ROOT/docker"
            if run_action $'YES\nYES\n' toolbox_system B1; then fail 'post-install foreign data started'; fi
            [[ $(<"$LOG") != *'rc-service docker start'* && $(<"$POST_INSTALL_FOREIGN") == foreign ]] || fail 'post-install data conflict not preserved';;
        race)
            # A foreign file introduced while the operator confirms is not ours.
            _toolbox_system_confirm() { printf 'foreign\n' > "$TOOLBOX_DOCKER_OPENRC_INIT_DIR/docker"; return 0; }
            assert_refused_without_write
            [[ $(<"$TOOLBOX_DOCKER_OPENRC_INIT_DIR/docker") == foreign ]] || fail 'confirmation race overwrote foreign service';;
        *) fail 'unknown case';;
    esac
    printf 'PASS %s (mock)\n' "$CASE"
)
cases=(confirm deps deps_failure docker portable_log existing conflicts prerequisites docker_failure install_failure update_failure bad_owner status_failure engine_failure version_failure cancel post_install_conflict race)
[[ -z ${SYSTEM_ALPINE_CASE:-} ]] || cases=("$SYSTEM_ALPINE_CASE")
failed=0
for test in "${cases[@]}"; do
    # Do not run the test in a conditional: its own exit must fail the suite.
    set +e
    ( set -e; case_test "$test" )
    rc=$?
    set -e
    (( rc == 0 )) || failed=1
done
(( failed == 0 )) || exit 1
printf 'Alpine feedback regressions passed (mock only; no host apk/Docker/OpenRC writes).\n'
