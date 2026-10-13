import Testing
import WinSDK

@testable import CECClientCore

@Suite struct CECEngineWorkerTests {
  @Test func completedSendAndReceiveOrder() throws {
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
    w.pointee.core = try CECWorkerCore(options: options, sessionCount: 1, payloadBytes: 1, frequency: 1000)
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
    w.pointee.core.sessions[0].state = .active
    w.pointee.core.sessions[0].requestedEchoes = 1
    w.pointee.core.sessions[0].attemptBytes = 1
    s.pointee.receiveArenaOffset = 1
    s.pointee.sendOutstanding = true
    s.pointee.receiveOutstanding = true
    s.pointee.generation = 1
    s.pointee.sendPostedBytes = w.pointee.core.sessions[0].attemptBytes
    s.pointee.receivePostedBytes = w.pointee.core.sessions[0].attemptBytes
    w.pointee.transport.totalOutstanding = 2
    w.pointee.transport.rioOutstanding = 2
    w.pointee.transport.notificationArmed = true
    w.pointee.transport.notifyArms = 1
    w.pointee.core.sessions[0].claimed = 1
    w.pointee.core.sessions[0].attemptAccounted = false
    w.pointee.core.sessions[0].receivePosted = true
    w.pointee.core.sessions[0].activeCounted = true
    w.pointee.core.metrics.claimed = 1
    w.pointee.core.metrics.active = 1


    w.pointee.memory![0] = 42
    w.pointee.memory![1] = 42
    var receive = RIORESULT()
    receive.RequestContext = UInt64(UInt(bitPattern: cecReceiveRequest(s)))
    receive.SocketContext = UInt64(UInt(bitPattern: s))
    receive.BytesTransferred = 1
    cecProcessRIOResult(w, result: receive)
    #expect(w.pointee.metrics.echoed == 0 && s.pointee.outstanding == 1)
    var send = RIORESULT()
    send.RequestContext = UInt64(UInt(bitPattern: cecSendRequest(s)))
    send.SocketContext = UInt64(UInt(bitPattern: s))
    send.BytesTransferred = 1
    cecProcessRIOResult(w, result: send)
    #expect(
      w.pointee.metrics.echoed == 1 && s.pointee.outstanding == 0
        && w.pointee.core.sessions[0].state == .pacing)
    _ = w.pointee.timers.remove(sessionIndex: 0)
  }
}
