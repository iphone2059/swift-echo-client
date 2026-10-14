import Foundation

package struct CECNotificationSnapshot {
  package var workerIndex: UInt32 = 0
  package var arms: UInt64 = 0
  package var deliveries: UInt64 = 0
  package var timeoutWakeups: UInt64 = 0
}
package func cecNotificationDiagnosticLine(
  _ snapshot: CECNotificationSnapshot, transport: CECTransport
) -> String {
  let name = transport == .tcp ? "tcp" : "udp"
  let gap = snapshot.arms >= snapshot.deliveries ? snapshot.arms - snapshot.deliveries : 0
  return
    "role=client protocol=\(name) worker=\(snapshot.workerIndex) notify_arms=\(snapshot.arms) notify_deliveries=\(snapshot.deliveries) notify_gap=\(gap) timeout_wakeups_while_outstanding=\(snapshot.timeoutWakeups)\n"
}
package func cecDeadlineWait(now: UInt64, deadline: UInt64) -> UInt32 {
  if deadline == UInt64.max { return UInt32.max }
  if deadline <= now { return 0 }
  return UInt32(min(deadline - now, UInt64(UInt32.max - 1)))
}
package struct CECWorkerMetricsSnapshot: Sendable {
  package var claimed: UInt64 = 0
  package var echoed: UInt64 = 0
  package var corrupted: UInt64 = 0
  package var lost: UInt64 = 0
  package var cancelled: UInt64 = 0
  package var sentBytes: UInt64 = 0
  package var receivedBytes: UInt64 = 0
  package var bytes: UInt64 = 0
  package var connections: UInt64 = 0
  package var reconnects: UInt64 = 0
  package var networkErrors: UInt64 = 0
  package var active: UInt32 = 0
  package var fatal = false
  package var latencyBins = InlineArray<64, UInt64>(repeating: 0)
  package var latencySamples: UInt64 = 0
  package var latencySumUS: UInt64 = 0
  package var latencyMaxUS: UInt64 = 0
  package var elapsedMilliseconds: UInt64 = 0
  package init() {}
  package mutating func merge(_ other: borrowing Self) {
    claimed &+= other.claimed
    echoed &+= other.echoed
    corrupted &+= other.corrupted
    lost &+= other.lost
    cancelled &+= other.cancelled
    sentBytes &+= other.sentBytes
    receivedBytes &+= other.receivedBytes
    bytes &+= other.bytes
    connections &+= other.connections
    reconnects &+= other.reconnects
    networkErrors &+= other.networkErrors
    active &+= other.active
    if other.fatal { fatal = true }
    latencySamples &+= other.latencySamples
    latencySumUS &+= other.latencySumUS
    latencyMaxUS = max(latencyMaxUS, other.latencyMaxUS)
    elapsedMilliseconds = max(elapsedMilliseconds, other.elapsedMilliseconds)
    for i in latencyBins.indices { latencyBins[i] &+= other.latencyBins[i] }
  }

  package var terminalCount: UInt64 { echoed &+ corrupted &+ lost &+ cancelled }
  package var pending: UInt64 { claimed > terminalCount ? claimed - terminalCount : 0 }
  package var meanLatencyUS: UInt64 { latencySamples == 0 ? 0 : latencySumUS / latencySamples }

  // Final run accounting includes requested finite echoes never posted by a
  // failed run. Session quotas are untouched; only the joined aggregate grows.
  package mutating func accountUnclaimed(limit: UInt64, controlledStop: Bool) {
    let unclaimed = cecUnclaimedEchoes(
      limit: limit, claimed: claimed, controlledStop: controlledStop)
    claimed &+= unclaimed
    lost &+= unclaimed
  }

  package mutating func recordLatency(microseconds: UInt64) {
    let value = max(1, microseconds)
    latencySamples &+= 1
    latencySumUS &+= value
    latencyMaxUS = max(latencyMaxUS, value)
    latencyBins[63 - value.leadingZeroBitCount] &+= 1
  }

  package func percentile(numerator: UInt64, denominator: UInt64) -> UInt64 {
    var total: UInt64 = 0
    for index in latencyBins.indices { total &+= latencyBins[index] }
    let target = cecPercentileTarget(total: total, numerator: numerator, denominator: denominator)
    guard target > 0 else { return 0 }
    var seen: UInt64 = 0
    for index in latencyBins.indices {
      seen &+= latencyBins[index]
      if seen >= target { return UInt64(1) << index }
    }
    return 0
  }
}
package func cecMergeMetrics(_ snapshots: [CECWorkerMetricsSnapshot]) -> CECWorkerMetricsSnapshot {
  var result = CECWorkerMetricsSnapshot()
  for snapshot in snapshots { result.merge(snapshot) }
  return result
}
package func cecClaimSessionAttempts(claimed: inout UInt64, limit: UInt64, requested: UInt64)
  -> UInt64
{
  guard requested != 0 else { return 0 }
  if limit == 0 {
    claimed &+= requested
    return requested
  }
  guard claimed < limit else { return 0 }
  let grant = min(requested, limit - claimed)
  claimed &+= grant
  return grant
}
package func cecPercentileTarget(total: UInt64, numerator: UInt64, denominator: UInt64) -> UInt64 {
  guard total > 0, denominator > 0, numerator > 0, numerator <= denominator else { return 0 }
  let division = denominator.dividingFullWidth(total.multipliedFullWidth(by: numerator))
  return division.quotient + (division.remainder == 0 ? 0 : 1)
}
package func cecRecordLatency(
  metrics: inout CECWorkerMetricsSnapshot, ticks: UInt64, frequency: UInt64
) {
  guard frequency != 0 else { return }
  let full = ticks.multipliedFullWidth(by: 1_000_000)
  let us =
    full.high >= frequency ? UInt64.max : max(1, frequency.dividingFullWidth(full).quotient)
  metrics.recordLatency(microseconds: us)
}
package func cecMetricsLine(
  phase: String, options: borrowing CECOptions, metrics: borrowing CECWorkerMetricsSnapshot,
  elapsedMilliseconds: UInt64
) -> String {
  let elapsed = max(1, elapsedMilliseconds)
  let echoed = metrics.echoed
  let bytes = metrics.bytes
  func percentile(_ n: UInt64, _ d: UInt64) -> UInt64 {
    metrics.percentile(numerator: n, denominator: d)
  }
  let rates = String(
    format: "echo_per_sec=%.2f MiB_per_sec=%.2f", locale: Locale(identifier: "en_US_POSIX"),
    Double(echoed) * 1000 / Double(elapsed),
    (Double(bytes) / 1_048_576) * 1000 / Double(elapsed))
  return
    "\(phase) elapsed_ms=\(elapsedMilliseconds) sessions=\(options.sessionCount) active=\(metrics.active) attempted=\(metrics.claimed) pending=\(metrics.pending) echoed=\(echoed) corrupted=\(metrics.corrupted) lost=\(metrics.lost) cancelled=\(metrics.cancelled) sent_bytes=\(metrics.sentBytes) received_bytes=\(metrics.receivedBytes) bytes=\(bytes) connections=\(metrics.connections) reconnects=\(metrics.reconnects) network_errors=\(metrics.networkErrors) \(rates) p50_us~\(percentile(50,100)) p99_us~\(percentile(99,100)) p999_us~\(percentile(999,1000)) mean_us=\(metrics.meanLatencyUS) max_us~\(percentile(1,1)) latency_sample=batch"
}
