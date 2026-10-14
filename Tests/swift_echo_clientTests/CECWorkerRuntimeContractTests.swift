import Testing

@testable import CECClientCore

private struct RecorderClock: CECWorkerClock {
  var now: UInt64 = 100
  func nowTicks() -> UInt64 { now }
}
private struct RecorderTransport: CECWorkerTransport {
  var actions: [CECAction] = []
  var failReceive = false
  var live = true
  var nativeSendBytes: UInt64 = 0
  func isLive(_ completion: CECCompletion) -> Bool { live }
  func sendBytes() -> UInt64 { nativeSendBytes }
  func compareReceive(index: UInt32, generation: UInt32, bytes: Int, expected: Int) -> Bool {
    bytes == expected
  }
  mutating func connect(_ index: UInt32) -> CECPostResult {
    actions.append(.connect(index))
    return .success(
      CECPosted(
        completion: CECCompletion(index: index, generation: 1, operation: .connect), postedAt: 100))
  }
  mutating func connected(_ completion: CECCompletion) -> CECPostResult { .success(CECPosted()) }
  mutating func receive(_ index: UInt32, bytes: Int) -> CECPostResult {
    actions.append(.receive(index: index, bytes: bytes))
    if failReceive {
      return .failure(
        CECNativeError(
          stage: "recorder receive", code: 10054, domain: .winsock, category: .connection,
          retryable: true))
    }
    return .success(CECPosted())
  }
  mutating func send(_ index: UInt32, bytes: Int) -> CECPostResult {
    actions.append(.send(index: index, bytes: bytes))
    return .success(CECPosted())
  }
  mutating func close(_ index: UInt32) -> CECPostResult {
    actions.append(.close(index))
    live = false
    return .success(
      CECPosted(
        completion: CECCompletion(index: index, generation: 1, operation: .generationDrained),
        postedAt: 100))
  }
  mutating func drainTimeout(_ index: UInt32) -> CECPostResult {
    actions.append(.drainTimeout(index))
    return .success(CECPosted())
  }
}

@Suite struct CECWorkerRuntimeContractTests {
  @Test func substitutedTransportRecordsOrderedActionsAndSnapshots() throws {
    var options = CECOptions()
    options.transport = .tcp
    options.echoCount = 2
    options.pipelineDepth = 2
    var core = try CECWorkerCore(
      options: options, sessionCount: 1, payloadBytes: 4, frequency: 1000)
    withUnsafeMutablePointer(to: &core) { pointer in
      var runtime = CECWorkerRuntime(
        core: pointer, transport: RecorderTransport(), clock: RecorderClock())
      runtime.start()
      #expect(
        runtime.transport.actions == [
          .connect(0), .receive(index: 0, bytes: 8), .send(index: 0, bytes: 8),
        ])
      runtime.handleCompletion(
        CECCompletion(index: 0, generation: 1, operation: .receive, bytes: 8))
      #expect(pointer.pointee.metrics.echoed == 0 && pointer.pointee.metrics.pending == 2)
      runtime.transport.nativeSendBytes = 8
      runtime.handleCompletion(CECCompletion(index: 0, generation: 1, operation: .send, bytes: 8))
      #expect(runtime.transport.actions.last == .close(0))
      #expect(pointer.pointee.metrics.echoed == 2 && pointer.pointee.metrics.sentBytes == 8)
      #expect(
        pointer.pointee.liveSessions == 0 && pointer.pointee.metrics.active == 0
          && pointer.pointee.timers.size == 0)
    }
  }
  @Test func synchronousReceiveFailureSuppressesSendAndPreservesPayload() throws {
    var options = CECOptions()
    options.transport = .tcp
    options.echoCount = 1
    var core = try CECWorkerCore(
      options: options, sessionCount: 1, payloadBytes: 4, frequency: 1000)
    withUnsafeMutablePointer(to: &core) { pointer in
      var transport = RecorderTransport()
      transport.failReceive = true
      var runtime = CECWorkerRuntime(core: pointer, transport: transport, clock: RecorderClock())
      runtime.start()
      #expect(runtime.transport.actions == [.connect(0), .receive(index: 0, bytes: 4), .close(0)])
      #expect(
        pointer.pointee.metrics.claimed == 1 && pointer.pointee.metrics.lost == 1
          && pointer.pointee.metrics.networkErrors == 1)
      #expect(
        pointer.pointee.failure.map { String(describing: $0.stage) } == "recorder receive"
          && pointer.pointee.failure?.code == 10054)
      #expect(
        pointer.pointee.failure?.domain == .winsock
          && pointer.pointee.failure?.category == .connection
          && pointer.pointee.failure?.retryable == true)
      #expect(pointer.pointee.liveSessions == 0 && pointer.pointee.timers.size == 0)
    }
  }
}
