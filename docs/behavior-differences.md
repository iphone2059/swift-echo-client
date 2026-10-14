# 当前实现差异与边界

本页描述 2026-10-14 源码收尾时的事实。历史 WIP 见 [暂停快照](REVIEW_CHECKPOINT_2026-10-14.md)，2026-10-02 的验证与性能结果保留在 [修复记录](remediation.md)、[优化记录](optimization.md) 和原始测量工件；这些历史结果不构成本轮新源码的验收证据。当前复核及待运行门禁见 [源码收尾审查](review/2026-10-14/client-final-source-report.md)；[恢复审查](review/2026-10-14/resume-client-report.md) 保留为较早的静态证据。

正常协议、严格 UTF-16 参数、参数诊断优先级、每 Session `/n`、RIO/ConnectEx/IOCP、重连排空、退出分类和统计字段以当前 `echo-binary-contract-v1` 的 C++/Rust/Zig 为目标。帮助程序名为 swift-echo-client。Swift Server 是独立仓库，不由本客户端源码提供。

## 文件、架构与所有权

生产源码为扁平 Sources 中的八个文件。Package.swift 是 Swift 的真实模块声明例外，对应 Rust lib.rs／Zig root.zig；不创建占位文件。纯 Session/WorkerCore/Timer 位于 internal.swift；RioTransport/RioAdapter、静态泛型 WorkerRuntime 和 Coordinator 位于 engine.swift；原生资源所有者位于 native.swift。执行链为 `Transport → Completion/Event → Runtime → Core → Action → Runtime → Transport`。

Worker、provider Slot、通知和注册表使用固定地址 HeapAlloc 存储；Core/Timer 使用不可复制 CECFixedArray。生产 Slot 保存非拥有原生 socket 值，关闭责任由 Transport/worker release 处理，不使用旧版 UniqueArray socket 集合。生产负载直接填入可失败 VirtualAlloc arena；UniqueArray/CECPatternStorage 和全局 CAS quota 辅助类型只供冷路径测试夹具，不参与生产配额处理。

C++、Rust、Zig 与 Swift 当前均为每 Session 的 TX/RX 窗口独立注册。各窗口有独立物理区域；存储预算是 `2 × sessions × maximumAttemptBytes`，不再使用旧版共享 TX 的 `(sessions + actualWorkers) × maximumAttemptBytes`。Worker 内存份额为 `(总预算 / 总 Session 数) × Worker Session 数`。每批先收后发；部分发送在原 Attempt 的 TX 区间继续尾部，不重新认领 `/n`。

业务账本与 Provider 账本独立。Send/Receive/ConnectEx 的完成只核销自己的所有权；代际、SocketContext、操作、提交长度和偏移在核销前验证，损坏的有符号偏移不会先触发算术 trap。关闭 socket 只发起取消；全部相关完成退休后才发布 GenerationDrained。首次 Close 锚定不可延长的 QPC 五秒宽限。

Coordinator 先 Join 全部已启动线程，再集中检查、快照并释放。每个 worker destroy 内部重复原生 Slot、聚合计数和通知 guard，包括 never-started 与重复 destroy；Worker、Transport、Resources 的隐式 deinit 也分别检查对应的所有权及释放前置条件，不能绕过显式释放边界。先关闭 CQ，再注销全部 Buffer ID，再释放 arena 与 Slot；通知 OVERLAPPED 的固定存储保持到 IOCP 已关闭之后，随后关闭线程句柄。Resources 隐式析构还要求所有依赖句柄、Socket/RQ 和注册先行退休。合法通知 gap 为 0/1，只消费真实 IOCP 通知，不合成 RIONotify 完成。

到期 timer 仲裁保留每个已取得 IOCP 包的正常服务顺序。通知完成原有最多 64 批 CQ 服务，STOP 在取得时立即开始关闭；有限包预算与直接 CQ 记录预算仍保留。Startup 先产生正常 Connect/Attempt actions，再观察既有 Stop。`/i` 非零时请求 1 ms timer resolution 并在所有返回路径平衡释放；请求失败保留原始 code，具名 `timeBeginPeriod(client pacing)` 并退出 4。

## 配额、统计与诊断

每 Session 独立认领 `/n`，统计由 Worker/Core 本地持有；有限和无限模式均无生产全局 quota CAS。开启 /report 后按 `min(report_seconds * 1000, 50)` 毫秒的间隔通过 Mutex 发布统计（与 Rust/Zig 一致）；周期快照可以滞后且不保证来自同一时刻，最终统计在 Join 后完整合并。

输出包含 attempted/pending/echoed/corrupted/lost/cancelled、原生成功发送前缀与接收字节、connections/reconnects/network_errors。有限运行失败的未认领额度同时计入最终 attempted 与 lost；受控 Stop 不补未认领额度。终态要求 `attempted = echoed + corrupted + lost + cancelled` 且 active/pending 为零。损坏、丢失与原生错误分类分别核算，64 桶延迟以完整批次采样，mean 为真实样本均值，max 为最大桶下界。

CEC_DIAG_FILE 的行格式、路径限制和文件选项与 C++/Rust 对应。读取所有通知计数发生在 Join/check 后、worker destroy 清除残余 arm 前；每个已启动 Worker 一行。诊断打开或写入失败不改变生产结果。这里描述源码行为，实际正反例和互操作仍需本轮门禁证明。

## 分配、工具链与性能边界

Windows x64 是本版本范围。SwiftPM 使用 tools-version 6.4、Swift 6 模式及 StrictMemorySafety；实际编译器/LLVM/SDK/运行库身份以新构建清单为准，不能用历史 Swift 6.4 Release 数据代替当前快照。

VirtualAlloc、HeapAlloc、Winsock/RIO/线程/句柄 API 的失败按具名边界处理。Swift 的控制/发布对象、CLI 容器、字符串输出与冷路径诊断仍使用运行库分配，极端 OOM 不保证具有可恢复的标准库接口。`/memory` 只限制注册 arena，不是进程总内存上限。热路径没有新增动态 protocol existential、Task/Actor 或每完成堆分配；生成代码、ARC 与正式性能结论须在冻结产物后验证，不由静态结构推断。
