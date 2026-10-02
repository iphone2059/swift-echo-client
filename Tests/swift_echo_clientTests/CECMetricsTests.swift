import Foundation
import Testing
import ucrt

@testable import CECClientCore

@Suite struct CECMetricsTests {
  @Test func claimsAndPercentiles() async {
    let m = CECEngineMetrics()
    m.claimed.store(7, ordering: .relaxed)
    #expect(cecClaimAttempts(metrics: m, limit: 10, requested: 8) == 3)
    #expect(cecClaimAttempts(metrics: m, limit: 10, requested: 1) == 0)
    let parallel = CECEngineMetrics()
    let total = await withTaskGroup(of: UInt64.self) { group in
      for _ in 0..<64 {
        group.addTask {
          var count: UInt64 = 0
          while true {
            let grant = cecClaimAttempts(metrics: parallel, limit: 10003, requested: 8)
            if grant == 0 { break }
            count += grant
          }
          return count
        }
      }
      var count: UInt64 = 0
      for await value in group { count += value }
      return count
    }
    #expect(total == 10003 && parallel.claimed.load(ordering: .relaxed) == 10003)
    #expect(cecPercentileTarget(total: 2, numerator: 50, denominator: 100) == 1)
    #expect(
      cecPercentileTarget(total: UInt64.max, numerator: 999, denominator: 1000)
        == 18_428_297_329_635_842_064)
    var snapshot = CECWorkerMetricsSnapshot()
    for ticks in [UInt64(1), 2, 3] {
      cecRecordLatency(metrics: &snapshot, ticks: ticks, frequency: 1_000_000)
    }
    #expect(
      snapshot.latencyBins[0] == 1
        && snapshot.latencyBins[1] == 2)
    snapshot.echoed = 3
    snapshot.bytes = 1024
    let line = cecMetricsLine(
      phase: "final", options: CECOptions(), metrics: snapshot, elapsedMilliseconds: 0)
    #expect(
      line.hasPrefix(
        "final elapsed_ms=0 sessions=1 echoed=3 corrupted=0 lost=0 network_errors=0 bytes=1024 echo_per_sec=3000.00 MiB_per_sec=0.98 "
      ))
    #expect(line.hasSuffix("latency_sample=batch"))
    #expect(line.contains("p50_us~2 p99_us~2 p999_us~2 max_us~2"))
    let old = setlocale(LC_NUMERIC, nil).map { String(cString: $0) } ?? "C"
    _ = setlocale(LC_NUMERIC, "German_Germany.1252")
    let commaLocaleLine = cecMetricsLine(
      phase: "final", options: CECOptions(), metrics: snapshot, elapsedMilliseconds: 0)
    _ = old.withCString { setlocale(LC_NUMERIC, $0) }
    #expect(commaLocaleLine == line)
  }

  @Test func unlimitedClaimsAndMergedAccounting() {
    let quota = CECEngineMetrics()
    quota.claimed.store(99, ordering: .relaxed)
    #expect(cecClaimAttempts(metrics: quota, limit: 0, requested: 8) == 8)
    #expect(cecClaimAttempts(metrics: quota, limit: 0, requested: 0) == 0)
    #expect(quota.claimed.load(ordering: .relaxed) == 99)
    var first = CECWorkerMetricsSnapshot()
    first.claimed = 8; first.echoed = 6; first.corrupted = 1; first.lost = 1
    first.bytes = 24; first.networkErrors = 1; first.latencyBins[0] = 2
    var second = CECWorkerMetricsSnapshot()
    second.claimed = 3; second.echoed = 2; second.lost = 1
    second.bytes = 8; second.networkErrors = 1; second.latencyBins[63] = 1
    let result = cecMergeMetrics([first, second])
    #expect(result.claimed == 11 && result.echoed == 8 && result.corrupted == 1 && result.lost == 2)
    #expect(result.bytes == 32 && result.networkErrors == 2)
    #expect(result.latencyBins[0] == 2 && result.latencyBins[63] == 1)
    #expect(cecSessionTerminalAccountingValid(
      claimed: result.claimed, echoed: result.echoed, corrupted: result.corrupted, lost: result.lost))
  }
  @Test func snapshotPublicationIsCoherent() async {
    let publication = CECWorkerPublication()
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for i: UInt64 in 1...10_000 {
          var value = CECWorkerMetricsSnapshot()
          value.claimed = i; value.echoed = i; value.bytes = i * 4
          value.latencyBins[0] = i
          publication.publish(value)
        }
        publication.finished.store(true, ordering: .releasing)
      }
      for _ in 0..<4 {
        group.addTask {
          for _ in 0..<10_000 {
            let value = publication.read()
            #expect(value.claimed == value.echoed && value.bytes == value.echoed * 4)
            #expect(value.latencyBins[0] == value.echoed)
          }
        }
      }
    }
    let finished = publication.finished.load(ordering: .acquiring)
    #expect(finished)
    #expect(publication.read().claimed == 10_000)
  }
  @Test func mergePreservesWrappingAndAllBins() {
    var first = CECWorkerMetricsSnapshot()
    var second = CECWorkerMetricsSnapshot()
    first.bytes = UInt64.max; second.bytes = 1
    for i in 0..<64 {
      first.latencyBins[i] = UInt64.max
      second.latencyBins[i] = UInt64(i + 1)
    }
    first.merge(second)
    #expect(first.bytes == 0)
    #expect((0..<64).allSatisfy { first.latencyBins[$0] == UInt64($0) })
  }
  @Test func deadlineWaitAndEventPublication() {
    #expect(cecDeadlineWait(now: 100, deadline: 99) == 0)
    #expect(cecDeadlineWait(now: 100, deadline: 100) == 0)
    #expect(cecDeadlineWait(now: 100, deadline: 125) == 25)
    #expect(cecDeadlineWait(now: 0, deadline: UInt64.max - 1) == UInt32.max - 1)
    #expect(cecDeadlineWait(now: 0, deadline: UInt64.max) == UInt32.max)
    let control = CECSharedControl()
    #expect(control.prepareWake() == 0 && control.prepareWake() == 0)
    control.signalWake()
    control.waitWake(0)
    control.resetWake()
    control.waitWake(0)
  }
}
