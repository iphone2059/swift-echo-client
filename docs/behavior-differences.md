# 与 C++ 基线的差异

正常协议、字节模式、原始 UTF-16 参数、参数范围及诊断、认领额度、RIO 数据通路、ConnectEx 建连、IOCP 工作线程、重连排空、退出分类和统计字段与基线一致。产品和帮助中的程序名改为 swift-echo-client；服务端未在本次重构中实现。

## 所有权与布局

资源聚合嵌入不可复制 worker，由 CECWorkerOwner 在固定分配中唯一持有。会话和 OVERLAPPED 分别由 CECPinnedStorage 保持固定地址。Session 中只存可复制原生上下文，不拥有 socket；socket 的关闭责任在 UniqueArray 中的 CECSocketOwner。原生字段地址由实际 MemoryLayout 偏移计算，不能把 Swift 临时 inout 地址交给异步 API。

RIO buffer/CQ owner 保存函数表副本，避免原版函数表裸指针的寿命依赖。共享停止/额度采用 Atomic，快照及协调器事件所有权采用 Mutex；完整引擎没有声明 unchecked Sendable，也不采用 Swift Task/actor 替代原生工作线程。

## 本轮 RIO 与存储修正

原版在同一个 worker 的多个在途收发中复用整个 arena 的注册 ID。Swift 版本改为每个 session/direction 独立注册，RIO_BUF.Offset 相对该注册区；短发送在自己的前次完成后复用 ID。全部注册在启动线程前建立，关闭 socket、排空、join、关闭 CQ 后才解除注册，最后释放物理内存。

同一 worker 的发送数据只初始化一次并保持只读，各发送 ID 可指向同一物理区；接收区仍互不重叠。实际存储由旧的 `2 × sessions × maximumAttemptBytes` 改为 `(sessions + actualWorkers) × maximumAttemptBytes`。解析阶段不再用旧公式提前拒绝 /memory，最终由引擎按实际线程分配检查。某些原来超过 /memory 的输入现在可以接受；注册 ID 数量为每会话两个，注册元数据开销不属于 /memory。

完成统计及 claimed 在 worker 本地累计，有限额度仍用全局 CAS；无限模式不再更新全局 claimed。周期快照可滞后约 100 ms，不保证所有 worker 来自同一时刻，最终统计在 join 后完整汇总。network_errors 记录可恢复错误，独立于终态损坏/丢失分类，原有退出策略保留。

## 已验证的健壮性修正

正常工作线程在处理最后一次完成时，协调器可能已投递停止包。原版通知关闭代码只接受下一个握手包，合法停止包先到会造成退出 4。故障驱动向真实 IOCP 先投递停止包，修复前稳定返回 4，修复后返回 0。Swift 版本在 1 秒总期限内消费这个已无作用的控制包，再验证握手的 key 与 OVERLAPPED；其他不合法包仍 fail-fast。

最终非受控退出在补未认领额度前检查 claimed = echoed + corrupted + lost。延迟换算和分位秩使用 full-width 整数运算，避免乘法溢出；统计速率显式使用 POSIX locale，保留小数点和两位小数。

## 分配与环境边界

VirtualAlloc、HeapAlloc、Winsock/RIO/线程/句柄 API 的失败可按原版阶段处理。UniqueArray、Swift 类及 worker 元数据使用标准库分配；真正耗尽这些分配时，Swift 运行库可能终止进程，无法保证映射到原版的可恢复退出码。CECPatternError.allocationFailure 预留给可失败分配实现，目前标准库没有该恢复路径。`/memory` 仅限制注册 arena，不是整个进程内存上限。

当前测试环境 DNS 将 .invalid 域名合成为 198.18.1.218；确定性解析失败测试使用格式错误的 IPv4 名称，生产仍直接遵循 GetAddrInfoW 的结果。Windows x64 以外的平台不在此版本范围内。必须提供匹配 Swift 6.4 的动态运行库；不要将 debug 测试库作为生产依赖部署。
