# 客户端修复验收

范围为已批准修复计划的任务 1–9。默认负载、参数、有限额度、RIO/IOCP 数据通路、重连、完整字节校验、延迟统计和退出分类保留；C++ 项目及 Swift 服务端未修改。

## 实现

- 每会话发送与接收分别注册，短发送只在前次完成后复用自己的 ID；初始化失败和正常关闭均先关闭 CQ、解除注册，再释放 arena。
- 每 worker 一份只读发送批次，各会话接收区独立。存储预算为 `(sessions + actualWorkers) × maximumAttemptBytes`；注册元数据及运行库不属于 /memory。
- 完成统计与 claimed 本地累加；有限次数继续全局 CAS，无限模式取消全局 claimed RMW。报告每 100 ms 同步发布，最终在 join 后精确汇总。
- 协调器通过手动事件与 release/acquire finished 标志等待；已结束 worker 不再重复检查，不增加 64 worker 的句柄等待上限问题。
- 持续非空 CQ 在每批完成之间处理 stop/fatal、定时器和统计发布，防止高吞吐时控制工作饥饿；仍排空 CQ 后才重装通知。
- 缓存并检查会话地址范围、字段布局与接收偏移，保留动态长度和完成身份检查。timer 同 deadline 跳过，其他更新按方向 sift。
- 配置借用在工作线程内部逐层传递，完整配置只在原生线程入口暂存一次。重复 pattern 用前缀及倍增复制初始化。

## 验收

所有修复及回归用例先写完，随后统一验证。最终 Debug、Release 和排除原构建缓存的独立目录 Release 均通过：

- Swift Testing：31 个测试、13 个 suite，包括并发快照、所有桶合并、精确认领、重复填充、注册失败清理、共享布局，以及持续非空 CQ 的停止/fatal 排空。
- 所有权编译正反例 8 个；内存安全编译正反例 6 个；源码策略及门禁自身回归。
- 原生故障场景 10 个，包括通知错误码、完成地址范围/身份、arena 容量和关闭停止包竞争。
- 实际 TCP/UDP 分片与停止排空、64 worker 自然退出和提前结束、报告/停止并发、无限模式失败核算、共享存储预算、最后非整批额度、重连、宽字符参数及 Ctrl+Break。
- 补齐计划的 1 ms 节拍、1 秒请求超时、UInt32 最大秒数期限的受控排空；更新后的进程脚本分别验证 Debug、Release 及独立目录 Release 产物。
- 优化 IR：beginAttempt、completeAttempt、cecProcessRIOResult、cecPostSend、cecDrainCompletions 和实际分发循环均为零直接 ARC；前两者无 288 字节完整配置 memcpy。原生线程入口保留一次非拥有暂存。低频报告/结束同步仍有必要的引用持有，未宣称整个程序零 ARC。

```powershell
pwsh -NoProfile -File build.ps1 -Configuration debug
pwsh -NoProfile -File build.ps1 -Configuration release
pwsh -NoProfile -File Tests/cec_standalone_check.ps1 -Configuration release
```

## 执行取舍

用户要求完成修复后再测试，因此没有逐任务 RED/GREEN 或中间版本测量；注册修正与最终共享存储一起验收。性能只比较修改前 executable 与最终版，不能分离单项优化收益。

快照直接累加，避免报告阶段的临时 Array；输出和 wrapping 语义保持一致。Mutex 内的事件唯一所有者由 CECSharedControl 的确切 @safe 声明封装，未开放原生句柄；源码策略仍拒绝未审查标注。低频同步留在独立函数，ARC 门禁同时检查实际工作循环，不能通过拆出入口绕过。

没有为强制 CreateThread 失败增加生产故障开关，也没有耗尽系统线程资源；该错误分支通过源码审查，动态覆盖低于其他注入失败。注册首个、中间、最后一个失败及真实部分 worker 启动失败已经执行。

工作区没有 Git；保留修改前 66 个文件的 SHA256 快照、原 executable、最终日志和清单，不创建提交，也不删除这些回退资料。初次独立复核无发现；性能验收随后暴露 CQ 饥饿，修复后的增量复核未发现生产问题。指出的一处测试时间假设已修正，快照断言不再依赖线程未跨过 100 ms 发布周期。

延迟采样、抽样/关闭校验、timing wheel 和 NUMA 保留为条件性任务 10。本轮仍全量计时、全量校验；回环测试不能建立跨主机/NIC 的性能结论。

完整日志与执行取舍保存在工作区的 `.superpowers/sdd/2026-10-02-swift-echo-client-remediation/`。

## 最终性能对照

Windows x64，Swift 6.4 RELEASE + assertions。相同原生 C++ RIO 服务端，每组双方各三次，预热不计入结果，AB/BA/AB 交替顺序，测量期间没有并行构建或测试。所有正式样本均无 corrupted/lost/network_errors。两种 worker 配置的客户端/服务端线程数对应为 1/1 和 4/4，payload 1024 字节，TCP depth 8。

1 worker/4 session 使用每次 5 秒；旧版在 4 worker/64 session 下也出现定时停止饥饿，因此该组采用相同固定额度自然退出：TCP 每次 2000 万、UDP 每次 200 万。两组不能作为相同测量条件的扩展性曲线。最终版单独的高负载 TCP /w 5 在引擎 5000 ms、进程约 5039 ms 正常退出，零损坏/丢失/网络错误。

下表为每组三次中位数；CPU 是客户端总进程 CPU 毫秒/百万已完成 echo，变化为最终版相对原版。

| worker / 协议 | 原版 echo/s | 最终版 echo/s | 吞吐变化 | 原版 CPU ms/百万 | 最终版 CPU ms/百万 | CPU 变化 |
|---|---:|---:|---:|---:|---:|---:|
| 1 / TCP | 1,630,697.60 | 1,657,419.20 | +1.64% | 563.41 | 541.13 | -3.95% |
| 1 / UDP | 351,679.23 | 323,522.80 | -8.01% | 2535.23 | 2546.11 | +0.43% |
| 4 / TCP | 3,497,726.48 | 3,636,363.64 | +3.96% | 1013.28 | 951.56 | -6.09% |
| 4 / UDP | 137,042.62 | 138,821.41 | +1.30% | 4140.63 | 4125.00 | -0.38% |

吞吐没有一致提升。1 worker UDP 的单次范围为原版约 28.6–35.5 万、最终版约 30.8–36.4 万 echo/s；中位数下降需保留，三次样本不足以区分持续回退与运行波动。p99 桶下界中位数分别保持 64、32、256、512 µs；桶本身不能反映桶内延迟差异。

本组峰值工作集中位数约 13.1–13.2 MiB，物理 arena 减小没有转化为可观的总工作集下降。对应 TCP arena 从 64 KiB 降到 40 KiB（1 worker），从 1024 KiB 降到 544 KiB（4 worker）；这些是布局公式的确定变化。注册元数据及启动时间没有独立 profiling。当前结果不支持稳定或普遍提速结论。

正式数据：[1 worker](remediation-performance-2026-10-02-w1.json)、[4 worker TCP](remediation-performance-2026-10-02-w4-tcp.json)、[4 worker UDP](remediation-performance-2026-10-02-w4-udp.json)。旧版 SHA256 为 `2A7D600F02108D93F6779D9B5F0E132141F6B39B26B6116CD98D8C1AA447BA86`；最终版为 `6822D191797D3A63AA8CC9A6F0E7982AB757205E63C956CFC8F67DC646E2BEF6`。CQ 修复前的测量已归档，不混入本表。
