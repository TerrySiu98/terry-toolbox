#!/usr/bin/env bash
# Source-only B10 entry point. No work occurs when this module is sourced.
# Upstream WebSSH provides a Dockerfile and compose build instructions, but we
# could not verify a publisher-provided registry image or application-level auth.
# https://github.com/huashengdun/webssh/blob/master/README.md
# https://github.com/huashengdun/webssh/pull/213 (image publication unmerged)
# Do not silently substitute third-party images or expose an unauthenticated proxy.
toolbox_webssh() {
    if (( $# != 0 )); then
        printf '用法: toolbox_webssh（无参数）\n' >&2
        return 2
    fi
    printf '%s\n' \
        'B10 WebSSH 暂不部署：无法验证上游官方发布的 Docker 镜像，无法固定可信镜像摘要。' \
        '上游项目的 Dockerfile 并不证明某第三方镜像是官方构建；本工具不会替换来源。' \
        'WebSSH 页面本身无已验证的访问认证；即使仅绑定回环地址也不是用户认证，容器和宿主机访问仍需隔离。' \
        '需要可验证的官方镜像和经审查的认证、TLS 及网络隔离方案后才能启用；未执行任何部署。' >&2
    return 1
}
