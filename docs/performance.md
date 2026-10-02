# 性能验证

修复版测量脚本 `Tests/cec_optimization_perf.ps1` 提供 SessionCount、WorkerCount、PayloadBytes、TCPDepth、ServerWorkers、Seconds 和 Iterations 参数；默认仍为 4 会话、1 worker、1024 字节、TCP depth 8、1 server worker。JSON 记录参数与三份二进制 SHA256。可依次比较 worker 1/2/4/8、session 4/64/1024、负载 64/1024/65507；TCP 批次必须不超过 64 MiB。多 worker 对照应同步增加服务端线程，以免仅测到固定单线程服务端上限。

Transport 可选 both/tcp/udp；EchoCount 默认为 0，使用 Seconds 定时。非零 EchoCount 改为双方相同总次数的自然完成，客户端超时 60 秒，Seconds 不适用；服务端在所有客户端完成后由脚本终止。高负载下旧基线会因持续非空 CQ 推迟停止，4 worker 对照使用固定额度，避免混入停止超时或只选择碰巧通过的定时样本。最终验收与测量见 [客户端修复验收](remediation.md)。

本轮按“所有修复写完后统一测试”实施，保留修改前 executable 对最终版比较；没有逐任务构建测量，无法分别归因 RIO 修正、本地统计或无限认领的收益。现有 QPC、整数换算和 histogram 仍按每个 attempt 执行；TCP 批次摊薄每个逻辑 echo 的成本，UDP 每包一条样本。延迟起点在发起请求前，终点在收发完成和字节比较之后，包含完成处理和校验，不等于纯网络 RTT。初始化的倍增复制只视为启动优化。

保留默认全量校验和全量计时；延迟采样、校验关闭、timing wheel 和 NUMA 不在本轮实现。回环短样本和零 ARC 都不能证明部署场景持续加速。

下文是客户端迁移完成时的短样本 Swift/C++ 对照。后续 Swift 6.4 所有权优化使用了每样本 5 秒的 Swift 优化前后对照，见 [优化记录](optimization.md) 和 [完整样本](optimization-performance-2026-10-02.json)。

使用 tests/cec_perf_compare.ps1 对 Release Swift/C++ 客户端与同一个原生 C++ RIO 服务端进行 TCP、UDP 回环对照。每种协议交替运行两种客户端各 3 次；参数为 20000 次、1024 字节模式、4 会话、1 工作线程，TCP 深度 8。记录引擎 elapsed_ms、吞吐、批次延迟桶、进程 CPU 时间、峰值工作集和包含启动时间的 wall time。

2026-10-02，Windows x64，Intel Family 6 Model 154，8 个可用逻辑处理器，Swift 6.4 RELEASE + assertions。最终测量串行执行，未同时进行构建或兼容测试；全部 12 个样本 echoed=20000、corrupted/lost/network_errors=0。完整记录：[performance-2026-10-02.json](performance-2026-10-02.json)。

下表是每组 3 次的中位数：

| 协议 / 客户端 | echo/s | MiB/s | 引擎 p99 桶下界 µs | 进程 wall ms | 进程 CPU ms | 峰值工作集 MiB |
|---|---:|---:|---:|---:|---:|---:|
| TCP / C++ | 1250000 | 1220.70 | 64 | 25.78 | 15.63 | 3.30 |
| TCP / Swift | 1250000 | 1220.70 | 64 | 50.39 | 62.50 | 13.03 |
| UDP / C++ | 322580.65 | 315.02 | 32 | 65.02 | 46.88 | 3.30 |
| UDP / Swift | 322580.65 | 315.02 | 32 | 80.34 | 62.50 | 13.03 |

该短样本的引擎吞吐中位数相同；Swift 的总进程时间、CPU 和峰值工作集更高。客户端引擎 elapsed_ms 只有 15–63 ms，Windows tick 与 CPU 时间量化使样本波动较大（CPU 小于量化粒度的样本可记录为 0）；不能据此宣称普遍性能等价。峰值工作集通过保留的进程句柄调用 K32GetProcessMemoryInfo，包含运行库成本；不是注册 arena 用量。

本实验不设吞吐通过阈值，也不替代部署机器上的长时间、跨主机压测。可用 tests/cec_perf_compare.ps1 传入本机三份 Release exe 路径重复对照，不把相邻 C++ 项目作为正式构建依赖。
