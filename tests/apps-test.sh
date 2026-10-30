#!/usr/bin/env bash
# Isolated tests: docker is a shell mock; no daemon or deployment is touched.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/../modules/apps.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-apps.XXXXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home" LOG="$TEST_DIR/docker.log"
mkdir -p "$HOME"
: > "$LOG"
docker() {
  printf '%s\n' "CALL $*" >> "$LOG"
  case "$1 ${2-}" in
    'context show') [[ ${MOCK_CONTEXT_FAIL:-0} != 1 ]] || return 1; printf '%s\n' "${MOCK_CONTEXT:-default}" ;;
    'context inspect') [[ ${MOCK_INSPECT_FAIL:-0} != 1 ]] || return 1; printf '%s\n' "${MOCK_ENDPOINT:-unix:///var/run/docker.sock}" ;;
    'version --format') [[ ${MOCK_VERSION_FAIL:-0} != 1 ]] || return 1; printf '%s\n' "${MOCK_VERSION:-28.0.0}" ;;
    'info ') [[ ${MOCK_OFFLINE:-0} != 1 ]] ;;
    'network create') [[ ${MOCK_NETWORK_FAIL:-0} != 1 ]] || return 1; if [[ ${MOCK_NETWORK_BAD:-0} == 1 ]]; then printf 'invalid\n'; else printf '%s' "$*" | sha256sum | cut -d' ' -f1; fi ;;
    'container ls') [[ ${MOCK_LIST_FAIL:-0} != 1 ]] || return 1; printf '%s\n' "${MOCK_NAMES:-}" ;;
    'run -d') [[ ${MOCK_FAIL:-0} != 1 ]] && printf 'mock-container-id\n' ;;
    *) printf 'unexpected docker call: %s\n' "$*" >&2; return 1 ;;
  esac
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_log() { grep -F -- "$1" "$LOG" >/dev/null || fail "missing log $1"; }
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION
reset_test() { : > "$LOG"; rm -rf "$HOME/.local"; unset MOCK_FAIL MOCK_OFFLINE MOCK_NAMES MOCK_LIST_FAIL MOCK_CONTEXT MOCK_CONTEXT_FAIL MOCK_ENDPOINT MOCK_INSPECT_FAIL MOCK_VERSION MOCK_VERSION_FAIL MOCK_NETWORK_FAIL MOCK_NETWORK_BAD || :; }

# Remote daemon overrides must be rejected before Docker or host filesystem writes.
if DOCKER_HOST=tcp://remote:2375 toolbox_app 9 <<< $'\ny' >/dev/null 2>&1; then fail 'remote Docker host accepted'; fi
[[ ! -s $LOG ]] || fail 'remote override invoked Docker'
for variable in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH DOCKER_API_VERSION; do
  export "$variable="
  if toolbox_app 9 <<< $'\ny' >/dev/null 2>&1; then fail "empty $variable accepted"; fi
  unset "$variable"
  [[ ! -s $LOG ]] || fail "$variable invoked Docker"
done
# Context and version failures must occur before network creation, data or container writes.
for scenario in 'MOCK_CONTEXT=remote' 'MOCK_CONTEXT_FAIL=1' 'MOCK_ENDPOINT=tcp://remote:2375' 'MOCK_ENDPOINT=unix:///tmp/proxy.sock' 'MOCK_INSPECT_FAIL=1' 'MOCK_VERSION=27.5.1' 'MOCK_VERSION=28.0.0-rc1' 'MOCK_VERSION=unknown' 'MOCK_VERSION_FAIL=1'; do
  reset_test
  export "${scenario?}"
  if toolbox_app 3 <<< $'\ny' >/dev/null 2>&1; then fail "unsafe prerequisite accepted: $scenario"; fi
  ! grep -E '^CALL (network create|run) ' "$LOG" >/dev/null || fail "unsafe prerequisite wrote: $scenario"
  [[ ! -e $HOME/.local ]] || fail "unsafe prerequisite created data: $scenario"
done
reset_test

# Dispatch failures and cancellation must never invoke docker run.
if toolbox_app 18 </dev/null; then fail 'B18 must be reserved'; fi
if toolbox_app invalid </dev/null; then fail 'invalid ID'; fi
if toolbox_app 9 <<< $'\nn'; then fail 'cancel must fail'; fi
! grep -F 'CALL run' "$LOG" >/dev/null || fail 'cancel ran docker'
reset_test
MOCK_OFFLINE=1
if toolbox_app 9 </dev/null; then fail 'offline daemon'; fi
! grep -F 'CALL run' "$LOG" >/dev/null || fail 'offline ran docker'
reset_test
MOCK_LIST_FAIL=1
if toolbox_app 9 </dev/null; then fail 'container listing failure'; fi
! grep -F 'CALL run' "$LOG" >/dev/null || fail 'failed lookup ran docker'
reset_test
MOCK_NAMES=terry-it-tools
if toolbox_app 9 </dev/null; then fail 'container conflict'; fi
! grep -F 'CALL run' "$LOG" >/dev/null || fail 'conflict ran docker'
reset_test
if toolbox_app 9 <<< $'0\ny'; then fail 'invalid port'; fi
if toolbox_app 9 <<< $'65536\ny'; then fail 'invalid port'; fi
if toolbox_app 9 <<< $'00080\ny'; then fail 'leading zero port'; fi
! grep -F 'CALL run' "$LOG" >/dev/null || fail 'invalid port ran docker'
reset_test
for id in 3 9 13 17 20 21 22 24 27 29 30; do
  toolbox_app "$id" <<< $'\ny' >/dev/null || fail "B$id did not run"
done
assert_log '127.0.0.1:7090:80'
assert_log '127.0.0.1:81:81'
assert_log '127.0.0.1:80:80'
assert_log '127.0.0.1:443:443'
# All except Stirling PDF (registry inaccessible during validation) must be pinned.
# Assert the image is the last run argument, not merely mentioned elsewhere.
for repo in xhofe/alist corentinth/it-tools jason5ng32/myip hslr/sun-panel neosmemo/memos jc21/nginx-proxy-manager halohub/halo cym1102/nginxwebui jeessy/ddns-go vaultwarden/server; do
  grep -E "^CALL run .* ${repo}@sha256:[0-9a-f]{64}$" "$LOG" >/dev/null || fail "missing pinned image: $repo"
done
assert_log 'docker.stirlingpdf.com/stirlingtools/stirling-pdf:latest'
stirling_output=$(toolbox_app 27 <<< $'REUSE\n\nn' 2>&1 || :)
[[ $stirling_output == *'镜像标签可变'* ]] || fail 'mutable image warning missing'
# Every published port is loopback only; host networking/socket never used.
if grep '^CALL run ' "$LOG" | grep -E -- '(^| )(-p|--publish) (0\.0\.0\.0|[0-9]+:)|--net(=|work[= ]host)|docker\.sock' >/dev/null; then fail 'unsafe network or socket'; fi
[[ $(grep -c '^CALL network create --driver bridge ' "$LOG") == 11 ]] || fail 'missing per-app network'
[[ $(grep '^CALL run ' "$LOG" | grep -c -- '--network [a-f0-9]\{64\}') == 11 ]] || fail 'network ID missing'
[[ $(grep '^CALL network create ' "$LOG" | sort -u | wc -l) == 11 ]] || fail 'network reused'
reset_test
if toolbox_app 21 <<< $'80\ny' >/dev/null; then fail 'NPM duplicate port'; fi
if toolbox_app 3 <<< $'\ny' >/dev/null; then :; else fail 'fresh alist'; fi
if toolbox_app 3 <<< $'\ny' >/dev/null; then fail 'existing data directory'; fi
reset_test
mkdir -p "$HOME/.local/share/terry-toolbox/apps/alist"
printf 'keep' > "$HOME/.local/share/terry-toolbox/apps/alist/sentinel"
if toolbox_app 3 <<< $'\ny' >/dev/null; then fail 'existing user data'; fi
[[ $(< "$HOME/.local/share/terry-toolbox/apps/alist/sentinel") == keep ]] || fail 'existing data modified'
reset_test
if HOME="${HOME},evil" toolbox_app 3 <<< $'\ny' >/dev/null; then fail 'ambiguous mount path'; fi
reset_test
if toolbox_app 26 <<< $'\ny\nshort' >/dev/null; then fail 'weak password accepted'; fi
if toolbox_app 25 <<< $'\ny\nwrong' >/dev/null; then fail 'invalid key accepted'; fi
! grep -F 'CALL run' "$LOG" >/dev/null || fail 'invalid credentials ran docker'
reset_test
MOCK_FAIL=1
if toolbox_app 9 <<< $'\ny' >/dev/null; then fail 'run failure'; fi
reset_test
# Failed stateful deployment preserves data; explicit REUSE and a second confirmation
# are required, and no cleanup call is permitted.
MOCK_FAIL=1
if toolbox_app 3 <<< $'\ny' >/dev/null 2>&1; then fail 'stateful run failure'; fi
[[ -d $HOME/.local/share/terry-toolbox/apps/alist ]] || fail 'failed deployment data missing'
printf keep > "$HOME/.local/share/terry-toolbox/apps/alist/sentinel"
unset MOCK_FAIL
: > "$LOG"
if toolbox_app 3 <<< $'yes\n\ny' >/dev/null 2>&1; then fail 'implicit reuse accepted'; fi
! grep -E '^CALL (run|network create)' "$LOG" >/dev/null || fail 'reuse refusal wrote docker resources'
if toolbox_app 3 <<< $'REUSE\n\nn' >/dev/null 2>&1; then fail 'reuse without final confirmation'; fi
! grep -E '^CALL (run|network create)' "$LOG" >/dev/null || fail 'cancelled reuse wrote docker resources'
toolbox_app 3 <<< $'REUSE\n\ny' >/dev/null 2>&1 || fail 'confirmed recovery'
[[ $(< "$HOME/.local/share/terry-toolbox/apps/alist/sentinel") == keep ]] || fail 'recovery modified sentinel'
assert_log "type=bind,src=$HOME/.local/share/terry-toolbox/apps/alist,dst=/opt/alist/data"
! grep -E '^CALL (rm|container rm|network rm|volume rm)' "$LOG" >/dev/null || fail 'automatic deletion'
reset_test
mkdir -p "$HOME/.local/share/terry-toolbox/apps" "$TEST_DIR/outside"
ln -s "$TEST_DIR/outside" "$HOME/.local/share/terry-toolbox/apps/alist"
if toolbox_app 3 <<< $'REUSE\n\ny' >/dev/null 2>&1; then fail 'symlink reuse accepted'; fi
! grep -E '^CALL (run|network create)' "$LOG" >/dev/null || fail 'symlink wrote Docker resources'
reset_test
mkdir -p "$HOME/.local/share/terry-toolbox/apps/nginx-proxy-manager" "$TEST_DIR/certs"
ln -s "$TEST_DIR/certs" "$HOME/.local/share/terry-toolbox/apps/nginx-proxy-manager/letsencrypt"
if toolbox_app 21 <<< $'REUSE\n\ny' >/dev/null 2>&1; then fail 'symlink certificate directory accepted'; fi
! grep -E '^CALL (run|network create)' "$LOG" >/dev/null || fail 'symlink cert wrote Docker resources'
reset_test
MOCK_NETWORK_FAIL=1
if toolbox_app 3 <<< $'\ny' >/dev/null 2>&1; then fail 'network failure accepted'; fi
[[ -d $HOME/.local/share/terry-toolbox/apps/alist ]] || fail 'network failure lost data'
! grep -F 'CALL run' "$LOG" >/dev/null || fail 'network failure ran container'
reset_test
MOCK_NETWORK_BAD=1
if toolbox_app 9 <<< $'\ny' >/dev/null 2>&1; then fail 'bad network ID accepted'; fi
! grep -F 'CALL run' "$LOG" >/dev/null || fail 'bad network ID ran container'
reset_test
npm_output=$(toolbox_app 21 <<< $'\nn' 2>&1 || :)
[[ $npm_output == *'localhost 指向 NPM 自身'* && $npm_output == *'无法访问宿主机 127.0.0.1'* && $npm_output == *'独立网络'* ]] || fail 'NPM limitations missing'
[[ $npm_output == *'自定义直接路由'* ]] || fail 'network exposure warning missing'
reset_test
# Environment variables, not command arguments, carry secrets into Docker.
toolbox_app 26 <<< $'\ny\nthis-is-a-strong-password' >/dev/null || fail 'LibreTV'
assert_log '--env PASSWORD'
grep -E '^CALL run .* ghcr\.io/librespark/libretv@sha256:[0-9a-f]{64}$' "$LOG" >/dev/null || fail 'LibreTV image not pinned'
! grep -F 'this-is-a-strong-password' "$LOG" >/dev/null || fail 'password in argv'
reset_test
toolbox_app 25 <<< $'\ny\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' >/dev/null || fail 'Nexterm'
assert_log '--env ENCRYPTION_KEY'
grep -E '^CALL run .* nexterm/aio@sha256:[0-9a-f]{64}$' "$LOG" >/dev/null || fail 'Nexterm image not pinned'
! grep -F '0123456789abcdef' "$LOG" >/dev/null || fail 'key in argv'
reset_test
# B4/B5: official pinned images, stateful mounts and isolated management ports.
for id in 4 5; do
  toolbox_app "$id" <<< $'\ny' > "$TEST_DIR/output-$id" 2>&1 || fail "B$id did not run"
done
assert_log '127.0.0.1:8008:8008'
assert_log '127.0.0.1:2053:2053'
assert_log "type=bind,src=$HOME/.local/share/terry-toolbox/apps/nezha,dst=/dashboard/data"
assert_log "type=bind,src=$HOME/.local/share/terry-toolbox/apps/x-ui,dst=/etc/x-ui"
assert_log "type=bind,src=$HOME/.local/share/terry-toolbox/apps/x-ui/cert,dst=/root/cert"
assert_log "type=bind,src=$HOME/.local/share/terry-toolbox/apps/x-ui/acme,dst=/root/.acme.sh"
assert_log 'XUI_ENABLE_FAIL2BAN=false'
for repo in ghcr.io/nezhahq/nezha ghcr.io/mhsanaei/3x-ui; do
  grep -E "^CALL run .* ${repo}@sha256:[0-9a-f]{64}$" "$LOG" >/dev/null || fail "missing pinned image: $repo"
done
[[ $(grep -c '^CALL network create --driver bridge ' "$LOG") == 2 ]] || fail 'B4/B5 missing isolated network'
! grep '^CALL run ' "$LOG" | grep -E -- '--net(=|work[= ]host)|docker\.sock|--cap-add' >/dev/null || fail 'B4/B5 unsafe privileges or network'
grep -F 'admin/admin' "$TEST_DIR/output-4" >/dev/null || fail 'Nezha bootstrap warning missing'
grep -F 'admin/admin' "$TEST_DIR/output-5" >/dev/null || fail '3x-ui bootstrap warning missing'
grep -F '入站端口' "$TEST_DIR/output-5" >/dev/null || fail '3x-ui inbound warning missing'
reset_test
mkdir -p "$HOME/.local/share/terry-toolbox/apps/x-ui" "$TEST_DIR/xui-outside"
ln -s "$TEST_DIR/xui-outside" "$HOME/.local/share/terry-toolbox/apps/x-ui/cert"
if toolbox_app 5 <<< $'REUSE\n\ny' >/dev/null 2>&1; then fail 'x-ui symlink cert accepted'; fi
! grep -E '^CALL (run|network create)' "$LOG" >/dev/null || fail 'unsafe x-ui cert wrote resources'
reset_test
for id in 4 5; do
  if toolbox_app "$id" <<< $'65536\ny' >/dev/null 2>&1; then fail "B$id accepted invalid port"; fi
  if toolbox_app "$id" <<< $'\nn' >/dev/null 2>&1; then fail "B$id accepted cancellation"; fi
done
! grep -E '^CALL (run|network create)' "$LOG" >/dev/null || fail 'invalid port/cancellation wrote resources'
[[ ! -e $HOME/.local ]] || fail 'invalid port/cancellation created data'
reset_test
for id in 4 5; do
  toolbox_app "$id" <<< $'18088\ny' >/dev/null 2>&1 || fail "B$id custom port"
done
assert_log '127.0.0.1:18088:8008'
assert_log '127.0.0.1:18088:2053'
reset_test
MOCK_FAIL=1
if toolbox_app 5 <<< $'\ny' >/dev/null 2>&1; then fail 'x-ui failed run accepted'; fi
[[ -d $HOME/.local/share/terry-toolbox/apps/x-ui/cert && -d $HOME/.local/share/terry-toolbox/apps/x-ui/acme ]] || fail 'x-ui data not preserved'
unset MOCK_FAIL
: > "$LOG"
if toolbox_app 5 <<< $'no\n\ny' >/dev/null 2>&1; then fail 'x-ui implicit reuse accepted'; fi
! grep -E '^CALL (run|network create)' "$LOG" >/dev/null || fail 'x-ui reuse refusal wrote resources'
toolbox_app 5 <<< $'REUSE\n\ny' >/dev/null 2>&1 || fail 'x-ui confirmed reuse failed'
! grep -E '^CALL (rm|container rm|network rm|volume rm)' "$LOG" >/dev/null || fail 'x-ui automatic deletion'
reset_test

# Every app must state its actual auth/bootstrap situation, not just "change the password".
# Cancelling after the port prompt is enough: notes print before it.
for pair in '9:无内置认证' '13:无内置登录认证' '17:admin@sun.cc' '17:12345678' '20:第一个账号' \
            '21:初始化向导' '22:/console' '24:无默认凭据' '25:创建管理员账号' '26:没有用户名' \
            '27:SECURITY_ENABLELOGIN=false' '29:无默认凭据' '30:SIGNUPS_ALLOWED=true' \
            '4:admin/admin' '5:admin/admin'; do
  audit_id=${pair%%:*}; audit_want=${pair#*:}
  audit_out=$(toolbox_app "$audit_id" <<< $'\nn' 2>&1 || :)
  [[ $audit_out == *"$audit_want"* ]] || fail "B$audit_id missing auth note: $audit_want"
done
! grep -E '^CALL (run|network create)' "$LOG" >/dev/null || fail 'auth note audit wrote resources'
reset_test

# B28: publisher image pinned by digest, secret via environment, H2 data mounted,
# amd64/root/default-credential limits stated in the note.
toolbox_app 28 <<< $'\ny\nthis-is-a-strong-password' > "$TEST_DIR/output-28" 2>&1 || fail 'B28 did not run'
assert_log '127.0.0.1:9999:9999'
assert_log "--mount type=bind,src=$HOME/.local/share/terry-toolbox/apps/mfa-start,dst=/mfa-start/data"
assert_log '--env SPRING_SECURITY_USER_PASSWORD'
assert_log 'SPRING_SECURITY_USER_NAME=mfa-start-user'
grep -E '^CALL run .* lovele/mfa-start@sha256:[0-9a-f]{64}$' "$LOG" >/dev/null || fail 'B28 image not pinned'
! grep -F 'this-is-a-strong-password' "$LOG" >/dev/null || fail 'B28 password in argv'
[[ $(grep -c '^CALL network create --driver bridge ' "$LOG") == 1 ]] || fail 'B28 missing isolated network'
! grep '^CALL run ' "$LOG" | grep -E -- '--net(=|work[= ]host)|docker\.sock|--cap-add|--privileged' >/dev/null || fail 'B28 unsafe privileges or network'
grep -F 'admin/admin1234' "$TEST_DIR/output-28" >/dev/null || fail 'B28 default credential warning missing'
grep -F 'amd64' "$TEST_DIR/output-28" >/dev/null || fail 'B28 architecture note missing'
grep -F 'root 运行' "$TEST_DIR/output-28" >/dev/null || fail 'B28 root/ownership warning missing'
reset_test
if toolbox_app 28 <<< $'\ny\nshort' >/dev/null 2>&1; then fail 'B28 weak password accepted'; fi
! grep -E '^CALL (run|network create)' "$LOG" >/dev/null || fail 'B28 weak password wrote resources'
[[ ! -e $HOME/.local ]] || fail 'B28 weak password created data'
reset_test
if toolbox_app 28 <<< $'\ny\nn' >/dev/null 2>&1; then fail 'B28 accepted cancellation'; fi
if toolbox_app 28 <<< $'\nn' >/dev/null 2>&1; then fail 'B28 accepted port cancellation'; fi
reset_test
MOCK_FAIL=1
if toolbox_app 28 <<< $'\ny\nthis-is-a-strong-password' >/dev/null 2>&1; then fail 'B28 failed run accepted'; fi
[[ -d $HOME/.local/share/terry-toolbox/apps/mfa-start ]] || fail 'B28 data not preserved'
unset MOCK_FAIL
: > "$LOG"
if toolbox_app 28 <<< $'no\n\ny\nthis-is-a-strong-password' >/dev/null 2>&1; then fail 'B28 implicit reuse accepted'; fi
! grep -E '^CALL (run|network create)' "$LOG" >/dev/null || fail 'B28 reuse refusal wrote resources'
toolbox_app 28 <<< $'REUSE\n\ny\nthis-is-a-strong-password' >/dev/null 2>&1 || fail 'B28 confirmed reuse failed'
! grep -E '^CALL (rm|container rm|network rm|volume rm)' "$LOG" >/dev/null || fail 'B28 automatic deletion'
reset_test
printf 'All apps tests passed.\n'
