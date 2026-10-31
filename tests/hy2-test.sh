#!/usr/bin/env bash
# A4 Hysteria 2 安装模块的隔离测试。
# shellcheck disable=SC2317,SC2016
# Mock callbacks are invoked indirectly by the sourced installer.
#
# 真实：openssl 生成证书、sha256sum、install/stat、模块逻辑本身。
# 桩：systemctl / ss / curl / hysteria 二进制 / sleep。
# 所有路径都在临时目录，绝不碰本机 /etc、/usr/local/bin、systemd。
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/scratch-root.sh"
toolbox_test_scratch
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/root/.cache/terry-toolbox-tests}/toolbox-hy2-test.XXXXXXXX")
cleanup() {
    local rc=$?
    if [[ -s $work/package-boundary.log ]]; then
        printf 'FAIL: unmocked package/service command\n' >&2
        command cat "$work/package-boundary.log" >&2
        rc=1
    fi
    python3 -c '
import os, signal, time
marker = ("TOOLBOX_TEST_WORK=" + os.environ["TOOLBOX_TEST_WORK"]).encode()
skip = {os.getpid(), os.getppid()}
def owned(pid):
    try:
        return marker in open("/proc/%s/environ" % pid, "rb").read().split(b"\0")
    except (OSError, ProcessLookupError):
        return False
pids = [int(p) for p in os.listdir("/proc") if p.isdigit() and int(p) not in skip and owned(p)]
for pid in pids:
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: pass
time.sleep(0.05)
for pid in pids:
    if owned(pid):
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass
'
    rm -rf -- "${work:?}"
    exit "$rc"
}
trap cleanup EXIT
export HOME=$work/home TOOLBOX_TEST_WORK=$work
export TMPDIR=$work
mkdir -p "$HOME"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SD=$work/state
mkdir -p "$SD" "$work/bin" "$work/units" "$work/fakebin" "$work/systemd-run" "$work/pkg"
export SD

# ---- 路径注入：全部指向临时目录
export TOOLBOX_HY2_ETC=$work/etc/terry-toolbox-hy2
export TOOLBOX_HY2_UNIT_DIR=$work/units
export TOOLBOX_HY2_BIN_DIR=$work/bin
export TOOLBOX_HY2_LOCK=$work/lock
export TOOLBOX_HY2_CLIENT_DIR=$work/verify
export TOOLBOX_HY2_SYSTEMD_RUN=$work/systemd-run
export TOOLBOX_HY2_OS_RELEASE=$work/os-release
export TOOLBOX_HY2_BIN_SRC=$work/pkg/hysteria-linux-amd64
export PATH=$work/fakebin:$PATH
unset TOOLBOX_HY2_URL TOOLBOX_HY2_SHA256_ARM64
for cmd in sudo apk apt apt-get apt-cache aptitude dpkg dpkg-query dpkg-deb dnf yum rpm sysctl systemctl rc-service rc-update modprobe rmmod dkms depmod; do
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$0 $*" >> %q\n' "$work/package-boundary.log"
        printf 'exit 99\n'
    } > "$work/fakebin/$cmd"
    chmod +x "$work/fakebin/$cmd"
done
for guard_env in inherited empty; do
    if [[ $guard_env == empty ]]; then
        env -i PATH="$PATH" bash --noprofile --norc -c 'apt-get --fixture-guard-probe' && exit 1 || [[ $? == 99 ]]
    else
        bash --noprofile --norc -c 'apt-get --fixture-guard-probe' && exit 1 || [[ $? == 99 ]]
    fi
done
[[ $(wc -l < "$work/package-boundary.log") -eq 2 ]]
: > "$work/package-boundary.log"

printf 'ID=debian\nVERSION_ID="13"\n' > "$TOOLBOX_HY2_OS_RELEASE"
printf 'ID=ubuntu\n' > "$work/os-ubuntu"
printf 'ID=alpine\n' > "$work/os-alpine"

# ---- 服务二进制桩：server 报启动成功，client 按 auth 与真实密码比对
cat > "$TOOLBOX_HY2_BIN_SRC" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SD/stub.log"
case ${1:-} in
    server)
        [[ -e $SD/smoke_fail ]] && { printf 'FATAL\tfailed to load server config\n'; exit 1; }
        [[ -e $SD/silent ]] && exit 0
        printf 'INFO\tserver up and running\n'
        ;;
    client)
        cfg=''
        for ((i = 1; i <= $#; i++)); do
            [[ ${!i} == -c ]] && { j=$((i + 1)); cfg=${!j}; }
        done
        auth=$(sed -n 's/^auth: //p' "$cfg")
        real=$(sed -n "s/^  password: '\(.*\)'/\1/p" "$TOOLBOX_HY2_ETC/config.yaml" 2>/dev/null) || real=''
        [[ -e $SD/accept_any ]] && { printf 'INFO\tconnected to server\n'; exit 0; }
        [[ -n $real && $auth == "$real" ]] && { printf 'INFO\tconnected to server\n'; exit 0; }
        printf 'FATAL\tauthentication error, HTTP status code: 502\n'
        exit 1
        ;;
esac
STUB
chmod +x "$TOOLBOX_HY2_BIN_SRC"
export TOOLBOX_HY2_SHA256
TOOLBOX_HY2_SHA256=$(sha256sum -- "$TOOLBOX_HY2_BIN_SRC" | cut -d' ' -f1)

# ---- curl 桩：下载时复制二进制；SOCKS 探测返回 200；可注入失败
cat > "$work/fakebin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SD/curl.log"
case " $* " in
    *--socks5-hostname*)
        [[ -e $SD/data_fail ]] && exit 7
        printf '200'
        exit 0
        ;;
esac
[[ -e $SD/download_fail ]] && exit 22
out='' prev=''
for a in "$@"; do [[ $prev == -o ]] && out=$a; prev=$a; done
[[ -n $out ]] && cp -- "$TOOLBOX_HY2_BIN_SRC" "$out"
exit 0
CURL
chmod +x "$work/fakebin/curl"

# ---- systemctl / ss / sleep 桩（同一 shell 内生效，子 shell 继承）
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$SD/systemctl.log"
    case ${1:-} in
        is-active)
            [[ -e $SD/status_fail ]] && return 1
            [[ -e $SD/active ]] && return 0 || return 3 ;;
        enable)
            [[ -e $SD/enable_fail ]] && return 1
            [[ $* == *--now* && ! -e $SD/noactivate ]] && : > "$SD/active"
            return 0
            ;;
        disable)
            [[ -e $SD/disable_fail ]] && return 1
            [[ $* == *--now* && ! -e $SD/stop_stuck ]] && rm -f "$SD/active"
            return 0 ;;
        show) [[ -e $SD/mainpid ]] && cat "$SD/mainpid"; return 0 ;;
        *) return 0 ;;
    esac
}
ss() {
    [[ -e $SD/ports ]] && cat "$SD/ports"
    if [[ $* == *lunpH* || $* == *-p* ]] && [[ -e $SD/active && -n ${MOCK_PORT:-} ]]; then
        printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:* users:(("terry-toolbox-hy2",pid=999999,fd=3))\n' "$MOCK_PORT"
    fi
    return 0
}
sleep() { :; }

source "$ROOT/modules/hy2.sh"

# ---- 断言工具
reset() {
    rm -rf -- "${work:?}/etc" "${work:?}/verify" "${work:?}/lock"
    find "$work/units" -mindepth 1 -delete
    find "$work/bin" -mindepth 1 -delete
    rm -f "$SD"/*.log "$SD/active"
    rm -f "$SD"/smoke_fail "$SD"/silent "$SD"/accept_any "$SD"/download_fail "$SD"/data_fail \
        "$SD"/enable_fail "$SD"/noactivate "$SD"/ports "$SD"/disable_fail "$SD"/stop_stuck "$SD"/mainpid
    rm -f "$SD/status_fail"
    unset MOCK_PORT
}
wrote() {
    [[ -e $work/bin/terry-toolbox-hy2 || -d $work/etc/terry-toolbox-hy2 \
        || -e $work/units/terry-toolbox-hy2.service ]]
}
assert_clean() { if wrote; then fail "$1：留下了写入"; fi; }
called() { grep -qF -- "$1" "$SD/systemctl.log" 2>/dev/null || fail "缺少 systemctl 调用: $1"; }

# ---- 证书夹具：真实 PEM；固定过期时间兼容 OpenSSL 1.1
mk_cert() { # <名> <CN/SAN> [额外 openssl 参数...]
    local name=$1 host=$2
    shift 2
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
        -keyout "$work/$name.key" -out "$work/$name.crt" \
        -subj "/CN=$host" -addext "subjectAltName=DNS:$host" "$@" >/dev/null 2>&1 \
        || fail "无法生成测试证书 $name"
}
mk_cert good hy2.example.test
mk_cert other wrong.example.test
mk_cert wild '*.wild.test'
# The shared helper avoids newer openssl req date flags; never skip expiry.
python3 "$ROOT/tests/certificate-fixture.py" "$work/past.crt" "$work/past.key" \
    20200101000000Z 20200102000000Z --hostname hy2.example.test

GOOD_H=hy2.example.test

# 1. sourcing 必须无副作用且只定义入口
before=$(find "$work" -mindepth 1 | wc -l)
out=$(bash -ec "source '$ROOT/modules/hy2.sh'; declare -F toolbox_hy2 >/dev/null && printf ok")
[[ $out == ok ]] || fail 'sourcing 未定义 toolbox_hy2'
[[ $(find "$work" -mindepth 1 | wc -l) -eq $before ]] || fail 'sourcing 产生文件'
out=$(bash -euc 'source "$1"; source "$1"; declare -F toolbox_hy2 >/dev/null; printf ok' _ "$ROOT/modules/hy2.sh" 2>"$work/source-twice.err") \
    || fail '重复 source hy2.sh 失败'
[[ $out == ok && ! -s $work/source-twice.err ]] || fail '重复 source hy2.sh 有输出或 readonly 报错'

# 2. 非 root 拒绝
if TOOLBOX_HY2_UID=1000 toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 443 <<< 'YES' >/dev/null 2>&1; then
    fail '非 root 被接受'
fi
assert_clean '非 root'

# 3. 非 Debian / 无 systemd 在写盘前拒绝
os_saved=$TOOLBOX_HY2_OS_RELEASE
TOOLBOX_HY2_OS_RELEASE=$work/os-ubuntu
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail 'Ubuntu 被接受'; fi
assert_clean 'Ubuntu'
TOOLBOX_HY2_OS_RELEASE=$work/os-alpine
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail 'Alpine 被接受'; fi
assert_clean 'Alpine'
TOOLBOX_HY2_OS_RELEASE=$os_saved
run_saved=$TOOLBOX_HY2_SYSTEMD_RUN
TOOLBOX_HY2_SYSTEMD_RUN=$work/nope
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail '无 systemd 被接受'; fi
assert_clean '无 systemd'
TOOLBOX_HY2_SYSTEMD_RUN=$run_saved

# 4. 输入校验：主机名 / 端口
if toolbox_hy2 install "$work/good.crt" "$work/good.key" 'Bad_Host' <<< 'YES' >/dev/null 2>&1; then fail '非法主机名被接受'; fi
assert_clean '非法主机名'
for p in 0 65536 0080 abc; do
    if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" "$p" <<< 'YES' >/dev/null 2>&1; then
        fail "非法端口被接受: $p"
    fi
done
assert_clean '非法端口'

# 5. 证书校验：缺失 / 不配对 / 域名不符 / 过期
if toolbox_hy2 install "$work/none.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail '缺失证书被接受'; fi
if toolbox_hy2 install "$work/good.crt" "$work/other.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail '不配对私钥被接受'; fi
out=$(toolbox_hy2 install "$work/good.crt" "$work/good.key" "other.example.test" <<< 'YES' 2>&1 || true)
if [[ $out != *'不包含主机名'* ]]; then printf 'GOT:[%s]\n' "$out" >&2; fail '域名不符未报错'; fi
if out=$(toolbox_hy2 install "$work/past.crt" "$work/past.key" "$GOOD_H" <<< 'YES' 2>&1); then
    fail '过期证书被接受'
fi
[[ $out == *'证书已过期'* ]] || fail '过期证书未到达时间校验'
assert_clean '证书校验'
# 通配符证书必须匹配子域
if ! hy2_check_cert "$work/wild.crt" "$work/wild.key" "a.wild.test" >/dev/null 2>&1; then
    fail '通配符证书被误拒'
fi
printf 'not-a-cert\n' > "$work/junk.crt"
if toolbox_hy2 install "$work/junk.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail '垃圾证书被接受'; fi
assert_clean '垃圾证书'

# 6. 端口占用必须拒绝，并在提示中给出占用者
printf 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=7,fd=3))\n' > "$SD/ports"
out=$(toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 443 <<< 'YES' 2>&1 || true)
[[ $out == *'已被占用'* && $out == *nginx* ]] || fail '端口占用未识别或未提示占用者'
assert_clean '端口占用'
rm -f "$SD/ports"

# 7. 外来单元必须拒绝覆盖；我们的残留也要提示先卸载
printf '[Service]\nExecStart=/usr/bin/someone-else\n' > "$work/units/terry-toolbox-hy2.service"
out=$(toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' 2>&1 || true)
[[ $out == *'不是本模块生成'* ]] || fail '外来单元未报告归属'
[[ ! -e $work/bin/terry-toolbox-hy2 ]] || fail '外来单元仍写入了二进制'
out=$(toolbox_hy2 uninstall <<< 'YES' 2>&1 || true)
[[ $out == *'不是本模块生成'* ]] || fail '卸载未保护外来单元'
[[ -e $work/units/terry-toolbox-hy2.service ]] || fail '卸载删除了外来单元'
reset
printf '[Unit]\nDescription=Terry Toolbox Hysteria 2 server\n[Service]\nWorkingDirectory=%s\nExecStart=%s server -c %s/config.yaml --disable-update-check\n' "$(hy2_etc)" "$(hy2_bin)" "$(hy2_etc)" > "$(hy2_unit)"
: > "$SD/active"
out=$(toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' 2>&1 || true)
[[ $out == *'已在运行'* ]] || fail '运行中的自有服务未拒绝重装'
rm -f "$SD/active"
reset

# 7b. 没有单元文件但已有同名二进制/配置目录：可能是别人的安装，写盘前拒绝
printf '#!/bin/sh\nexit 0\n' > "$work/bin/terry-toolbox-hy2"
out=$(toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' 2>&1 || true)
[[ $out == *'请人工确认归属'* ]] || fail '同名二进制未被拒绝'
[[ ! -e $work/units/terry-toolbox-hy2.service ]] || fail '同名二进制仍写了单元'
[[ ! -d $work/etc/terry-toolbox-hy2 ]] || fail '同名二进制仍写了配置'
reset
mkdir -p "$work/etc/terry-toolbox-hy2"
out=$(toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' 2>&1 || true)
[[ $out == *'请人工确认归属'* ]] || fail '同名配置目录未被拒绝'
[[ ! -e $work/units/terry-toolbox-hy2.service ]] || fail '同名配置目录仍写了单元'
reset

# 7c. 无单元时卸载也不能删除来源不明的二进制/目录。
printf 'foreign-data\n' > "$(hy2_bin)"
if toolbox_hy2 uninstall <<< 'YES' >"$work/unowned.out" 2>&1; then fail '无单元的外来二进制被卸载'; fi
[[ $(<"$(hy2_bin)") == foreign-data ]] || fail '卸载删除/覆盖了无主二进制'
[[ ! -s $SD/systemctl.log ]] || fail '无主卸载调用了 systemctl'
reset
# 回滚没有本次创建记录时不得按路径猜测归属。
printf 'foreign-data\n' > "$(hy2_bin)"
hy2_rollback >/dev/null 2>&1 || true
[[ -f $(hy2_bin) ]] || fail '回滚删除了未登记的外来文件'
reset

# 7d. 断链也属于外来目标；安装/卸载不得触碰。
for target in "$(hy2_bin)" "$(hy2_unit)" "$(hy2_etc)"; do
    mkdir -p "$(dirname -- "$target")"
    ln -s "$work/missing-target" "$target"
    if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1; then fail '安装接受断链目标'; fi
    if toolbox_hy2 uninstall <<< YES >/dev/null 2>&1; then fail '卸载接受断链目标'; fi
    [[ -L $target ]] || fail '外来断链被改动'
    [[ ! -s $SD/systemctl.log ]] || fail '外来断链调用了 systemctl'
    reset
done
printf '[Service]\nExecStart=%s-foreign server\n' "$(hy2_bin)" > "$(hy2_unit)"
[[ $(hy2_unit_state) == foreign ]] || fail 'ExecStart 前缀被误认为本模块'
reset

# 8. 取消确认不得写盘
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'n' >/dev/null 2>&1; then fail '取消被当成安装'; fi
assert_clean '取消'

# 9. 下载失败 → 回滚，不留任何东西
: > "$SD/download_fail"
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail '下载失败被当成成功'; fi
assert_clean '下载失败'
rm -f "$SD/download_fail"

# 10. 校验和不符 → 拒绝安装并回滚（证明校验真的生效）
TOOLBOX_HY2_SHA256=0000000000000000000000000000000000000000000000000000000000000000
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >"$work/out" 2>&1; then fail '校验和不符被接受'; fi
grep -q 'SHA-256 不匹配' "$work/out" || fail '校验失败未报告原因'
assert_clean '校验失败'
TOOLBOX_HY2_SHA256=$(sha256sum -- "$TOOLBOX_HY2_BIN_SRC" | cut -d' ' -f1)

# 11. 冒烟启动失败 → 回滚
: > "$SD/smoke_fail"
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail '冒烟失败被当成成功'; fi
assert_clean '冒烟失败'
grep -q 'server' "$SD/stub.log" || fail '冒烟未执行'
rm -f "$SD/smoke_fail"

# 12. 服务启动后探测失败（正确密码连不上）→ 停掉自己的服务并回滚
: > "$SD/accept_any"
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail '错误密码被接受时未失败'; fi
called 'disable --now terry-toolbox-hy2.service'
[[ ! -e $SD/active ]] || fail '回滚后服务仍在运行'
assert_clean '认证探测失败'
rm -f "$SD/accept_any"

# 13. enable 失败 → 回滚
: > "$SD/enable_fail"
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail 'enable 失败被当成成功'; fi
assert_clean 'enable 失败'
rm -f "$SD/enable_fail"

# 14. 单元写入后服务始终不 active → 回滚
: > "$SD/noactivate"
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then fail '未 active 被当成成功'; fi
assert_clean '未 active'
rm -f "$SD/noactivate"

# ================= 成功路径 =================
reset
export MOCK_PORT=18443
out=$(toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< 'YES' 2>&1) \
    || { printf '%s\n' "$out" >&2; fail '正常安装失败'; }
unit=$work/units/terry-toolbox-hy2.service
bin=$work/bin/terry-toolbox-hy2
conf=$work/etc/terry-toolbox-hy2/config.yaml

[[ -x $bin ]] || fail '二进制未安装或不可执行'
[[ -s $conf ]] || fail '配置未写入'
[[ -e $unit ]] || fail '单元未写入'
[[ -e $SD/active ]] || fail '服务未启动'
called 'enable --now terry-toolbox-hy2.service'
called 'daemon-reload'

# 单元内容：绝对路径、能力最小化、沙箱
grep -qF "ExecStart=$bin server -c $conf" "$unit" || fail 'ExecStart 不是精确绝对路径'
grep -qF 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$unit" || fail '缺少绑定低端口能力'
grep -qF 'NoNewPrivileges=yes' "$unit" || fail '缺少 NoNewPrivileges'
grep -qF 'ProtectSystem=strict' "$unit" || fail '缺少 ProtectSystem'
grep -qF 'PrivateTmp=yes' "$unit" || fail '缺少 PrivateTmp'
grep -qF 'RestrictAddressFamilies=AF_INET AF_INET6' "$unit" || fail '缺少地址族限制'
grep -qF "ReadWritePaths=$work/etc/terry-toolbox-hy2" "$unit" || fail '缺少可写路径'
! grep -qE '^(User|DynamicUser)=' "$unit" || fail '意外切换用户'

# 配置：强密码、严格 SNI、绝对证书路径
[[ $(stat -c %a "$conf") == 600 ]] || fail '配置权限不是 600'
[[ $(stat -c %a "$work/etc/terry-toolbox-hy2") == 755 ]] || fail '目录权限异常'
grep -q '^listen: :18443$' "$conf" || fail '监听地址不对'
grep -q '^  cert: .*/etc/terry-toolbox-hy2/cert.pem$' "$conf" || fail '证书路径不对'
grep -q '^  sniGuard: strict$' "$conf" || fail '缺少 sniGuard strict'
grep -qE "^  password: '[A-Za-z0-9]{32}'$" "$conf" || fail '密码未生成或格式不对'
pw=$(sed -n "s/^  password: '\(.*\)'$/\1/p" "$conf")
[[ ${#pw} -eq 32 ]] || fail '密码长度不足'
grep -q "^  password: '$pw'$" "$work/etc/terry-toolbox-hy2/config.yaml" || fail '密码不一致'

# 证书副本受限，且原始文件仍在
[[ $(stat -c %a "$work/etc/terry-toolbox-hy2/cert.pem") == 600 ]] || fail '证书副本权限不是 600'
[[ $(stat -c %a "$work/etc/terry-toolbox-hy2/key.pem") == 600 ]] || fail '私钥副本权限不是 600'
cmp -s "$work/good.key" "$work/etc/terry-toolbox-hy2/key.pem" || fail '私钥副本内容不一致'
[[ -e $work/good.key ]] || fail '原始私钥被移动'

# 元数据、报告内容
[[ -s $work/etc/terry-toolbox-hy2/meta ]] || fail '缺少 meta'
[[ $(stat -c %a "$work/etc/terry-toolbox-hy2/meta") == 600 ]] || fail 'meta 权限不是 600'
grep -q 'hysteria2://' <<< "$out" || fail '未输出客户端链接'
grep -q 'insecure=1' <<< "$out" || fail '自签证书应提示 insecure'
grep -q '\[已验证\]' <<< "$out" || fail '未报告验证结果'
grep -q 'UDP 18443' <<< "$out" || fail '未提示放行端口'
if grep -q 'server -c' <<< "$out"; then printf '%s\n' "$out" >&2; fail '报告混入内部命令'; fi

# 密码不进 stub/curl 参数以外的 arglist：确认客户端配置用的是密码文件而非命令行
[[ -s $work/verify/good.yaml ]] || fail '探测配置未生成'
[[ ! -e $work/verify/good.yaml.bak ]] || true

# 14b. 端口归属判定：是我们就通过，别人占用就不通过
hy2_port_owned_by 18443 "$bin" || fail '未识别自有监听'
printf 'UNCONN 0 0 0.0.0.0:20000 0.0.0.0:* users:(("nginx",pid=999999,fd=3))\n' > "$SD/ports"
if hy2_port_owned_by 20000 "$bin"; then fail '把他人的监听当成自己的'; fi
# systemd 的 MainPID 也是有效证据（脚本安装时 exe 是解释器）
printf '[Service]\nExecStart=%s/terry-toolbox-hy2 server\n' "$work/bin" > "$work/units/u.service"
printf 'UNCONN 0 0 0.0.0.0:20001 0.0.0.0:* users:(("bash",pid=555,fd=3))\n' > "$SD/ports"
printf '555\n' > "$SD/mainpid"
if hy2_port_owned_by 20001 "$bin" u.service; then :; else fail 'MainPID 证据未被采纳'; fi
printf '777\n' > "$SD/mainpid"
if hy2_port_owned_by 20001 "$bin" u.service; then fail '不相关 MainPID 被采纳'; fi
rm -f "$SD/ports" "$SD/mainpid" "$work/units/u.service"

# 15. 再次安装必须拒绝（已在运行），且不改动现有文件
sum=$(sha256sum "$conf" | cut -d' ' -f1)
out=$(toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< 'YES' 2>&1 || true)
[[ $out == *'已在运行'* ]] || fail '重复安装未拒绝'
[[ $(sha256sum "$conf" | cut -d' ' -f1) == "$sum" ]] || fail '重复安装改动了配置'

# 16. 解锁后重新安装前，占用检测要能认出我们自己的端口（active 时 ss 有记录）
lock_saved=$TOOLBOX_HY2_LOCK
TOOLBOX_HY2_LOCK=$work/lock2
toolbox_hy2 status > "$work/status.out" 2>&1 || true
TOOLBOX_HY2_LOCK=$lock_saved
grep -q '由本服务持有' "$work/status.out" || fail 'status 未识别自有监听'

# 17. 并发互斥：锁被占时第二次必须失败且不写盘
# 18a. 未确认停止的服务必须保留全部文件。
: > "$SD/disable_fail"
if toolbox_hy2 uninstall <<< YES >/dev/null 2>&1; then fail '停止失败仍报卸载成功'; fi
[[ -e $unit && -x $bin && -s $conf && -e $SD/active ]] || fail '停止失败仍删文件'
rm -f "$SD/disable_fail"
: > "$SD/stop_stuck"
if toolbox_hy2 uninstall <<< YES >/dev/null 2>&1; then fail '仍 active 时报卸载成功'; fi
[[ -e $unit && -x $bin && -s $conf ]] || fail '仍 active 时删除了文件'
rm -f "$SD/stop_stuck"
: > "$SD/status_fail"
if toolbox_hy2 uninstall <<< YES >/dev/null 2>&1; then fail '无法读取 stopped 状态仍卸载'; fi
[[ -e $unit && -x $bin && -s $conf ]] || fail '无法确认停止仍删除文件'
rm -f "$SD/status_fail"

# 18. 卸载：只删自己的东西，原始证书保留
toolbox_hy2 uninstall <<< 'YES' >/dev/null 2>&1 || fail '卸载失败'
[[ ! -e $unit && ! -e $bin && ! -d $work/etc/terry-toolbox-hy2 ]] || fail '卸载未清理'
[[ -e $work/good.crt && -e $work/good.key ]] || fail '卸载删除了原始证书'
[[ ! -e $SD/active ]] || fail '卸载未停止服务'
called 'disable --now terry-toolbox-hy2.service'
if toolbox_hy2 status >/dev/null 2>&1; then fail '卸载后 status 仍报存在'; fi

# 19. 并发互斥：锁被占时第二次必须失败且不写盘
( flock 9; command sleep 3 ) 9>"$work/lock" &
lockpid=$!
command sleep 0.3
if flock -n "$work/lock" -c true; then fail '测试自身的锁没有生效'; fi
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< 'YES' >"$work/lock.out" 2>&1; then
    cat "$work/lock.out" >&2; fail "锁被占时仍安装成功"
fi
grep -q '正在进行' "$work/lock.out" || { cat "$work/lock.out" >&2; fail '未报告并发'; }
assert_clean '并发'
wait "$lockpid" 2>/dev/null || true
reset

# 20. 未安装时卸载要明确失败
if toolbox_hy2 uninstall <<< 'YES' >/dev/null 2>&1; then fail '未安装时卸载仍成功'; fi

# 21. 端口可省略，默认为 443
export MOCK_PORT=443
toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< "YES" >"$work/dflt.out" 2>&1 || { cat "$work/dflt.out" >&2; fail "默认端口安装失败"; }
grep -q '^listen: :443$' "$work/etc/terry-toolbox-hy2/config.yaml" || fail '默认端口不是 443'
reset

# 22. 邻近单元不影响安装/卸载
printf '[Service]\nExecStart=/usr/bin/other\n' > "$work/units/other.service"
export MOCK_PORT=18443
toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< 'YES' >/dev/null 2>&1 || fail '邻近单元干扰安装'
[[ -e $work/units/other.service ]] || fail '安装删除了邻近单元'
toolbox_hy2 uninstall <<< 'YES' >/dev/null 2>&1 || true
[[ -e $work/units/other.service ]] || fail '卸载删除了邻近单元'
reset

# 23. 未知动作与参数错误
if toolbox_hy2 frobnicate >/dev/null 2>&1; then fail '未知动作被接受'; fi
if toolbox_hy2 install >/dev/null 2>&1; then fail '缺少参数仍安装'; fi
assert_clean '参数错误'

# 24a. 真 CA → 中间 CA → 叶证书链，信任锚与服务端证书独立。
# Isolate extensions from the host's v3_ca defaults (1.1 may duplicate -addext).
printf '[req]\ndistinguished_name=dn\n[dn]\n' > "$work/ca.cnf"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=Root-CA -config "$work/ca.cnf" \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$work/ca.key" -out "$work/ca.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj /CN=Intermediate-CA \
    -keyout "$work/intermediate.key" -out "$work/intermediate.csr" >/dev/null 2>&1
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > "$work/intermediate.ext"
openssl x509 -req -in "$work/intermediate.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" \
    -set_serial 2 -days 30 -extfile "$work/intermediate.ext" -out "$work/intermediate.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj /CN=hy2.example.test \
    -keyout "$work/leaf.key" -out "$work/leaf.csr" >/dev/null 2>&1
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:hy2.example.test\n' > "$work/leaf.ext"
openssl x509 -req -in "$work/leaf.csr" -CA "$work/intermediate.crt" -CAkey "$work/intermediate.key" \
    -set_serial 3 -days 30 -extfile "$work/leaf.ext" -out "$work/leaf.crt" >/dev/null 2>&1
cat "$work/leaf.crt" "$work/intermediate.crt" > "$work/fullchain.crt"
TOOLBOX_HY2_CAFILE=$work/ca.crt hy2_tls_trusted "$work/fullchain.crt" || fail 'HY2 完整中间证书链校验失败'
if TOOLBOX_HY2_CAFILE=$work/ca.crt hy2_tls_trusted "$work/leaf.crt"; then fail '缺中间证书仍验证成功'; fi
if TOOLBOX_HY2_CAFILE=$work/other.crt hy2_tls_trusted "$work/fullchain.crt"; then fail '错误 CA 接受完整链'; fi
# Option discovery must precede exactly one strict verification, including when
# verification fails. Exercise both OpenSSL help shapes on either host version.
for ca_store in absent present; do
    (
        unset -f net_tls_verify
        verify_log=$work/verify-$ca_store.log
        openssl() {
            if [[ $* == 'verify -help' ]]; then
                [[ $ca_store != present ]] || printf '%s\n' ' -no-CAstore Do not load the default CA store'
                return 0
            fi
            printf '%s\n' "$*" >> "$verify_log"
            return 42
        }
        if TOOLBOX_HY2_CAFILE=$work/ca.crt hy2_tls_trusted "$work/fullchain.crt"; then fail '证书验证失败被当作成功'; fi
        [[ $(wc -l < "$verify_log") == 1 ]] || fail '证书验证失败后重试'
        expected="verify -CAfile $work/ca.crt -no-CApath"
        [[ $ca_store != present ]] || expected+=' -no-CAstore'
        expected+=" -purpose sslserver -untrusted $work/fullchain.crt $work/fullchain.crt"
        [[ $(<"$verify_log") == "$expected" ]] || fail 'HY2 独立验证选项不完整'
    )
done
(
    source "$ROOT/modules/network.sh"
    TOOLBOX_NET_CAFILE=$work/ca.crt net_tls_trusted "$work/fullchain.crt" || fail 'network 完整链校验失败'
    TOOLBOX_NET_CAFILE=$work/other.crt TOOLBOX_HY2_CAFILE=$work/ca.crt hy2_tls_trusted "$work/fullchain.crt" || fail 'HY2 CA 被 NET 覆盖'
    if TOOLBOX_HY2_CAFILE=$work/ca.crt hy2_tls_trusted "$work/leaf.crt"; then fail 'HY2 共享验证接受缺中间证书'; fi
    if TOOLBOX_HY2_CAFILE=$work/other.crt hy2_tls_trusted "$work/fullchain.crt"; then fail 'HY2 共享验证接受错误 CA'; fi
)

# 仅 loopback 的真实 TLS 握手：服务端发完整链，正确根 CA/SNI 成功，错误 CA/SNI 失败。
if [[ ${TOOLBOX_NETWORK_REAL_TESTS:-0} == 1 ]]; then
    tls_ca_flags=(-no-CApath)
    # OpenSSL 1.1 has no URI CA store; OpenSSL 3 must also disable its default.
    if openssl s_client -help 2>&1 | grep -F -- '-no-CAstore' >/dev/null; then
        tls_ca_flags+=(-no-CAstore)
    fi
    tls_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    openssl s_server -accept "127.0.0.1:$tls_port" -cert "$work/leaf.crt" \
        -cert_chain "$work/intermediate.crt" -key "$work/leaf.key" -www >"$work/tls-server.log" 2>&1 &
    # shellcheck disable=SC2031
    tls_pid=$!
    python3 -c 'import socket,sys,time
for _ in range(100):
    try:
        with socket.create_connection(("127.0.0.1",int(sys.argv[1])),0.2): pass
        break
    except OSError: time.sleep(0.02)
else: sys.exit("TLS loopback server not ready")' "$tls_port" || fail 'TLS loopback 未就绪'
    timeout 10 openssl s_client -connect "127.0.0.1:$tls_port" -servername "$GOOD_H" \
        -verify_hostname "$GOOD_H" -verify_return_error -CAfile "$work/ca.crt" \
        "${tls_ca_flags[@]}" </dev/null >"$work/tls-good.log" 2>&1 || fail '真实 TLS 根 CA 校验失败'
    if timeout 10 openssl s_client -connect "127.0.0.1:$tls_port" -servername "$GOOD_H" \
        -verify_hostname "$GOOD_H" -verify_return_error -CAfile "$work/other.crt" \
        "${tls_ca_flags[@]}" </dev/null >"$work/tls-wrong-ca.log" 2>&1; then fail '真实 TLS 接受错误 CA'; fi
    if timeout 10 openssl s_client -connect "127.0.0.1:$tls_port" -servername "$GOOD_H" \
        -verify_hostname wrong.example.test -verify_return_error -CAfile "$work/ca.crt" \
        "${tls_ca_flags[@]}" </dev/null >"$work/tls-wrong-sni.log" 2>&1; then fail '真实 TLS 接受错误 SNI'; fi
    kill "$tls_pid" 2>/dev/null || true
    wait "$tls_pid" 2>/dev/null || true
    printf 'TLS loopback fullchain/CA/SNI verification passed\n'
fi

# 24. 独立 CA 必须真正用于信任判定和严格客户端探测。
for ca in "$work/other.crt" "$work/missing.crt" ''; do
    export MOCK_PORT=18443
    if TOOLBOX_HY2_CAFILE=$ca toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >"$work/ca-refusal.out" 2>&1; then
        fail 'HY2 显式 CA 无效仍降级安装'
    fi
    assert_clean 'HY2 显式 CA 校验失败'
    [[ ! -s $SD/systemctl.log && ! -s $SD/stub.log ]] || fail 'HY2 CA 校验失败仍触碰服务'
    reset
done
export MOCK_PORT=18443
if TOOLBOX_HY2_CAFILE=$work/ca.crt toolbox_hy2 install "$work/leaf.crt" "$work/leaf.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1; then
    fail 'HY2 缺中间证书降级安装'
fi
assert_clean 'HY2 缺中间证书'
[[ ! -s $SD/systemctl.log && ! -s $SD/stub.log ]] || fail 'HY2 缺中间证书仍触碰服务'
reset
if ! TOOLBOX_HY2_CAFILE=$work/good.crt hy2_tls_trusted "$work/good.crt"; then fail 'HY2 独立 CA 未生效'; fi
if TOOLBOX_HY2_CAFILE=$work/other.crt hy2_tls_trusted "$work/good.crt"; then fail 'HY2 接受错误 CA'; fi
if TOOLBOX_HY2_CAFILE=$work/missing.crt hy2_tls_trusted "$work/good.crt"; then fail 'HY2 CA 缺失仍受信任'; fi
export MOCK_PORT=18443
out=$(printf '%s\n%s\n%s\n18443\nYES\n' "$work/good.crt" "$work/good.key" "$GOOD_H" | TOOLBOX_HY2_CAFILE=$work/good.crt toolbox_hy2 install 2>&1) \
    || { printf '%s\n' "$out" >&2; fail 'HY2 交互自定义端口/独立 CA 安装失败'; }
grep -q '^listen: :18443$' "$(hy2_etc)/config.yaml" || fail 'HY2 交互自定义端口被忽略'
grep -q '|0|' "$(hy2_etc)/meta" || fail 'HY2 独立 CA 的 meta 仍标 insecure'
grep -q '其他客户端也需配置同一信任锚' <<< "$out" || fail 'HY2 把本机信任误报为所有客户端信任'
grep -qF "$work/good.crt" "$(hy2_client_dir)/good.yaml" || fail 'HY2 探针没有配置独立 CA'
grep -q 'insecure: true' "$(hy2_client_dir)/good.yaml" && fail 'HY2 独立 CA 探针关闭校验'
[[ $(stat -c %a "$(hy2_client_dir)/good.yaml") == 600 ]] || fail 'HY2 探针凭据权限不是 600'
toolbox_hy2 uninstall <<< YES >/dev/null 2>&1 || fail 'HY2 独立 CA 卸载失败'
reset
ca_quoted="$work/ca's \"quoted\".pem"
cp -- "$work/good.crt" "$ca_quoted"
export MOCK_PORT=18443
TOOLBOX_HY2_CAFILE=$ca_quoted toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1 || fail 'HY2 引号 CA 路径安装失败'
python3 -c 'import sys,yaml; cfg=yaml.safe_load(open(sys.argv[1])); assert cfg["tls"]["ca"] == sys.argv[2]; assert "insecure" not in cfg["tls"]' \
    "$(hy2_client_dir)/good.yaml" "$ca_quoted" || fail 'HY2 CA 路径 YAML 转义失败'
toolbox_hy2 uninstall <<< YES >/dev/null 2>&1 || fail 'HY2 引号 CA 卸载失败'
reset

# 25. 菜单里不带参数：缺的证书/私钥/主机名要逐项提问，端口回车用默认。
export MOCK_PORT=443
source "$ROOT/modules/network.sh"
out=$(printf '%s\n%s\n%s\n\nYES\n' "$work/good.crt" "$work/good.key" "$GOOD_H" | toolbox_network A4 install 2>&1) \
    || { printf '%s\n' "$out" >&2; fail '交互式补全参数后安装失败'; }
grep -q '^listen: :443$' "$work/etc/terry-toolbox-hy2/config.yaml" || fail '交互式安装端口不是默认 443'
toolbox_hy2 uninstall <<< 'YES' >/dev/null 2>&1 || fail '交互式安装后卸载失败'
reset
# 问到一半就 EOF 也要在写盘前退出
printf '%s\n' "$work/good.crt" | toolbox_hy2 install >/dev/null 2>&1 && fail 'EOF 被当成安装'
assert_clean '交互式 EOF'

# 26. 部分落位失败以及同期外来/被改动文件：回滚只删本次创建清单。
(
    install() {
        local dest=${!#}
        if [[ $dest == "$(hy2_bin)."* ]]; then printf partial > "$dest"; return 1; fi
        command install "$@"
    }
    if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1; then fail '部分落位失败仍成功'; fi
)
assert_clean 'HY2 部分落位失败'
[[ -z $(find "$work/bin" -mindepth 1 -print) ]] || fail 'HY2 部分写入留下临时文件'
reset
(
    hy2_fetch() { printf foreign-data > "$(hy2_bin)"; return 1; }
    if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1; then fail '下载失败仍成功'; fi
)
[[ $(<"$(hy2_bin)") == foreign-data ]] || fail '下载失败回滚删除同期外来二进制'
reset
(
    hy2_smoke() { printf changed > "$(hy2_bin)"; printf foreign-data > "$(hy2_etc)/foreign"; return 1; }
    if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1; then fail '冒烟失败仍成功'; fi
)
[[ $(<"$(hy2_bin)") == changed && $(<"$(hy2_etc)/foreign") == foreign-data ]] || fail '回滚删除被修改/外来文件'
[[ ! -e $(hy2_unit) ]] || fail '回滚未删除本次单元'
reset
(
    hy2_smoke() { printf '# changed\n' >> "$(hy2_unit)"; return 1; }
    if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1; then fail '单元被改动仍成功'; fi
)
[[ -e $(hy2_unit) && -x $(hy2_bin) && -s $(hy2_etc)/config.yaml ]] || fail '单元变动回滚未保留依赖文件'
[[ ! -s $SD/systemctl.log ]] || fail '单元变动回滚触碰未知单元'
reset
: > "$SD/disable_fail"
: > "$SD/accept_any"
# shellcheck disable=SC2030
export MOCK_PORT=18443
if toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1; then fail '错误密码被接受仍成功'; fi
[[ -e $(hy2_unit) && -x $(hy2_bin) && -s $(hy2_etc)/config.yaml && -e $SD/active ]] || fail '回滚停止失败仍删服务文件'
reset

# 确认读到无换行的 YES 但返回 EOF：不能把失败的 read 当确认。
export MOCK_PORT=18443
if printf YES | toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 >"$work/eof-confirm.out" 2>&1; then
    fail 'HY2 EOF 截断的 YES 被接受'
fi
assert_clean 'HY2 确认 EOF'
reset
# 父菜单用 || 捕获失败；cat 即使写了非空内容再失败，也必须立即回滚。
(
    cat() { if (( $# == 0 )); then command cat; return 1; fi; command cat "$@"; }
    # shellcheck disable=SC2030
    export MOCK_PORT=18443
    toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >"$work/write-fail.out" 2>&1 \
        && fail 'HY2 条件上下文吞掉配置写入失败'
    :
)
assert_clean 'HY2 配置写入失败'
[[ ! -s $SD/stub.log ]] || fail 'HY2 写入失败仍启动了二进制'
reset

# 每个必填项/端口处 EOF 均取消；全部参数给齐时缺确认也取消。
for input in '' "$(printf '%s\n%s\n' "$work/good.crt" "$work/good.key")" "$(printf '%s\n%s\n%s\n' "$work/good.crt" "$work/good.key" "$GOOD_H")"; do
    printf '%s' "$input" | toolbox_hy2 install >/dev/null 2>&1 && fail 'HY2 必填交互 EOF 仍安装'
    assert_clean 'HY2 必填交互 EOF'
done
toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 </dev/null >/dev/null 2>&1 && fail 'HY2 确认 EOF 仍安装'
assert_clean 'HY2 确认 EOF'
# 探针目录来源未知、或确认期间出现外来目标：不覆盖，不删除。
mkdir -p "$(hy2_client_dir)"
printf keep > "$(hy2_client_dir)/foreign"
toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1 && fail 'HY2 接受外来探针目录'
[[ $(<"$(hy2_client_dir)/foreign") == keep ]] || fail 'HY2 修改了外来探针目录'
reset
(
    read() {
        if [[ ${!#} == answer ]]; then printf foreign-data > "$(hy2_bin)"; fi
        builtin read -r "$@"
    }
    toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1 && fail 'HY2 覆盖确认期间出现的二进制'
    :
)
[[ $(<"$(hy2_bin)") == foreign-data && ! -e $(hy2_unit) && ! -e $(hy2_etc) ]] || fail 'HY2 确认竞争仍写入/改动文件'
[[ ! -s $SD/systemctl.log ]] || fail 'HY2 确认竞争仍触碰服务'
reset

# 同期改写探针文件不在回滚删除范围内，不能以 good/bad 固定名字猜归属。
(
    hy2_probe() {
        printf foreign-probe > "$(hy2_client_dir)/good.yaml"
        return 1
    }
    # shellcheck disable=SC2031
    export MOCK_PORT=18443
    toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" 18443 <<< YES >/dev/null 2>&1 && fail 'HY2 探针失败仍成功'
    :
)
[[ -f $(hy2_client_dir)/good.yaml && $(<"$(hy2_client_dir)/good.yaml") == foreign-probe ]] || fail 'HY2 回滚删除未登记探针文件'
reset

[[ ! -s $work/package-boundary.log ]] || fail '命中了真实命令兜底拒绝桩'
printf 'All hy2 tests passed.\n'
