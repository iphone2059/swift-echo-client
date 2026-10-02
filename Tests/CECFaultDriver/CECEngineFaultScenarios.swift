import CECClientCore
import WinSDK

func cecExerciseInvalidCompletionContext(identity: Bool) {
  var bytes = UniqueArray<UInt8>()
  bytes.append(0)
  let owner = CECWorkerOwner(configuration: CECWorkerConfiguration(
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
  result.RequestContext = UInt64(identity ? first + 1 : w.pointee.sessionRange.upperBound)
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
  cecPostWorkerStop(w)
  cecShutdownNotification(w)
}

/// Fault driver exercises the real initializer and stop/join path, without client CLI modes.
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
    while first.baseAddress.pointee.publication.read().claimed < 2 && GetTickCount64() < deadline { Sleep(1) }
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

