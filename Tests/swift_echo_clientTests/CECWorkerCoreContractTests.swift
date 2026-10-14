import Testing

@testable import CECClientCore

@Suite struct CECWorkerCoreContractTests {
  @Test func receiveBeforeSendCannotSettleOrStartAnotherAttempt() throws {
    var options = CECOptions()
    options.transport = .tcp
    options.echoCount = 5
    options.pipelineDepth = 4
    var core = try CECWorkerCore(
      options: options, sessionCount: 1, payloadBytes: 4, frequency: 1000)
    let start = core.start(now: 0)
    #expect(start.count == 1)
    let connected = core.onEvent(.connected(0), now: 1)
    #expect(connected.count == 2)
    #expect(core.onEvent(.received(index: 0, bytes: 16, equal: true), now: 2).count == 0)
    #expect(core.metrics.echoed == 0 && core.metrics.claimed == 4)
    let sent = core.onEvent(.sent(0), now: 3)
    #expect(sent.count == 2)
    #expect(core.metrics.echoed == 4 && core.metrics.claimed == 5)
  }

  @Test func failureAfterReceiveLosesWholeUnsettledBatch() throws {
    var options = CECOptions()
    options.transport = .tcp
    options.echoCount = 4
    options.pipelineDepth = 4
    var core = try CECWorkerCore(
      options: options, sessionCount: 1, payloadBytes: 4, frequency: 1000)
    _ = core.start(now: 0)
    _ = core.onEvent(.connected(0), now: 1)
    _ = core.onEvent(.received(index: 0, bytes: 16, equal: true), now: 2)
    let failed = core.onEvent(.transportFailure(0), now: 3)
    #expect(failed.count == 1)
    #expect(core.metrics.echoed == 0 && core.metrics.lost == 4 && core.metrics.networkErrors == 1)
    #expect(core.sessions[0].state == .closing)
  }

  @Test func reconnectDelayStartsAtGenerationDrained() throws {
    var options = CECOptions()
    options.transport = .tcp
    options.reconnectSeconds = 2
    var core = try CECWorkerCore(
      options: options, sessionCount: 1, payloadBytes: 4, frequency: 1000)
    _ = core.start(now: 0)
    _ = core.onEvent(.transportFailure(0), now: 100)
    #expect(core.sessions[0].state == .closing)
    _ = core.onEvent(.generationDrained(0), now: 1000)
    #expect(core.poll(now: 2999).count == 0)
    #expect(core.poll(now: 3000).count == 1)
  }

  @Test func closingKeepsFirstDrainDeadlineAcrossRepeatedStop() throws {
    var options = CECOptions()
    options.transport = .tcp
    var core = try CECWorkerCore(
      options: options, sessionCount: 1, payloadBytes: 4, frequency: 1000)
    _ = core.start(now: 0)
    _ = core.onEvent(.connected(0), now: 1)
    _ = core.onEvent(.transportFailure(0), now: 100)
    core.stopping = true
    _ = core.stopSession(index: 0, now: 500)
    #expect(core.poll(now: 5099).count == 0)
    let timeout = core.poll(now: 5100)
    #expect(timeout.count == 1)
    #expect(timeout[0] == .drainTimeout(0))
  }

  @Test func controlledStopCompletesLedgerAsCancelled() throws {
    var options = CECOptions()
    options.transport = .tcp
    options.pipelineDepth = 4
    var core = try CECWorkerCore(
      options: options, sessionCount: 1, payloadBytes: 4, frequency: 1000)
    _ = core.start(now: 0)
    _ = core.onEvent(.connected(0), now: 1)
    core.stopping = true
    _ = core.stopSession(index: 0, now: 2)
    _ = core.onEvent(.generationDrained(0), now: 3)
    #expect(core.metrics.cancelled == 4 && core.metrics.lost == 0)
    #expect(core.liveSessions == 0 && core.metrics.active == 0 && core.timers.size == 0)
  }
}
