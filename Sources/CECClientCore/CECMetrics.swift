import Foundation
import Synchronization
import WinSDK

package func cecDeadlineWait(now: UInt64, deadline: UInt64) -> UInt32 {
  if deadline == UInt64.max { return UInt32.max }
  if deadline <= now { return 0 }
  return UInt32(min(deadline - now, UInt64(UInt32.max - 1)))
}

// Safe public control interface: the handle never leaves this object, all
// adoption/access is synchronized, and each wait/signal borrows a live self.
// The coordinator and workers retain self through join and console unregister.
@safe
package final class CECSharedControl: Sendable {
  package let stopRequested = Atomic<Bool>(false)
  package let fatal = Atomic<Bool>(false)
  // The handle is initialized before workers start and lives until all join.
  // Mutex protects adoption; no lock is held while waiting or signaling.
  private let wake = unsafe Mutex(CECHandleOwner())
  package init() {}
  package func prepareWake() -> Int32 {
    unsafe wake.withLock { owner in
      if unsafe owner.rawValue != nil { return 0 }
      guard let event = unsafe CreateEventW(nil, true, false, nil) else {
        return Int32(bitPattern: GetLastError())
      }
      unsafe owner.reset(event)
      return 0
    }
  }
  private func wakeHandle() -> HANDLE? { unsafe wake.withLock { unsafe $0.rawValue } }
  package func signalWake() {
    guard let event = unsafe wakeHandle() else { return }
    if unsafe !SetEvent(event) {
      cecFailFast(stage: "client coordinator wake", error: Int32(bitPattern: GetLastError()))
    }
  }
  package func resetWake() {
    guard let event = unsafe wakeHandle(), unsafe ResetEvent(event) else {
      cecFailFast(stage: "client coordinator reset", error: Int32(bitPattern: GetLastError()))
    }
  }
  package func waitWake(_ milliseconds: UInt32) {
    guard let event = unsafe wakeHandle() else {
      cecFailFast(stage: "client coordinator event", error: 6)
    }
    let result = unsafe WaitForSingleObject(event, milliseconds)
    if result != WAIT_OBJECT_0 && result != WAIT_TIMEOUT {
      cecFailFast(stage: "client coordinator wait", error: Int32(bitPattern: GetLastError()))
    }
  }
}
package final class CECEngineMetrics: Sendable {
  package let claimed = Atomic<UInt64>(0)
  package init() {}
}
package struct CECWorkerMetricsSnapshot: Sendable {
  package var claimed: UInt64 = 0
  package var echoed: UInt64 = 0
  package var corrupted: UInt64 = 0
  package var lost: UInt64 = 0
  package var bytes: UInt64 = 0
  package var networkErrors: UInt64 = 0
  package var latencyBins = InlineArray<64, UInt64>(repeating: 0)
  package init() {}
  package mutating func merge(_ other: borrowing Self) {
    claimed &+= other.claimed
    echoed &+= other.echoed
    corrupted &+= other.corrupted
    lost &+= other.lost
    bytes &+= other.bytes
    networkErrors &+= other.networkErrors
    for i in latencyBins.indices { latencyBins[i] &+= other.latencyBins[i] }
  }
}
package final class CECWorkerPublication: Sendable {
  private let snapshot = Mutex(CECWorkerMetricsSnapshot())
  package let finished = Atomic<Bool>(false)
  package init() {}
  // Keep the infrequent synchronized copy out of the native dispatcher's body.
  @inline(never)
  package func publish(_ value: borrowing CECWorkerMetricsSnapshot) {
    let published = copy value
    snapshot.withLock { $0 = published }
  }
  package func read() -> CECWorkerMetricsSnapshot { snapshot.withLock { $0 } }
}
package func cecMergeMetrics(_ snapshots: [CECWorkerMetricsSnapshot]) -> CECWorkerMetricsSnapshot {
  var result = CECWorkerMetricsSnapshot()
  for snapshot in snapshots { result.merge(snapshot) }
  return result
}
package func cecClaimAttempts(metrics: borrowing CECEngineMetrics, limit: UInt64, requested: UInt64)
  -> UInt64
{
  guard requested != 0 else { return 0 }
  if limit == 0 {
    return requested
  }
  var observed = metrics.claimed.load(ordering: .relaxed)
  while observed < limit {
    let grant = min(requested, limit - observed)
    let result = metrics.claimed.weakCompareExchange(
      expected: observed, desired: observed + grant, ordering: .relaxed)
    if result.exchanged { return grant }
    observed = result.original
  }
  return 0
}
package func cecPercentileTarget(total: UInt64, numerator: UInt64, denominator: UInt64) -> UInt64 {
  guard total > 0, denominator > 0, numerator > 0, numerator <= denominator else { return 0 }
  let division = denominator.dividingFullWidth(total.multipliedFullWidth(by: numerator))
  return division.quotient + (division.remainder == 0 ? 0 : 1)
}
package func cecRecordLatency(metrics: inout CECWorkerMetricsSnapshot, ticks: UInt64, frequency: UInt64)
{
  guard frequency != 0 else { return }
  let full = ticks.multipliedFullWidth(by: 1_000_000)
  let us =
    full.high >= frequency ? UInt64.max : max(1, frequency.dividingFullWidth(full).quotient)
  metrics.latencyBins[63 - us.leadingZeroBitCount] &+= 1
}
package func cecMetricsLine(
  phase: String, options: borrowing CECOptions, metrics: borrowing CECWorkerMetricsSnapshot,
  elapsedMilliseconds: UInt64
) -> String {
  let elapsed = max(1, elapsedMilliseconds)
  let echoed = metrics.echoed
  let bytes = metrics.bytes
  var total: UInt64 = 0
  for i in metrics.latencyBins.indices { total &+= metrics.latencyBins[i] }
  func percentile(_ n: UInt64, _ d: UInt64) -> UInt64 {
    let target = cecPercentileTarget(total: total, numerator: n, denominator: d)
    guard target > 0 else { return 0 }
    var count: UInt64 = 0
    for i in metrics.latencyBins.indices {
      count &+= metrics.latencyBins[i]
      if count >= target { return i == 63 ? UInt64.max : UInt64(1) << i }
    }
    return 0
  }
  let rates = String(
    format: "echo_per_sec=%.2f MiB_per_sec=%.2f", locale: Locale(identifier: "en_US_POSIX"),
    Double(echoed) * 1000 / Double(elapsed), Double(bytes) * 1000 / Double(elapsed) / 1_048_576)
  return
    "\(phase) elapsed_ms=\(elapsedMilliseconds) sessions=\(options.sessionCount) echoed=\(echoed) corrupted=\(metrics.corrupted) lost=\(metrics.lost) network_errors=\(metrics.networkErrors) bytes=\(bytes) \(rates) p50_us~\(percentile(50,100)) p99_us~\(percentile(99,100)) p999_us~\(percentile(999,1000)) max_us~\(percentile(1,1)) latency_sample=batch"
}
