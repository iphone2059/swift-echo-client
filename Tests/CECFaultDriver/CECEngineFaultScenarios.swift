import CECClientCore
import Foundation
import Synchronization
// Test-only adapter: the real provider dequeues every record. Withholding one
// cancelled record leaves the production software ledger genuinely undrained.
import WinSDK

/// Fault driver exercises the real initializer and stop/join path, without client CLI modes.

// Drive the real runtime/IOCP loop with a completion withheld from its provider
// ledger. Closing the socket must retain that ownership until the 5s deadline.

private nonisolated(unsafe) var e2eRealDequeue: LPFN_RIODEQUEUECOMPLETION?
private struct E2ECancelTrace: Sendable {
  var hide = false
  var cancelled = 0
  var withheld = 0
}
private let e2eCancelTrace = Mutex(E2ECancelTrace())
@c private func e2eStopWorker(_ parameter: UnsafeMutableRawPointer?) -> DWORD {
  let worker = parameter!.assumingMemoryBound(to: CECEngineWorker.self)
  Sleep(1000)
  worker.pointee.configuration.control.stopRequested.store(true, ordering: .releasing)
  cecPostWorkerStop(worker)
  return 0
}
func cecExerciseRealCancelledCompletion(port: UInt16, hide: Bool) {
  do {
    let winsock = try CECWinSockOwner()
    var extensions = try cecLoadExtensions()
    e2eRealDequeue = extensions.rio.RIODequeueCompletion
    e2eCancelTrace.withLock { $0 = E2ECancelTrace(hide: hide) }
    extensions.rio.RIODequeueCompletion = { queue, results, capacity in
      let count = e2eRealDequeue!(queue, results, capacity)
      if count == UInt32.max || count > capacity { return count }
      var written: UInt32 = 0
      for index in 0..<Int(count) {
        let result = results![index]
        let omit = e2eCancelTrace.withLock { trace in
          // Closing a socket aborts a pending RIO operation with ERROR_OPERATION_ABORTED
          // or, once the TCP connection is aborted as well, WSAECONNABORTED. Both are the
          // real provider completion this scenario withholds; production retires either.
          if result.Status == 995 || result.Status == 10053 {
            trace.cancelled += 1
            if trace.hide && trace.withheld == 0 {
              trace.withheld = 1
              FileHandle.standardError.write(
                Data("e2e observed_cancelled_completion=995 withheld=1\n".utf8))
              return true
            }
          }
          return false
        }
        if !omit {
          results![Int(written)] = result
          written += 1
        }
      }
      return written
    }
    var options = CECOptions()
    options.transport = .tcp
    options.echoCount = 0
    options.timeoutSeconds = 30
    options.patternKind = .binaryCounter
    options.patternBytes = 4096
    options.cqCapacity = 64
    let control = CECSharedControl()
    guard control.prepareWake() == 0 else { cecFailFast(stage: "e2e coordinator event", error: 8) }
    let remote = try cecResolveIPv4(hostUTF16: Array("127.0.0.1".utf16), port: port)
    let owner = try CECWorkerOwner(
      preparedConfiguration: CECWorkerConfiguration(
        options: options, remoteAddress: remote, extensions: extensions, pattern: nil,
        maximumAttemptBytes: 4096, control: control, workerIndex: 0, sessionCount: 1,
        memoryShare: 8192, payloadBytes: 4096))
    guard cecInitializeWorker(owner.baseAddress) else {
      cecFailFast(stage: "e2e worker initialization", error: 13)
    }
    let stopper = CECHandleOwner(CreateThread(nil, 0, e2eStopWorker, owner.baseAddress, 0, nil))
    guard stopper.rawValue != nil else { cecFailFast(stage: "e2e stopper thread", error: 8) }
    cecJoinWorker(owner.baseAddress)
    guard WaitForSingleObject(stopper.rawValue, 3000) == WAIT_OBJECT_0 else {
      cecFailFast(stage: "e2e stopper join", error: 1460)
    }
    let trace = e2eCancelTrace.withLock { $0 }
    guard trace.cancelled > 0, !hide, trace.withheld == 0 else {
      cecFailFast(stage: "e2e cancellation evidence", error: 13)
    }
    cecRequireWorkerRelease(owner.baseAddress)
    cecDestroyWorker(owner.baseAddress)
    winsock.keepAlive()
    print("e2e cancelled_completions=\(trace.cancelled) withheld=\(trace.withheld)")
  } catch {
    cecFailFast(stage: "e2e cancellation setup", error: 13)
  }
}
func cecExerciseInvalidCompletionContext(identity: Bool) {
  var bytes = UniqueArray<UInt8>()
  bytes.append(0)
  let owner = CECWorkerOwner(
    configuration: CECWorkerConfiguration(
      options: CECOptions(), remoteAddress: SOCKADDR_IN(),
      extensions: CECNativeExtensions(rio: RIO_EXTENSION_FUNCTION_TABLE(), connectEx: nil),
      pattern: CECPatternStorage(consume bytes), maximumAttemptBytes: 1,
      metrics: CECEngineMetrics(), control: CECSharedControl(), workerIndex: 0,
      sessionCount: 1, memoryShare: 2))
  let w = owner.baseAddress
  guard let storage = CECPinnedStorage(count: 1, initialValue: CECEngineSession()) else {
    cecFailFast(stage: "completion test allocation", error: 8)
  }
  let first = UInt(bitPattern: storage.baseAddress)
  w.pointee.sessionAddress = storage.baseAddress
  w.pointee.resources.sessions = consume storage
  w.pointee.sessionRange = first..<(first + UInt(MemoryLayout<CECEngineSession>.stride))
  w.pointee.sessionAddress!.pointee.owner = w
  var result = RIORESULT()
  result.RequestContext =
    identity ? 1 : CECRioContext.encode(index: 1, generation: 0, operation: .receive)
  result.SocketContext = UInt64(first)
  cecProcessRIOResult(w, result: result)
  cecFailFast(stage: "invalid completion was accepted", error: 13)
}
func cecExerciseShutdownStopRace() {
  var bytes = UniqueArray<UInt8>()
  bytes.append(0)
  let owner = CECWorkerOwner(
    configuration: CECWorkerConfiguration(
      options: CECOptions(), remoteAddress: SOCKADDR_IN(),
      extensions: CECNativeExtensions(rio: RIO_EXTENSION_FUNCTION_TABLE(), connectEx: nil),
      pattern: CECPatternStorage(consume bytes), maximumAttemptBytes: 1,
      metrics: CECEngineMetrics(), control: CECSharedControl(), workerIndex: 0, sessionCount: 0,
      memoryShare: 0))
  let w = owner.baseAddress
  w.pointee.resources.port.reset(CreateIoCompletionPort(HANDLE(bitPattern: -1), nil, 0, 1))
  guard let storage = CECPinnedStorage(count: 1, initialValue: OVERLAPPED()) else {
    cecFailFast(stage: "race test allocation", error: 8)
  }
  w.pointee.notificationAddress = storage.baseAddress
  w.pointee.resources.notification = consume storage
  w.pointee.notificationArmed = true
  w.pointee.transport.notifyArms = 1
  cecPostWorkerStop(w)
  cecShutdownNotification(w)
}
func cecExercisePartialStartupFailure(port: UInt16) -> CECExitCode {
  do {
    let winsock = try CECWinSockOwner()
    let ext = try cecLoadExtensions()
    let remote = try cecResolveIPv4(hostUTF16: Array("127.0.0.1".utf16), port: port)
    var o = CECOptions()
    o.transport = .tcp
    o.echoCount = 0
    o.reportSeconds = 1
    o.timeoutSeconds = 30
    o.cqCapacity = 64
    o.patternKind = .binaryCounter
    o.patternBytes = 4096
    let pattern = CECPatternStorage(try cecBuildPattern(options: o))
    let metrics = CECEngineMetrics()
    let control = CECSharedControl()
    let first = CECWorkerOwner(
      configuration: CECWorkerConfiguration(
        options: o, remoteAddress: remote, extensions: ext, pattern: pattern,
        maximumAttemptBytes: 4096, metrics: metrics, control: control, workerIndex: 0,
        sessionCount: 1, memoryShare: 1_048_576))
    guard cecInitializeWorker(first.baseAddress) else { return .network }
    let deadline = GetTickCount64() + 5000
    while first.baseAddress.pointee.publication.read().claimed < 2 && GetTickCount64() < deadline {
      Sleep(1)
    }
    guard first.baseAddress.pointee.publication.read().claimed >= 2 else {
      cecFailFast(stage: "partial startup peer did not echo", error: 1460)
    }
    let second = CECWorkerOwner(
      configuration: CECWorkerConfiguration(
        options: o, remoteAddress: remote, extensions: ext, pattern: pattern,
        maximumAttemptBytes: 4096, metrics: metrics, control: control, workerIndex: 1,
        sessionCount: 33, memoryShare: 1_048_576))
    if cecInitializeWorker(second.baseAddress) {
      cecFailFast(stage: "partial startup failure did not occur", error: 13)
    }
    control.fatal.store(true, ordering: .releasing)
    cecPostWorkerStop(first.baseAddress)
    guard
      WaitForSingleObject(first.baseAddress.pointee.resources.thread.rawValue, 5000)
        == WAIT_OBJECT_0
    else { cecFailFast(stage: "partial startup drain timeout", error: 1460) }
    var workers: InlineArray<2, UnsafeMutablePointer<CECEngineWorker>?> = [
      first.baseAddress, second.baseAddress,
    ]
    workers.span.withUnsafeBufferPointer { cecJoinAndCheckWorkers($0) }
    cecDestroyWorker(first.baseAddress)
    cecDestroyWorker(second.baseAddress)
    winsock.keepAlive()
    print("partial startup drained")
    return .internalFailure
  } catch let error as CECNativeError {
    cecReport(stage: error.stage, error: error.code)
    return .network
  } catch {
    cecReport(stage: "payload pattern", error: 13)
    return .usage
  }
}
func cecExerciseArenaCapacity() -> CECExitCode {
  var bytes = UniqueArray<UInt8>()
  bytes.append(0)
  var o = CECOptions()
  o.transport = .tcp
  let owner = CECWorkerOwner(
    configuration: CECWorkerConfiguration(
      options: o, remoteAddress: SOCKADDR_IN(),
      extensions: CECNativeExtensions(rio: RIO_EXTENSION_FUNCTION_TABLE(), connectEx: nil),
      pattern: CECPatternStorage(consume bytes), maximumAttemptBytes: 67_108_864,
      metrics: CECEngineMetrics(), control: CECSharedControl(), workerIndex: 0, sessionCount: 63,
      memoryShare: UInt64.max))
  if cecInitializeWorker(owner.baseAddress) {
    cecFailFast(stage: "arena DWORD guard did not reject", error: 13)
  }
  return .internalFailure
}
private func faultConfiguration(
  sessionCount: UInt32 = 1, maximumAttemptBytes: Int = 1,
  extensions: CECNativeExtensions = CECNativeExtensions(rio: RIO_EXTENSION_FUNCTION_TABLE())
) -> CECWorkerConfiguration {
  var bytes = UniqueArray<UInt8>()
  bytes.append(42)
  var options = CECOptions()
  options.transport = .tcp
  options.echoCount = 1
  return CECWorkerConfiguration(
    options: options,
    remoteAddress: SOCKADDR_IN(),
    extensions: extensions,
    pattern: CECPatternStorage(consume bytes), maximumAttemptBytes: maximumAttemptBytes,
    metrics: CECEngineMetrics(), control: CECSharedControl(), workerIndex: 0,
    sessionCount: sessionCount, memoryShare: UInt64(sessionCount) * 2)
}
private func faultOwner(
  sessionCount: UInt32 = 1, maximumAttemptBytes: Int = 1,
  extensions: CECNativeExtensions = CECNativeExtensions(rio: RIO_EXTENSION_FUNCTION_TABLE())
) -> CECWorkerOwner {
  CECWorkerOwner(
    configuration: faultConfiguration(
      sessionCount: sessionCount, maximumAttemptBytes: maximumAttemptBytes,
      extensions: extensions))
}
func cecExerciseMissingCompletion(positive: Bool, connect: Bool) {
  // The withheld completion must be resolved by the production drain path, so this
  // fixture needs the real RIO table and a real completion queue. A fabricated
  // worker without them would trap inside RIODequeueCompletion instead of reaching
  // the named five-second drain boundary.
  guard let winsock = try? CECWinSockOwner(), let extensions = try? cecLoadExtensions() else {
    cecFailFast(stage: "missing completion native setup", error: 8)
  }
  let owner = faultOwner(extensions: extensions)
  let worker = owner.baseAddress
  guard let sessions = CECPinnedStorage(count: 1, initialValue: CECEngineSession()),
    let notification = CECPinnedStorage(count: 1, initialValue: OVERLAPPED()),
    QueryPerformanceFrequency(&worker.pointee.performanceFrequency)
  else { cecFailFast(stage: "missing completion setup", error: 8) }
  worker.pointee.resources.port.reset(CreateIoCompletionPort(HANDLE(bitPattern: -1), nil, 0, 1))
  guard worker.pointee.resources.port.rawValue != nil else {
    cecFailFast(stage: "missing completion IOCP", error: 8)
  }
  worker.pointee.sessionAddress = sessions.baseAddress
  worker.pointee.notificationAddress = notification.baseAddress
  worker.pointee.resources.sessions = consume sessions
  worker.pointee.resources.notification = consume notification
  let first = UInt(bitPattern: worker.pointee.sessionAddress)
  worker.pointee.sessionRange = first..<(first + UInt(MemoryLayout<CECEngineSession>.stride))
  var notificationRecord = unsafe RIO_NOTIFICATION_COMPLETION()
  unsafe notificationRecord.Type = RIO_IOCP_COMPLETION
  unsafe notificationRecord.Iocp.IocpHandle = worker.pointee.resources.port.rawValue
  unsafe notificationRecord.Iocp.CompletionKey = UnsafeMutableRawPointer(worker)
  unsafe notificationRecord.Iocp.Overlapped = UnsafeMutableRawPointer(
    worker.pointee.notificationAddress!)
  guard
    let queue = unsafe extensions.rio.RIOCreateCompletionQueue!(
      worker.pointee.configuration.options.cqCapacity, &notificationRecord)
  else { cecFailFast(stage: "missing completion CQ", error: 8) }
  unsafe worker.pointee.resources.completionQueue.reset(rio: extensions.rio, value: queue)
  do {
    worker.pointee.core = try CECWorkerCore(
      options: worker.pointee.configuration.options,
      sessionCount: 1, payloadBytes: 1,
      frequency: UInt64(worker.pointee.performanceFrequency.QuadPart))
  } catch { cecFailFast(stage: "missing completion Core", error: 8) }
  let slot = worker.pointee.sessionAddress!
  slot.pointee.owner = worker
  slot.pointee.generation = 1
  slot.pointee.connectOutstanding = connect
  slot.pointee.receiveOutstanding = !connect
  slot.pointee.receivePostedBytes = 1
  worker.pointee.transport.totalOutstanding = 1
  worker.pointee.transport.rioOutstanding = connect ? 0 : 1
  worker.pointee.transport.notificationArmed = !connect
  worker.pointee.transport.notifyArms = connect ? 0 : 1
  _ = worker.pointee.core.start(now: 0)
  cecStopWorker(worker)
  if positive {
    if connect {
      withUnsafeMutablePointer(to: &worker.pointee.transport) { native in
        withUnsafePointer(to: worker.pointee.configuration) { configuration in
          var adapter = CECRioAdapter(
            native: native, configuration: configuration,
            ownerKey: UInt(bitPattern: worker),
            clock: CECNativeClock(frequency: UInt64(worker.pointee.performanceFrequency.QuadPart)))
          guard let completion = adapter.retireConnect(slot, ok: false, error: 995, bytes: 0) else {
            cecFailFast(stage: "positive completion drain", error: 13)
          }
          _ = worker.pointee.core.onEvent(.generationDrained(completion.index), now: 1)
        }
      }
    } else {
      var result = RIORESULT()
      result.Status = 995
      result.SocketContext = UInt64(UInt(bitPattern: slot))
      result.RequestContext = CECRioContext.encode(index: 0, generation: 1, operation: .receive)
      cecProcessRIOResult(worker, result: result)
    }
    guard worker.pointee.transport.totalOutstanding == 0, worker.pointee.liveSessions == 0 else {
      cecFailFast(stage: "positive completion ledger", error: 13)
    }
  }
  _ = cecWorkerThread(UnsafeMutableRawPointer(worker))
  print("completion drained positive")
  winsock.keepAlive()
}
func cecExerciseReleaseBoundary(positive: Bool, stackOrder: Bool) {
  let owner = faultOwner()
  let worker = owner.baseAddress
  if positive {
    cecDestroyWorker(worker)
    cecDestroyWorker(worker)
    print("worker release positive")
    return
  }
  // A stack address cannot be VirtualFree'd. The named ownership guard must
  // therefore run before arena release; reversing it changes the diagnostic.
  var stackByte: UInt8 = 42
  withUnsafeMutablePointer(to: &stackByte) { address in
    if stackOrder {
      worker.pointee.resources.arena.reset(UnsafeMutableRawPointer(address), byteCount: 1)
    }
    worker.pointee.transport.totalOutstanding = 1
    cecDestroyWorker(worker)
  }
}
func cecExerciseOperationFault(mode: String) {
  let sendExtent = mode == "send_offset_underflow" || mode == "send_extent_positive"
  let owner = faultOwner(maximumAttemptBytes: sendExtent ? 2 : 1)
  let worker = owner.baseAddress
  guard let storage = CECPinnedStorage(count: 1, initialValue: CECEngineSession()) else {
    cecFailFast(stage: "operation fault setup", error: 8)
  }
  worker.pointee.sessionAddress = storage.baseAddress
  worker.pointee.resources.sessions = consume storage
  do {
    worker.pointee.core = try CECWorkerCore(
      options: worker.pointee.configuration.options, sessionCount: 1, payloadBytes: 1,
      frequency: 1000)
  } catch { cecFailFast(stage: "operation fault Core", error: 8) }
  worker.pointee.core.sessions[0].state = .closing
  let slot = worker.pointee.sessionAddress!
  slot.pointee.closing = true
  slot.pointee.generation = 1
  slot.pointee.receiveOutstanding = true
  slot.pointee.receivePostedBytes = 1
  if sendExtent {
    slot.pointee.receiveOutstanding = false
    slot.pointee.sendOutstanding = true
    slot.pointee.sendPostedBytes = 2
    slot.pointee.sendOffset = mode == "send_offset_underflow" ? Int.min : 1
  } else if mode == "duplicate_operation" {
    // Ownership must be checked before this corrupt unused direction's
    // subtraction, so its named duplicate diagnostic cannot become a trap.
    slot.pointee.sendOffset = Int.min
  }
  worker.pointee.transport.totalOutstanding = 1
  worker.pointee.transport.rioOutstanding = 1
  var result = RIORESULT()
  result.SocketContext = UInt64(UInt(bitPattern: slot))
  result.RequestContext = CECRioContext.encode(
    index: 0, generation: mode == "stale_generation" ? 2 : 1,
    operation: mode == "duplicate_operation" || sendExtent ? .send : .receive)
  result.BytesTransferred = mode == "posted_extent" ? 2 : 1
  if mode == "socket_identity" { result.SocketContext = 1 }
  cecProcessRIOResult(worker, result: result)
  if mode == "operation_positive" || mode == "send_extent_positive" {
    guard worker.pointee.transport.totalOutstanding == 0, worker.pointee.liveSessions == 0 else {
      cecFailFast(stage: "operation positive ledger", error: 13)
    }
    print("operation ledger positive")
    return
  }
  cecFailFast(stage: "operation fault accepted", error: 13)
}
@c private func joinedFaultWorker(_ parameter: UnsafeMutableRawPointer?) -> DWORD {
  let worker = parameter!.assumingMemoryBound(to: CECEngineWorker.self)
  Sleep(50)
  worker.pointee.phase = .stopped
  FileHandle.standardOutput.write(
    Data("join marker worker=\(worker.pointee.configuration.workerIndex)\n".utf8))
  return 0
}
func cecExerciseJoinBarrier(positive: Bool) {
  let first = faultOwner(sessionCount: 0)
  let second = faultOwner(sessionCount: 0)
  for worker in [first.baseAddress, second.baseAddress] {
    worker.pointee.started = true
    worker.pointee.resources.thread.reset(CreateThread(nil, 0, joinedFaultWorker, worker, 0, nil))
    guard worker.pointee.resources.thread.rawValue != nil else {
      cecFailFast(stage: "join barrier setup", error: 8)
    }
  }
  if !positive { first.baseAddress.pointee.transport.totalOutstanding = 1 }
  let workers: InlineArray<2, UnsafeMutablePointer<CECEngineWorker>?> = [
    first.baseAddress, second.baseAddress,
  ]
  workers.span.withUnsafeBufferPointer { cecJoinAndCheckWorkers($0) }
  print("join barrier positive workers=2")
}
func cecExerciseSlotOwnership() {
  let owner = faultOwner()
  let worker = owner.baseAddress
  guard let storage = CECPinnedStorage(count: 1, initialValue: CECEngineSession()) else {
    cecFailFast(stage: "slot ownership setup", error: 8)
  }
  worker.pointee.sessionAddress = storage.baseAddress
  worker.pointee.resources.sessions = consume storage
  worker.pointee.sessionAddress!.pointee.receiveOutstanding = true
  // Aggregate counters are deliberately zero: slot evidence alone must reject release.
  cecDestroyWorker(worker)
}
private func consumeDirectWorker(_ worker: consuming CECEngineWorker) {}
private func consumeDirectTransport(_ transport: consuming CECRioTransport) {}
private func consumeDirectResources(_ resources: consuming CECEngineWorkerResources) {}
func cecExerciseAggregateDeinit(mode: String) {
  if mode == "aggregate_deinit_positive" {
    for kind in 0..<3 {
      guard
        let memory = VirtualAlloc(
          nil, 4096, DWORD(UInt32(MEM_COMMIT) | UInt32(MEM_RESERVE)), DWORD(UInt32(PAGE_READWRITE)))
      else {
        cecFailFast(stage: "aggregate deinit positive allocation", error: 8)
      }
      if kind == 0 {
        var worker = CECEngineWorker(configuration: faultConfiguration(sessionCount: 0))
        worker.started = true
        worker.joined = true
        worker.phase = .stopped
        worker.resources.arena.reset(memory, byteCount: 4096)
        consumeDirectWorker(consume worker)
      } else if kind == 1 {
        var transport = CECRioTransport()
        transport.resources.arena.reset(memory, byteCount: 4096)
        consumeDirectTransport(consume transport)
      } else {
        var resources = CECEngineWorkerResources()
        resources.arena.reset(memory, byteCount: 4096)
        consumeDirectResources(consume resources)
      }
      var info = MEMORY_BASIC_INFORMATION()
      guard VirtualQuery(memory, &info, UInt64(MemoryLayout<MEMORY_BASIC_INFORMATION>.size)) != 0,
        info.State == DWORD(UInt32(MEM_FREE))
      else { cecFailFast(stage: "aggregate deinit positive release", error: 13) }
    }
    print("aggregate deinit positive owners=3")
    return
  }
  // Direct implicit destruction, with a non-heap arena to distinguish the
  // named guard from any earlier owned member's release/destructor.
  var stackByte: UInt8 = 42
  withUnsafeMutablePointer(to: &stackByte) { address in
    if mode == "worker_deinit" || mode == "worker_deinit_unjoined" {
      var worker = CECEngineWorker(configuration: faultConfiguration(sessionCount: 0))
      worker.resources.arena.reset(UnsafeMutableRawPointer(address), byteCount: 1)
      if mode == "worker_deinit_unjoined" {
        worker.started = true
        worker.phase = .running
      } else {
        worker.transport.totalOutstanding = 1
      }
      consumeDirectWorker(consume worker)
    } else if mode == "transport_deinit" {
      var transport = CECRioTransport()
      transport.resources.arena.reset(UnsafeMutableRawPointer(address), byteCount: 1)
      transport.totalOutstanding = 1
      consumeDirectTransport(consume transport)
    } else if mode == "resources_deinit" {
      var resources = CECEngineWorkerResources()
      resources.arena.reset(UnsafeMutableRawPointer(address), byteCount: 1)
      guard let sessions = CECPinnedStorage(count: 1, initialValue: CECEngineSession()) else {
        cecFailFast(stage: "aggregate deinit Slot allocation", error: 8)
      }
      sessions.baseAddress.pointee.receiveOutstanding = true
      resources.sessions = consume sessions
      consumeDirectResources(consume resources)
    }
  }
  cecFailFast(stage: "aggregate deinit guard accepted", error: 13)
}
private struct TimerPeriodTrace: Sendable {
  var begins = 0
  var ends = 0
}
private let timerPeriodTrace = Mutex(TimerPeriodTrace())
private struct FaultTimerPeriodAPI: CECTimerPeriodAPI {
  let status: UInt32
  func begin(_ period: UInt32) -> UInt32 {
    guard period == 1 else { cecFailFast(stage: "timer period request", error: 13) }
    timerPeriodTrace.withLock { $0.begins += 1 }
    return status
  }
  func end(_ period: UInt32) {
    guard period == 1 else { cecFailFast(stage: "timer period release", error: 13) }
    timerPeriodTrace.withLock { $0.ends += 1 }
  }
}
private func consumeDirectTimer(_ timer: consuming CECTimerResolutionOwner<FaultTimerPeriodAPI>) {
  timer.keepAlive()
}
func cecExerciseTimerResolution(positive: Bool) -> CECExitCode {
  timerPeriodTrace.withLock { $0 = TimerPeriodTrace() }
  if !positive {
    if let timer = cecPrepareTimerResolution(
      intervalMilliseconds: 1, api: FaultTimerPeriodAPI(status: 97))
    {
      consumeDirectTimer(consume timer)
      cecFailFast(stage: "timer failure accepted", error: 13)
    }
    let trace = timerPeriodTrace.withLock { $0 }
    guard trace.begins == 1, trace.ends == 0 else {
      cecFailFast(stage: "timer rejected request balance", error: 13)
    }
    return .internalFailure
  }
  guard
    let disabled = cecPrepareTimerResolution(
      intervalMilliseconds: 0, api: FaultTimerPeriodAPI(status: 97))
  else {
    cecFailFast(stage: "timer disabled request", error: 13)
  }
  consumeDirectTimer(consume disabled)
  guard timerPeriodTrace.withLock({ $0.begins == 0 && $0.ends == 0 }) else {
    cecFailFast(stage: "timer disabled balance", error: 13)
  }
  guard
    let enabled = cecPrepareTimerResolution(
      intervalMilliseconds: 9, api: FaultTimerPeriodAPI(status: 0))
  else {
    cecFailFast(stage: "timer positive request", error: 13)
  }
  consumeDirectTimer(consume enabled)
  guard timerPeriodTrace.withLock({ $0.begins == 1 && $0.ends == 1 }) else {
    cecFailFast(stage: "timer positive balance", error: 13)
  }
  print("timer resolution positive begin=1 end=1 disabled=0")
  return .success
}
