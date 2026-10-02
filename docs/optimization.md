# Swift 6.4 客户端优化记录

## 后续修复轮次

本轮实现了独立 RIO 注册身份、worker 本地计数及 Mutex 快照、无限模式本地 claimed、事件协调器、缓存 session 范围/字段布局、方向性 timer sift、每 worker 共享只读发送区及倍增填充。配置通过 borrowing 参数传入函数后形成局部 Ref，避免从 UnsafePointer.pointee 的临时访问直接形成长寿命借用；生成代码结果以本轮统一验证为准。完成结果数组为 256 × 24 字节，即 6 KiB。

高吞吐下 CQ 可能持续非空，最终版在每批完成之间处理停止/fatal、期限和统计发布，继续遵守排空后 rearm。当前验收和修复前后测量见 [客户端修复验收](remediation.md)。

协调器共享控制封装是本轮新增的第二个已审查 @safe 边界：句柄由 Mutex 内唯一所有者持有，不通过公开接口接纳或导出，wait/signal 借用活的对象；其生命周期覆盖 worker join 与控制台回调注销。源码门禁仅允许 arena 与该控制类的确切声明，并拒绝在这两个文件中追加任意 @safe。没有关闭诊断或加入 unchecked Sendable。重复填充在存储所有者的同步借用中执行，源和目标指针不逃逸。

以下所有权及性能数字记录的是上一轮验收，不能当作本轮测量。测试用例和修复先全部编写，随后统一执行 Debug/Release 门禁、进程回归和优化 IR 检查；不以语言特性推断吞吐收益。

2026-10-02，Windows x64，Swift 6.4 RELEASE + assertions。命令行、共享额度、统计、RIO/ConnectEx/IOCP、原生线程、重连及停止排空语义保持一致。

## 所有权与生成代码

每个工作线程唯一持有 `CECWorkerConfiguration: ~Copyable`，配置通过 `consuming` 初始化转移给固定地址的 worker。七处原先复制配置的访问改为同步 `borrowing` 回调；热路径使用局部 `Ref`，统计函数接收借用参数，pattern/control 使用 `borrow` accessor。

初版局部借用消除了函数体直接的 retain/release，却在调用处生成配置复制 value witness，仍有间接 ARC。第一次长时测量暴露了回退；随后配置改为不可复制，并扩展 IR 门禁，拒绝这种复制。编译反例同时验证配置显式复制被拒绝。

最终优化 IR 中，beginAttempt、completeAttempt、cecProcessRIOResult、cecPostSend 的所有生成函数体均无直接 retain/release；原生 cecWorkerThread 的静态 ARC 调用位置从 14 降为 0，模块没有配置复制 value-witness 调用。Release 验证脚本自动检查函数体及原生调用者。这是生成代码证据，不能换算为吞吐提升比例。

IR 仍有 288 字节的非拥有配置临时 memcpy；消除所有权复制及 ARC，并不等于消除全部字节复制。这些临时复制对性能的贡献没有单独测量。

配置成员上的嵌套 Ref 曾触发本机编译器断言；直接借用配置参数中的 metrics，并保留局部配置 Ref，可稳定编译。没有关闭所有权、寿命或 exclusivity 检查。

## 初始化与有界内存

UniqueArray 的 OutputSpan 初始化器逐个写入实际负载字节；UTF-16 文本仍由 Windows WideCharToMultiByte 严格转换，直接写入未初始化输出，只有成功写入的前缀计入 initializedCount，随后检查完整长度。取消先填零再覆写，保留内嵌 NUL、非法代理项拒绝及既有计数格式。

可打印计数的 8 个除数、报告的 64 个延迟桶快照采用 InlineArray，避免对应动态数组分配。原子读取顺序、ordering、整数语义和 POSIX 输出格式保持一致。

arena 所有者记录实际分配长度，提供同步 Span/MutableSpan 回调。会话偏移乘加、负数、单块容量和总范围均检查；回调结果必须可逃逸，因此不能返回 Span。借用期间不能 reset/mutate 所有者，编译反例验证此限制。双方长度一致且完成已排空后，才在有界适配器内调用原生 memcmp。

Windows 异步保存的地址仍由固定存储和注册 arena 持有。关闭 socket 后先排空完成及通知，join 后释放 CQ、注册、arena 和上下文；UniqueBox 和临时分配没有替代这些存储。

## 严格内存安全与 ABI

核心和正式 executable target 的 Package.swift 均启用 `.strictMemorySafety()` 与 `.treatWarning("StrictMemorySafety", as: .error)`；普通 Debug/Release 构建即执行检查，不使用 unsafeFlags。原生记录声明为 @unsafe，指针、分配、Windows/RIO 操作逐处标记 unsafe；文件说明对应寿命、范围、初始化和线程归属条件。

唯一的 @safe 存储适配是 arena 所有者：范围与借用回调接口有界，原生指针接纳、释放和导出仍是 unsafe 签名。源码策略阻止额外 @safe 声明。诊断收口不证明 Windows 异步寿命；已有 unsafe 边界内部仍须人工审查。

线程入口采用已通过 Windows ABI 和实际线程测试的 @c DWORD/raw-pointer 签名。控制台回调保留 SDK 的 WindowsBool 签名，没有为采用新语法引入额外桥接。

## 验证与复现

```powershell
pwsh -NoProfile -File build_debug.ps1
pwsh -NoProfile -File build_release.ps1
pwsh -NoProfile -File Tests/cec_standalone_check.ps1 -Configuration release
```

单元测试现为 22 个测试、11 个 suite；新增初始化边界及 arena 溢出、越界、空视图和保护字节用例。验证另含 8 个所有权编译用例、6 个内存安全编译用例及原有的原生故障、TCP/UDP、多线程、重连、宽字符参数、周期统计和真实 Ctrl+Break。测试驱动、反例和测量脚本均位于 Tests；正式 Sources 没有测试文件。单元测试继续使用 native 后端以确保执行真实测试，生产构建使用默认后端。

安全用例覆盖已审查指针读取、有界 arena 读取、未标注指针读取/存储、Span 逃逸和借用时销毁 arena；门禁要求预期诊断，其他编译错误不能冒充拒绝。

独立审阅后的门禁回归测试另外验证：反例文件名带 Escape 但诊断无关时必须拒绝，同一所有者文件中加入额外 @safe 声明时也必须拒绝。诊断匹配只读取 error 消息，源码策略同时核对 @safe 总数和唯一许可声明。

长时测量使用 Tests/cec_optimization_perf.ps1；优化前 exe 保留在 .build/optimization/swift-echo-client-before.exe。每种协议各 3 轮、每样本 5 秒，预热后按 AB/BA/AB 交替；1024 字节、4 会话、1 工作线程，TCP 深度 8，同一原生 RIO 服务端。测量期间不并行构建，CPU 按完成一百万次逻辑 echo 归一化，包含启动/退出成本。

完整样本和双方 exe、服务端 SHA256：[optimization-performance-2026-10-02.json](optimization-performance-2026-10-02.json)。部署环境应另行复测。

最终 12 个样本全部 corrupted/lost/network_errors=0。每组 3 个样本的中位数如下：

| 协议 | 优化前 echo/s | 优化后 echo/s | 优化前 CPU ms / 百万 echo | 优化后 CPU ms / 百万 echo |
|---|---:|---:|---:|---:|
| TCP | 1,348,291.87 | 1,331,711.32 | 621.66 | 656.49 |
| UDP | 274,270.93 | 262,238.68 | 2,873.45 | 2,999.93 |

本组回环测量没有显示吞吐或 CPU 改进：TCP/UDP 吞吐中位数分别下降约 1.2%/4.4%，归一化 CPU 分别增加约 5.6%/4.4%。三个样本不能确定长期差异或将差异归因于某个特性。当前可确认的收益是消除上述 ARC、减少初始化重复写入、固定大小统计快照不再动态分配，以及可检查的内存边界；不能宣传已经提高实测吞吐。

语言依据：[SE-0519 Ref](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0519-ref-mutableref-types.md)、[SE-0458 Strict Memory Safety](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md)。本地编译和运行结果是本项目的兼容性验收依据。
