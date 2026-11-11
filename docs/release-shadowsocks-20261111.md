# A6 Alpine SS / A7 Debian SS — 已发布开发预览

[PR #13](https://github.com/TerrySiu98/terry-toolbox/pull/13) 已合并并发布到既有 Cloudflare Worker `terry-toolbox` / `sh.uw.cx`。发布时间（UTC）：`2026-11-11T14:50:26.460793+00:00`。仍为开发预览，尚非稳定版。

- 已审 head：`a12d0967a9b241ff19294b264df6365f75de3649`
- 合并源码：`5cdafa5921384d0257ca8c83536a780a89975c70`，tree 与已验候选一致。
- 线上脚本 SHA-256：`ca071eb9d8dda96b2c58441f3d07918d0c50d460c303933e097af89f12b07db7`；823673 字节。
- SS 模块 SHA-256：`a3d2c9ff2cb1fdbb2fc0895af4303086405e82c935291d1596831a9f6b0832dd`。

## 使用

```bash
bash <(curl -fsSL sh.uw.cx)
```

重新下载后直接输入 `A6`（Alpine/OpenRC）或 `A7`（Debian/systemd），选择 `1 安装 / 2 卸载 / 3 状态`。填服务器公网 IPv4 或解析至 IPv4 的域名，以及 TCP/UDP 端口（默认 8388）；两次完整 YES 后才安装。Ubuntu/其他发行版及 IPv6 字面入口当前拒绝。

固定校验 Xray 26.10.31，单用户 `chacha20-ietf-poly1305`、TCP + 原生 UDP。无需证书，服务/目录独立；不改已有 HY2/Xray、DNS、防火墙或安全组。默认不启用开机自启。安装成功后仅标准输入和输出均为终端时显示密码，分享链接和 `0600` 导出请勿公开。Mihomo 条目仍需加入代理组与规则。服务端及云安全组自行放行所选 TCP 和 UDP 端口。

该旧版兼容协议上游已标为弃用、无前向保密；不能保证比 HY2 或 VLESS 更快。完整使用说明见 README；[原候选记录](shadowsocks-candidate.md)保留历史。

## 验证与边界

- Alpine 3.24.4/OpenRC 与 Debian 13.7/systemd 的独立 x86_64/KVM guest：安装、状态、重启、卸载；实际生成导出对应的 Xray/Mihomo TCP/UDP nonce 正向、错误密码零目标命中及随后正向控制通过。修补后的 TERM 清理边界通过。
- 前次 11 项相关检查和最终 5 项受影响复跑均有有效结果；这是依赖核对后的组合覆盖，不是一次最终源码全仓 suite。已知基线 `network-alpine-feedback-test.sh` 失败保留。
- 已发现的锁登记、同 inode 存活进程删除及清理 trap 顺序阻塞均修复和复核关闭。最后补丁独立复审 approve；该审查的额外完整 review 脚本 90 秒超时 rc124，虽然新增回归已 PASS，仍不计为完整通过。
- 单文件重建与已验候选一致，16 个内嵌模块与源文件逐字节匹配，Worker 路由通过。
- 一次受限完整上传后四个 Worker 模块、完整 settings/annotations、workers.dev、域名和 DNS 精确回读一致。14 项普通/新查询公网检查、11 项下载安全检查（含 A6/A7 导航）与系统 TLS 信任通过。欢迎页/router未改，未重复浏览器 UI。
- 暂存和实际 commit 扫描均 raw exit1，四处继承的公开协议样例或空变量声明已逐项核对，不是秘密；未添加 allowlist。GitHub 无 checks/status 或 required gates，空列表不称 CI 通过。

公网 SS 入站、用户手机导入、YouTube A/B、整机自启、arm64、Ubuntu/其他发行版、IPv6 未验。测试服务已卸载、guest 已停止；本次发布只更新分发脚本，没有在任何用户节点安装或升级 SS。

发布失败现场和旧版完整 Worker/配置快照由维护者私有保存；不盲目重复旧 adapter、不自动回退或重新绑定域名。回退下载脚本不会卸载用户自行安装的 SS。

Terry's Hermes
