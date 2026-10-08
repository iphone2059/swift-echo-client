import WinSDK

// Configuration is immutable. Live reports read only Mutex-published snapshots;
// mutable native worker state is read by the coordinator only after thread join.
package func cecRunClient(options: borrowing CECOptions, control: CECSharedControl) -> CECExitCode {
  let wakeError = control.prepareWake()
  guard wakeError == 0 else {
    cecReport(stage: "client coordinator event", error: wakeError)
    return .internalFailure
  }
  do {
    let winsock = try CECWinSockOwner()
    let result = runStarted(options: options, control: control)
    winsock.keepAlive()
    return result
  } catch {
    cecReport(stage: error.stage, error: error.code)
    return .network
  }
}
private func runStarted(options: borrowing CECOptions, control: CECSharedControl) -> CECExitCode {
  let extensions: CECNativeExtensions
  let remote: SOCKADDR_IN
  do {
    unsafe extensions = unsafe try cecLoadExtensions()
    remote = try cecResolveIPv4(hostUTF16: options.hostUTF16, port: options.remotePort)
  } catch {
    cecReport(stage: error.stage, error: error.code)
    return .network
  }
  let pattern: CECPatternStorage
  do { pattern = CECPatternStorage(try cecBuildPattern(options: options)) } catch {
    cecReport(stage: "payload pattern", error: 13)
    return .usage
  }
  guard let maximum = cecMaximumAttemptBytes(
    options: options, patternBytes: UInt64(pattern.bytes.count))
  else {
    cecReport(
      stage: options.transport == .udp ? "payload pattern" : "payload batch size",
      error: options.transport == .udp ? 13 : 534)
    return .usage
  }
  // The contract owns the split, so the parser's capacity budgets and the run's actual shard can
  // never disagree about how many workers and sessions exist.
  let count = UInt32(
    cecResolveWorkerCount(configured: options.workerCount, sessions: options.sessionCount))
  guard cecCheckedSharedStorageBytes(
    sessions: UInt64(options.sessionCount), workers: UInt64(count),
    batchBytes: maximum, memoryLimit: options.memoryBytes) != nil
  else {
    cecReport(stage: "registered storage /memory limit", error: 8)
    return .usage
  }
  let quota = CECEngineMetrics()
  var workers = unsafe UniqueArray<CECWorkerOwner>()
  unsafe workers.reserveCapacity(Int(count))
  var remaining = options.sessionCount
  for index in 0..<count {
    let left = count - index
    let sessions = (remaining + left - 1) / left
    let config = unsafe CECWorkerConfiguration(
      options: copy options, remoteAddress: remote, extensions: extensions, pattern: pattern,
      maximumAttemptBytes: Int(maximum), metrics: quota, control: control, workerIndex: index,
      sessionCount: sessions, memoryShare: (UInt64(sessions) + 1) * maximum)
    let owner = unsafe CECWorkerOwner(configuration: config)
    if unsafe !cecInitializeWorker(owner.baseAddress) {
      control.fatal.store(true, ordering: .releasing)
      control.signalWake()
      break
    }
    unsafe workers.append(consume owner)
    remaining -= sessions
  }
  let start = GetTickCount64()
  let stopDeadline =
    options.runSeconds == 0 ? UInt64.max : start + UInt64(options.runSeconds) * 1000
  var nextReport =
    options.reportSeconds == 0 ? UInt64.max : start + UInt64(options.reportSeconds) * 1000
  var sentStops = false
  var finished = InlineArray<64, Bool>(repeating: false)
  while true {
    // Reset before checking predicates: an earlier wake is reflected in the
    // published flags, and a later wake remains signaled during the wait.
    control.resetWake()
    let now = GetTickCount64()
    if now >= stopDeadline { control.stopRequested.store(true, ordering: .releasing) }
    if now >= nextReport {
      var snapshot = CECWorkerMetricsSnapshot()
      for i in unsafe 0..<workers.count {
        unsafe snapshot.merge(workers[i].baseAddress.pointee.publication.read())
      }
      print(cecMetricsLine(
        phase: "report", options: options, metrics: snapshot, elapsedMilliseconds: now - start))
      nextReport = now + UInt64(options.reportSeconds) * 1000
    }
    if !sentStops
      && (control.fatal.load(ordering: .acquiring)
        || control.stopRequested.load(ordering: .acquiring))
    {
      for i in unsafe 0..<workers.count { unsafe cecPostWorkerStop(workers[i].baseAddress) }
      sentStops = true
    }
    var done = true
    for i in unsafe 0..<workers.count {
      if !finished[i] {
        finished[i] = unsafe workers[i].baseAddress.pointee.publication.finished.load(ordering: .acquiring)
      }
      if !finished[i] {
        done = false
      }
    }
    if done { break }
    // After cancellation the run deadline no longer supplies a timeout.
    let deadline = sentStops ? nextReport : min(nextReport, stopDeadline)
    control.waitWake(cecDeadlineWait(now: now, deadline: deadline))
  }
  var final = CECWorkerMetricsSnapshot()
  for i in unsafe 0..<workers.count {
    unsafe cecDestroyWorker(workers[i].baseAddress)
    unsafe final.merge(workers[i].baseAddress.pointee.metrics)
  }
  if options.echoCount != 0 && quota.claimed.load(ordering: .relaxed) != final.claimed {
    cecFailFast(stage: "client final quota accounting", error: 13)
  }
  let controlledStop = control.stopRequested.load(ordering: .acquiring)
  if !controlledStop && !cecSessionTerminalAccountingValid(
    claimed: final.claimed, echoed: final.echoed, corrupted: final.corrupted, lost: final.lost)
  {
    cecFailFast(stage: "client final claimed accounting", error: 13)
  }
  // /n is a per-session quota, so the run the command line describes is /n times the session
  // count; a run that never connected therefore reports the whole size as never claimed.
  final.lost &+= cecUnclaimedEchoes(
    limit: options.echoCount * UInt64(options.sessionCount), claimed: final.claimed,
    controlledStop: controlledStop)
  if !options.quiet || options.stats {
    print(cecMetricsLine(
      phase: "final", options: options, metrics: final,
      elapsedMilliseconds: GetTickCount64() - start))
  }
  return cecClassifyResult(
    echoed: final.echoed, corrupted: final.corrupted, lost: final.lost,
    networkErrors: final.networkErrors, fatal: control.fatal.load(ordering: .acquiring),
    controlledStop: controlledStop)
}
