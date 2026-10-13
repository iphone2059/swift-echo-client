import Synchronization

package struct CECTimerNode {
  package var deadline: UInt64 = 0
  package var sessionIndex: UInt32 = 0
}
package struct CECTimerHeap: ~Copyable {
  package let capacity: Int
  package private(set) var size = 0
  package var nextDeadline: UInt64? { size == 0 ? nil : nodes[0].deadline }
  private var nodes: CECFixedArray<CECTimerNode>
  private var positions: CECFixedArray<Int>
  package init() { capacity = 0; nodes = CECFixedArray(); positions = CECFixedArray() }
  package init(capacity: UInt32) throws(CECFailure) {
    self.capacity = Int(capacity)
    nodes = try CECFixedArray(count: Int(capacity), repeating: CECTimerNode())
    positions = try CECFixedArray(count: Int(capacity), repeating: -1)
  }
  private borrowing func less(_ a: Int, _ b: Int) -> Bool {
    nodes[a].deadline == nodes[b].deadline
      ? nodes[a].sessionIndex < nodes[b].sessionIndex : nodes[a].deadline < nodes[b].deadline
  }
  private mutating func swap(_ a: Int, _ b: Int) {
    let temporary = nodes[a]
    nodes[a] = nodes[b]
    nodes[b] = temporary
    positions[Int(nodes[a].sessionIndex)] = a
    positions[Int(nodes[b].sessionIndex)] = b
  }
  private mutating func siftUp(_ start: Int) -> Int {
    var i = start
    while i > 0 {
      let parent = (i - 1) / 2
      if !less(i, parent) { break }
      swap(i, parent)
      i = parent
    }
    return i
  }
  private mutating func siftDown(_ start: Int) {
    var i = start
    while i * 2 + 1 < size {
      var child = i * 2 + 1
      if child + 1 < size && less(child + 1, child) { child += 1 }
      if !less(child, i) { break }
      swap(child, i)
      i = child
    }
  }
  package mutating func insertOrUpdate(sessionIndex: UInt32, deadline: UInt64) -> Bool {
    guard Int(sessionIndex) < capacity else { return false }
    var i = positions[Int(sessionIndex)]
    if i >= 0 {
      let previous = nodes[i].deadline
      if previous == deadline { return true }
      nodes[i].deadline = deadline
      if deadline < previous { _ = siftUp(i) } else { siftDown(i) }
      return true
    }
    if i < 0 {
      guard size < capacity else { return false }
      i = size
      size += 1
      positions[Int(sessionIndex)] = i
    }
    nodes[i] = CECTimerNode(deadline: deadline, sessionIndex: sessionIndex)
    _ = siftUp(i)
    return true
  }
  package mutating func remove(sessionIndex: UInt32) -> Bool {
    guard Int(sessionIndex) < capacity else { return false }
    let i = positions[Int(sessionIndex)]
    guard i >= 0 else { return false }
    positions[Int(sessionIndex)] = -1
    size -= 1
    if i < size {
      nodes[i] = nodes[size]
      positions[Int(nodes[i].sessionIndex)] = i
      let p = siftUp(i)
      siftDown(p)
    }
    return true
  }
  package mutating func popExpired(now: UInt64) -> UInt32? {
    guard size > 0, nodes[0].deadline <= now else { return nil }
    let index = nodes[0].sessionIndex
    _ = remove(sessionIndex: index)
    return index
  }
  package borrowing func waitMilliseconds(now: UInt64) -> UInt32 {
    guard size > 0 else { return UInt32.max }
    return UInt32(
      min(UInt64(UInt32.max - 1), nodes[0].deadline > now ? nodes[0].deadline - now : 0))
  }
}

// Pure worker vocabulary. No socket, request queue, OVERLAPPED or provider counter
// participates in a scheduler decision. Runtime supplies clock samples and events.
package enum CECEngineState: UInt8 {
  case dormant, connecting, active, pacing, reconnecting, closing, done
}
package struct CECSession {
  package var index: UInt32 = 0
  package var state: CECEngineState = .dormant
  package var activeCounted = false
  package var claimed: UInt64 = 0
  package var requestedEchoes: UInt64 = 0
  package var settled: UInt64 = 0
  package var attemptBytes = 0
  package var deadline: UInt64 = 0
  package var nextAction: UInt64 = 0
  package var startedAt: UInt64 = 0
  package var sendDone = false
  package var receiveDone = false
  package var receivePosted = false
  package var receiveEqual = false
  package var attemptAccounted = true
  package var reconnectAfterClose = false
}
package enum CECEvent {
  case connected(UInt32), sent(UInt32), generationDrained(UInt32)
  case transportFailure(UInt32, failure: CECFailure? = nil)
  case received(index: UInt32, bytes: Int, equal: Bool)
}
package enum CECAction: Equatable {
  case connect(UInt32), close(UInt32), drainTimeout(UInt32)
  case receive(index: UInt32, bytes: Int), send(index: UInt32, bytes: Int)
  package var index: UInt32 {
    switch self {
    case .connect(let index), .close(let index), .drainTimeout(let index): return index
    case .receive(let index, _), .send(let index, _): return index
    }
  }
}
// One event produces at most RX+TX or close. Value storage remains on the stack;
// nested synchronous connect/failure/drain delivery cannot overwrite its caller.
package struct CECActionBatch {
  private var storage = InlineArray<3, CECAction>(repeating: .close(0))
  package private(set) var count = 0
  package subscript(_ index: Int) -> CECAction { storage[index] }
  package mutating func append(_ action: CECAction) {
    precondition(count < 3)
    storage[count] = action
    count += 1
  }
}
package struct CECWorkerLifecycle {
  package var phase: CECWorkerPhase = .starting
  package var liveSessions: UInt32 = 0
  package var totalOutstanding: UInt32 = 0
  package var rioOutstanding: UInt32 = 0
  package var notificationArmed = false
  package var joined = true
}
package func cecWorkerMayRelease(_ value: CECWorkerLifecycle) -> Bool {
  value.phase == .stopped && value.joined && value.liveSessions == 0
    && value.totalOutstanding == 0 && value.rioOutstanding == 0
}
package func cecSessionTerminalAccountingValid(
  claimed: UInt64, echoed: UInt64, corrupted: UInt64, lost: UInt64, cancelled: UInt64 = 0
) -> Bool { claimed == echoed &+ corrupted &+ lost &+ cancelled }
package func cecNotificationMarkDelivered(_ armed: inout Bool) -> Bool {
  guard armed else { return false }
  armed = false
  return true
}
package func cecNotificationMarkRearmed(_ armed: inout Bool) -> Bool {
  guard !armed else { return false }
  armed = true
  return true
}
package func cecMillisecondsToTicks(_ milliseconds: UInt64, frequency: UInt64) -> UInt64 {
  guard frequency > 0 else { return UInt64.max }
  let product = milliseconds.multipliedFullWidth(by: frequency)
  guard product.high < 1000 else { return UInt64.max }
  let division = UInt64(1000).dividingFullWidth(product)
  return division.quotient == UInt64.max || division.remainder == 0
    ? division.quotient : division.quotient + 1
}
package func cecTicksToWaitMilliseconds(_ ticks: UInt64, frequency: UInt64) -> UInt32 {
  guard frequency > 0 else { return UInt32.max - 1 }
  let product = ticks.multipliedFullWidth(by: 1000)
  guard product.high < frequency else { return UInt32.max - 1 }
  let division = frequency.dividingFullWidth(product)
  let rounded = division.quotient == UInt64.max || division.remainder == 0
    ? division.quotient : division.quotient + 1
  return UInt32(min(rounded, UInt64(UInt32.max - 1)))
}
package func cecSaturatingDeadline(_ now: UInt64, _ delta: UInt64) -> UInt64 {
  let (value, overflow) = now.addingReportingOverflow(delta)
  return overflow ? UInt64.max : value
}

package struct CECWorkerCore: ~Copyable {
  package var sessions: CECFixedArray<CECSession>
  package var timers: CECTimerHeap
  package var metrics = CECWorkerMetricsSnapshot()
  package var liveSessions: UInt32
  package var stopping = false
  package private(set) var failure: CECFailure?
  private let options: CECOptions
  private let payloadBytes: Int
  private let frequency: UInt64
  private let timeoutTicks: UInt64
  private let intervalTicks: UInt64
  private let reconnectTicks: UInt64
  private let drainTicks: UInt64
  package init() {
    sessions = CECFixedArray(); timers = CECTimerHeap(); liveSessions = 0
    options = CECOptions(); payloadBytes = 0; frequency = 1000
    timeoutTicks = 0; intervalTicks = 0; reconnectTicks = 0; drainTicks = 5000
  }
  package init(options: CECOptions, sessionCount: UInt32, payloadBytes: Int, frequency: UInt64) throws(CECFailure) {
    self.options = options
    self.payloadBytes = payloadBytes
    self.frequency = frequency
    liveSessions = sessionCount
    sessions = try CECFixedArray(count: Int(sessionCount), repeating: CECSession())
    timers = try CECTimerHeap(capacity: sessionCount)
    timeoutTicks = cecMillisecondsToTicks(UInt64(options.timeoutSeconds) * 1000, frequency: frequency)
    intervalTicks = cecMillisecondsToTicks(UInt64(options.intervalMilliseconds), frequency: frequency)
    reconnectTicks = cecMillisecondsToTicks(UInt64(max(0, options.reconnectSeconds)) * 1000, frequency: frequency)
    drainTicks = cecMillisecondsToTicks(5000, frequency: frequency)
    for index in sessions.indices { sessions[index] = CECSession(index: UInt32(index)) }
  }
  private mutating func schedule(_ index: UInt32, _ deadline: UInt64) {
    if !timers.insertOrUpdate(sessionIndex: index, deadline: deadline) { metrics.fatal = true }
  }
  package mutating func start(index: UInt32 = 0, now: UInt64) -> CECActionBatch {
    var actions = CECActionBatch()
    guard Int(index) < sessions.count else { metrics.fatal = true; return actions }
    guard sessions[Int(index)].state == .dormant else { return actions }
    sessions[Int(index)].state = .connecting
    sessions[Int(index)].deadline = cecSaturatingDeadline(now, timeoutTicks)
    schedule(index, sessions[Int(index)].deadline)
    actions.append(.connect(index))
    return actions
  }
  package mutating func anchorPostedTimeout(index: UInt32, now: UInt64) {
    guard Int(index) < sessions.count else { metrics.fatal = true; return }
    if sessions[Int(index)].state == .active || sessions[Int(index)].state == .connecting {
      sessions[Int(index)].deadline = cecSaturatingDeadline(now, timeoutTicks)
      schedule(index, sessions[Int(index)].deadline)
    }
  }
  package mutating func anchorAttemptStarted(index: UInt32, now: UInt64) {
    guard Int(index) < sessions.count else { metrics.fatal = true; return }
    sessions[Int(index)].startedAt = now
    anchorPostedTimeout(index: index, now: now)
  }
  package mutating func anchorClose(index: UInt32, now: UInt64) {
    guard Int(index) < sessions.count, sessions[Int(index)].state == .closing else { return }
    sessions[Int(index)].deadline = cecSaturatingDeadline(now, drainTicks)
    schedule(index, sessions[Int(index)].deadline)
  }
  package borrowing func waitMilliseconds(now: UInt64, maximum: UInt32 = 1000) -> UInt32 {
    guard let deadline = timers.nextDeadline else { return maximum }
    return min(maximum, cecTicksToWaitMilliseconds(deadline > now ? deadline - now : 0, frequency: frequency))
  }
  package mutating func onEvent(_ event: CECEvent, now: UInt64) -> CECActionBatch {
    var actions = CECActionBatch()
    let index: UInt32
    switch event {
    case .connected(let value), .sent(let value), .generationDrained(let value): index = value
    case .transportFailure(let value, _): index = value
    case .received(let value, _, _): index = value
    }
    guard Int(index) < sessions.count else { metrics.fatal = true; return actions }
    let slot = Int(index)
    switch event {
    case .connected:
      guard sessions[slot].state == .connecting else { return actions }
      sessions[slot].state = .active
      if !sessions[slot].activeCounted { sessions[slot].activeCounted = true; metrics.active &+= 1 }
      metrics.connections &+= 1
      return beginAttempt(index, now: now)
    case .sent:
      guard sessions[slot].state == .active else { return actions }
      guard !sessions[slot].sendDone, sessions[slot].attemptBytes > 0 else { metrics.fatal = true; return actions }
      sessions[slot].sendDone = true
      return settleAttempt(index, now: now)
    case .received(_, let bytes, let equal):
      guard sessions[slot].state == .active else { return actions }
      guard sessions[slot].receivePosted, !sessions[slot].receiveDone, sessions[slot].attemptBytes > 0 else { metrics.fatal = true; return actions }
      guard bytes >= 0 else { failure = .invariant(stage: "client received byte count"); metrics.fatal = true; return actions }
      sessions[slot].receivePosted = false
      if options.transport == .tcp && bytes != sessions[slot].attemptBytes { return fail(index, now: now) }
      metrics.receivedBytes &+= UInt64(bytes)
      sessions[slot].receiveDone = true
      sessions[slot].receiveEqual = equal && bytes == sessions[slot].attemptBytes
      return settleAttempt(index, now: now)
    case .transportFailure(_, let reason):
      if let reason {
        failure = reason
        if reason.classification != .network { metrics.fatal = true }
      }
      guard sessions[slot].state != .closing, sessions[slot].state != .done else { return actions }
      return fail(index, now: now)
    case .generationDrained:
      guard sessions[slot].state == .closing else { return actions }
      _ = timers.remove(sessionIndex: index)
      if sessions[slot].reconnectAfterClose && !stopping {
        sessions[slot].state = .reconnecting
        sessions[slot].nextAction = cecSaturatingDeadline(now, reconnectTicks)
        schedule(index, sessions[slot].nextAction)
      } else { markDone(index) }
    }
    return actions
  }
  private mutating func beginAttempt(_ index: UInt32, now: UInt64) -> CECActionBatch {
    var actions = CECActionBatch()
    let slot = Int(index)
    _ = timers.remove(sessionIndex: index)
    var claimed = sessions[slot].claimed
    let granted = cecClaimSessionAttempts(claimed: &claimed, limit: options.echoCount,
      requested: options.transport == .tcp ? UInt64(options.pipelineDepth) : 1)
    sessions[slot].claimed = claimed
    if granted == 0 {
      sessions[slot].reconnectAfterClose = false
      sessions[slot].state = .closing
      sessions[slot].deadline = cecSaturatingDeadline(now, drainTicks)
      schedule(index, sessions[slot].deadline)
      actions.append(.close(index))
      return actions
    }
    let (bytes, overflow) = payloadBytes.multipliedReportingOverflow(by: Int(granted))
    guard !overflow, bytes > 0, bytes <= Int(UInt32.max) else { metrics.fatal = true; return actions }
    metrics.claimed &+= granted
    sessions[slot].requestedEchoes = granted
    sessions[slot].attemptBytes = bytes
    sessions[slot].sendDone = false
    sessions[slot].receiveDone = false
    sessions[slot].receivePosted = true
    sessions[slot].receiveEqual = false
    sessions[slot].attemptAccounted = false
    sessions[slot].state = .active
    sessions[slot].startedAt = now
    sessions[slot].deadline = cecSaturatingDeadline(now, timeoutTicks)
    schedule(index, sessions[slot].deadline)
    actions.append(.receive(index: index, bytes: bytes))
    actions.append(.send(index: index, bytes: bytes))
    return actions
  }
  private mutating func settleAttempt(_ index: UInt32, now: UInt64) -> CECActionBatch {
    let slot = Int(index)
    guard sessions[slot].sendDone, sessions[slot].receiveDone, !sessions[slot].receivePosted else { return CECActionBatch() }
    if sessions[slot].receiveEqual {
      metrics.echoed &+= sessions[slot].requestedEchoes
      metrics.bytes &+= UInt64(sessions[slot].attemptBytes)
    } else { metrics.corrupted &+= sessions[slot].requestedEchoes }
    sessions[slot].settled &+= sessions[slot].requestedEchoes
    sessions[slot].attemptAccounted = true
    cecRecordLatency(metrics: &metrics, ticks: now >= sessions[slot].startedAt ? now - sessions[slot].startedAt : 0, frequency: frequency)
    _ = timers.remove(sessionIndex: index)
    if intervalTicks != 0 {
      sessions[slot].state = .pacing
      sessions[slot].nextAction = cecSaturatingDeadline(now, intervalTicks)
      schedule(index, sessions[slot].nextAction)
      return CECActionBatch()
    }
    return beginAttempt(index, now: now)
  }
  private mutating func fail(_ index: UInt32, now: UInt64) -> CECActionBatch {
    let slot = Int(index)
    if sessions[slot].state == .active && !sessions[slot].attemptAccounted {
      metrics.lost &+= sessions[slot].requestedEchoes
      sessions[slot].settled &+= sessions[slot].requestedEchoes
      sessions[slot].attemptAccounted = true
    }
    metrics.networkErrors &+= 1
    sessions[slot].reconnectAfterClose = options.reconnectSeconds >= 0 && !stopping
    if sessions[slot].reconnectAfterClose { metrics.reconnects &+= 1 }
    sessions[slot].state = .closing
    sessions[slot].deadline = cecSaturatingDeadline(now, drainTicks)
    schedule(index, sessions[slot].deadline)
    var actions = CECActionBatch()
    actions.append(.close(index))
    return actions
  }
  private mutating func markDone(_ index: UInt32) {
    let slot = Int(index)
    _ = timers.remove(sessionIndex: index)
    if sessions[slot].state != .done {
      guard liveSessions > 0 else { metrics.fatal = true; return }
      liveSessions -= 1
    }
    if sessions[slot].activeCounted {
      guard metrics.active > 0 else { metrics.fatal = true; return }
      metrics.active -= 1
      sessions[slot].activeCounted = false
    }
    sessions[slot].state = .done
    sessions[slot].deadline = 0
    sessions[slot].nextAction = 0
  }
  // Stops are delivered one session at a time by Runtime; each close action has
  // its own stack batch and preserves a generation's already anchored grace.
  package mutating func stopSession(index: UInt32, now: UInt64) -> CECActionBatch {
    var actions = CECActionBatch()
    guard Int(index) < sessions.count else { return actions }
    let slot = Int(index)
    guard sessions[slot].state != .done else { return actions }
    if sessions[slot].state == .active && !sessions[slot].attemptAccounted {
      if metrics.fatal { metrics.lost &+= sessions[slot].requestedEchoes }
      else { metrics.cancelled &+= sessions[slot].requestedEchoes }
      sessions[slot].settled &+= sessions[slot].requestedEchoes
      sessions[slot].attemptAccounted = true
    }
    sessions[slot].reconnectAfterClose = false
    if sessions[slot].state != .closing {
      sessions[slot].state = .closing
      sessions[slot].deadline = cecSaturatingDeadline(now, drainTicks)
      schedule(index, sessions[slot].deadline)
    }
    actions.append(.close(index))
    return actions
  }
  package mutating func poll(now: UInt64) -> CECActionBatch {
    guard let index = timers.popExpired(now: now) else { return CECActionBatch() }
    let slot = Int(index)
    switch sessions[slot].state {
    case .active, .connecting: return fail(index, now: now)
    case .closing:
      var actions = CECActionBatch()
      actions.append(.drainTimeout(index))
      return actions
    case .pacing: return beginAttempt(index, now: now)
    case .reconnecting:
      sessions[slot].state = .dormant
      return start(index: index, now: now)
    default: return CECActionBatch()
    }
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
