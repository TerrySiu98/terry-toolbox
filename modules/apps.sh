#!/usr/bin/env bash
# Source this file; nothing runs until toolbox_app NUMBER is called.
# Docker CLI and a working daemon must already be installed. All host ports are
# loopback-only on Docker Engine >= 28. Each app gets its own bridge network;
# this is not a firewall against host users, privileged containers, custom routing,
# direct routing or other containers deliberately connected to that network.
# No host networking or Docker socket mounts. Existing data requires explicit
# reuse confirmation and may be modified by the app; nothing is deleted.
# Only the default local Unix socket is accepted. A socket proxy could still point
# to a remote daemon: the operator must ensure it really is the local Engine.
# Multi-platform manifest digests resolved from official registries on 2026-10-30;
# SHA-256 verified against manifest bytes and registry digest header. Pinning is not
# signature verification, security review or a guarantee of application readiness.
# Pins require deliberate security updates and compatibility testing before reuse.
# Stirling PDF remains mutable: its registry returned HTTP 403 during validation.
# References: upstream READMEs at github.com/{AlistGo/alist,CorentinTh/it-tools,
# jason5ng32/MyIP,hslr-s/sun-panel,usememos/memos,NginxProxyManager/nginx-proxy-manager,
# halo-dev/halo,cym1102/nginxWebUI,gnmyt/Nexterm,LibreSpark/LibreTV,
# Stirling-Tools/Stirling-PDF,jeessy2/ddns-go,dani-garcia/vaultwarden};
# https://docs.nexterm.dev/installation
# https://nezha.wiki/en_US/guide/dashboard.html
# https://github.com/MHSanaei/3x-ui/wiki/Installation

# A subshell prevents secrets, umask and local environment changes leaking to the caller.
toolbox_app() (
    local id=${1-} name image default_port target_port data_target='' note='' port answer
    local root data names secret extra_ports='' environment='' context endpoint version major network_id reuse=0 canonical subdir
    local -a args=()
    if [[ $# != 1 ]]; then printf '用法: toolbox_app <数字>\n' >&2; return 2; fi
    case "$id" in
        3)  name=alist; image=xhofe/alist@sha256:afa909f81817770520df07515287eb3df3d4e3c6631ca28b02cbae8499149b39; default_port=5244; target_port=5244; data_target=/opt/alist/data; note='初始化后立即更换管理员密码；查看上游文档获取初始密码。' ;;
        4)  name=nezha; image=ghcr.io/nezhahq/nezha@sha256:c3de06b940fc2da673e7d29be3c742270440cb881675df84b35e474ab9799bf1; default_port=8008; target_port=8008; data_target=/dashboard/data; note='上游首次启动默认 admin/admin；立即从 /dashboard 登录并修改密码，公网开放前必须配置 HTTPS 和认证。Agent 通信和网页共用端口；本部署仅本机访问，远程 Agent 须另行安全配置支持 gRPC 的 TLS 代理及 Agent 地址。复用数据如已更改监听端口，需自行调整配置。' ;;
        5)  name=x-ui; image=ghcr.io/mhsanaei/3x-ui@sha256:1628adbd9bed680d25d6f714bef4a20f132105f4612ea294952f6665dad32e5b; default_port=2053; target_port=2053; data_target=/etc/x-ui; environment=xui; note='3X-UI 上游首次启动默认 admin/admin；立即修改凭据，建议开启 2FA、设置独立路径，公网访问前配置 HTTPS。仅映射管理端口，代理入站端口未映射；须另行审查并配置端口、协议及防火墙。未授予 NET_ADMIN/NET_RAW，Fail2ban 已禁用，IP 限制封禁不会生效。复用数据如已更改监听端口或路径需自行调整。' ;;
        9)  name=it-tools; image=corentinth/it-tools@sha256:8b8128748339583ca951af03dfe02a9a4d7363f61a216226fc28030731a5a61f; default_port=7090; target_port=80 ;;
        13) name=myip; image=jason5ng32/myip@sha256:ba54d22576f1cd86dcfb9c453fcf805bd6817ca9bed234a6fd529f5f0f19fb31; default_port=18966; target_port=18966; note='MaxMind 功能需要另行配置凭据；域名访问需配置 ALLOWED_DOMAINS。' ;;
        17) name=sun-panel; image=hslr/sun-panel@sha256:dc8fea427bf5ee825b81ebbc5bd6f39e61123ecbf8173601a57b1ec00637c444; default_port=3002; target_port=3002; data_target=/app/conf; note='上游说明最新版本可能闭源；初始化后修改默认账号。' ;;
        18) printf 'B18 为预留项。\n' >&2; return 2 ;;
        20) name=memos; image=neosmemo/memos@sha256:24c2707ddd8fbd2ceaa7a61ecab86a53cdcde640b24ce572b73da14b00b5785f; default_port=5230; target_port=5230; data_target=/var/opt/memos; note='请立即通过本机页面完成管理员初始化。' ;;
        21) name=nginx-proxy-manager; image=jc21/nginx-proxy-manager@sha256:4393e642e233e5efd5adeb7f10918d4aaea71c9ed875b94190273fc8e87f9594; default_port=81; target_port=81; data_target=/data; extra_ports=npm; note='代理端口 80/443 仅绑定本机，初始化后更改默认登录凭据。容器内 localhost 指向 NPM 自身，无法访问宿主机 127.0.0.1 或其他应用的 loopback 端口；默认独立网络也无法访问其他应用。请另行设计并审查安全的上游连接及 TLS，勿假定 localhost 可用。' ;;
        22) name=halo; image=halohub/halo@sha256:cc28f8bab142b79bf1bc5bdb07c2e0746821af5c814705e72b5beda6e9cabbc9; default_port=8090; target_port=8090; data_target=/root/.halo2; note='请立即通过本机页面完成初始化。' ;;
        24) name=nginxwebui; image=cym1102/nginxwebui@sha256:3e5ffa13dfc23702e3cd8d60320466617649a783b39ae5087ebee0a1ac704c67; default_port=8080; target_port=8080; data_target=/home/nginxWebUI; note='仅映射管理端口；容器内 Nginx 的代理端口需自行审查并映射。' ;;
        25) name=nexterm; image=nexterm/aio@sha256:def6f6a50b48c842d3fbe796ff8e7ce6b8fa54e2d92116a62742859c64f47d7e; default_port=6989; target_port=6989; data_target=/app/data; environment=nexterm; note='Bridge 网络不支持所有 host 网络功能；请妥善备份加密密钥。' ;;
        26) name=libretv; image=ghcr.io/librespark/libretv@sha256:f19c897f84c303e887d1f03313897dc294dfbeebd4ac9d2aa42070146d18b7e9; default_port=8080; target_port=8080; environment=libretv; note='上游要求设置访问密码；仅使用合法视频源。' ;;
        27) name=stirling-pdf; image=docker.stirlingpdf.com/stirlingtools/stirling-pdf:latest; default_port=8080; target_port=8080; data_target=/configs; note='默认仅本机访问；公网访问前请单独配置认证和 TLS。' ;;
        28) printf 'B28 mfa-start 未实现：原脚本下载未校验的 JAR 和脚本，无法安全确认发行物。\n' >&2; return 2 ;;
        29) name=ddns-go; image=jeessy/ddns-go@sha256:0336e6eddcb4052e978c90f0aa530f77205b1dd08fe28057869dbc77a60c5671; default_port=9876; target_port=9876; data_target=/root; note='请在本机页面初始化并设置密码；bridge 模式可能无法读取宿主机网卡/IPv6。' ;;
        30) name=vaultwarden; image=vaultwarden/server@sha256:efb3cde962015fcc036b2ea625242248611943b27212ebf4392841fb30fad055; default_port=3003; target_port=80; data_target=/data; note='先在本机完成账号初始化并关闭注册；正式使用需可信域名、HTTPS、备份及上游安全配置。' ;;
        *) printf '未知应用编号: %s\n' "$id" >&2; return 2 ;;
    esac
    if ! command -v docker >/dev/null 2>&1; then
        printf '未找到 Docker；请先自行安装并启动 Docker。\n' >&2; return 1
    fi
    # Do not infer locality from daemon info: bind paths are resolved by the daemon.
    if [[ -v DOCKER_HOST || -v DOCKER_CONTEXT || -v DOCKER_TLS_VERIFY || -v DOCKER_CERT_PATH || -v DOCKER_API_VERSION ]]; then
        printf 'Docker 连接环境变量会造成目标歧义；请清除 DOCKER_HOST/DOCKER_CONTEXT/TLS/API 覆盖后重试。\n' >&2; return 1
    fi
    if ! context=$(docker context show) || [[ $context != default ]] ||
       ! endpoint=$(docker context inspect default --format '{{.Endpoints.docker.Host}}') ||
       [[ $endpoint != unix:///var/run/docker.sock ]]; then
        printf '仅支持 default context 的 unix:///var/run/docker.sock 本机 daemon；远程或未知连接已拒绝。确认该 socket 并非远程代理。\n' >&2; return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        printf 'Docker 不可用或无权限访问 daemon；未作任何部署。\n' >&2; return 1
    fi
    if ! version=$(docker version --format '{{.Server.Version}}') || [[ ! $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(\+[a-zA-Z0-9.+_-]+)?$ ]]; then
        printf '无法确定稳定版 Docker Engine 版本；中止。\n' >&2; return 1
    fi
    major=${BASH_REMATCH[1]}
    if (( ${#major} > 3 )) || (( 10#$major < 28 )); then
        printf '需要 Docker Engine 28 或更高版本，以避免旧版 loopback 端口向同网段泄露。\n' >&2; return 1
    fi
    if ! names=$(docker container ls -a --format '{{.Names}}'); then
        printf '无法检查容器名称；中止。\n' >&2; return 1
    fi
    if [[ $'\n'"$names"$'\n' == *$'\n'"terry-$name"$'\n'* ]]; then
        printf '容器 terry-%s 已存在；不会覆盖或删除。\n' "$name" >&2; return 1
    fi
    root=${HOME:?HOME 必须设置}/.local/share/terry-toolbox/apps
    data=$root/$name
    if [[ $data == *','* || $data == *$'\n'* || $data != /* ]]; then
        printf 'HOME 必须是绝对路径且不能包含逗号或换行，避免 Docker 挂载参数歧义。\n' >&2; return 1
    fi
    if ! canonical=$(realpath -m -- "$data") || [[ $canonical != "$data" ]]; then
        printf '数据路径包含符号链接或非规范路径；拒绝挂载。\n' >&2; return 1
    fi
    if [[ -n $data_target && ( -e $data || -L $data ) ]]; then
        if [[ ! -d $data || -L $data || ! -O $data ]]; then
            printf '已有数据路径不是当前用户所有的真实目录；拒绝复用。\n' >&2; return 1
        fi
        reuse=1
        printf '已有数据: %s。可能是失败部署或用户数据；复用会允许容器修改、迁移或损坏其中数据。请先检查并备份；本工具不会删除任何内容。\n输入 REUSE 明确确认复用，其他输入取消: ' "$data" >&2
        if ! IFS= read -r answer || [[ $answer != REUSE ]]; then
            printf '未确认复用，已取消。\n' >&2; return 1
        fi
    fi
    if [[ $extra_ports == npm && ( -e $data/letsencrypt || -L $data/letsencrypt ) ]]; then
        if [[ ! -d $data/letsencrypt || -L $data/letsencrypt || ! -O $data/letsencrypt ]]; then
            printf '证书路径不安全；拒绝使用。\n' >&2; return 1
        fi
    fi
    if [[ $id == 5 ]]; then
        for subdir in cert acme; do
            if [[ -e $data/$subdir || -L $data/$subdir ]]; then
                if [[ ! -d $data/$subdir || -L $data/$subdir || ! -O $data/$subdir ]]; then
                    printf 'X-UI 证书路径不安全；拒绝使用。\n' >&2; return 1
                fi
            fi
        done
    fi
    printf 'B%s %s\n镜像: %s\n' "$id" "$name" "$image"
    if [[ $image == *@sha256:* ]]; then
        printf '镜像已固定 digest；仍需审查来源、安全更新与兼容性，应用未经过真实部署验证。\n'
    else
        printf '警告：镜像标签可变，尚未能校验并固定 digest；部署前应自行审查。\n' >&2
    fi
    if [[ -n $data_target ]]; then
        if (( reuse )); then printf '将复用持久数据目录: %s\n' "$data"; else printf '新建持久数据目录: %s\n' "$data"; fi
    fi
    printf '安全边界: 仅接受默认 Unix socket；请确认它不是转发到远程 daemon 的代理。独立 bridge 不阻止宿主机用户、特权容器、被连接到该网络的容器或自定义直接路由访问；127.0.0.1 仅限制宿主机端口发布。\n'
    [[ -z $note ]] || printf '注意: %s\n' "$note"
    printf '本机端口 [%s]: ' "$default_port"
    if ! IFS= read -r port; then printf '\n输入结束，已取消。\n' >&2; return 1; fi
    port=${port:-$default_port}
    if [[ ! $port =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$port > 65535 )); then
        printf '无效端口，须为 1–65535 的十进制数。\n' >&2; return 1
    fi
    if [[ $extra_ports == npm && ( $port == 80 || $port == 443 ) ]]; then
        printf '管理端口不能与代理端口 80 或 443 相同。\n' >&2; return 1
    fi
    printf '将仅绑定 127.0.0.1:%s -> %s' "$port" "$target_port"
    [[ $extra_ports != npm ]] || printf '，以及 127.0.0.1:80、443'
    printf '。确认创建容器? [y/N] '
    if ! IFS= read -r answer || [[ $answer != y && $answer != Y ]]; then
        printf '已取消。\n' >&2; return 1
    fi
    case "$environment" in
        nexterm)
            printf '输入自行生成并妥善备份的 64 位十六进制加密密钥（输入不回显）: ' >&2
            if ! IFS= read -r -s secret; then printf '\n输入结束。\n' >&2; return 1; fi
            printf '\n' >&2
            if [[ ! $secret =~ ^[0-9a-fA-F]{64}$ ]]; then printf '无效密钥。\n' >&2; return 1; fi
            export ENCRYPTION_KEY=$secret; unset secret
            args+=(--env ENCRYPTION_KEY)
            ;;
        libretv)
            printf '设置 LibreTV 访问密码（至少 12 字符，输入不回显）: ' >&2
            if ! IFS= read -r -s secret; then printf '\n输入结束。\n' >&2; return 1; fi
            printf '\n' >&2
            if (( ${#secret} < 12 )); then printf '密码过短。\n' >&2; return 1; fi
            export PASSWORD=$secret; unset secret
            args+=(--env PASSWORD)
            ;;
    esac
    if [[ $environment == xui ]]; then
        args+=(--env 'XUI_ENABLE_FAIL2BAN=false' --env 'XRAY_VMESS_AEAD_FORCED=false')
    fi
    # Docker itself arbitrates ports and container names atomically. Never remove
    # anything after failure: a newly created directory may contain valuable data.
    if [[ -n $data_target ]]; then
        umask 077
        if ! mkdir -p -- "$root" || { (( ! reuse )) && ! mkdir -- "$data"; }; then
            printf '无法安全创建数据目录: %s\n' "$data" >&2; return 1
        fi
        if [[ -L $data || ! -d $data || ! -O $data ]] || ! canonical=$(realpath -m -- "$data") || [[ $canonical != "$data" ]]; then
            printf '数据目录不安全；中止。\n' >&2; return 1
        fi
        args+=(--mount "type=bind,src=$data,dst=$data_target")
        if [[ $extra_ports == npm ]]; then
            if [[ ! -e $data/letsencrypt && ! -L $data/letsencrypt ]]; then
                if ! mkdir -- "$data/letsencrypt"; then printf '无法创建证书目录。\n' >&2; return 1; fi
            fi
            if [[ ! -d $data/letsencrypt || -L $data/letsencrypt || ! -O $data/letsencrypt ]]; then
                printf '证书目录不安全。\n' >&2; return 1
            fi
            args+=(--mount "type=bind,src=$data/letsencrypt,dst=/etc/letsencrypt")
        fi
        if [[ $id == 5 ]]; then
            for subdir in cert acme; do
                if [[ ! -e $data/$subdir && ! -L $data/$subdir ]]; then
                    if ! mkdir -- "$data/$subdir"; then printf '无法创建 X-UI 证书目录。\n' >&2; return 1; fi
                fi
                if [[ ! -d $data/$subdir || -L $data/$subdir || ! -O $data/$subdir ]] || ! canonical=$(realpath -m -- "$data/$subdir") || [[ $canonical != "$data/$subdir" ]]; then
                    printf 'X-UI 证书目录不安全。\n' >&2; return 1
                fi
            done
            args+=(--mount "type=bind,src=$data/cert,dst=/root/cert" --mount "type=bind,src=$data/acme,dst=/root/.acme.sh")
        fi
    fi
    if [[ $extra_ports == npm ]]; then
        args+=(-p 127.0.0.1:80:80 -p 127.0.0.1:443:443)
    fi
    if [[ $id == 24 ]]; then args+=(--env 'BOOT_OPTIONS=--server.port=8080'); fi
    # Unique, fresh bridge each attempt: never reuse an existing, possibly shared network.
    # Network creation can leave an orphan on failure; do not delete it automatically.
    if ! network_id=$(docker network create --driver bridge "terry-$name-$(date +%s)-$BASHPID-$RANDOM"); then
        printf '无法创建独立网络；数据保留。检查 Docker 网络及数据后再重试。\n' >&2; return 1
    fi
    if [[ ! $network_id =~ ^[a-fA-F0-9]{12,64}$ ]]; then
        printf 'Docker 返回的网络 ID 无效；不运行容器，网络和数据均保留以供检查。\n' >&2; return 1
    fi
    if ! docker run -d --name "terry-$name" --network "$network_id" --restart unless-stopped \
        -p "127.0.0.1:$port:$target_port" "${args[@]}" "$image"; then
        printf '容器创建失败（可能是端口冲突或镜像拉取失败）；数据和网络均保留。检查是否存在同名容器，检查并备份数据后可输入 REUSE 重试；不会自动删除任何资源。\n' >&2; return 1
    fi
    printf 'Docker 已接受创建请求。地址: http://127.0.0.1:%s；应用就绪状态尚未验证。\n' "$port"
    printf '远程访问请使用 SSH 隧道；如需公网访问，先完成认证及 HTTPS 安全配置。\n'
)
