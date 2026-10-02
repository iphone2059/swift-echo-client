import Synchronization
import Testing
import WinSDK

@testable import CECClientCore

private struct DrainTrace: Sendable {
  var worker: UInt = 0
  var calls = 0
  var fatal = false
}
private let drainTrace = Mutex(DrainTrace())

@Suite(.serialized) struct CECDrainTests {
  @Test(arguments: [false, true]) func continuouslyNonemptyQueueServicesControl(fatal: Bool) {
    let control = CECSharedControl()
    var rio = RIO_EXTENSION_FUNCTION_TABLE()
    rio.RIOReceive = { _, _, _, _, _ in true }
    rio.RIOSend = { _, _, _, _, _ in true }
    rio.RIODequeueCompletion = { _, results, capacity in
      drainTrace.withLock { trace in
        trace.calls += 1
        let w = UnsafeMutablePointer<CECEngineWorker>(bitPattern: trace.worker)!
        let s = w.pointee.sessionAddress!
        // Bound a broken implementation instead of hanging the test runner.
        if s.pointee.outstanding == 0 || trace.calls > 512 { return 0 }
        precondition(capacity >= 2 && s.pointee.outstanding == 2)
        results![0] = RIORESULT()
        results![0].RequestContext = UInt64(UInt(bitPattern: cecReceiveRequest(s)))
        results![0].BytesTransferred = 1
        results![1] = RIORESULT()
        results![1].RequestContext = UInt64(UInt(bitPattern: cecSendRequest(s)))
        results![1].BytesTransferred = 1
        if w.pointee.stopping {
          results![0].Status = 995
          results![1].Status = 995
        } else if trace.calls == 3 {
          if trace.fatal {
            w.pointee.configuration.control.fatal.store(true, ordering: .releasing)
          } else {
            w.pointee.configuration.control.stopRequested.store(true, ordering: .releasing)
          }
        }
        return 2
      }
    }
    var options = CECOptions()
    options.transport = .tcp
    options.echoCount = 0
    options.pipelineDepth = 1
    options.timeoutSeconds = 30
    var pattern = UniqueArray<UInt8>()
    pattern.append(42)
    let owner = CECWorkerOwner(configuration: CECWorkerConfiguration(
      options: options, remoteAddress: SOCKADDR_IN(),
      extensions: CECNativeExtensions(rio: rio, connectEx: nil),
      pattern: CECPatternStorage(consume pattern), maximumAttemptBytes: 1,
      metrics: CECEngineMetrics(), control: control, workerIndex: 0,
      sessionCount: 1, memoryShare: 2))
    let w = owner.baseAddress
    guard let storage = CECPinnedStorage(count: 1, initialValue: CECEngineSession()),
      let memory = VirtualAlloc(nil, 4096, DWORD(MEM_COMMIT | MEM_RESERVE), DWORD(PAGE_READWRITE))
    else { Issue.record("allocation"); return }
    w.pointee.sessionAddress = storage.baseAddress
    let first = UInt(bitPattern: storage.baseAddress)
    w.pointee.sessionRange = first..<(first + UInt(MemoryLayout<CECEngineSession>.stride))
    w.pointee.resources.sessions = consume storage
    w.pointee.resources.sockets.append(CECSocketOwner())
    w.pointee.resources.arena.reset(memory, byteCount: 4096)
    w.pointee.memory = memory.assumingMemoryBound(to: UInt8.self)
    w.pointee.memory![0] = 42
    w.pointee.memory![1] = 42
    w.pointee.liveSessions = 1
    w.pointee.metrics.claimed = 1
    w.pointee.nextPublication = 0
    _ = QueryPerformanceFrequency(&w.pointee.performanceFrequency)
    let s = w.pointee.sessionAddress!
    s.pointee.owner = w
    s.pointee.state = .active
    s.pointee.outstanding = 2
    s.pointee.requestedEchoes = 1
    s.pointee.attemptBytes = 1
    s.pointee.receiveArenaOffset = 1
    s.pointee.receiveRequest = CECEngineRequest(sessionIndex: 0, operation: .receive)
    s.pointee.sendRequest = CECEngineRequest(sessionIndex: 0, operation: .send)
    _ = QueryPerformanceCounter(&s.pointee.startedAt)
    drainTrace.withLock { $0 = DrainTrace(worker: UInt(bitPattern: w), fatal: fatal) }
    cecDrainCompletions(w)
    #expect(drainTrace.withLock { $0.calls } == 5)
    #expect(w.pointee.stopping && w.pointee.liveSessions == 0)
    #expect(s.pointee.outstanding == 0 && s.pointee.state == .done)
    #expect(w.pointee.metrics.echoed == 3 && w.pointee.metrics.claimed == 4)
    #expect(w.pointee.metrics.lost == (fatal ? 1 : 0))
    #expect(w.pointee.metrics.networkErrors == 0 && w.pointee.timers.size == 0)
    let snapshot = w.pointee.publication.read()
    #expect((1...3).contains(snapshot.echoed))
    #expect(snapshot.claimed == snapshot.echoed + 1 && snapshot.bytes == snapshot.echoed)
    var samples: UInt64 = 0
    for i in snapshot.latencyBins.indices { samples += snapshot.latencyBins[i] }
    #expect(samples == snapshot.echoed)
  }
}
