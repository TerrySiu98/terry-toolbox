#!/usr/bin/env bash
# A1/A2（Alpine + OpenRC）与 B23（systemd-resolved）的隔离测试。
#
# 真实：openssl 生成证书、sha256sum、install/stat、unzip、模块逻辑本身。
# 桩：rc-service / rc-update / ss / curl / uname 以外的外部命令、apt 二进制与
#     resolvectl / systemctl。所有路径都在临时目录，绝不碰本机 /etc、/usr/local/bin、
#     /run 或 systemd。
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-net-alpine-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SD=$work/state
for d in bin initd run lock pkg openrc-run state etc dns/systemd/resolve dns/dropin; do
    mkdir -p "$work/$d"
done
export SD
export TOOLBOX_NET_UID=0
export TOOLBOX_NET_OS_RELEASE=$work/os-release
export TOOLBOX_NET_OPENRC_RUN=$work/openrc-run
export TOOLBOX_NET_INITD=$work/initd
export TOOLBOX_NET_BIN_DIR=$work/bin
export TOOLBOX_NET_RUN=$work/run
export TOOLBOX_NET_LOCK_DIR=$work/lock
export TOOLBOX_A1_ETC=$work/etc/terry-toolbox-hy2
export TOOLBOX_A2_ETC=$work/etc/terry-toolbox-xray
export TOOLBOX_A1_BIN_SRC=$work/pkg/hysteria-linux-amd64
export TOOLBOX_A2_ZIP_SRC=$work/pkg/xray.zip
export TOOLBOX_DNS_RESOLVE_RUN=$work/dns/systemd/resolve
export TOOLBOX_DNS_DROPIN_DIR=$work/dns/dropin
export TOOLBOX_DNS_RESOLV_CONF=$work/resolv.conf
export PATH=$work/bin:$PATH
unset TOOLBOX_A1_SHA256_ARM64 TOOLBOX_A2_SHA256_ARM64

printf 'ID=alpine\nVERSION_ID="3.22"\n' > "$TOOLBOX_NET_OS_RELEASE"
printf 'ID=debian\n' > "$work/os-debian"
: > "$work/dns/systemd/resolve/stub-resolv.conf"
ln -s "$work/dns/systemd/resolve/stub-resolv.conf" "$work/resolv.conf"

# 轮询睡眠不需要真实等待。
sleep() { :; }

# ---------------------------------------------------------------- 桩：OpenRC
cat > "$work/bin/rc-service" <<'EOF'
#!/usr/bin/env bash
name=${1:-}; action=${2:-}
printf '%s %s\n' "$name" "$action" >> "$SD/rc-service.log"
case $action in
    status) [[ -e $SD/active_$name ]] && exit 0 || exit 3 ;;
    start)
        [[ -e $SD/start_fail ]] && exit 1
        : > "$SD/active_$name"
        printf '%s\n' 4242 > "$TOOLBOX_NET_RUN/$name.pid"
        port=$(cat "$SD/port" 2>/dev/null) || port=''
        if [[ -z $port ]]; then exit 0; fi
        if [[ -e $SD/foreign_owner ]]; then
            line='users:(("nginx",pid=999,fd=3))'
        else
            line="users:((\"$name\",pid=4242,fd=3))"
        fi
        case $name in
            terry-toolbox-hy2) printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:* %s\n' "$port" "$line" > "$SD/ports.udp" ;;
            terry-toolbox-xray) printf 'LISTEN 0 0 0.0.0.0:%s 0.0.0.0:* %s\n' "$port" "$line" > "$SD/ports.tcp" ;;
        esac
        exit 0
        ;;
    stop)
        rm -f "$SD/active_$name" "$SD/ports.udp" "$SD/ports.tcp" "$TOOLBOX_NET_RUN/$name.pid"
        exit 0
        ;;
esac
exit 0
EOF
cat > "$work/bin/rc-update" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SD/rc-update.log"
[[ -e $SD/rcupd_fail ]] && exit 1
exit 0
EOF
cat > "$work/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SD/ss.log"
case " $* " in
    *' -lunpH '*) f=$SD/ports.udp ;;
    *' -ltnpH '*) f=$SD/ports.tcp ;;
    *' -lunH '*)  f=$SD/ports.udp ;;
    *' -ltnH '*)  f=$SD/ports.tcp ;;
    *) f='' ;;
esac
[[ -n $f && -e $f ]] && cat "$f"
exit 0
EOF
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SD/curl.log"
case " $* " in
    *--socks5-hostname*) [[ -e $SD/data_fail ]] && exit 7; printf '200'; exit 0 ;;
esac
[[ -e $SD/download_fail ]] && exit 22
out='' prev=''
for a in "$@"; do [[ $prev == -o ]] && out=$a; prev=$a; done
[[ -z $out ]] && exit 0
case " $* " in
    *hysteria-linux*) cp -- "$TOOLBOX_A1_BIN_SRC" "$out" ;;
    *Xray-linux*) cp -- "$TOOLBOX_A2_ZIP_SRC" "$out" ;;
esac
exit 0
EOF
cat > "$work/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SD/systemctl.log"
case ${1:-} in
    is-active) [[ -e $SD/resolved_down ]] && exit 3 || exit 0 ;;
    restart) [[ -e $SD/restart_fail ]] && exit 1; exit 0 ;;
esac
exit 0
EOF
cat > "$work/bin/resolvectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SD/resolvectl.log"
conf=$TOOLBOX_DNS_DROPIN_DIR/99-terry-toolbox-dns.conf
dns=''
[[ -e $conf ]] && dns=$(sed -n 's/^DNS=//p' "$conf")
case ${1:-} in
    status)
        printf 'Global\n       Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no\nCurrent DNS Server: %s\n       DNS Servers: %s\n' "$dns" "$dns"
        if [[ -e $SD/status.txt ]]; then
            cat "$SD/status.txt"
        else
            printf '\nLink 2 (eth0)\n         Protocols: +DefaultRoute +LLMNR\nCurrent DNS Server: %s\n       DNS Servers: %s\n\nLink 3 (eth1)\n         Protocols: -DefaultRoute\nCurrent DNS Server: 10.9.9.9\n       DNS Servers: 10.9.9.9\n' \
                "$dns" "$dns"
        fi
        ;;
    dns) printf '%s\n' "$*" >> "$SD/dns.applied" ;;
    domain) printf '%s\n' "$*" >> "$SD/domain.applied" ;;
    query) [[ -e $SD/query_fail ]] && exit 1; printf 'www.cloudflare.com. 300 IN A 1.2.3.4\n'; exit 0 ;;
    revert)
        # 真实 systemd 不带链路参数会报 Interface argument required
        [[ -n ${2:-} ]] || { printf 'Interface argument required.\n'; exit 1; }
        exit 0
        ;;
esac
exit 0
EOF
chmod +x "$work/bin/"*

# ---------------------------------------------------------------- 桩：服务二进制
cat > "$TOOLBOX_A1_BIN_SRC" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SD/hysteria.log"
case ${1:-} in
    server)
        [[ -e $SD/smoke_fail ]] && { printf 'FATAL\tfailed to load server config\n'; exit 1; }
        [[ -e $SD/silent ]] && exit 0
        printf 'INFO\tserver up and running\n'
        exit 0
        ;;
    client)
        [[ -e $SD/probe_fail ]] && { printf 'FATAL\tauthentication error\n'; exit 1; }
        cfg='' prev=''
        for a in "$@"; do [[ $prev == -c ]] && cfg=$a; prev=$a; done
        auth=$(sed -n 's/^auth: //p' "$cfg")
        real=$(sed -n "s/^  password: '\(.*\)'$/\1/p" "$TOOLBOX_A1_ETC/config.yaml" 2>/dev/null)
        [[ -e $SD/accept_any ]] && { printf 'INFO\tconnected to server\n'; exit 0; }
        [[ -n $real && $auth == "$real" ]] && { printf 'INFO\tconnected to server\n'; exit 0; }
        printf 'FATAL\tauthentication error, HTTP status code: 502\n'
        exit 1
        ;;
esac
exit 0
EOF
chmod +x "$TOOLBOX_A1_BIN_SRC"

cat > "$work/pkg/xray-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SD/xray.log"
case ${1:-} in
    uuid) printf 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\n'; exit 0 ;;
    x25519)
        printf 'PrivateKey: PRIV-TEST-KEY-aaaaaaaaaaaa\n'
        printf 'Password (PublicKey): PUB-TEST-KEY-bbbbbbbbbbbb\n'
        exit 0
        ;;
    run)
        cfg='' prev=''
        for a in "$@"; do [[ $prev == -c ]] && cfg=$a; prev=$a; done
        if [[ " $* " == *' -test '* ]]; then
            [[ -e $SD/test_fail ]] && { printf 'failed to read config\n'; exit 1; }
            exit 0
        fi
        [[ -e $SD/probe_fail ]] && { printf 'Failed to start: TLS handshake failure\n'; exit 1; }
        # 负向探测用固定错误 UUID；stub 只按配置里的 id 前缀判断。
        if grep -q '11111111-1111' "$cfg"; then
            printf 'Failed to start: TLS handshake failure\n'
            exit 1
        fi
        printf 'Warning: Xray started\n'
        exec /bin/sleep 300
        ;;
esac
exit 0
EOF
( cd "$work/pkg" && cp xray-stub xray && chmod +x xray && python3 -c '
import zipfile, sys
z = zipfile.ZipFile("xray.zip", "w", zipfile.ZIP_DEFLATED)
z.write("xray", "xray")
z.close()' )

export TOOLBOX_A1_SHA256 TOOLBOX_A2_SHA256
TOOLBOX_A1_SHA256=$(sha256sum -- "$TOOLBOX_A1_BIN_SRC" | cut -d' ' -f1)
TOOLBOX_A2_SHA256=$(sha256sum -- "$TOOLBOX_A2_ZIP_SRC" | cut -d' ' -f1)

source "$ROOT/modules/network.sh"

# ---------------------------------------------------------------- 断言工具
reset() {
    rm -rf -- "${work:?}/etc" "${work:?}/lock"
    mkdir -p "$work/etc" "$work/lock"
    find "$work/initd" -mindepth 1 -delete
    find "$work/bin" -mindepth 1 -maxdepth 1 ! -name 'rc-service' ! -name 'rc-update' \
        ! -name 'ss' ! -name 'curl' ! -name 'systemctl' ! -name 'resolvectl' -delete
    find "$work/run" -mindepth 1 -delete
    rm -f "$SD"/*.log "$SD"/active_* "$SD"/ports.* "$SD"/port "$SD"/status.txt \
        "$SD"/smoke_fail "$SD"/silent "$SD"/probe_fail "$SD"/accept_any "$SD"/download_fail \
        "$SD"/data_fail "$SD"/start_fail "$SD"/rcupd_fail "$SD"/test_fail "$SD"/foreign_owner \
        "$SD"/query_fail "$SD"/resolved_down "$SD"/restart_fail
    rm -f "$work/dns/dropin"/* "$work/dns/dropin"/*.pre-toolbox 2>/dev/null || true
    rm -f "$TOOLBOX_DNS_RESOLV_CONF"
    ln -s "$work/dns/systemd/resolve/stub-resolv.conf" "$TOOLBOX_DNS_RESOLV_CONF"
}
wrote() {
    [[ -e $work/bin/terry-toolbox-hy2 || -e $work/bin/terry-toolbox-xray \
        || -d "$TOOLBOX_A1_ETC" || -d "$TOOLBOX_A2_ETC" \
        || -e $work/initd/terry-toolbox-hy2 || -e $work/initd/terry-toolbox-xray ]]
}
assert_clean() { if wrote; then fail "$1：留下了写入"; fi; }
called() { grep -qF -- "$1" "$SD/$2" 2>/dev/null || fail "缺少 $2 调用: $1"; }

# ---------------------------------------------------------------- 证书夹具
mk_cert() { # <名> <CN/SAN>
    local name=$1 host=$2
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 \
        -keyout "$work/$name.key" -out "$work/$name.crt" \
        -subj "/CN=$host" -addext "subjectAltName=DNS:$host" >/dev/null 2>&1 \
        || fail "无法生成测试证书 $name"
}
mk_cert good a1.example.test
mk_cert other wrong.example.test
openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -keyout "$work/past.key" -out "$work/past.crt" \
    -not_before 20200101000000Z -not_after 20200102000000Z \
    -subj '/CN=a1.example.test' -addext 'subjectAltName=DNS:a1.example.test' >/dev/null 2>&1 \
    && HAVE_PAST=1 || HAVE_PAST=0

H=a1.example.test

# 1. sourcing 无副作用且只定义入口
before=$(find "$work" -mindepth 1 | wc -l)
out=$(bash -ec "source '$ROOT/modules/network.sh'; declare -F toolbox_network >/dev/null && printf ok")
[[ $out == ok ]] || fail 'sourcing 未定义入口'
[[ $(find "$work" -mindepth 1 | wc -l) -eq $before ]] || fail 'sourcing 产生文件'

# ================================================================ A1 拒绝路径
a1() { printf '%s' "${2:-}" | toolbox_network A1 "$1" "${@:3}"; }

if printf 'YES\n' | TOOLBOX_NET_UID=1000 toolbox_network A1 install \
    "$work/good.crt" "$work/good.key" "$H" >/dev/null 2>&1; then fail 'A1 非 root 被接受'; fi
assert_clean 'A1 非 root'

if printf 'YES\n' | TOOLBOX_NET_OS_RELEASE=$work/os-debian toolbox_network A1 install \
    "$work/good.crt" "$work/good.key" "$H" >"$work/o" 2>&1; then fail 'A1 接受 Debian'; fi
grep -q '只支持 Alpine' "$work/o" || fail 'A1 未说明发行版限制'
assert_clean 'A1 Debian'

if printf 'YES\n' | TOOLBOX_NET_OPENRC_RUN=$work/nope toolbox_network A1 install \
    "$work/good.crt" "$work/good.key" "$H" >"$work/o" 2>&1; then fail 'A1 接受无 OpenRC'; fi
grep -q 'OpenRC 未作为 init 运行' "$work/o" || fail 'A1 未说明 OpenRC 缺失'

# 输入校验
for bad in 'Bad_Host' 'no-dot'; do
    if printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$bad" >/dev/null 2>&1; then
        fail "A1 非法主机名被接受: $bad"
    fi
done
for p in 0 65536 0080; do
    if printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" "$p" >/dev/null 2>&1; then
        fail "A1 非法端口被接受: $p"
    fi
done
assert_clean 'A1 输入校验'

# 证书
if printf 'YES\n' | toolbox_network A1 install "$work/none.crt" "$work/good.key" "$H" >/dev/null 2>&1; then
    fail 'A1 缺失证书被接受'
fi
if printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/other.key" "$H" >/dev/null 2>&1; then
    fail 'A1 不配对私钥被接受'
fi
out=$(printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" other.example.test 2>&1 || true)
[[ $out == *'不包含主机名'* ]] || fail 'A1 域名不符未报错'
if [[ $HAVE_PAST == 1 ]]; then
    if printf 'YES\n' | toolbox_network A1 install "$work/past.crt" "$work/past.key" "$H" >/dev/null 2>&1; then
        fail 'A1 过期证书被接受'
    fi
fi
printf 'not-a-cert\n' > "$work/junk.crt"
if printf 'YES\n' | toolbox_network A1 install "$work/junk.crt" "$work/good.key" "$H" >/dev/null 2>&1; then
    fail 'A1 垃圾证书被接受'
fi
assert_clean 'A1 证书'

# 端口占用必须给出占用者
printf 'UNCONN 0 0 0.0.0.0:18443 0.0.0.0:* users:(("nginx",pid=7,fd=3))\n' > "$SD/ports.udp"
out=$(printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" 18443 2>&1 || true)
[[ $out == *'已被占用'* && $out == *nginx* ]] || fail 'A1 端口占用未识别或未提示占用者'
rm -f "$SD/ports.udp"
assert_clean 'A1 端口占用'

# 外来 / 自有残留 init 脚本
printf '#!/sbin/openrc-run\ncommand="/usr/bin/someone-else"\n' > "$work/initd/terry-toolbox-hy2"
out=$(printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" 2>&1 || true)
[[ $out == *'不是本模块生成'* ]] || fail 'A1 外来 init 未报告归属'
[[ ! -e $work/bin/terry-toolbox-hy2 ]] || fail 'A1 外来 init 仍写入了二进制'
out=$(printf 'YES\n' | toolbox_network A1 uninstall 2>&1 || true)
[[ $out == *'不是本模块生成'* ]] || fail 'A1 卸载未保护外来 init'
[[ -e $work/initd/terry-toolbox-hy2 ]] || fail 'A1 卸载删除了外来 init'
reset
printf '#!/sbin/openrc-run\ncommand="%s/terry-toolbox-hy2"\n' "$work/bin" > "$work/initd/terry-toolbox-hy2"
: > "$SD/active_terry-toolbox-hy2"
out=$(printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" 2>&1 || true)
[[ $out == *'已在运行'* ]] || fail 'A1 运行中的自有服务未拒绝重装'
reset
printf '#!/sbin/openrc-run\ncommand="%s/terry-toolbox-hy2"\n' "$work/bin" > "$work/initd/terry-toolbox-hy2"
out=$(printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" 2>&1 || true)
[[ $out == *'残留'* ]] || fail 'A1 未识别自有残留'
reset
# 只有二进制或配置目录、没有 init：可能是别人的安装，不覆盖
printf '#!/bin/sh\n' > "$work/bin/terry-toolbox-hy2"
out=$(printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" 2>&1 || true)
[[ $out == *'却没有本模块的 init 脚本'* ]] || fail 'A1 未保护同名二进制'
[[ ! -d $TOOLBOX_A1_ETC ]] || fail 'A1 同名二进制仍在写配置'
reset
mkdir -p "$TOOLBOX_A1_ETC"
out=$(printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" 2>&1 || true)
[[ $out == *'却没有本模块的 init 脚本'* ]] || fail 'A1 未保护同名配置目录'
reset

# 取消不写盘
if printf 'n\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" >/dev/null 2>&1; then
    fail 'A1 取消被当成安装'
fi
assert_clean 'A1 取消'

# 下载失败 / 校验和不符 → 回滚
: > "$SD/download_fail"
if ( export TOOLBOX_A1_BIN_SRC=$work/nope
     printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" ) >/dev/null 2>&1; then
    fail 'A1 下载失败被接受'
fi
assert_clean 'A1 下载失败'
rm -f "$SD/download_fail"
if ( export TOOLBOX_A1_SHA256=0000000000000000000000000000000000000000000000000000000000000000
     printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" ) >"$work/o" 2>&1; then
    fail 'A1 校验和不符被接受'
fi
grep -q "SHA-256 不匹配" "$work/o" || { cat "$work/o" >&2; fail "A1 校验失败未报告原因"; }
assert_clean 'A1 校验失败'

# 冒烟失败 → 回滚
: > "$SD/smoke_fail"
if printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" >/dev/null 2>&1; then
    fail 'A1 冒烟失败被当成成功'
fi
assert_clean 'A1 冒烟失败'
rm -f "$SD/smoke_fail"

# rc-update / rc-service 失败 → 回滚
: > "$SD/rcupd_fail"
if printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" >/dev/null 2>&1; then
    fail 'A1 rc-update 失败被当成成功'
fi
assert_clean 'A1 rc-update 失败'
rm -f "$SD/rcupd_fail"
: > "$SD/start_fail"
if printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" >/dev/null 2>&1; then
    fail 'A1 rc-service start 失败被当成成功'
fi
assert_clean 'A1 rc-service 失败'
rm -f "$SD/start_fail"

# 服务起来但端口不是自己的 → 回滚
printf '18443\n' > "$SD/port"
: > "$SD/foreign_owner"
if printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" 18443 >"$work/o" 2>&1; then
    fail 'A1 端口归属错误被当成成功'
fi
grep -q '监听进程不是' "$work/o" || fail 'A1 未说明归属不符'
assert_clean 'A1 归属不符'
rm -f "$SD/foreign_owner"

# 认证探测失败（错误密码也被接受）→ 回滚并停服务
: > "$SD/accept_any"
if printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" 18443 >/dev/null 2>&1; then
    fail 'A1 错误密码被接受时未失败'
fi
called 'terry-toolbox-hy2 stop' rc-service.log
[[ ! -e $SD/active_terry-toolbox-hy2 ]] || fail 'A1 回滚后服务仍在运行'
assert_clean 'A1 认证失败'
rm -f "$SD/accept_any"

# ================================================================ A1 成功路径
reset
printf '18443\n' > "$SD/port"
out=$(printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" 18443 2>&1) \
    || { printf '%s\n' "$out" >&2; fail 'A1 正常安装失败'; }
bin=$work/bin/terry-toolbox-hy2
init=$work/initd/terry-toolbox-hy2
conf=$TOOLBOX_A1_ETC/config.yaml

[[ -x $bin ]] || fail 'A1 二进制未安装或不可执行'
[[ -s $conf ]] || fail 'A1 配置未写入'
[[ -e $init ]] || fail 'A1 init 脚本未写入'
[[ -e $SD/active_terry-toolbox-hy2 ]] || fail 'A1 服务未启动'
called 'terry-toolbox-hy2 default' rc-update.log
called 'terry-toolbox-hy2 start' rc-service.log

grep -q "^command=\"$bin\"$" "$init" || fail 'A1 init command 不是精确绝对路径'
grep -qF "command_args=\"server -c $conf --disable-update-check\"" "$init" || fail 'A1 init 参数不对'
grep -qF 'command_background="yes"' "$init" || fail 'A1 缺少后台模式'
grep -q '^#!/sbin/openrc-run$' "$init" || fail 'A1 init 缺少 openrc-run shebang'
grep -qF "pidfile=" "$init" || fail 'A1 缺少 pidfile'
grep -qF 'need net' "$init" || fail 'A1 缺少依赖声明'

[[ $(stat -c %a "$conf") == 600 ]] || fail 'A1 配置权限不是 600'
[[ $(stat -c %a "$TOOLBOX_A1_ETC") == 755 ]] || fail 'A1 配置目录权限异常'
grep -q '^listen: :18443$' "$conf" || fail 'A1 监听地址不对'
grep -q '^  sniGuard: strict$' "$conf" || fail 'A1 缺少 sniGuard strict'
grep -qE "^  password: '[A-Za-z0-9]{32}'$" "$conf" || fail 'A1 密码未生成或格式不对'
[[ $(stat -c %a "$TOOLBOX_A1_ETC/key.pem") == 600 ]] || fail 'A1 私钥副本权限不是 600'
cmp -s "$work/good.key" "$TOOLBOX_A1_ETC/key.pem" || fail 'A1 私钥副本内容不一致'
[[ -e $work/good.key ]] || fail 'A1 原始私钥被移动'
[[ $(stat -c %a "$TOOLBOX_A1_ETC/meta") == 600 ]] || fail 'A1 meta 权限不是 600'
grep -q 'hysteria2://' <<< "$out" || fail 'A1 未输出客户端链接'
grep -q 'insecure=1' <<< "$out" || fail 'A1 自签证书应提示 insecure'
grep -q '\[已验证\]' <<< "$out" || fail 'A1 未报告验证结果'
[[ -s "$work/run/terry-toolbox-hy2-verify/good.yaml" ]] || fail 'A1 探测配置未生成'
grep -q 'FATAL' "$work/run/terry-toolbox-hy2-verify/bad.log" 2>/dev/null \
    || fail 'A1 未执行负向探测'

# 重复安装要拒绝且不改配置
sum=$(sha256sum "$conf" | cut -d' ' -f1)
out=$(printf 'YES\n' | toolbox_network A1 install "$work/good.crt" "$work/good.key" "$H" 18443 2>&1 || true)
[[ $out == *'已在运行'* ]] || fail 'A1 重复安装未拒绝'
[[ $(sha256sum "$conf" | cut -d' ' -f1) == "$sum" ]] || fail 'A1 重复安装改动了配置'

# 状态：识别自有监听
toolbox_network A1 status > "$work/status.out" 2>&1 || fail 'A1 status 失败'
grep -q '由本服务持有' "$work/status.out" || fail 'A1 status 未识别自有监听'

# 卸载：只删自己的东西，邻近单元保留
printf '#!/sbin/openrc-run\ncommand="/usr/bin/other"\n' > "$work/initd/other"
toolbox_network A1 uninstall <<< 'YES' >/dev/null 2>&1 || fail 'A1 卸载失败'
[[ ! -e $init && ! -e $bin && ! -d $TOOLBOX_A1_ETC ]] || fail 'A1 卸载未清理'
[[ -e $work/initd/other ]] || fail 'A1 卸载删除了邻近单元'
[[ -e $work/good.crt && -e $work/good.key ]] || fail 'A1 卸载删除了原始证书'
if toolbox_network A1 status >/dev/null 2>&1; then fail 'A1 卸载后 status 仍报存在'; fi
if printf 'YES\n' | toolbox_network A1 uninstall >/dev/null 2>&1; then fail 'A1 未安装时卸载仍成功'; fi
reset

# ================================================================ A2
if printf 'YES\n' | TOOLBOX_NET_OS_RELEASE=$work/os-debian toolbox_network A2 install \
    >/dev/null 2>&1; then fail 'A2 接受 Debian'; fi
for bad in 'no-dot' 'host:0' 'host:70000' 'a_b.test'; do
    if printf 'YES\n' | toolbox_network A2 install 18444 "$bad" >/dev/null 2>&1; then
        fail "A2 非法回落目标被接受: $bad"
    fi
done
assert_clean 'A2 参数校验'

printf 'LISTEN 0 0 0.0.0.0:18444 0.0.0.0:* users:(("nginx",pid=7,fd=3))\n' > "$SD/ports.tcp"
out=$(printf 'YES\n' | toolbox_network A2 install 18444 2>&1 || true)
[[ $out == *'已被占用'* && $out == *nginx* ]] || fail 'A2 端口占用未识别'
rm -f "$SD/ports.tcp"
assert_clean 'A2 端口占用'

printf '#!/sbin/openrc-run\ncommand="/usr/bin/xray"\n' > "$work/initd/terry-toolbox-xray"
out=$(printf 'YES\n' | toolbox_network A2 install 18444 2>&1 || true)
[[ $out == *'不是本模块生成'* ]] || fail 'A2 外来 init 未报告归属'
reset
printf '#!/bin/sh\n' > "$work/bin/terry-toolbox-xray"
out=$(printf 'YES\n' | toolbox_network A2 install 18444 2>&1 || true)
[[ $out == *'却没有本模块的 init 脚本'* ]] || fail 'A2 未保护同名二进制'
reset

if printf 'n\n' | toolbox_network A2 install 18444 >/dev/null 2>&1; then fail 'A2 取消被当成安装'; fi
assert_clean 'A2 取消'

if ( export TOOLBOX_A2_SHA256=0000000000000000000000000000000000000000000000000000000000000000
     printf 'YES\n' | toolbox_network A2 install 18444 ) >"$work/o" 2>&1; then
    fail 'A2 校验和不符被接受'
fi
grep -q 'SHA-256 不匹配' "$work/o" || { cat "$work/o" >&2; fail 'A2 校验失败未报告原因'; }
assert_clean 'A2 校验失败'

: > "$SD/test_fail"
if printf 'YES\n' | toolbox_network A2 install 18444 >"$work/o" 2>&1; then fail 'A2 配置自检失败被当成成功'; fi
grep -q '配置自检失败' "$work/o" || fail 'A2 未报告配置自检失败'
assert_clean 'A2 配置自检'
rm -f "$SD/test_fail"

: > "$SD/probe_fail"
if printf 'YES\n' | toolbox_network A2 install 18444 >/dev/null 2>&1; then fail 'A2 探测失败被当成成功'; fi
called 'terry-toolbox-xray stop' rc-service.log
assert_clean 'A2 探测失败'
rm -f "$SD/probe_fail"

# 成功路径
reset
printf '18444\n' > "$SD/port"
out=$(printf 'YES\n' | toolbox_network A2 install 18444 'www.cloudflare.com:443' 2>&1) \
    || { printf '%s\n' "$out" >&2; fail 'A2 正常安装失败'; }
bin=$work/bin/terry-toolbox-xray
init=$work/initd/terry-toolbox-xray
cfg=$TOOLBOX_A2_ETC/config.json
[[ -x $bin ]] || fail 'A2 二进制未安装'
[[ -e $init && -s $cfg ]] || fail 'A2 init 或配置未写入'
python3 -m json.tool "$cfg" > /dev/null || fail 'A2 配置不是合法 JSON'
[[ $(stat -c %a "$cfg") == 600 ]] || fail 'A2 配置权限不是 600'
grep -q '"port": 18444' "$cfg" || fail 'A2 端口未写入'
grep -q '"dest": "www.cloudflare.com:443"' "$cfg" || fail 'A2 回落目标未写入'
grep -q '"security": "reality"' "$cfg" || fail 'A2 未启用 REALITY'
grep -q '"id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"' "$cfg" || fail 'A2 uuid 未写入'
grep -q '"privateKey": "PRIV-TEST-KEY' "$cfg" || fail 'A2 私钥未写入'
grep -q '"shortIds"' "$cfg" || fail 'A2 缺少 shortId'
grep -q "^command=\"$bin\"$" "$init" || fail 'A2 init command 不对'
grep -qF "command_args=\"run -c $cfg\"" "$init" || fail 'A2 init 参数不对'
called 'terry-toolbox-xray default' rc-update.log
called 'terry-toolbox-xray start' rc-service.log
grep -q 'vless://' <<< "$out" || fail 'A2 未输出客户端链接'
grep -q 'pbk=PUB-TEST-KEY' <<< "$out" || fail 'A2 链接缺少公钥'
grep -q '\[已验证\]' <<< "$out" || fail 'A2 未报告验证结果'

out=$(printf 'YES\n' | toolbox_network A2 install 18444 2>&1 || true)
[[ $out == *'已在运行'* ]] || fail 'A2 重复安装未拒绝'
toolbox_network A2 status > "$work/status.out" 2>&1 || fail 'A2 status 失败'
grep -q '由本服务持有' "$work/status.out" || fail 'A2 status 未识别自有监听'
toolbox_network A2 uninstall <<< 'YES' >/dev/null 2>&1 || fail 'A2 卸载失败'
[[ ! -e $init && ! -e $bin && ! -d $TOOLBOX_A2_ETC ]] || fail 'A2 卸载未清理'
reset

# 未知动作与参数错误
if toolbox_network A1 frobnicate >/dev/null 2>&1; then fail 'A1 未知动作被接受'; fi
if printf 'YES\n' | toolbox_network A1 install >/dev/null 2>&1; then fail 'A1 缺少参数仍安装'; fi
if toolbox_network A2 frobnicate >/dev/null 2>&1; then fail 'A2 未知动作被接受'; fi
assert_clean 'A1/A2 参数错误'

# ================================================================ B23
if printf '1\nYES\n' | TOOLBOX_NET_UID=1000 toolbox_network B23 >/dev/null 2>&1; then
    fail 'B23 非 root 被接受'
fi
out=$( ( command() { [[ ${1:-} == -v && ${2:-} == resolvectl ]] && return 1; builtin command "$@"; }
         printf '1\nYES\n' | toolbox_network B23 ) 2>&1 || true)
[[ $out == *'未找到 resolvectl'* ]] || fail 'B23 缺失 resolvectl 未 fail closed'
[[ ! -e $TOOLBOX_DNS_DROPIN_DIR/99-terry-toolbox-dns.conf ]] || fail 'B23 缺 resolvectl 时写盘'

: > "$SD/resolved_down"
out=$(printf '1\nYES\n' | toolbox_network B23 2>&1 || true)
[[ $out == *'systemd-resolved 未运行'* ]] || fail 'B23 未拒绝未运行的 resolved'
rm -f "$SD/resolved_down"

# resolv.conf 不是 stub 链接
rm -f "$TOOLBOX_DNS_RESOLV_CONF"
printf 'nameserver 8.8.8.8\n' > "$TOOLBOX_DNS_RESOLV_CONF"
out=$(printf '1\nYES\n' | toolbox_network B23 2>&1 || true)
[[ $out == *'普通文件'* ]] || fail 'B23 未拒绝普通文件 resolv.conf'
rm -f "$TOOLBOX_DNS_RESOLV_CONF"
ln -s /run/NetworkManager/resolv.conf "$TOOLBOX_DNS_RESOLV_CONF"
out=$(printf '1\nYES\n' | toolbox_network B23 2>&1 || true)
[[ $out == *'被其他程序接管'* ]] || fail 'B23 未拒绝外来 resolv.conf'
rm -f "$TOOLBOX_DNS_RESOLV_CONF"
ln -s "$work/dns/systemd/resolve/stub-resolv.conf" "$TOOLBOX_DNS_RESOLV_CONF"

# 自定义地址校验
out=$(printf '6\n1.1.1.300 8.8.8.8\nYES\n' | toolbox_network B23 2>&1 || true)
[[ $out == *'不是合法的 IPv4/IPv6'* ]] || fail 'B23 未拒绝非法地址'
[[ ! -e $TOOLBOX_DNS_DROPIN_DIR/99-terry-toolbox-dns.conf ]] || fail 'B23 非法地址仍写盘'

# 取消不写盘、不重启
printf '1\nn\n' | toolbox_network B23 >/dev/null 2>&1 || true
[[ ! -e $TOOLBOX_DNS_DROPIN_DIR/99-terry-toolbox-dns.conf ]] || fail 'B23 取消仍写盘'
grep -q 'restart systemd-resolved' "$SD/systemctl.log" 2>/dev/null && fail 'B23 取消仍重启'

# 成功路径：预置 1
out=$(printf '1\nYES\n' | toolbox_network B23 2>&1) || { printf '%s\n' "$out" >&2; fail 'B23 应用失败'; }
dropin=$TOOLBOX_DNS_DROPIN_DIR/99-terry-toolbox-dns.conf
[[ -e $dropin ]] || fail 'B23 未写 drop-in'
[[ $(stat -c %a "$dropin") == 644 ]] || fail 'B23 drop-in 权限不是 644'
grep -q '^DNS=1.1.1.1 1.0.0.1$' "$dropin" || fail 'B23 DNS 未写入'
grep -q '^Domains=~.$' "$dropin" || fail 'B23 缺少 ~. 路由域'
grep -q '^\[Resolve\]$' "$dropin" || fail 'B23 缺少段名'
called 'dns eth0 1.1.1.1 1.0.0.1' dns.applied
called 'domain eth0 ~.' domain.applied
grep -q 'restart systemd-resolved' "$SD/systemctl.log" || fail 'B23 未重启解析服务'
grep -q '\[已验证\] 1.1.1.1' <<< "$out" || fail 'B23 未报告验证'
grep -q 'eth1(10.9.9.9)' <<< "$out" || fail 'B23 未提示其他链路泄漏'
[[ $out == *'eth0('* ]] && fail 'B23 把默认路由链路自己也列成泄漏'
grep -q '明文 DNS' <<< "$out" || fail 'B23 未提示明文 DNS'

# 已有 drop-in 先备份；再次应用覆盖并保留备份
printf '[Resolve]\nDNS=9.9.9.9\n' > "$dropin"
out=$(printf '2\nYES\n' | toolbox_network B23 2>&1) || fail 'B23 覆盖已有配置失败'
grep -q '^DNS=8.8.8.8 8.8.4.4$' "$dropin" || fail 'B23 未覆盖'
[[ -e $dropin.pre-toolbox ]] || fail 'B23 未备份原有配置'
grep -q '^DNS=9.9.9.9$' "$dropin.pre-toolbox" || fail 'B23 备份内容不对'

# 校验失败 → 回滚，原有内容恢复
: > "$SD/query_fail"
out=$(printf '3\nYES\n' | toolbox_network B23 2>&1 || true)
[[ $out == *'解析查询仍然失败'* ]] || fail 'B23 校验失败未报错'
[[ $out == *'回滚'* ]] || fail 'B23 未回滚'
grep -q '^DNS=9.9.9.9$' "$dropin" || fail 'B23 回滚未恢复原文件'
[[ ! -e $dropin.pre-toolbox ]] || fail 'B23 回滚后仍留备份'
called 'revert eth0' resolvectl.log
grep -q '^DNS=9.9.9.9$' "$dropin" || fail 'B23 回滚内容不符'
rm -f "$SD/query_fail"

# 默认路由不唯一时只写全局并提示
cat > "$SD/status.txt" <<'EOF'
Global
         Protocols: -LLMNR
Link 2 (eth0)
    Current Scopes: DNS
         Protocols: +DefaultRoute
       DNS Servers: 10.1.1.1
Link 3 (eth2)
    Current Scopes: DNS
         Protocols: +DefaultRoute
       DNS Servers: 10.2.2.2
EOF
before_apply=$(wc -l < "$SD/dns.applied" 2>/dev/null || echo 0)
out=$(printf '4\nYES\n' | toolbox_network B23 2>&1) || fail 'B23 双默认路由失败'
[[ $out == *'未能唯一定位默认路由'* ]] || fail 'B23 未提示路由不唯一'
grep -q '^DNS=223.5.5.5 223.6.6.6$' "$dropin" || fail 'B23 全局配置未写'
[[ $(wc -l < "$SD/dns.applied") -eq $before_apply ]] || fail 'B23 路由不唯一时仍写了链路'

# 有默认路由但没有 DNS 的链路（tailscale/网桥）不算出口链路
cat > "$SD/status.txt" <<'EOF'
Global
Link 2 (eth0)
    Current Scopes: DNS
         Protocols: +DefaultRoute
       DNS Servers: 10.1.1.1
     Default Route: yes
Link 3 (tailscale0)
    Current Scopes: none
         Protocols: +DefaultRoute
     Default Route: yes
EOF
out=$(printf '4\nYES\n' | toolbox_network B23 2>&1) || fail 'B23 无 DNS 链路干扰'
[[ $out == *'作用链路  : eth0'* ]] || fail 'B23 把无 DNS 链路当成出口'
called 'dns eth0 223.5.5.5 223.6.6.6' dns.applied
rm -f "$SD/status.txt"

# 自定义地址
out=$(printf '6\n1.1.1.1,2606:4700:4700::1111\nYES\n' | toolbox_network B23 2>&1) \
    || fail 'B23 自定义地址失败'
grep -q '^DNS=1.1.1.1 2606:4700:4700::1111$' "$dropin" || fail 'B23 自定义地址未写入'

# 状态
out=$(printf '8\n' | toolbox_network B23 2>&1) || fail 'B23 状态失败'
grep -q '本工具配置' <<< "$out" || fail 'B23 状态未显示配置'
grep -q 'systemd-resolved' <<< "$out" || fail 'B23 状态未显示服务'

# 恢复：有备份就还原备份内容
printf '7\nYES\n' | toolbox_network B23 >/dev/null 2>&1 || fail 'B23 恢复失败'
grep -q '^DNS=9.9.9.9$' "$dropin" || fail 'B23 恢复未还原备份'
[[ ! -e $dropin.pre-toolbox ]] || fail 'B23 恢复后仍留备份'
called 'revert eth0' resolvectl.log
# 还原后的文件不是本工具生成的，再恢复不能误删
if printf '7\nYES\n' | toolbox_network B23 >"$work/o" 2>&1; then fail 'B23 二次恢复误删'; fi
grep -q '不是本工具生成' "$work/o" || fail 'B23 二次恢复未说明原因'
rm -f "$dropin"
if printf '7\nYES\n' | toolbox_network B23 >/dev/null 2>&1; then fail 'B23 无配置时恢复仍成功'; fi
if printf '9\n' | toolbox_network B23 >/dev/null 2>&1; then fail 'B23 非法菜单项被接受'; fi
if toolbox_network B23 install nope >/dev/null 2>&1; then fail 'B23 install 接受非法地址'; fi

printf 'network alpine/dns tests passed\n'
