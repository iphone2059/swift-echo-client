import WinSDK
import ucrt

// Native boundary invariants:
// - w and s point into the pinned worker/session owners, retained until join.
// - Only the native worker mutates session state, timers and outstanding counts.
// - RIO/ConnectEx retain contexts and buffers until the matching completion;
//   close cancels requests, and draining completes before allocation release.
// - Incoming completion addresses are range/identity checked before dereference.
// - Payload views below are synchronous and bounded by the registered arena.

// UnsafePointer.pointee is an ephemeral access. Pass configuration as a
// borrowing parameter before forming Ref; the borrow cannot outlive the call.
@inline(__always)
package func cecConnectionFailed(_ s: UnsafeMutablePointer<CECEngineSession>) {
  unsafe cecConnectionFailed(s, configuration: s.pointee.owner!.pointee.configuration)
}
@inline(__always)
package func cecPostSend(_ s: UnsafeMutablePointer<CECEngineSession>) -> Bool {
  unsafe cecPostSend(s, configuration: s.pointee.owner!.pointee.configuration)
}
@inline(__always)
package func cecInitializeWorker(_ w: UnsafeMutablePointer<CECEngineWorker>) -> Bool {
  unsafe cecInitializeWorker(w, configuration: w.pointee.configuration)
}

@inline(__always)
package func cecProcessRIOResult(_ w: UnsafeMutablePointer<CECEngineWorker>, result: RIORESULT) {
  unsafe cecProcessRIOResult(w, result: result, configuration: w.pointee.configuration)
}
@inline(__always)
package func cecStopWorker(_ w: UnsafeMutablePointer<CECEngineWorker>) {
  unsafe cecStopWorker(w, configuration: w.pointee.configuration)
}

@inline(__always)
package func cecDrainCompletions(_ w: UnsafeMutablePointer<CECEngineWorker>) {
  unsafe cecDrainCompletions(w, configuration: w.pointee.configuration)
}

private func sessions(_ w: UnsafeMutablePointer<CECEngineWorker>) -> UnsafeMutablePointer<
  CECEngineSession
> { unsafe w.pointee.sessionAddress! }
private func socketClose(_ s: UnsafeMutablePointer<CECEngineSession>) {
  unsafe s.pointee.owner!.pointee.resources.sockets[Int(s.pointee.index)].reset()
  unsafe s.pointee.socket = ~SOCKET(0)
}
private func schedule(_ s: UnsafeMutablePointer<CECEngineSession>, _ deadline: UInt64) {
  if unsafe !s.pointee.owner!.pointee.timers.insertOrUpdate(
    sessionIndex: s.pointee.index, deadline: deadline)
  {
    cecFailFast(stage: "client timer insert/update", error: 13)
  }
}
private func unschedule(_ s: UnsafeMutablePointer<CECEngineSession>) {
  _ = unsafe s.pointee.owner!.pointee.timers.remove(sessionIndex: s.pointee.index)
}
private func markDone(_ s: UnsafeMutablePointer<CECEngineSession>) {
  unsafe unschedule(s)
  unsafe socketClose(s)
  unsafe s.pointee.requestQueue = nil
  if unsafe s.pointee.state != .done {
    unsafe s.pointee.state = .done
    unsafe s.pointee.owner!.pointee.liveSessions -= 1
  }
}
private func finishClose(_ s: UnsafeMutablePointer<CECEngineSession>) {
  let w = unsafe s.pointee.owner!
  if unsafe s.pointee.reconnectAfterClose && !w.pointee.stopping {
    unsafe s.pointee.state = .reconnecting
    unsafe s.pointee.nextAction =
      unsafe GetTickCount64() + UInt64(w.pointee.configuration.options.reconnectSeconds) * 1000
    unsafe schedule(s, s.pointee.nextAction)
  } else {
    unsafe markDone(s)
  }
}
private func closeAttempt(_ s: UnsafeMutablePointer<CECEngineSession>, reconnect: Bool) {
  if unsafe s.pointee.state == .closing || s.pointee.state == .done { return }
  unsafe unschedule(s)
  unsafe s.pointee.reconnectAfterClose = reconnect
  unsafe s.pointee.state = .closing
  unsafe socketClose(s)
  if unsafe s.pointee.outstanding == 0 { unsafe finishClose(s) }
}
private func cecConnectionFailed(_ s: UnsafeMutablePointer<CECEngineSession>, configuration: borrowing CECWorkerConfiguration) {
  let w = unsafe s.pointee.owner!
  let c = unsafe Ref(configuration)
  if unsafe s.pointee.state == .active && !s.pointee.attemptAccounted {
    unsafe w.pointee.metrics.lost &+= s.pointee.requestedEchoes
    unsafe s.pointee.attemptAccounted = true
  }
  unsafe w.pointee.metrics.networkErrors &+= 1
  unsafe closeAttempt(s, reconnect: c.value.options.reconnectSeconds >= 0 && !w.pointee.stopping)
}
private func createRequestQueue(_ s: UnsafeMutablePointer<CECEngineSession>) -> Bool {
  let w = unsafe s.pointee.owner!
  let cq = unsafe w.pointee.resources.completionQueue.rawValue
  unsafe s.pointee.requestQueue = unsafe w.pointee.configuration.extensions.rio
    .RIOCreateRequestQueue!(
      s.pointee.socket, 1, 1, 1, 1, cq, cq, s)
  if unsafe s.pointee.requestQueue == nil {
    cecReport(stage: "RIOCreateRequestQueue(client)", error: WSAGetLastError())
    return false
  }
  return true
}
private func cecPostSend(_ s: UnsafeMutablePointer<CECEngineSession>, configuration: borrowing CECWorkerConfiguration) -> Bool {
  let c = unsafe Ref(configuration)
  guard unsafe s.pointee.sendOffset >= 0,
    unsafe s.pointee.sendOffset < s.pointee.attemptBytes,
    unsafe s.pointee.attemptBytes <= c.value.maximumAttemptBytes
  else { cecFailFast(stage: "client send registration extent", error: 13) }
  unsafe s.pointee.sendBuffer.Offset = unsafe UInt32(s.pointee.sendOffset)
  unsafe s.pointee.sendBuffer.Length = unsafe UInt32(
    s.pointee.attemptBytes - s.pointee.sendOffset)
  guard
    unsafe c.value.extensions.rio.RIOSend!(
      s.pointee.requestQueue, cecSendBuffer(s), 1, 0, cecSendRequest(s)
    )
    .boolValue
  else {
    cecReport(stage: "RIOSend(client)", error: WSAGetLastError())
    return false
  }
  unsafe s.pointee.outstanding += 1
  return true
}
private func postReceive(_ s: UnsafeMutablePointer<CECEngineSession>, configuration: borrowing CECWorkerConfiguration) -> Bool {
  let c = unsafe Ref(configuration)
  guard unsafe s.pointee.attemptBytes > 0,
    unsafe s.pointee.attemptBytes <= c.value.maximumAttemptBytes
  else { cecFailFast(stage: "client receive registration extent", error: 13) }
  unsafe s.pointee.receiveBuffer.Offset = 0
  unsafe s.pointee.receiveBuffer.Length = unsafe UInt32(s.pointee.attemptBytes)
  let flags: DWORD = unsafe c.value.options.transport == .tcp ? DWORD(RIO_MSG_WAITALL) : 0
  guard
    unsafe c.value.extensions.rio.RIOReceive!(
      s.pointee.requestQueue, cecReceiveBuffer(s), 1, flags, cecReceiveRequest(s)
    ).boolValue
  else {
    cecReport(stage: "RIOReceive(client)", error: WSAGetLastError())
    return false
  }
  unsafe s.pointee.outstanding += 1
  return true
}
private func beginAttempt(_ s: UnsafeMutablePointer<CECEngineSession>, configuration: borrowing CECWorkerConfiguration) -> Bool {
  let w = unsafe s.pointee.owner!
  let c = unsafe Ref(configuration)
  // The quota is spent per session: the counter is read into a local, claimed against, and written
  // back. The run-wide quota still accumulates every grant, because the final accounting compares it
  // with the sum the workers report.
  var sessionClaimed = unsafe s.pointee.claimed
  let grant = unsafe cecClaimSessionAttempts(
    claimed: &sessionClaimed, limit: c.value.options.echoCount,
    requested: c.value.options.transport == .tcp ? UInt64(c.value.options.pipelineDepth) : 1)
  unsafe s.pointee.claimed = sessionClaimed
  if grant != 0 { _ = unsafe configuration.metrics.claimed.wrappingAdd(grant, ordering: .relaxed) }
  if grant == 0 {
    unsafe markDone(s)
    return true
  }
  unsafe w.pointee.metrics.claimed &+= grant
  unsafe s.pointee.requestedEchoes = grant
  unsafe s.pointee.attemptBytes = c.value.pattern.bytes.count * Int(grant)
  unsafe s.pointee.sendOffset = 0
  unsafe s.pointee.receivedBytes = 0
  unsafe s.pointee.sendDone = false
  unsafe s.pointee.receiveDone = false
  unsafe s.pointee.attemptAccounted = false
  unsafe s.pointee.state = .active
  unsafe QueryPerformanceCounter(&s.pointee.startedAt)
  unsafe s.pointee.deadline = GetTickCount64() + UInt64(c.value.options.timeoutSeconds) * 1000
  unsafe schedule(s, s.pointee.deadline)
  return unsafe postReceive(s, configuration: configuration) && cecPostSend(s, configuration: configuration)
}
private func startSocket(_ s: UnsafeMutablePointer<CECEngineSession>, configuration: borrowing CECWorkerConfiguration) -> Bool {
  let w = unsafe s.pointee.owner!
  let c = unsafe Ref(configuration)
  unsafe s.pointee.socket = cecRegisteredSocket(transport: c.value.options.transport)
  unsafe w.pointee.resources.sockets[Int(s.pointee.index)].reset(s.pointee.socket)
  guard unsafe s.pointee.socket != ~SOCKET(0),
    unsafe cecConfigureSocket(s.pointee.socket, options: c.value.options)
  else {
    cecReport(stage: "client socket creation", error: WSAGetLastError())
    return false
  }
  var local = SOCKADDR_IN()
  local.sin_family = UInt16(AF_INET)
  local.sin_port = unsafe htons(c.value.options.localPort)
  let bound = withUnsafePointer(to: &local) {
    unsafe bind(
      s.pointee.socket, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self),
      Int32(MemoryLayout<SOCKADDR_IN>.size))
  }
  guard bound == 0 else {
    cecReport(stage: "bind(client)", error: WSAGetLastError())
    return false
  }
  var remote = unsafe c.value.remoteAddress
  if unsafe c.value.options.transport == .udp {
    let status = withUnsafePointer(to: &remote) {
      unsafe connect(
        s.pointee.socket, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self),
        Int32(MemoryLayout<SOCKADDR_IN>.size))
    }
    guard status == 0, unsafe createRequestQueue(s) else {
      cecReport(stage: "connect/RQ(UDP client)", error: WSAGetLastError())
      return false
    }
    return unsafe beginAttempt(s, configuration: configuration)
  }
  let port = unsafe w.pointee.resources.port.rawValue
  guard
    unsafe CreateIoCompletionPort(
      HANDLE(bitPattern: UInt(s.pointee.socket)), port, UInt64(UInt(bitPattern: s)), 0)
      == port
  else {
    cecReport(
      stage: "CreateIoCompletionPort(ConnectEx socket)",
      error: Int32(bitPattern: GetLastError()))
    return false
  }
  unsafe s.pointee.connectOverlapped = unsafe OVERLAPPED()
  unsafe s.pointee.state = .connecting
  unsafe s.pointee.deadline = GetTickCount64() + UInt64(c.value.options.timeoutSeconds) * 1000
  unsafe schedule(s, s.pointee.deadline)
  unsafe s.pointee.outstanding += 1
  // ConnectEx copies the remote address during this call; only OVERLAPPED is retained.
  let connected = withUnsafePointer(to: &remote) {
    unsafe c.value.extensions.connectEx!(
      s.pointee.socket, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self),
      Int32(MemoryLayout<SOCKADDR_IN>.size), nil, 0, nil, cecConnectOverlapped(s))
  }
  if !connected.boolValue && WSAGetLastError() != 997 {
    unsafe s.pointee.outstanding -= 1
    cecReport(stage: "ConnectEx", error: WSAGetLastError())
    return false
  }
  return true
}
private func completeAttempt(_ s: UnsafeMutablePointer<CECEngineSession>, configuration: borrowing CECWorkerConfiguration) {
  guard unsafe s.pointee.sendDone, unsafe s.pointee.receiveDone, unsafe s.pointee.outstanding == 0
  else { return }
  let w = unsafe s.pointee.owner!
  let c = unsafe Ref(configuration)
  guard
    let sendRange = unsafe cecAttemptBufferRange(
      offset: 0, maximumBytes: c.value.maximumAttemptBytes, count: s.pointee.attemptBytes),
    let receiveRange = unsafe cecAttemptBufferRange(
      offset: s.pointee.receiveArenaOffset, maximumBytes: c.value.maximumAttemptBytes,
      count: s.pointee.attemptBytes)
  else { cecFailFast(stage: "client comparison range", error: 13) }
  guard unsafe receiveRange.upperBound <= w.pointee.resources.arena.byteCount,
    unsafe w.pointee.resources.arena.rawValue != nil
  else { cecFailFast(stage: "client comparison allocation extent", error: 13) }
  let equal =
    unsafe s.pointee.receivedBytes == s.pointee.attemptBytes
    && (w.pointee.resources.arena.withBytes(in: sendRange) { sent in
      unsafe w.pointee.resources.arena.withBytes(in: receiveRange) { received in
        cecBytesEqual(sent, received)
      } ?? false
    } ?? false)
  var finish = LARGE_INTEGER()
  unsafe QueryPerformanceCounter(&finish)
  unsafe cecRecordLatency(
    metrics: &w.pointee.metrics,
    ticks: UInt64(max(0, finish.QuadPart - s.pointee.startedAt.QuadPart)),
    frequency: UInt64(w.pointee.performanceFrequency.QuadPart))
  if equal {
    unsafe w.pointee.metrics.echoed &+= s.pointee.requestedEchoes
    unsafe w.pointee.metrics.bytes &+= UInt64(s.pointee.attemptBytes)
  } else {
    unsafe w.pointee.metrics.corrupted &+= s.pointee.requestedEchoes
  }
  unsafe s.pointee.attemptAccounted = true
  if unsafe c.value.options.intervalMilliseconds != 0 {
    unsafe s.pointee.state = .pacing
    unsafe s.pointee.nextAction = GetTickCount64() + UInt64(c.value.options.intervalMilliseconds)
    unsafe schedule(s, s.pointee.nextAction)
  } else if unsafe !beginAttempt(s, configuration: configuration) {
    unsafe cecConnectionFailed(s, configuration: configuration)
  }
}
private func cecProcessRIOResult(_ w: UnsafeMutablePointer<CECEngineWorker>, result: RIORESULT, configuration: borrowing CECWorkerConfiguration) {
  let first = unsafe UInt(bitPattern: sessions(w))
  let stride = unsafe MemoryLayout<CECEngineSession>.stride
  let requestAddress = UInt(result.RequestContext)
  // Check allocation range and exact field identity before dereferencing native context.
  guard unsafe w.pointee.sessionRange.contains(requestAddress)
  else { cecFailFast(stage: "client RIO RequestContext range", error: 13) }
  let index = (requestAddress - first) / UInt(stride)
  let s = unsafe sessions(w).advanced(by: Int(index))
  let receive = unsafe requestAddress == UInt(bitPattern: cecReceiveRequest(s))
  let send = unsafe requestAddress == UInt(bitPattern: cecSendRequest(s))
  guard receive || send, unsafe s.pointee.owner == w else {
    cecFailFast(stage: "client RIO RequestContext identity", error: 13)
  }
  let request = unsafe receive ? cecReceiveRequest(s) : cecSendRequest(s)
  guard unsafe request.pointee.sessionIndex == UInt32(index),
    unsafe request.pointee.operation == (receive ? .receive : .send)
  else { cecFailFast(stage: "client RIO request metadata", error: 13) }
  unsafe cecRequireOutstanding(s.pointee.outstanding, stage: "client RIO outstanding count")
  unsafe s.pointee.outstanding -= 1
  if unsafe s.pointee.state == .closing {
    if unsafe s.pointee.outstanding == 0 { unsafe finishClose(s) }
    return
  }
  if result.Status != 0 {
    unsafe cecConnectionFailed(s, configuration: configuration)
    return
  }
  if send {
    let transferred = Int(result.BytesTransferred)
    guard transferred > 0, unsafe transferred <= s.pointee.attemptBytes - s.pointee.sendOffset
    else {
      unsafe cecConnectionFailed(s, configuration: configuration)
      return
    }
    unsafe s.pointee.sendOffset += transferred
    if unsafe s.pointee.sendOffset < s.pointee.attemptBytes {
      if unsafe !cecPostSend(s, configuration: configuration) { unsafe cecConnectionFailed(s, configuration: configuration) }
      return
    }
    unsafe s.pointee.sendDone = true
  } else {
    if unsafe configuration.options.transport == .tcp
      && Int(result.BytesTransferred) != s.pointee.attemptBytes
    {
      unsafe cecConnectionFailed(s, configuration: configuration)
      return
    }
    unsafe s.pointee.receivedBytes = Int(result.BytesTransferred)
    unsafe s.pointee.receiveDone = true
  }
  unsafe completeAttempt(s, configuration: configuration)
}
private func processConnect(_ s: UnsafeMutablePointer<CECEngineSession>, ok: Bool, error: DWORD, configuration: borrowing CECWorkerConfiguration) {
  unsafe cecRequireOutstanding(s.pointee.outstanding, stage: "ConnectEx outstanding count")
  unsafe s.pointee.outstanding -= 1
  if unsafe s.pointee.state == .closing {
    if unsafe s.pointee.outstanding == 0 { unsafe finishClose(s) }
    return
  }
  if unsafe !ok || setsockopt(s.pointee.socket, SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT, nil, 0) != 0
  {
    cecReport(
      stage: "ConnectEx completion", error: ok ? WSAGetLastError() : Int32(bitPattern: error))
    unsafe cecConnectionFailed(s, configuration: configuration)
    return
  }
  if unsafe !createRequestQueue(s) || !beginAttempt(s, configuration: configuration) { unsafe cecConnectionFailed(s, configuration: configuration) }
}
private func arm(_ w: UnsafeMutablePointer<CECEngineWorker>, configuration: borrowing CECWorkerConfiguration) {
  guard unsafe !w.pointee.notificationArmed else {
    cecFailFast(stage: "client duplicate notification arm", error: 5023)
  }
  unsafe w.pointee.notificationAddress!.pointee = unsafe OVERLAPPED()
  unsafe cecRequireRIONotifySuccess(
    configuration.extensions.rio.RIONotify!(
      w.pointee.resources.completionQueue.rawValue), stage: "RIONotify(client)")
  if unsafe !cecNotificationMarkRearmed(&w.pointee.notificationArmed) {
    cecFailFast(stage: "client rearm transition", error: 5023)
  }
}
private func cecDrainCompletions(_ w: UnsafeMutablePointer<CECEngineWorker>, configuration: borrowing CECWorkerConfiguration) {
  var results = InlineArray<256, RIORESULT>(repeating: RIORESULT())
  while true {
    var view = results.mutableSpan
    let count = view.withUnsafeMutableBufferPointer {
      unsafe cecRequireValidDequeueCount(
        configuration.extensions.rio.RIODequeueCompletion!(
          w.pointee.resources.completionQueue.rawValue, $0.baseAddress, 256),
        stage: "RIODequeueCompletion(client)")
    }
    if count == 0 { return }
    guard count <= 256 else { cecFailFast(stage: "client dequeue batch", error: 13) }
    for i in 0..<Int(count) { unsafe cecProcessRIOResult(w, result: results[i], configuration: configuration) }
    // Reposted attempts can keep CQ nonempty indefinitely. Service control,
    // timers and publication between batches without rearming before empty.
    unsafe serviceWorker(w, configuration: configuration)
  }
}
private func processDeadlines(_ w: UnsafeMutablePointer<CECEngineWorker>, configuration: borrowing CECWorkerConfiguration) {
  let now = GetTickCount64()
  while let index = unsafe w.pointee.timers.popExpired(now: now) {
    let s = unsafe sessions(w).advanced(by: Int(index))
    switch unsafe s.pointee.state {
    case .active, .connecting: unsafe cecConnectionFailed(s, configuration: configuration)
    case .pacing: if unsafe !beginAttempt(s, configuration: configuration) { unsafe cecConnectionFailed(s, configuration: configuration) }
    case .reconnecting:
      unsafe s.pointee.requestQueue = nil
      if unsafe !startSocket(s, configuration: configuration) { unsafe cecConnectionFailed(s, configuration: configuration) }
    default: break
    }
  }
}
private func cecStopWorker(_ w: UnsafeMutablePointer<CECEngineWorker>, configuration: borrowing CECWorkerConfiguration) {
  if unsafe w.pointee.stopping { return }
  unsafe w.pointee.stopping = true
  unsafe w.pointee.phase = .draining
  for i in unsafe 0..<Int(configuration.sessionCount) {
    let s = unsafe sessions(w).advanced(by: i)
    if unsafe s.pointee.state == .done { continue }
    if unsafe configuration.control.fatal.load(ordering: .acquiring)
      && s.pointee.state == .active && !s.pointee.attemptAccounted
    {
      unsafe w.pointee.metrics.lost &+= s.pointee.requestedEchoes
      unsafe s.pointee.attemptAccounted = true
    }
    unsafe s.pointee.reconnectAfterClose = false
    unsafe unschedule(s)
    if unsafe s.pointee.outstanding == 0 {
      unsafe markDone(s)
    } else {
      unsafe s.pointee.state = .closing
      unsafe socketClose(s)
    }
  }
}
package func cecPostWorkerStop(_ w: UnsafePointer<CECEngineWorker>) {
  let ok = unsafe PostQueuedCompletionStatus(w.pointee.resources.port.rawValue, 0, 1, nil)
  cecRequireControlPostSuccess(
    ok, error: Int32(bitPattern: GetLastError()),
    stage: "PostQueuedCompletionStatus(client stop)")
}
// Synchronized publication is infrequent (100 ms or thread exit), and its
// required class ownership stays outside the per-completion dispatch body.
@inline(never)
private func publishWorker(_ w: UnsafeMutablePointer<CECEngineWorker>) {
  unsafe w.pointee.publication.publish(w.pointee.metrics)
}
@inline(never)
private func finishWorker(
  _ w: UnsafeMutablePointer<CECEngineWorker>, configuration: borrowing CECWorkerConfiguration
) {
  unsafe publishWorker(w)
  unsafe w.pointee.publication.finished.store(true, ordering: .releasing)
  unsafe configuration.control.signalWake()
}
private func serviceWorker(
  _ w: UnsafeMutablePointer<CECEngineWorker>, configuration: borrowing CECWorkerConfiguration
) {
  if unsafe configuration.control.stopRequested.load(ordering: .acquiring)
    || configuration.control.fatal.load(ordering: .acquiring)
  {
    unsafe cecStopWorker(w, configuration: configuration)
  }
  unsafe processDeadlines(w, configuration: configuration)
  let now = GetTickCount64()
  if unsafe now >= w.pointee.nextPublication {
    unsafe publishWorker(w)
    unsafe w.pointee.nextPublication = now + 100
  }
}
@c
package func cecWorkerThread(_ parameter: UnsafeMutableRawPointer?) -> DWORD {
  let w = unsafe parameter!.assumingMemoryBound(to: CECEngineWorker.self)
  return unsafe cecRunWorker(w, configuration: w.pointee.configuration)
}
private func cecRunWorker(
  _ w: UnsafeMutablePointer<CECEngineWorker>, configuration: borrowing CECWorkerConfiguration
) -> DWORD {
  unsafe w.pointee.phase = .running
  if unsafe configuration.options.reportSeconds != 0 {
    unsafe w.pointee.nextPublication = GetTickCount64() + 100
  }
  unsafe arm(w, configuration: configuration)
  for i in unsafe 0..<Int(configuration.sessionCount) {
    let s = unsafe sessions(w).advanced(by: i)
    if unsafe !startSocket(s, configuration: configuration) { unsafe cecConnectionFailed(s, configuration: configuration) }
  }
  while unsafe w.pointee.liveSessions != 0 {
    var transferred: DWORD = 0
    var key: UInt64 = 0
    var overlap: UnsafeMutablePointer<OVERLAPPED>?
    let now = GetTickCount64()
    let publicationWait = unsafe cecDeadlineWait(now: now, deadline: w.pointee.nextPublication)
    let ok = unsafe GetQueuedCompletionStatus(
      w.pointee.resources.port.rawValue, &transferred, &key, &overlap,
      min(w.pointee.timers.waitMilliseconds(now: now), publicationWait))
    let error = ok ? 0 : GetLastError()
    let notification = unsafe w.pointee.notificationAddress!
    if unsafe overlap == notification {
      if !ok {
        cecFailFast(
          stage: "GetQueuedCompletionStatus(client notification)",
          error: Int32(bitPattern: error))
      }
      unsafe cecRequireNotificationPacket(
        key: UInt(key), overlapped: overlap, expectedKey: UInt(bitPattern: w),
        expectedOverlapped: notification, stage: "client notification key")
      if unsafe !cecNotificationMarkDelivered(&w.pointee.notificationArmed) {
        cecFailFast(stage: "client notification delivery transition", error: 5023)
      }
      unsafe cecDrainCompletions(w, configuration: configuration)
      unsafe arm(w, configuration: configuration)
    } else if unsafe overlap == nil && key == 1 {
      unsafe cecStopWorker(w, configuration: configuration)
    } else if let overlap = unsafe overlap, key > 1 {
      let candidate = UInt(key)
      let first = unsafe UInt(bitPattern: sessions(w))
      let stride = unsafe MemoryLayout<CECEngineSession>.stride
      guard unsafe w.pointee.sessionRange.contains(candidate),
        (candidate - first) % UInt(stride) == 0
      else { cecFailFast(stage: "unexpected ConnectEx completion key", error: 13) }
      let s = unsafe sessions(w).advanced(by: Int((candidate - first) / UInt(stride)))
      guard unsafe overlap == cecConnectOverlapped(s) else {
        cecFailFast(stage: "unexpected ConnectEx completion identity", error: 13)
      }
      unsafe processConnect(s, ok: ok, error: error, configuration: configuration)
    } else if unsafe !(!ok && error == WAIT_TIMEOUT && overlap == nil) {
      cecFailFast(stage: "unexpected client IOCP packet", error: Int32(bitPattern: error))
    }
    unsafe serviceWorker(w, configuration: configuration)
  }
  unsafe cecShutdownNotification(w)
  unsafe w.pointee.phase = .stopped
  // Publish completion before waking; the coordinator then joins the real thread.
  unsafe finishWorker(w, configuration: configuration)
  return unsafe configuration.control.fatal.load(ordering: .acquiring) ? 1 : 0
}
private func cecInitializeWorker(_ w: UnsafeMutablePointer<CECEngineWorker>, configuration: borrowing CECWorkerConfiguration) -> Bool {
  let c = unsafe Ref(configuration)
  guard unsafe QueryPerformanceFrequency(&w.pointee.performanceFrequency),
    unsafe w.pointee.performanceFrequency.QuadPart > 0
  else {
    cecReport(stage: "QueryPerformanceFrequency", error: Int32(bitPattern: GetLastError()))
    return false
  }
  unsafe w.pointee.resources.port.reset(CreateIoCompletionPort(HANDLE(bitPattern: -1), nil, 0, 1))
  guard unsafe w.pointee.resources.port.rawValue != nil,
    unsafe c.value.options.cqCapacity >= c.value.sessionCount * 2,
    let bytes = unsafe cecCheckedSharedStorageBytes(
      sessions: UInt64(c.value.sessionCount), workers: 1, batchBytes: UInt64(c.value.maximumAttemptBytes),
      memoryLimit: c.value.memoryShare), bytes <= UInt32.max
  else {
    cecReport(stage: "client worker IOCP/CQ/arena capacity", error: 8)
    return false
  }
  unsafe w.pointee.resources.arena.reset(
    VirtualAlloc(nil, bytes, DWORD(UInt32(MEM_RESERVE) | UInt32(MEM_COMMIT)), DWORD(UInt32(PAGE_READWRITE))),
    byteCount: Int(bytes))
  if let storage = unsafe CECPinnedStorage(
    count: Int(c.value.sessionCount), initialValue: CECEngineSession())
  {
    unsafe w.pointee.sessionAddress = unsafe storage.baseAddress
    unsafe w.pointee.resources.sessions = unsafe consume storage
  }
  if let storage = unsafe CECPinnedStorage(count: 1, initialValue: OVERLAPPED()) {
    unsafe w.pointee.notificationAddress = unsafe storage.baseAddress
    unsafe w.pointee.resources.notification = unsafe consume storage
  }
  guard let memory = unsafe w.pointee.resources.arena.rawValue,
    unsafe w.pointee.sessionAddress != nil,
    unsafe w.pointee.notificationAddress != nil
  else {
    cecReport(stage: "client worker allocation", error: 8)
    return false
  }
  unsafe w.pointee.memory = unsafe memory.assumingMemoryBound(to: UInt8.self)
  unsafe w.pointee.resources.sockets.reserveCapacity(Int(c.value.sessionCount))
  for _ in unsafe 0..<c.value.sessionCount {
    unsafe w.pointee.resources.sockets.append(CECSocketOwner())
  }
  let first = unsafe UInt(bitPattern: sessions(w))
  let (extent, extentOverflow) = unsafe UInt(MemoryLayout<CECEngineSession>.stride)
    .multipliedReportingOverflow(by: UInt(c.value.sessionCount))
  let (end, endOverflow) = first.addingReportingOverflow(extent)
  guard !extentOverflow && !endOverflow else {
    cecFailFast(stage: "client session allocation extent", error: 13)
  }
  unsafe w.pointee.sessionRange = first..<end
  // Resolve native field layouts before any request can be posted.
  _ = unsafe cecReceiveRequest(sessions(w))
  _ = unsafe cecSendRequest(sessions(w))
  _ = unsafe cecConnectOverlapped(sessions(w))
  _ = unsafe cecReceiveBuffer(sessions(w))
  _ = unsafe cecSendBuffer(sessions(w))
  guard unsafe w.pointee.resources.arena.withMutableBytes(
    in: 0..<c.value.maximumAttemptBytes, { unsafe c.value.pattern.fill(&$0) }) != nil
  else { cecFailFast(stage: "client shared pattern arena range", error: 13) }
  unsafe w.pointee.resources.registrations.reserveCapacity(Int(c.value.sessionCount) * 2)
  var notification = unsafe RIO_NOTIFICATION_COMPLETION()
  unsafe notification.Type = RIO_IOCP_COMPLETION
  unsafe notification.Iocp.IocpHandle = unsafe w.pointee.resources.port.rawValue
  unsafe notification.Iocp.CompletionKey = UnsafeMutableRawPointer(w)
  unsafe notification.Iocp.Overlapped = unsafe UnsafeMutableRawPointer(
    w.pointee.notificationAddress!)
  guard
    let cq = unsafe c.value.extensions.rio.RIOCreateCompletionQueue!(
      c.value.options.cqCapacity, &notification)
  else {
    cecReport(stage: "RIOCreateCompletionQueue(client)", error: WSAGetLastError())
    return false
  }
  unsafe w.pointee.resources.completionQueue.reset(rio: c.value.extensions.rio, value: cq)
  for i in unsafe 0..<Int(c.value.sessionCount) {
    let s = unsafe sessions(w).advanced(by: i)
    unsafe s.pointee.owner = unsafe w
    unsafe s.pointee.index = UInt32(i)
    unsafe s.pointee.receiveRequest = CECEngineRequest(
      sessionIndex: UInt32(i), operation: .receive)
    unsafe s.pointee.sendRequest = CECEngineRequest(sessionIndex: UInt32(i), operation: .send)
    unsafe s.pointee.receiveArenaOffset = (i + 1) * c.value.maximumAttemptBytes
    // Each send ID registers the same immutable physical region, but has only
    // one pending send. Receives use their own ID and disjoint writable region.
    guard let sendID = unsafe c.value.extensions.rio.RIORegisterBuffer!(
      memory.assumingMemoryBound(to: CChar.self), UInt32(c.value.maximumAttemptBytes))
    else {
      cecReport(stage: "RIORegisterBuffer(client send)", error: WSAGetLastError())
      return false
    }
    var sendOwner = unsafe CECRIORegistrationOwner()
    unsafe sendOwner.reset(rio: c.value.extensions.rio, value: sendID)
    unsafe w.pointee.resources.registrations.append(consume sendOwner)
    unsafe s.pointee.sendBuffer.BufferId = sendID
    guard let receiveID = unsafe c.value.extensions.rio.RIORegisterBuffer!(
      memory.advanced(by: s.pointee.receiveArenaOffset).assumingMemoryBound(to: CChar.self),
      UInt32(c.value.maximumAttemptBytes))
    else {
      cecReport(stage: "RIORegisterBuffer(client receive)", error: WSAGetLastError())
      return false
    }
    var receiveOwner = unsafe CECRIORegistrationOwner()
    unsafe receiveOwner.reset(rio: c.value.extensions.rio, value: receiveID)
    unsafe w.pointee.resources.registrations.append(consume receiveOwner)
    unsafe s.pointee.receiveBuffer.BufferId = receiveID
  }
  unsafe w.pointee.resources.thread.reset(CreateThread(nil, 0, cecWorkerThread, w, 0, nil))
  if unsafe w.pointee.resources.thread.rawValue == nil {
    cecReport(stage: "CreateThread(client worker)", error: Int32(bitPattern: GetLastError()))
    return false
  }
  return true
}
package func cecDestroyWorker(_ w: UnsafeMutablePointer<CECEngineWorker>) {
  if let thread = unsafe w.pointee.resources.thread.rawValue {
    guard unsafe WaitForSingleObject(thread, UInt32.max) == WAIT_OBJECT_0 else {
      cecFailFast(stage: "client worker join", error: Int32(bitPattern: GetLastError()))
    }
    var outstanding: UInt32 = 0
    for i in unsafe 0..<Int(w.pointee.configuration.sessionCount) {
      unsafe outstanding += sessions(w)[i].outstanding
    }
    let life = unsafe CECWorkerLifecycle(
      phase: w.pointee.phase, liveSessions: w.pointee.liveSessions,
      totalOutstanding: outstanding, notificationArmed: w.pointee.notificationArmed)
    guard cecWorkerMayRelease(life), unsafe w.pointee.timers.size == 0 else {
      cecFailFast(stage: "client worker release precondition", error: 5023)
    }
    unsafe w.pointee.resources.thread.reset()
  }
  for i in unsafe 0..<w.pointee.resources.sockets.count {
    unsafe w.pointee.resources.sockets[i].reset()
  }
  unsafe w.pointee.resources.completionQueue.reset()
  unsafe w.pointee.resources.registrations = UniqueArray()
  unsafe w.pointee.resources.arena.reset()
  unsafe w.pointee.memory = nil
  unsafe w.pointee.resources.sockets = UniqueArray()
  unsafe w.pointee.resources.sessions = nil
  unsafe w.pointee.resources.notification = nil
  unsafe w.pointee.sessionRange = 0..<0
  unsafe w.pointee.sessionAddress = nil
  unsafe w.pointee.notificationAddress = nil
  unsafe w.pointee.timers = CECTimerHeap(capacity: 0)
  unsafe w.pointee.resources.port.reset()
}

package func cecShutdownNotification(_ w: UnsafeMutablePointer<CECEngineWorker>) {
  if unsafe w.pointee.notificationArmed {
    let notification = unsafe w.pointee.notificationAddress!
    let posted = unsafe PostQueuedCompletionStatus(
      w.pointee.resources.port.rawValue, 0, 0, notification)
    cecRequireControlPostSuccess(
      posted, error: Int32(bitPattern: GetLastError()),
      stage: "client notification shutdown post")
    var transferred: DWORD = 0
    var key: UInt64 = 0
    var overlap: UnsafeMutablePointer<OVERLAPPED>?
    let deadline = GetTickCount64() + 1000
    while true {
      let now = GetTickCount64()
      if now >= deadline { cecFailFast(stage: "client notification shutdown timeout", error: 1460) }
      guard
        unsafe GetQueuedCompletionStatus(
          w.pointee.resources.port.rawValue, &transferred, &key, &overlap, UInt32(deadline - now))
      else {
        cecFailFast(
          stage: "client notification shutdown wait", error: Int32(bitPattern: GetLastError()))
      }
      // The coordinator can post its one stop packet while the worker is
      // finishing its final completion. With no live session, it has no effect.
      if unsafe key == 1 && overlap == nil { continue }
      break
    }
    unsafe cecRequireNotificationPacket(
      key: UInt(key), overlapped: overlap, expectedKey: 0, expectedOverlapped: notification,
      stage: "client notification shutdown packet")
    if unsafe !cecNotificationMarkDelivered(&w.pointee.notificationArmed) {
      cecFailFast(stage: "client shutdown transition", error: 5023)
    }
  }
}