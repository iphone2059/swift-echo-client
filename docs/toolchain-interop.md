# Swift 6.4 Windows 互操作证据

后续所有权优化已验证不可复制配置的 consuming 转移、同步 borrowing/Ref、UniqueArray 的 OutputSpan 初始化、正式 SwiftPM strictMemorySafety 设置以及 @c 原生线程入口。新增后完整单元验证为 22 tests in 11 suites；详见 [优化记录](optimization.md)。

2026-10-02，x86_64-unknown-windows-msvc，Swift 6.4 RELEASE，Swift Testing 6.4。

初始能力测试在核心模块不存在时失败；建立 CECClientCore 后，CECOwnershipFeatureTests 两个用例通过。UniqueArray 支持 noncopyable 元素及 append/subscript；UniqueBox.value 支持借用；borrow/mutate 真实成员访问器、InlineArray.span、InlineArray<256,RIORESULT> 和 Synchronization.Atomic.wrappingAdd 均编译运行成功。

SOCKET、HANDLE、UInt 和指针为 8 字节，WCHAR 为 2 字节。WinSDK 导入 RIO_BUF、RIORESULT、RIO_NOTIFICATION_COMPLETION、RIO_EXTENSION_FUNCTION_TABLE、LPFN_CONNECTEX。SDK 的预编译模块首次导入出现 wchar_t 模块恢复警告，编译器自动恢复后通过；目前无需 C 桥接。

FeaturesPositive.swift 独立编译成功；FeaturesCopyRejected.swift 编译返回 1，诊断为 value consumed more than once。Windows 异步上下文采用明确分配的固定存储所有者，不将 UniqueBox.value 的临时取址作用域外逃逸。

正式 socket 集合通过 borrow/mutate 访问器暴露真实 UniqueArray 存储；pattern 唯一存储通过 borrow 访问器访问。元数据保留原生分配地址，worker 线程唯一修改会话和堆，协调器仅投递停止并在 join 后销毁。RIO 注册、CQ 所有者内保存函数表值副本。

WinSDK 未导入两个 SIO_GET_* 宏，采用与 SDK 展开式一致的 DWORD 0xC8000024（RIO）及 0xC8000006（ConnectEx）；GUID、结构及函数 ABI 均直接使用 WinSDK。Windows 宽 argv 使用 ucrt._configure_wide_argv、__p___argc 和 __p___wargv；中文、emoji、引号、尾反斜线及原始非法代理项已通过实际进程测试，无 C 桥接。

观察到 Swift 6.4 MoveOnlyChecker 对“先声明、后初始化的不可复制 let 被 defer 捕获”产生编译器断言。以直接 let 初始化和 borrowing keepAlive 保持寿命后编译通过；未禁用任何检查。类中 UniqueArray.span 跨属性借用作用域会被寿命检查拒绝，填充改用同步索引借用；公共填充函数仍使用有界 Span/MutableSpan 并经字节测试验证。

Windows 句柄和 arena、固定上下文分配由可失败原生 API 处理。UniqueArray 和 Swift 对象的分配没有标准库可恢复 OOM 接口；该差异详见 behavior-differences.md。独立副本的 SwiftPM package identity 随目录名变化，所有权编译脚本按目录计算规范身份，避免硬编码只在原目录可见的 package 接口。

Release PE 导入表经 llvm-readobj --coff-imports 检查：WS2_32、KERNEL32、swiftCore、swiftWinSDK、swiftSynchronization、Foundation、FoundationEssentials、VCRUNTIME140 和 UCRT。安装环境的 Swift 动态运行库目录为 Runtimes/6.4.0/usr/bin（含传递依赖 dispatch、BlocksRuntime、ICU 等）；测试库独立位于工具链 SDK 的 Testing 目录，仅测试时使用。

最终审阅发现默认 Swift Build 后端的 Release 单元测试返回 0，但 Swift Testing 实际报告 0 tests in 0 suites。`--disable-dead-strip` 仍为零；`llvm-readobj --coff-imports` 确认 Debug runner 导入 swift_echo_clientTests.dll，Release runner 未导入，而 Release DLL 的 .sw5test section 仍保留测试记录。生成的入口调用一个空的 public test anchor；优化导致 DLL 引用消失是据此作出的推断，未修改工具链生成代码。

单元测试改用工具链支持的 `--build-system native`，直接链接测试对象，实际 Release 运行 19 tests in 10 suites。该选项在本工具链帮助中标为 deprecated，未来升级时应复查默认后端；生产构建继续使用 Swift Build。后端选择是 [SwiftPM 官方命令行支持的路径](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftBuildPreview.md)。build.ps1 同时检查退出码和非零 Swift Testing 成功汇总；零测试原日志触发 exit 1 的验证失败。此前仅凭退出码记录的 Release 单元测试成功不成立，已由本次完整复验取代。
