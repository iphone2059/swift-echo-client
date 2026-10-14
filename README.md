# swift-echo-client

> 2026-10-14：已补齐完成区间、有限额度账本、CEC_DIAG_FILE、IOCP 控制顺序、隐式释放 guard 与 pacing timer-resolution owner；当前源码证据见 [源码收尾审查](docs/review/2026-10-14/client-final-source-report.md) 和 [携回补丁核对](docs/review/2026-10-14/client-overlay-source-audit.md)。本轮完整格式化、Release/Debug 门禁仍待执行。此前 [暂停交接](docs/REVIEW_CHECKPOINT_2026-10-14.md) 和 [恢复审查](docs/review/2026-10-14/resume-client-report.md) 保留为历史源码记录，验收依据为 [跨语言规范](docs/CPP_Rust_Zig_Swift_Refactoring_Spec_v2.0.md)。

Swift 6 语言模式的 Windows x64 RIO Echo 压测客户端。参数、TCP/UDP 回显字节、工作线程划分、有限次数认领、停止排空、退出码和统计沿用 C++ 客户端。默认负载为 `echo from <host>`。

## 构建与运行

要求 Windows 10 或更新版本、支持本包 Swift 6.4 tools-version 与所有权特性的 Windows 工具链及配套 Windows SDK、PowerShell 7。实际编译器、LLVM、SDK 与优化配置以本轮构建清单为准；Swift 6.4 tools-version 不等于编译器版本。无第三方 Swift 包，不依赖相邻客户端或服务端源码。工具链及运行库须在 PATH 中。

```powershell
swift build -c release --product swift-echo-client
$bin = swift build -c release --show-bin-path
& "$bin/swift-echo-client.exe" 127.0.0.1 /p tcp /r 7001 /n 37 /k 8 /z 4096 /c 8 /threads 3 /q /stats
& "$bin/swift-echo-client.exe" 127.0.0.1 /p udp /r 7001 /n 5 /z 65507 /stats
& "$bin/swift-echo-client.exe" /h
```

完整验证依次运行 `format.ps1` → `build_release.ps1` → `build_debug.ps1`（两种构建均含 SwiftPM 单元测试与 PowerShell 原生门禁、reset storm）：构建、Swift Testing、所有权编译正反例、源码策略、原生失败边界、TCP/UDP 进程测试、多线程、重连、周期统计、宽字符参数和真实 Ctrl+Break 停止。所有客户端子进程有超时，对端在 finally 中清理。

历史 Swift 6.4 Windows 环境中，默认构建后端的 Release 测试运行器曾遗漏测试 DLL，导致发现零个测试。验证脚本在单元测试阶段显式采用 `swift test -c release --build-system native`（Debug 同样采用 native），核心模块与测试均按对应配置编译；正式客户端构建仍使用默认后端。脚本拒绝零测试结果，历史证据见工具链文档；本轮实际发现数与结果须重新记录。

```powershell
pwsh -NoProfile -File tests/cec_standalone_check.ps1 -Configuration release
```

该命令将包复制到独立目录，排除原构建缓存，再运行同一完整验证。`swift-echo-client-fault-driver.exe` 是测试工具，源码和故障场景位于 `Tests/CECFaultDriver` 的独立 executable target；它依赖生产核心，正式客户端不依赖它。上面的 `--product swift-echo-client` 仅构建正式产品；完整验证脚本另行构建测试驱动。

## 参数与结果

| 参数 | 默认值 / 语义 |
|---|---|
| target、`/p tcp\|udp` | 必填；IPv4 解析 |
| `/r`、`/l` | 远端端口 7，本地端口 0；固定本地端口要求 `/c 1` |
| `/n` | 每会话 5；0 为不限次数；批次按会话本地认领 |
| `/t`、`/i` | 每批超时 5 秒；批间间隔 0 毫秒 |
| `/d`、`/z`、`/zt` | 字面文本、二进制计数、可打印计数；互斥 |
| `/k` | TCP 批次深度 1；最终批次可少于深度 |
| `/c`、`/threads` | 1 会话；默认线程数为 CPU 数（最多 64）与会话数的较小值 |
| `/w` | 默认不设时限；指定后到期受控停止 |
| `/rc [seconds]` | 默认不重连；省略秒数为 1，允许 0；TCP 固定本地端口不允许重连 |
| `/report`、`/b` | 默认不周期输出；socket buffer 采用系统默认 |
| `/cq`、`/memory` | 每线程 CQ 容量 4096；实际发送/接收存储总限额 1073741824 字节 |
| `/q`、`/stats` | quiet 抑制最终输出，stats 强制最终输出；report 独立生效 |

退出码：0 成功（含无既有错误的受控停止）、1 参数/负载无效、2 网络准备失败或无成功回显且没有回显损失、3 损坏或丢失、4 内部错误。`/n` 不隐含时限，持续重连可一直运行，应按需要显式设置 `/w`。

UDP 单包最多 65507 字节，TCP 单批最多 64 MiB。每线程 arena 不超过 DWORD.max，CQ 至少容纳本线程会话数的两倍。每会话拥有独立发送与接收窗口，各窗口独立注册；存储预算为 `2 × 会话数 × 最大批次字节数`，worker 内存份额为 `(总预算 / 总会话数) × worker 会话数`，不包含注册元数据或运行库开销。生产负载直接填充可失败的 VirtualAlloc arena，worker、provider slot、通知、注册 ID、Core 与 Timer 存储均由可失败的 HeapAlloc 初始化；UniqueArray 负载构造只供冷路径测试夹具使用。延迟直方图为 64 个对数桶，按完整批次采样；输出 attempted、pending、cancelled、原生成功发送前缀／接收字节、连接／重连、p50/p99/p999、真实样本 mean 和最大桶下界。完成数组 `InlineArray<256, RIORESULT>` 占 6 KiB。

## 实现与部署

生产源码直接位于扁平 `Sources`，没有 target 子目录。`Package.swift` 为 Swift 的模块声明差异：CECClientCore 和 swift_echo_client 共享物理 Sources 路径并使用明确、不相交的 source 列表；模块名保留既有测试契约。Rust lib.rs／Zig root.zig 没有占位 Swift 文件。

| 文件 | 职责 |
| --- | --- |
| main.swift | UTF-16 参数入口、console 注册、退出码 |
| contract.swift | 参数表、校验、预算与二进制规则 |
| types.swift | 共享选项、错误元数据、事件操作词汇 |
| payload.swift | 确定性字节计数、填充、重复负载 |
| metrics.swift | 纯业务账本、64 桶、最终统计格式 |
| native.swift | Windows ABI、原生资源、固定存储所有权、共享停止控制 |
| internal.swift | Session、纯 WorkerCore、Scheduler／Timer、统计发布 |
| engine.swift | RioTransport、静态泛型 WorkerRuntime、IOCP loop、Coordinator |

执行链为 `Transport → Completion/Event → Runtime → Core → Action → Runtime → Transport`。Core／Timer 自己拥有不可复制的固定存储，不依赖 socket、RQ、OVERLAPPED 或 provider outstanding。生产 Runtime 使用静态泛型，测试可替换 Transport 与 Clock，并比较相同事件序列的 Action、状态与账本。批次先提交 receive 再提交 send；部分发送只重发同一批尾部。原生完成先验证 socket context、代际、操作归属、提交长度，再独立核销每类操作；ConnectEx 的 IOCP key 也携带提交代际。

关闭 socket 只发起取消，保留未完成 provider 账本；全部相关 Completion 核销后才能发布 GenerationDrained。第一次 close 启动 QPC 5 秒排空期限，重复 stop 不延长。RIO 通知只核销真实 IOCP 投递，排空允许剩余一个空 arm；通知 OVERLAPPED 保持固定地址，直到 CQ 与 IOCP 均已关闭才释放。Coordinator 先 Join 全部 worker，再集中检查／快照／释放，显式 release 和聚合对象 deinit 内部均检查原生所有权；已启动 worker 还必须已 Join，原生存储的隐式析构必须先完成句柄关闭与 Buffer ID 注销。到期 timer 仲裁按实际取得的包依次处理：通知完成原有 64 批有界 CQ 服务后才取得下一个包，STOP 取得时立即开始关闭。`/i` 非零时持有 1 ms timer-resolution request 至 run 返回，失败具名为 `timeBeginPeriod(client pacing)` 并退出 4。开启 /report 时 worker 每 100 ms 经 Mutex 发布快照；停止控制使用 Atomic，业务配额与统计由 worker 独占。

错误保留 domain、classification、stage、原始 code、category、retryable；容量准备、连接失败、provider 不变量、排空超时维持独立边界。Native 的强制失败不能被静默全局状态替代。Span／MutableSpan 只在 owner 的同步闭包中借用，原生 provider 另由 completion 生命周期保障。物理 arena 的 TX／RX 分区遵循 Rust／Zig 的 Native 实现差异，仍映射 C++ 的每会话两个独立窗口。

测试驱动覆盖替换 Transport 的顺序记录、未完成 receive／ConnectEx 的真实 5 秒 loop、操作／代际／长度拒绝与正向对照、全 Join 屏障、never-started guard，以及用栈 arena 证明 guard 先于释放。正式 E0、热路径生成代码和性能基线须在统一门禁与冻结二进制清单后另行验收；功能通过不能代表性能零回退。

设置 `CEC_DIAG_FILE` 可在全部 worker Join 与释放检查后、销毁资源前，将通知计数写入指定文件。每个已启动 worker 一行，格式与 C++/Rust 一致：`role=client protocol=tcp|udp worker=N notify_arms=N notify_deliveries=N notify_gap=N timeout_wakeups_while_outstanding=N`。文件采用 UTF-8/ASCII 与 LF，最多 511 个 UTF-16 路径单元；正常残余 arm 的 gap 为 0 或 1。未设置变量或文件打开／写入失败不改变 stdout、stderr 与退出码。有限运行失败时，未认领额度同时加入最终 attempted 与 lost，使终态账本保持平衡。

运行目录须能找到构建工具链配套的 `swiftCore.dll`、`swiftWinSDK.dll`、`swiftSynchronization.dll`、`Foundation.dll`、`FoundationEssentials.dll` 及其传递依赖，同时具备 MSVC x64 运行库和 Windows UCRT。最直接的部署方式是安装匹配的 Swift 工具链并保留其运行库 PATH；单拷贝 exe 到没有运行库的机器不能运行。开发测试不需要额外服务，测试脚本使用 .NET 回环对端。

[工具链与 ABI 证据](docs/toolchain-interop.md)、[兼容差异与限制](docs/behavior-differences.md)、[性能测量](docs/performance.md)、[Swift 6.4 所有权与内存安全优化](docs/optimization.md)。

本轮正确性和性能修复的实现、验收及执行取舍见 [修复记录](docs/remediation.md)。
