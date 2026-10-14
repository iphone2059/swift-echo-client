import Testing

@testable import CECClientCore

/// Expected cases come from echo-binary-contract-v1 in the current C++/Rust/Zig implementations,
/// independently of the Swift implementation. Execution waits for the complete source phase.
@Suite struct CECBinaryContractAlignmentTests {
  private func arguments(_ values: [String]) -> [[UInt16]] {
    (["client"] + values).map { Array($0.utf16) }
  }

  @Test func explicitZerosAndFullReconnectRange() throws {
    let options = try cecParseOptions(
      arguments([
        "127.0.0.1", "/p", "tcp", "/threads", "0", "/w", "0", "/report", "0",
        "/rc", "4294967295",
      ]))
    #expect(options.workerCount == 0 && options.runSeconds == 0 && options.reportSeconds == 0)
    #expect(options.reconnectSeconds == Int64(UInt32.max))
    #expect(CECSwitchTable.lookup("threads")?.minimum == 0)
    #expect(CECSwitchTable.lookup("w")?.minimum == 0)
    #expect(CECSwitchTable.lookup("report")?.minimum == 0)
    #expect(throws: CECArgumentError.self) {
      try cecParseOptions(arguments(["host", "/p", "tcp", "/rc", "4294967296"]))
    }
  }

  @Test func helpStillChecksTwoDirectionsAndShardCQ() throws {
    // 2 * 4 sessions * 131072 bytes is exactly the minimum one-MiB arena budget;
    // changing the worker count must not change the global two-direction storage cost.
    for workers in ["1", "4"] {
      let options = try cecParseOptions(
        arguments([
          "/h", "/p", "tcp", "/c", "4", "/threads", workers, "/z", "131072",
          "/memory", "1048576",
        ]))
      #expect(options.help)
    }
    let cases: [([String], String)] = [
      (
        [
          "/h", "/p", "tcp", "/c", "4", "/threads", "1", "/z", "131073",
          "/memory", "1048576",
        ], "memory-capacity"
      ),
      (
        [
          "/h", "/p", "tcp", "/c", "33", "/threads", "1", "/z", "1",
          "/cq", "64",
        ], "cq-capacity"
      ),
    ]
    for (values, expected) in cases {
      do {
        _ = try cecParseOptions(arguments(values))
        Issue.record("Expected contract rejection: \(expected)")
      } catch { #expect(error.message == expected) }
    }
  }

  @Test func malformedUTF16PreservesDiagnosticPrecedence() {
    let malformed: [UInt16] = [0xD800]
    let cases: [([[UInt16]], String)] = [
      (arguments([]) + [malformed], "invalid-utf16"),
      (arguments(["/d"]) + [malformed], "missing-target"),
      (arguments(["/h", "/d"]) + [malformed], "invalid-utf16"),
      (
        arguments(["/h", "/d"]) + [malformed] + [Array("/z".utf16), Array("1".utf16)],
        "conflicting-payload"
      ),
    ]
    for (values, expected) in cases {
      do {
        _ = try cecParseOptions(values)
        Issue.record("Expected contract rejection: \(expected)")
      } catch { #expect(error.message == expected) }
    }
    #expect(cecUTF8ByteCount(Array("aé中😀".utf16)) == 10)
    #expect(cecUTF8ByteCount([0xDC00]) == nil)
    #expect(cecUTF8ByteCount([0xD800, 65]) == nil)
  }

  @Test func completeStatisticsLiteralMatchesAllThreeReferences() {
    // Field order and formatting: C++ cec_engine.cpp cec_engine_print_metrics;
    // Rust metrics.rs StatisticsLine::fmt; Zig metrics.zig Statistics.writeLine.
    var options = CECOptions()
    options.sessionCount = 4
    var metrics = CECWorkerMetricsSnapshot()
    metrics.claimed = 11
    metrics.echoed = 8
    metrics.corrupted = 1
    metrics.lost = 1
    metrics.cancelled = 1
    metrics.sentBytes = 48
    metrics.receivedBytes = 40
    metrics.bytes = 32
    metrics.connections = 2
    metrics.reconnects = 1
    metrics.networkErrors = 1
    metrics.active = 1
    metrics.recordLatency(microseconds: 3)
    metrics.recordLatency(microseconds: 5)
    let expected =
      "final elapsed_ms=1000 sessions=4 active=1 attempted=11 pending=0 echoed=8 corrupted=1 lost=1 cancelled=1 sent_bytes=48 received_bytes=40 bytes=32 connections=2 reconnects=1 network_errors=1 echo_per_sec=8.00 MiB_per_sec=0.00 p50_us~2 p99_us~4 p999_us~4 mean_us=4 max_us~4 latency_sample=batch"
    #expect(
      cecMetricsLine(
        phase: "final", options: options, metrics: metrics, elapsedMilliseconds: 1000) == expected)
    #expect(metrics.pending == 0 && metrics.terminalCount == metrics.claimed)
    metrics.claimed = 13
    #expect(metrics.pending == 2)
  }

  @Test func finalHistogramBucketIsItsLowerBound() {
    var metrics = CECWorkerMetricsSnapshot()
    metrics.recordLatency(microseconds: UInt64.max)
    #expect(metrics.percentile(numerator: 1, denominator: 1) == UInt64(1) << 63)
    #expect(metrics.meanLatencyUS == UInt64.max)
  }

  @Test func failedFiniteQuotaAndControlledStopKeepTerminalLedgerBalanced() {
    // C++ adds terminal_unclaimed to displayed attempted and lost; Rust/Zig
    // add unclaimed directly to both aggregate fields after joining workers.
    var failed = CECWorkerMetricsSnapshot()
    failed.claimed = 4
    failed.echoed = 2
    failed.lost = 2
    failed.accountUnclaimed(limit: 10, controlledStop: false)
    #expect(failed.claimed == 10 && failed.echoed == 2 && failed.lost == 8)
    #expect(failed.pending == 0 && failed.claimed == failed.terminalCount)

    var stopped = CECWorkerMetricsSnapshot()
    stopped.claimed = 4
    stopped.echoed = 2
    stopped.cancelled = 2
    stopped.accountUnclaimed(limit: 10, controlledStop: true)
    #expect(stopped.claimed == 4 && stopped.cancelled == 2 && stopped.lost == 0)
    #expect(stopped.pending == 0 && stopped.claimed == stopped.terminalCount)
  }

  @Test func failurePayloadKeepsRawCodeCategoryAndRetryability() {
    // Zig types.Failure carries stage/code/domain/category/retryable; Rust additionally classifies
    // network/invariant/drain-timeout. The Swift shared representation retains both dimensions.
    let failure = CECFailure(
      classification: .network, domain: .winsock, stage: "ConnectEx", code: 10061,
      category: .connection, retryable: true)
    let preserved = failure
    #expect(preserved.classification == .network && preserved.domain == .winsock)
    #expect(String(describing: preserved.stage) == "ConnectEx" && preserved.code == 10061)
    #expect(preserved.category == .connection && preserved.retryable)
    let capacity = CECFailure(
      classification: .network, domain: .capacity, stage: "registered arena", code: 8)
    #expect(capacity.category == .initialization && !capacity.retryable)
    #expect(CECFailure.invariant(stage: "generation drain").category == .invariant)
    #expect(CECFailure.timeout(stage: "generation drain").classification == .drainTimeout)
  }
}
