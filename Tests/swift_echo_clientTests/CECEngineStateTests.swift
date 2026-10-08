import Synchronization
import Testing
import WinSDK

@testable import CECClientCore

private let sentContinuation = Mutex<(Int, Int)>((0, 0))
private struct AllocationError: Error {}
private func stateWorker(
  transport: CECTransport, rio: RIO_EXTENSION_FUNCTION_TABLE = RIO_EXTENSION_FUNCTION_TABLE()
) throws -> CECWorkerOwner {
  var options = CECOptions()
  options.transport = transport
  options.echoCount = 1
  options.intervalMilliseconds = 10
  var pattern = UniqueArray<UInt8>()
  for i in 0..<4 { pattern.append(UInt8(i)) }
  let owner = CECWorkerOwner(
    configuration: CECWorkerConfiguration(
      options: options, remoteAddress: SOCKADDR_IN(),
      extensions: CECNativeExtensions(rio: rio, connectEx: nil),
      pattern: CECPatternStorage(consume pattern), maximumAttemptBytes: 4,
      metrics: CECEngineMetrics(), control: CECSharedControl(), workerIndex: 0, sessionCount: 1,
      memoryShare: 8))
  let w = owner.baseAddress
  guard let storage = CECPinnedStorage(count: 1, initialValue: CECEngineSession()),
    let memory = VirtualAlloc(nil, 4096, DWORD(UInt32(MEM_RESERVE) | UInt32(MEM_COMMIT)), DWORD(UInt32(PAGE_READWRITE)))
  else { throw AllocationError() }
  w.pointee.sessionAddress = storage.baseAddress
  let first = UInt(bitPattern: storage.baseAddress)
  w.pointee.sessionRange = first..<(first + UInt(MemoryLayout<CECEngineSession>.stride))
  w.pointee.resources.sessions = consume storage
  w.pointee.resources.arena.reset(memory, byteCount: 4096)
  w.pointee.memory = memory.assumingMemoryBound(to: UInt8.self)
  w.pointee.resources.sockets.append(CECSocketOwner())
  let s = w.pointee.sessionAddress!
  s.pointee.owner = w
  s.pointee.state = .active
  s.pointee.receiveArenaOffset = 4
  s.pointee.attemptBytes = 4
  s.pointee.requestedEchoes = 1
  s.pointee.outstanding = 2
  QueryPerformanceCounter(&s.pointee.startedAt)
  QueryPerformanceFrequency(&w.pointee.performanceFrequency)
  w.pointee.configuration.metrics.claimed.store(1, ordering: .relaxed)
  w.pointee.metrics.claimed = 1
  for i in 0..<4 {
    w.pointee.memory![i] = UInt8(i)
    w.pointee.memory![i + 4] = UInt8(i)
  }
  return owner
}
@Suite struct CECEngineStateTests {
  @Test func partialSendAndUDPShort() throws {
    var rio = RIO_EXTENSION_FUNCTION_TABLE()
    rio.RIOSend = { _, buffer, _, _, _ in
      sentContinuation.withLock { $0 = (Int(buffer!.pointee.Offset), Int(buffer!.pointee.Length)) }
      return true
    }
    let owner = try stateWorker(transport: .udp, rio: rio)
    let w = owner.baseAddress
    let s = w.pointee.sessionAddress!
    var send = RIORESULT()
    send.RequestContext = UInt64(UInt(bitPattern: cecSendRequest(s)))
    send.BytesTransferred = 2
    cecProcessRIOResult(w, result: send)
    #expect(s.pointee.sendOffset == 2 && s.pointee.outstanding == 2 && !s.pointee.sendDone)
    #expect(sentContinuation.withLock { $0.0 == 2 && $0.1 == 2 })
    cecProcessRIOResult(w, result: send)
    var receive = RIORESULT()
    receive.RequestContext = UInt64(UInt(bitPattern: cecReceiveRequest(s)))
    receive.BytesTransferred = 3
    cecProcessRIOResult(w, result: receive)
    #expect(
      w.pointee.metrics.corrupted == 1
        && w.pointee.metrics.lost == 0)
    _ = w.pointee.timers.remove(sessionIndex: 0)
  }
  @Test func TCPShortAndCloseOnlyDrain() throws {
    let owner = try stateWorker(transport: .tcp)
    let w = owner.baseAddress
    let s = w.pointee.sessionAddress!
    var receive = RIORESULT()
    receive.RequestContext = UInt64(UInt(bitPattern: cecReceiveRequest(s)))
    receive.BytesTransferred = 2
    cecProcessRIOResult(w, result: receive)
    #expect(s.pointee.state == .closing && s.pointee.outstanding == 1)
    var send = RIORESULT()
    send.RequestContext = UInt64(UInt(bitPattern: cecSendRequest(s)))
    send.Status = 995
    cecProcessRIOResult(w, result: send)
    #expect(s.pointee.state == .done && s.pointee.outstanding == 0 && w.pointee.liveSessions == 0)
    #expect(
      w.pointee.metrics.lost == 1
        && w.pointee.metrics.networkErrors == 1)
  }
  @Test func controlledCancellationIsNotLoss() throws {
    let owner = try stateWorker(transport: .tcp)
    let w = owner.baseAddress
    let s = w.pointee.sessionAddress!
    cecStopWorker(w)
    #expect(s.pointee.state == .closing && s.pointee.outstanding == 2)
    var result = RIORESULT()
    result.Status = 995
    result.RequestContext = UInt64(UInt(bitPattern: cecReceiveRequest(s)))
    cecProcessRIOResult(w, result: result)
    result.RequestContext = UInt64(UInt(bitPattern: cecSendRequest(s)))
    cecProcessRIOResult(w, result: result)
    #expect(
      s.pointee.state == .done && w.pointee.metrics.lost == 0
        && w.pointee.metrics.networkErrors == 0)
  }
}
