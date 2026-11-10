# A5 REALITY 兼容修复候选

日期：2026-11-11。分支 `codex/a5-reality-compat-20261111`，基于已发布源码 `5f44ee4075a85f3cf2569e9380e9d050396d77c2`。尚未合并或部署到 Cloudflare Workers。

## 问题与修复

用户 Debian 的 OpenSSL 1.1.1w 对 `www.cloudflare.com:443` 已返回 `New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384`、`ALPN protocol: h2` 和证书验证成功，旧 A5 却要求另有 `Protocol : TLSv1.3` 行。TLS 1.3 的会话详情依赖收到 NewSessionTicket，不能假设始终存在。现接受完整 New/Reused 摘要行或完整 Protocol 行；不匹配未知格式时说明“未能确认”，不再断言目标网站不支持。

保留 TLS 1.3、h2 与证书主机名检查；握手返回非零时保留退出码并拒绝，即使已输出证书也不放行。未添加忽略 TLS 错误选项。证书链检查仍沿用原有提示语义；本补丁不是整个 OpenSSL 文本解析器或所有旧版本 EOF 行为的安全重写。

同时修复客户端导入链接把 SNI 当作服务器地址的问题。菜单明确区分目标网站、SNI、监听端口和本服务器公网地址；地址只做语法校验，不调用第三方公网 IP 查询服务。IPv4、IPv6（含压缩、方括号及 IPv4 尾部）和域名均支持，拒绝 URL/端口/空白/控制字符等混入。

新增 CLI 第四个可选参数：`install <回落目标> <SNI> [监听端口] [服务器公网IP或域名]`。旧 CLI 无地址时保持原确认输入顺序，生成明确的 `SERVER_ADDRESS` 模板。完整链接以 `0600` 保存到已有安装目录中的 `vless.txt`，纳入原文件清单/失败回滚；meta 八字段格式不变。安装完成后只有链接显示失败时，明确报告服务已启动及文件位置，不误报整项安装失败或回滚服务。

## 验证

开发机最终冻结 runner **14/14 通过**：syntax、build、dependencies、dependency-entrypoints、entry、network-a5-target、network-alpine-feedback、network-alpine、network、vmess-dispatch、menu、entry-feedback、deploy-cloudflare、worker。源码无漂移，全部子孙进程清理完成。证据摘要 SHA-256：`379e842bcd5bc7c2497a0f54882ecf01306250de82df9fdf4ac2d85d0766f409`。

独立目标检测 **39 个模拟场景**（8 个成功、31 个拒绝）在源码和最终单文件均通过，包括用户输出、Reused、Protocol、TLS 1.2、缺证书、无 h2/h2c、真实证书主机名不符、前后缀误命中、非零退出及超时带完整正常输出。网络套件还覆盖服务器地址、导出字节、权限、旧 CLI、菜单默认/自定义端口、EOF、写入失败回滚和显示失败保留服务。独立源码复核发现的安装尾部显示失败语义已修正并补测。

父级只读公网探测在开发机 OpenSSL 3.5.7 上成功，实际调用候选 `net_a5_check_target www.cloudflare.com 443 www.cloudflare.com` 返回 0。这是目标握手验证，不是安装或公网 VLESS 客户端验证；用户机器的 1.1.1w 成功握手来自用户提供的输出，修复后未在用户机器重跑。

15 个内嵌模块与源码逐字节一致，四个 Worker 模块与 manifest 一致。候选 752321 字节，SHA-256 `405b73b8274b984f42e6f675b3d46556d2eff81071af3895e9cb387c43a03492`；manifest SHA-256 `4e09eb28ed07527c4e618d966ed22928c643a010ccd36feb6f13a621827b71af`。

首轮 12/14 通过，两项失败分别来自开发机缺 cryptography，以及旧网络 fixture 在早期 B23 检查假定 root。已把签名仓库中的 cryptography/cffi/bcrypt 解包到项目独立工具目录（未安装到宿主），并给两处 fixture 显式设置已有 UID 模拟值；原非 root 拒绝断言保留。最终整批 14 项重跑通过，首轮日志保留。未安装服务、修改内核/网络或操作用户服务器，未执行旧 B31 可选真实转发测试。

## 官方依据与交接

已只读核对 OpenSSL 官方固定版本源码：

- [1.1.1w s_client.c](https://github.com/openssl/openssl/blob/OpenSSL_1_1_1w/apps/s_client.c)：864–872 行说明 NewSessionTicket 触发 TLS 1.3 会话打印；3277–3280 行输出 New/Reused 摘要；3365–3374 行区分 TLS 1.3 与传统会话详情。
- [3.0.15 s_client.c](https://github.com/openssl/openssl/blob/openssl-3.0.15/apps/s_client.c)：同样存在摘要与会话详情的区别。

Hermes 按本分支精确提交复核后，沿用现有 `sh.uw.cx` Workers 发布、annotations 保留、私有备份及四模块/公网回读流程。GitHub 合并与 Worker 发布分别记录；现有 PR #9 线上记录保持历史事实，不能用候选哈希冒充已上线版本。
