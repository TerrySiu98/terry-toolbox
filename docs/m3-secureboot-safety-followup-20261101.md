# PR #4 合并复核安全补丁（2026-11-01）

## 修改

- 独立复核发现原 Secure Boot helper 把整段 `read(name)` 的 ENOENT 都当作变量不存在；真实 fixture 文件成功打开后的 read ENOENT 使 helper 和完整 Alpine preflight 错误通过。这是合并阻塞，不是原生已开启 Secure Boot 主机实测结论。
- 现在仅 SecureBoot/SetupMode 文件名 `os.open` 失败且 errno=ENOENT 才允许缺失；open 成功立即按“存在变量”拒绝，不读取它。close 错误也拒绝；BootCurrent/BootOrder 保持真实读取和长度、属性、一致性核对。
- `unset EFIVARFS_PATH LIBEFIVAR_OPS VARS_PATH` 失败终止，不在无法清除覆盖时调用 mokutil。原磁盘、公钥、双 YES、exact disk、再次预检、取消、状态与普通重启门禁未改。

## 实际验证

- 新增 `tests/secureboot-error-boundary-test.sh`。正向两种官方消息/helper/preflight 均通过，13/49 RED 断言暴露 read/fstat/close ENOENT 及 readonly unset 误放行；修正后 49/49 GREEN。覆盖两变量、三种 fd 操作及 errno 2/5/13、存在/空/符号链接/FIFO、readonly 清理失败。原错误入口 syntax harness 日志保留，不计入 RED。
- 修正冻结源码的 repository runner 单次 9/9 有效通过、无跳过/超时/源码漂移/子孙遗留：syntax、build、entry、reinstall、secureboot-error-boundary、system-reboot-plan、menu、deploy-cloudflare、Worker。重装 85 项模拟、独立安全测试 49 项、重启门禁 18 项；不是全仓复跑或真实重装验收。
- 修正 SHA-256 `2f8f180fa295cd08f4300f63184c10264210e3cd31b4280d0477b479389ffea7`，705455 字节；15 个内嵌模块和冻结源码逐字节一致，完整 Worker manifest 与候选一致。
- 初始独立审查和原有绿色测试无法排除新增缺陷，保留初始 blocker 与真实 RED/GREEN 证据。修正的独立有限复核 15/15、exit 0，SB-1 已关闭且补丁范围无新增阻塞；另复跑新增测试 49/49。轨迹证明成功 open 后不再进入 read/fstat，readonly 三例均未调用 mokutil；不把这些通过称为真实固件错误注入实测。

## 边界与状态

未实际安装服务、prepare、挂载、修改引导、擦盘或重启，宿主软件包数据库/日志哈希未变。作者真实 Alpine UEFI 只读预检只对应原候选，不是当前补丁原生复验。部分异常只报 Python traceback 但 fail closed；不承诺抵御另一个 root 并发换挂载。既有 loop 父设备未挂载而子分区已挂载的边界仍在，此类布局不要 M3 prepare。

当前尚未合并或上线，原域名和 Worker 保持 PR #3。待精确 head 合并、Worker 四模块/完整设置/DNS 与公网回读后另记录发布结果。
