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
  @Test(arguments: [false, true]) func continuouslyNonemptyQueueServicesControl(fatal: Bool) throws {
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
        results![0].SocketContext = UInt64(UInt(bitPattern: s))
        results![0].BytesTransferred = 1
        results![1] = RIORESULT()
        results![1].RequestContext = UInt64(UInt(bitPattern: cecSendRequest(s)))
        results![1].SocketContext = UInt64(UInt(bitPattern: s))
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
    w.pointee.core = try CECWorkerCore(options: options, sessionCount: 1, payloadBytes: 1, frequency: 1000)
    guard let storage = CECPinnedStorage(count: 1, initialValue: CECEngineSession()),
      let memory = VirtualAlloc(nil, 4096, DWORD(UInt32(MEM_COMMIT) | UInt32(MEM_RESERVE)), DWORD(UInt32(PAGE_READWRITE)))
    else { Issue.record("allocation"); return }
    w.pointee.sessionAddress = storage.baseAddress
    let first = UInt(bitPattern: storage.baseAddress)
    w.pointee.sessionRange = first..<(first + UInt(MemoryLayout<CECEngineSession>.stride))
    w.pointee.resources.sessions = consume storage
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
    w.pointee.core.sessions[0].state = .active
    s.pointee.sendOutstanding = true
    s.pointee.receiveOutstanding = true
    s.pointee.generation = 1
    s.pointee.sendPostedBytes = 1
    s.pointee.receivePostedBytes = 1
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
    w.pointee.core.sessions[0].requestedEchoes = 1
    w.pointee.core.sessions[0].attemptBytes = 1
    s.pointee.receiveArenaOffset = 1


    drainTrace.withLock { $0 = DrainTrace(worker: UInt(bitPattern: w), fatal: fatal) }
    cecDrainCompletions(w)
    #expect(drainTrace.withLock { $0.calls } == 64)
    #expect(w.pointee.stopping && w.pointee.liveSessions == 1 && s.pointee.outstanding == 2)
    #expect(w.pointee.core.sessions[0].state == .closing)
    cecDrainCompletions(w)
    #expect(drainTrace.withLock { $0.calls } == 66)
    #expect(w.pointee.stopping && w.pointee.liveSessions == 0)
    #expect(s.pointee.outstanding == 0 && w.pointee.core.sessions[0].state == .done)
    #expect(w.pointee.metrics.echoed == 64 && w.pointee.metrics.claimed == 65)
    #expect(w.pointee.metrics.lost == (fatal ? 1 : 0))
    #expect(w.pointee.metrics.cancelled == (fatal ? 0 : 1))
    #expect(w.pointee.metrics.networkErrors == 0 && w.pointee.timers.size == 0)
    let snapshot = w.pointee.publication.read()
    #expect(snapshot.echoed == 64)
    #expect(snapshot.claimed == snapshot.echoed + 1 && snapshot.bytes == snapshot.echoed)
    var samples: UInt64 = 0
    for i in snapshot.latencyBins.indices { samples += snapshot.latencyBins[i] }
    #expect(samples == snapshot.echoed)
  }
}
