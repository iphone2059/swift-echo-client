import Testing
import WinSDK

@testable import CECClientCore

@Suite struct CECEngineWorkerTests {
  @Test func completedSendAndReceiveOrder() {
    let m = CECEngineMetrics()
    let control = CECSharedControl()
    var options = CECOptions()
    options.transport = .tcp
    options.echoCount = 1
    options.intervalMilliseconds = 10
    var pattern = UniqueArray<UInt8>()
    pattern.append(42)
    let config = CECWorkerConfiguration(
      options: options, remoteAddress: SOCKADDR_IN(),
      extensions: CECNativeExtensions(rio: RIO_EXTENSION_FUNCTION_TABLE(), connectEx: nil),
      pattern: CECPatternStorage(consume pattern), maximumAttemptBytes: 1, metrics: m,
      control: control, workerIndex: 0, sessionCount: 1, memoryShare: 2)
    let owner = CECWorkerOwner(configuration: config)
    let w = owner.baseAddress
    guard let sessions = CECPinnedStorage(count: 1, initialValue: CECEngineSession()),
      let memory = VirtualAlloc(nil, 4096, DWORD(UInt32(MEM_COMMIT) | UInt32(MEM_RESERVE)), DWORD(UInt32(PAGE_READWRITE)))
    else {
      Issue.record("allocation")
      return
    }
    w.pointee.sessionAddress = sessions.baseAddress
    let first = UInt(bitPattern: sessions.baseAddress)
    w.pointee.sessionRange = first..<(first + UInt(MemoryLayout<CECEngineSession>.stride))
    w.pointee.resources.sessions = consume sessions
    w.pointee.resources.arena.reset(memory, byteCount: 4096)
    w.pointee.memory = memory.assumingMemoryBound(to: UInt8.self)
    let s = w.pointee.sessionAddress!
    s.pointee.owner = w
    s.pointee.state = .active
    s.pointee.requestedEchoes = 1
    s.pointee.attemptBytes = 1
    s.pointee.receiveArenaOffset = 1
    s.pointee.outstanding = 2
    s.pointee.receiveRequest = CECEngineRequest(sessionIndex: 0, operation: .receive)
    s.pointee.sendRequest = CECEngineRequest(sessionIndex: 0, operation: .send)
    w.pointee.memory![0] = 42
    w.pointee.memory![1] = 42
    var receive = RIORESULT()
    receive.RequestContext = UInt64(UInt(bitPattern: cecReceiveRequest(s)))
    receive.BytesTransferred = 1
    cecProcessRIOResult(w, result: receive)
    #expect(w.pointee.metrics.echoed == 0 && s.pointee.outstanding == 1)
    var send = RIORESULT()
    send.RequestContext = UInt64(UInt(bitPattern: cecSendRequest(s)))
    send.BytesTransferred = 1
    cecProcessRIOResult(w, result: send)
    #expect(
      w.pointee.metrics.echoed == 1 && s.pointee.outstanding == 0
        && s.pointee.state == .pacing)
    _ = w.pointee.timers.remove(sessionIndex: 0)
  }
}
