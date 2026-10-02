# swift-echo-client

Swift 6.4 重写的 Windows x64 RIO Echo 压测客户端。参数、TCP/UDP 回显字节、工作线程划分、有限次数认领、停止排空、退出码和统计沿用 C++ 客户端。默认负载仍为 `C++ echo from <host>`。

## 构建与运行

要求 Windows 10 或更新版本、Swift 6.4 Windows 工具链及配套 Windows SDK、PowerShell 7。无第三方 Swift 包，不依赖相邻客户端或服务端源码。工具链及运行库须在 PATH 中。

```powershell
swift build -c release --product swift-echo-client
$bin = swift build -c release --show-bin-path
& "$bin/swift-echo-client.exe" 127.0.0.1 /p tcp /r 7001 /n 37 /k 8 /z 4096 /c 8 /threads 3 /q /stats
& "$bin/swift-echo-client.exe" 127.0.0.1 /p udp /r 7001 /n 5 /z 65507 /stats
& "$bin/swift-echo-client.exe" /h
```

完整验证使用 `pwsh -NoProfile -File build_debug.ps1` 或 `build_release.ps1`：构建、Swift Testing、所有权编译正反例、源码策略、原生失败边界、TCP/UDP 进程测试、多线程、重连、周期统计、宽字符参数和真实 Ctrl+Break 停止。所有客户端子进程有超时，对端在 finally 中清理。

当前 Swift 6.4 Windows 默认构建后端的 Release 测试运行器会遗漏测试 DLL，导致发现零个测试。验证脚本仅在单元测试阶段显式采用 `swift test -c release --build-system native`（Debug 同样采用 native），核心模块与测试均按对应配置编译；正式客户端构建仍使用默认后端。脚本拒绝零测试结果，具体证据见工具链文档。

```powershell
pwsh -NoProfile -File tests/cec_standalone_check.ps1 -Configuration release
```

该命令将包复制到独立目录，排除原构建缓存，再运行同一完整验证。`swift-echo-client-fault-driver.exe` 是测试工具，源码和故障场景位于 `Tests/CECFaultDriver` 的独立 executable target；它依赖生产核心，正式客户端不依赖它。上面的 `--product swift-echo-client` 仅构建正式产品；完整验证脚本另行构建测试驱动。

## 参数与结果

| 参数 | 默认值 / 语义 |
|---|---|
| target、`/p tcp\|udp` | 必填；IPv4 解析 |
| `/r`、`/l` | 远端端口 7，本地端口 0；固定本地端口要求 `/c 1` |
| `/n` | 5；0 为不限次数；由所有工作线程共享额度 |
| `/t`、`/i` | 每批超时 5 秒；批间间隔 0 毫秒 |
| `/d`、`/z`、`/zt` | 字面文本、二进制计数、可打印计数；互斥 |
| `/k` | TCP 批次深度 1；最终批次可少于深度 |
| `/c`、`/threads` | 1 会话；默认线程数为 CPU 数（最多 32）与会话数的较小值 |
| `/w` | 默认不设时限；指定后到期受控停止 |
| `/rc [seconds]` | 默认不重连；省略秒数为 1，允许 0；TCP 固定本地端口不允许重连 |
| `/report`、`/b` | 默认不周期输出；socket buffer 采用系统默认 |
| `/cq`、`/memory` | 每线程 CQ 容量 4096；实际发送/接收存储总限额 1073741824 字节 |
| `/q`、`/stats` | quiet 抑制最终输出，stats 强制最终输出；report 独立生效 |

退出码：0 成功（含无既有错误的受控停止）、1 参数/负载无效、2 网络准备失败或无成功回显且没有回显损失、3 损坏或丢失、4 内部错误。`/n` 不隐含时限，持续重连可一直运行，应按需要显式设置 `/w`。

UDP 单包最多 65507 字节，TCP 单批最多 64 MiB。每线程 arena 不超过 DWORD.max，CQ 至少容纳本线程会话数的两倍。每 worker 只存一份只读发送批次，各会话接收区独立；每会话收发分别持有不同 RIO 注册 ID。存储预算为 `(会话数 + 实际 worker 数) × 最大批次字节数`，不包含注册元数据或运行库开销。延迟直方图按批次采样，`p50_us~` 等为对数桶下界，非单个逻辑 echo 的精确延迟；包含完成处理与字节校验成本。完成数组 `InlineArray<256, RIORESULT>` 占 6 KiB。

## 实现与部署

核心位于 `Sources/CECClientCore`；两个入口共享同一实现。原生资源使用 `~Copyable` 所有者、UniqueArray 及 borrow/mutate 访问器；负载视图使用 Span/MutableSpan，完成结果使用 InlineArray。停止标志和有限额度使用 Synchronization.Atomic；完成统计由 worker 独占写入，开启 /report 时每 100 ms 通过 Mutex 发布快照，最终 join 后精确汇总。每个 Windows 工作线程独占会话、CQ、IOCP、注册 arena 与索引堆。停止先关闭 socket，再排空完成、完成通知握手、join，最后释放资源。全程保持 Swift 6 并发与所有权检查。

运行目录须能找到 Swift 6.4 的 `swiftCore.dll`、`swiftWinSDK.dll`、`swiftSynchronization.dll`、`Foundation.dll`、`FoundationEssentials.dll` 及其传递依赖，同时具备 MSVC x64 运行库和 Windows UCRT。最直接的部署方式是安装匹配的 Swift 工具链并保留其运行库 PATH；单拷贝 exe 到没有运行库的机器不能运行。开发测试不需要额外服务，测试脚本使用 .NET 回环对端。

[工具链与 ABI 证据](docs/toolchain-interop.md)、[兼容差异与限制](docs/behavior-differences.md)、[性能测量](docs/performance.md)、[Swift 6.4 所有权与内存安全优化](docs/optimization.md)。

本轮正确性和性能修复的实现、验收及执行取舍见 [修复记录](docs/remediation.md)。
