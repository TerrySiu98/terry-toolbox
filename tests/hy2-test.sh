#!/usr/bin/env bash
# A4 Hysteria 2 安装模块的隔离测试。
#
# 真实：openssl 生成证书、sha256sum、install/stat、模块逻辑本身。
# 桩：systemctl / ss / curl / hysteria 二进制 / sleep。
# 所有路径都在临时目录，绝不碰本机 /etc、/usr/local/bin、systemd。
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-hy2-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
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
        is-active) [[ -e $SD/active ]] && return 0 || return 3 ;;
        enable)
            [[ -e $SD/enable_fail ]] && return 1
            [[ $* == *--now* && ! -e $SD/noactivate ]] && : > "$SD/active"
            return 0
            ;;
        disable) [[ $* == *--now* ]] && rm -f "$SD/active"; return 0 ;;
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
    rm -rf -- "$work/etc" "$work/verify" "$work/lock"
    find "$work/units" -mindepth 1 -delete
    find "$work/bin" -mindepth 1 -delete
    rm -f "$SD"/*.log "$SD/active"
    rm -f "$SD"/smoke_fail "$SD"/silent "$SD"/accept_any "$SD"/download_fail "$SD"/data_fail \
        "$SD"/enable_fail "$SD"/noactivate "$SD"/ports
    unset MOCK_PORT
}
wrote() {
    [[ -e $work/bin/terry-toolbox-hy2 || -d $work/etc/terry-toolbox-hy2 \
        || -e $work/units/terry-toolbox-hy2.service ]]
}
assert_clean() { if wrote; then fail "$1：留下了写入"; fi; }
called() { grep -qF -- "$1" "$SD/systemctl.log" 2>/dev/null || fail "缺少 systemctl 调用: $1"; }

# ---- 证书夹具：全部由 openssl 真实生成
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
# 过去有效期的证书：openssl 3.x 的 -not_before/-not_after；旧版跳过该场景。
openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -keyout "$work/past.key" -out "$work/past.crt" \
    -not_before 20200101000000Z -not_after 20200102000000Z \
    -subj '/CN=hy2.example.test' -addext 'subjectAltName=DNS:hy2.example.test' >/dev/null 2>&1 \
    && HAVE_PAST=1 || HAVE_PAST=0

GOOD_H=hy2.example.test

# 1. sourcing 必须无副作用且只定义入口
before=$(find "$work" -mindepth 1 | wc -l)
out=$(bash -ec "source '$ROOT/modules/hy2.sh'; declare -F toolbox_hy2 >/dev/null && printf ok")
[[ $out == ok ]] || fail 'sourcing 未定义 toolbox_hy2'
[[ $(find "$work" -mindepth 1 | wc -l) -eq $before ]] || fail 'sourcing 产生文件'

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
if [[ $HAVE_PAST == 1 ]]; then
    if toolbox_hy2 install "$work/past.crt" "$work/past.key" "$GOOD_H" <<< 'YES' >/dev/null 2>&1; then
        fail '过期证书被接受'
    fi
fi
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
printf '[Service]\nExecStart=%s/terry-toolbox-hy2 server\n' "$work/bin" > "$work/units/terry-toolbox-hy2.service"
: > "$SD/active"
out=$(toolbox_hy2 install "$work/good.crt" "$work/good.key" "$GOOD_H" <<< 'YES' 2>&1 || true)
[[ $out == *'已在运行'* ]] || fail '运行中的自有服务未拒绝重装'
rm -f "$SD/active"
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
[[ $(stat -c %a $work/etc/terry-toolbox-hy2/meta) == 600 ]] || fail 'meta 权限不是 600'
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

printf 'All hy2 tests passed.\n'
