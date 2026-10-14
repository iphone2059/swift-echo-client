import WinSDK
import ucrt

// This statically specialized bridge alone connects business and provider state.

// These pointer projections last only for the synchronous call; the worker and
// all externally borrowed allocations remain pinned throughout the real thread.

// Coordinator and release boundaries retain all pinned owners until every worker joins.

// This shared coordinator barrier is also exercised by subprocess fault fixtures.

@unsafe
package struct CECWorkerConfiguration: ~Copyable {
  package let options: CECOptions
  package let remoteAddress: SOCKADDR_IN
  package let extensions: CECNativeExtensions
  private let patternStorage: CECPatternStorage?
  package var pattern: CECPatternStorage? { borrow { unsafe patternStorage } }
  package let payloadBytes: Int
  package let maximumAttemptBytes: Int
  private let controlStorage: CECSharedControl
  package var control: CECSharedControl { borrow { unsafe controlStorage } }
  package let workerIndex: UInt32
  package let sessionCount: UInt32
  package let memoryShare: UInt64
  package init(
    options: CECOptions, remoteAddress: SOCKADDR_IN, extensions: CECNativeExtensions,
    pattern: CECPatternStorage?, maximumAttemptBytes: Int, metrics: CECEngineMetrics? = nil,
    control: CECSharedControl, workerIndex: UInt32, sessionCount: UInt32, memoryShare: UInt64,
    payloadBytes: Int? = nil
  ) {
    unsafe self.options = options
    unsafe self.remoteAddress = remoteAddress
    unsafe self.extensions = extensions
    unsafe patternStorage = pattern
    unsafe self.payloadBytes = payloadBytes ?? pattern?.bytes.count ?? 0
    unsafe self.maximumAttemptBytes = maximumAttemptBytes
    unsafe controlStorage = control
    unsafe self.workerIndex = workerIndex
    unsafe self.sessionCount = sessionCount
    unsafe self.memoryShare = memoryShare
  }
}
@unsafe
package struct CECEngineWorkerResources: ~Copyable {
  package var thread = unsafe CECHandleOwner()
  package var port = unsafe CECHandleOwner()
  package var arena = unsafe CECVirtualArenaOwner()
  package var completionQueue = unsafe CECRIOCQOwner()
  package var sessions: CECPinnedStorage<CECEngineSession>?
  package var notification: CECPinnedStorage<OVERLAPPED>?
  package var registrationIDs: CECPinnedStorage<RIO_BUFFERID?>?
  package var registeredCount = 0
  package init() {}
  package borrowing func requireProviderRelease() {
    _ = unsafe cecWithOptionalBorrow(sessions) { storage in
      for index in unsafe 0..<storage.count {
        if unsafe storage.baseAddress[index].outstanding != 0 {
          cecFailFast(stage: "client worker release precondition", error: 996)
        }
      }
    }
  }
  package borrowing func requireStorageRetired() {
    // These resources have dependencies that raw member deinitialization cannot
    // order. Their owning worker must close/deregister them explicitly first.
    guard unsafe thread.rawValue == nil, unsafe port.rawValue == nil,
      unsafe completionQueue.rawValue == nil, unsafe registeredCount == 0
    else {
      cecFailFast(stage: "client worker release precondition", error: 5023)
    }
    _ = unsafe cecWithOptionalBorrow(sessions) { storage in
      for index in unsafe 0..<storage.count {
        guard unsafe storage.baseAddress[index].socket == ~SOCKET(0),
          unsafe storage.baseAddress[index].requestQueue == nil
        else {
          cecFailFast(stage: "client worker release precondition", error: 5023)
        }
      }
    }
    _ = unsafe cecWithOptionalBorrow(registrationIDs) { storage in
      for index in unsafe 0..<storage.count {
        if unsafe storage.baseAddress[index] != nil {
          cecFailFast(stage: "client worker release precondition", error: 5023)
        }
      }
    }
  }
  deinit {
    unsafe requireProviderRelease()
    unsafe requireStorageRetired()
  }
}
@unsafe
package struct CECRioTransport: ~Copyable {
  package var resources = unsafe CECEngineWorkerResources()
  package var sessionAddress: UnsafeMutablePointer<CECEngineSession>?
  package var notificationAddress: UnsafeMutablePointer<OVERLAPPED>?
  package var memory: UnsafeMutablePointer<UInt8>?
  package var sessionRange: Range<UInt> = 0..<0
  package var totalOutstanding: UInt32 = 0
  package var rioOutstanding: UInt32 = 0
  package var sentBytes: UInt64 = 0
  package var notificationArmed = false
  package var notifyArms: UInt64 = 0
  package var notifyDeliveries: UInt64 = 0
  package var notifyTimeoutWakeups: UInt64 = 0
  package init() {}
  package borrowing func requireRelease() {
    unsafe resources.requireProviderRelease()
    if let address = unsafe sessionAddress {
      guard
        unsafe cecWithOptionalBorrow(
          resources.sessions,
          { storage in
            unsafe storage.baseAddress == address
          }) == true
      else {
        cecFailFast(stage: "client worker release precondition", error: 996)
      }
    }
    guard unsafe totalOutstanding == 0, unsafe rioOutstanding == 0 else {
      cecFailFast(stage: "client worker release precondition", error: 996)
    }
    guard unsafe notifyArms >= notifyDeliveries, unsafe notifyArms - notifyDeliveries <= 1,
      unsafe notificationArmed == (notifyArms != notifyDeliveries)
    else {
      cecFailFast(stage: "client notification accounting", error: 5023)
    }
  }
  deinit {
    unsafe requireRelease()
    unsafe resources.requireStorageRetired()
  }
}
@unsafe
package struct CECEngineWorker: ~Copyable {
  fileprivate var configurationStorage: CECWorkerConfiguration
  package var configuration: CECWorkerConfiguration { borrow { unsafe configurationStorage } }
  package var transport = unsafe CECRioTransport()
  package var core: CECWorkerCore
  package var phase: CECWorkerPhase = .starting
  package var started = false
  package var joined = false
  package var released = false
  package var preparationFailure: CECFailure?
  package var performanceFrequency = LARGE_INTEGER()
  private let publicationStorage = CECWorkerPublication()
  package var publication: CECWorkerPublication { borrow { unsafe publicationStorage } }
  package var nextPublication: UInt64 = 0
  package var resources: CECEngineWorkerResources {
    borrow { unsafe transport.resources }
    mutate { unsafe &transport.resources }
  }
  package var timers: CECTimerHeap {
    borrow { unsafe core.timers }
    mutate { unsafe &core.timers }
  }
  package var metrics: CECWorkerMetricsSnapshot {
    get { unsafe core.metrics }
    set { unsafe core.metrics = newValue }
  }
  package var liveSessions: UInt32 {
    get { unsafe core.liveSessions }
    set { unsafe core.liveSessions = newValue }
  }
  package var stopping: Bool {
    get { unsafe core.stopping }
    set { unsafe core.stopping = newValue }
  }
  package var sessionAddress: UnsafeMutablePointer<CECEngineSession>? {
    get { unsafe transport.sessionAddress }
    set { unsafe transport.sessionAddress = newValue }
  }
  package var notificationAddress: UnsafeMutablePointer<OVERLAPPED>? {
    get { unsafe transport.notificationAddress }
    set { unsafe transport.notificationAddress = newValue }
  }
  package var sessionRange: Range<UInt> {
    get { unsafe transport.sessionRange }
    set { unsafe transport.sessionRange = newValue }
  }
  package var memory: UnsafeMutablePointer<UInt8>? {
    get { unsafe transport.memory }
    set { unsafe transport.memory = newValue }
  }
  package var notificationArmed: Bool {
    get { unsafe transport.notificationArmed }
    set { unsafe transport.notificationArmed = newValue }
  }
  package init(configuration: consuming CECWorkerConfiguration) {
    unsafe core = CECWorkerCore()
    unsafe configurationStorage = consume configuration
  }
  package borrowing func requireRelease() {
    unsafe transport.requireRelease()
    if unsafe started {
      guard unsafe joined, unsafe phase == .stopped, unsafe core.liveSessions == 0,
        unsafe core.timers.size == 0, unsafe core.metrics.active == 0
      else {
        cecFailFast(stage: "client worker release precondition", error: 5023)
      }
      #if DEBUG
        if unsafe transport.notifyTimeoutWakeups != 0 {
          cecFailFast(stage: "client notification starvation", error: 5023)
        }
      #endif
    }
  }
  deinit { unsafe requireRelease() }
}
@unsafe
package struct CECWorkerOwner: ~Copyable {
  package let baseAddress: UnsafeMutablePointer<CECEngineWorker>
  private let nativeHeap: Bool
  package init(configuration: consuming CECWorkerConfiguration) {
    // Cold fixture constructor; production prepares fallible HeapAlloc storage.
    unsafe nativeHeap = false
    unsafe baseAddress = .allocate(capacity: 1)
    unsafe baseAddress.initialize(to: CECEngineWorker(configuration: consume configuration))
  }
  package init(preparedConfiguration: consuming CECWorkerConfiguration) throws(CECFailure) {
    guard
      let raw = unsafe HeapAlloc(GetProcessHeap(), 0, UInt64(MemoryLayout<CECEngineWorker>.stride))
    else { throw .allocation(stage: "client worker allocation") }
    unsafe nativeHeap = true
    unsafe baseAddress = raw.bindMemory(to: CECEngineWorker.self, capacity: 1)
    unsafe baseAddress.initialize(to: CECEngineWorker(configuration: consume preparedConfiguration))
  }
  deinit {
    unsafe cecDestroyWorker(baseAddress)
    unsafe baseAddress.deinitialize(count: 1)
    if unsafe nativeHeap {
      unsafe HeapFree(GetProcessHeap(), 0, baseAddress)
    } else {
      unsafe baseAddress.deallocate()
    }
  }
}
package struct CECCompletion {
  package var index: UInt32
  package var generation: UInt32
  package var operation: CECEngineOperation
  package var status: Int32 = 0
  package var bytes = 0
  package var failureStage: CECCompletionFailureStage = .completion
}
package struct CECPosted {
  package var completion: CECCompletion?
  package var postedAt: UInt64?
}
package enum CECPostResult {
  case success(CECPosted)
  case failure(CECNativeError)
}
package protocol CECWorkerClock { func nowTicks() -> UInt64 }
extension CECNativeClock: CECWorkerClock {}
package protocol CECWorkerTransport: ~Copyable {
  func isLive(_ completion: CECCompletion) -> Bool
  func sendBytes() -> UInt64
  func compareReceive(index: UInt32, generation: UInt32, bytes: Int, expected: Int) -> Bool
  mutating func connect(_ index: UInt32) -> CECPostResult
  mutating func connected(_ completion: CECCompletion) -> CECPostResult
  mutating func receive(_ index: UInt32, bytes: Int) -> CECPostResult
  mutating func send(_ index: UInt32, bytes: Int) -> CECPostResult
  mutating func close(_ index: UInt32) -> CECPostResult
  mutating func drainTimeout(_ index: UInt32) -> CECPostResult
}
@unsafe
package struct CECWorkerRuntime<T: CECWorkerTransport & ~Copyable, C: CECWorkerClock>: ~Copyable {
  package let core: UnsafeMutablePointer<CECWorkerCore>
  package var transport: T
  package var clock: C
  package var stopPacketSeen = false
  package mutating func deliver(_ event: CECEvent) {
    let actions = unsafe core.pointee.onEvent(event, now: clock.nowTicks())
    unsafe dispatch(actions)
  }
  package mutating func handleCompletion(_ completion: CECCompletion) {
    guard unsafe Int(completion.index) < core.pointee.sessions.count else {
      cecFailFast(stage: "client completion index", error: 13)
    }
    unsafe core.pointee.metrics.sentBytes = transport.sendBytes()
    let live = unsafe transport.isLive(completion)
    if completion.operation == .generationDrained {
      unsafe deliver(.generationDrained(completion.index))
      return
    }
    guard live else { return }
    if completion.status != 0 {
      unsafe deliver(
        .transportFailure(
          completion.index,
          failure: CECFailure(
            classification: .network,
            domain: .winsock,
            stage: completion.failureStage == .sendPost
              ? "RIOSend(client)"
              : (completion.operation == .connect ? "ConnectEx completion" : "RIO completion"),
            code: completion.status, category: .connection, retryable: true)))
      return
    }
    switch completion.operation {
    case .connect:
      switch unsafe transport.connected(completion) {
      case .success: unsafe deliver(.connected(completion.index))
      case .failure(let failure):
        cecReport(stage: failure.stage, error: failure.code)
        unsafe deliver(.transportFailure(completion.index, failure: failure.failure))
      }
    case .send:
      if unsafe completion.bytes != core.pointee.sessions[Int(completion.index)].attemptBytes {
        unsafe deliver(.transportFailure(completion.index))
      } else {
        unsafe deliver(.sent(completion.index))
      }
    case .receive:
      let expected = unsafe core.pointee.sessions[Int(completion.index)].attemptBytes
      let equal = unsafe transport.compareReceive(
        index: completion.index, generation: completion.generation, bytes: completion.bytes,
        expected: expected)
      unsafe deliver(.received(index: completion.index, bytes: completion.bytes, equal: equal))
    case .generationDrained: break
    }
  }
  package mutating func dispatch(_ actions: CECActionBatch) {
    var failed: UInt32?
    for position in 0..<actions.count {
      let action = actions[position]
      if failed == action.index { continue }
      let result: CECPostResult
      switch action {
      case .connect(let index): unsafe result = transport.connect(index)
      case .receive(let index, let bytes):
        unsafe core.pointee.anchorAttemptStarted(index: index, now: clock.nowTicks())
        unsafe result = transport.receive(index, bytes: bytes)
      case .send(let index, let bytes): unsafe result = transport.send(index, bytes: bytes)
      case .close(let index): unsafe result = transport.close(index)
      case .drainTimeout(let index): unsafe result = transport.drainTimeout(index)
      }
      unsafe core.pointee.metrics.sentBytes = transport.sendBytes()
      switch result {
      case .success(let posted):
        if let at = posted.postedAt {
          switch action {
          case .connect(let index): unsafe core.pointee.anchorPostedTimeout(index: index, now: at)
          case .receive(let index, _):
            unsafe core.pointee.anchorAttemptStarted(index: index, now: at)
          case .close(let index): unsafe core.pointee.anchorClose(index: index, now: at)
          default: break
          }
        }
        if let completion = posted.completion { unsafe handleCompletion(completion) }
      case .failure(let failure):
        cecReport(stage: failure.stage, error: failure.code)
        failed = action.index
        unsafe deliver(.transportFailure(action.index, failure: failure.failure))
      }
    }
  }
  package mutating func start() {
    for index in unsafe 0..<UInt32(core.pointee.sessions.count) {
      unsafe dispatch(core.pointee.start(index: index, now: clock.nowTicks()))
    }
  }
  package mutating func beginStop(fatal: Bool) {
    if unsafe core.pointee.stopping { return }
    unsafe core.pointee.stopping = true
    if fatal { unsafe core.pointee.metrics.fatal = true }
    for index in unsafe 0..<UInt32(core.pointee.sessions.count) {
      unsafe dispatch(core.pointee.stopSession(index: index, now: clock.nowTicks()))
    }
  }
  package mutating func poll(now: UInt64) {
    while unsafe core.pointee.waitMilliseconds(now: now, maximum: 1) == 0 {
      let actions = unsafe core.pointee.poll(now: now)
      if actions.count == 0 { break }
      unsafe dispatch(actions)
    }
  }
}
@unsafe
package struct CECRioAdapter: CECWorkerTransport {
  package let native: UnsafeMutablePointer<CECRioTransport>
  package let configuration: UnsafePointer<CECWorkerConfiguration>
  package let ownerKey: UInt
  package let clock: CECNativeClock
  package init(
    native: UnsafeMutablePointer<CECRioTransport>,
    configuration: UnsafePointer<CECWorkerConfiguration>, ownerKey: UInt, clock: CECNativeClock
  ) {
    unsafe self.native = native
    unsafe self.configuration = configuration
    unsafe self.ownerKey = ownerKey
    unsafe self.clock = clock
  }
  private func slot(_ index: UInt32) -> UnsafeMutablePointer<CECEngineSession> {
    guard unsafe index < configuration.pointee.sessionCount,
      let first = unsafe native.pointee.sessionAddress
    else {
      cecFailFast(stage: "client transport session index", error: 13)
    }
    return unsafe first.advanced(by: Int(index))
  }
  package func sendBytes() -> UInt64 { unsafe native.pointee.sentBytes }
  package func isLive(_ completion: CECCompletion) -> Bool {
    let entry = unsafe slot(completion.index)
    guard unsafe entry.pointee.generation == completion.generation else {
      cecFailFast(stage: "client completion generation", error: 13)
    }
    return unsafe !entry.pointee.closing
  }
  package func compareReceive(index: UInt32, generation: UInt32, bytes: Int, expected: Int) -> Bool
  {
    let entry = unsafe slot(index)
    guard unsafe entry.pointee.generation == generation, bytes >= 0,
      unsafe bytes == entry.pointee.completedReceiveBytes,
      unsafe expected <= configuration.pointee.maximumAttemptBytes
    else { cecFailFast(stage: "client completion byte view", error: 13) }
    if bytes != expected { return false }
    let send = unsafe entry.pointee.sendArenaOffset..<(entry.pointee.sendArenaOffset + expected)
    let receive =
      unsafe entry.pointee.receiveArenaOffset..<(entry.pointee.receiveArenaOffset + bytes)
    guard
      let equal = unsafe native.pointee.resources.arena.withBytes(
        in: send,
        { sent in
          unsafe native.pointee.resources.arena.withBytes(in: receive) { received in
            cecBytesEqual(sent, received)
          }
        }), let equal
    else { cecFailFast(stage: "client comparison allocation extent", error: 13) }
    return equal
  }
  private func socketClose(_ entry: UnsafeMutablePointer<CECEngineSession>) {
    if unsafe entry.pointee.socket != ~SOCKET(0) { unsafe closesocket(entry.pointee.socket) }
    unsafe entry.pointee.socket = ~SOCKET(0)
  }
  private func drained(_ index: UInt32) -> CECCompletion? {
    let entry = unsafe slot(index)
    guard unsafe entry.pointee.closing, unsafe entry.pointee.outstanding == 0,
      unsafe !entry.pointee.drainReported
    else { return nil }
    unsafe entry.pointee.drainReported = true
    return unsafe CECCompletion(
      index: index, generation: entry.pointee.generation, operation: .generationDrained)
  }
  package mutating func close(_ index: UInt32) -> CECPostResult {
    let entry = unsafe slot(index)
    let first = unsafe !entry.pointee.closing
    let at: UInt64? = unsafe first ? clock.nowTicks() : nil
    if let at { unsafe entry.pointee.closeStartedAt = at }
    unsafe entry.pointee.closing = true
    unsafe socketClose(entry)
    return .success(CECPosted(completion: unsafe drained(index), postedAt: at))
  }
  package mutating func drainTimeout(_ index: UInt32) -> CECPostResult {
    if unsafe slot(index).pointee.outstanding != 0 {
      cecFailFast(stage: "client generation drain", error: 1460)
    }
    return .success(CECPosted(completion: unsafe drained(index)))
  }
  private func createRequestQueue(_ index: UInt32) -> CECNativeError? {
    let entry = unsafe slot(index)
    unsafe entry.pointee.requestQueue = configuration.pointee.extensions.rio.RIOCreateRequestQueue!(
      entry.pointee.socket,
      1, 1, 1, 1, native.pointee.resources.completionQueue.rawValue,
      native.pointee.resources.completionQueue.rawValue, entry)
    return unsafe entry.pointee.requestQueue == nil
      ? CECNativeError(
        stage: "RIOCreateRequestQueue(client)", code: WSAGetLastError(), retryable: true) : nil
  }
  package mutating func connect(_ index: UInt32) -> CECPostResult {
    let entry = unsafe slot(index)
    guard unsafe entry.pointee.outstanding == 0 else {
      cecFailFast(stage: "client generation reset", error: 996)
    }
    unsafe socketClose(entry)
    unsafe entry.pointee.generation &+= 1
    if unsafe entry.pointee.generation == 0 { unsafe entry.pointee.generation = 1 }
    unsafe entry.pointee.closing = false
    unsafe entry.pointee.drainReported = false
    unsafe entry.pointee.requestQueue = nil
    unsafe entry.pointee.sendOffset = 0
    unsafe entry.pointee.socket = cecRegisteredSocket(
      transport: configuration.pointee.options.transport)
    guard unsafe entry.pointee.socket != ~SOCKET(0) else {
      return .failure(
        CECNativeError(stage: "client socket creation", code: WSAGetLastError(), retryable: true))
    }
    do {
      unsafe try cecConfigureSocketChecked(
        entry.pointee.socket, options: configuration.pointee.options)
    } catch { return .failure(error) }
    var local = SOCKADDR_IN()
    local.sin_family = UInt16(AF_INET)
    local.sin_port = unsafe htons(configuration.pointee.options.localPort)
    let bound = withUnsafePointer(to: &local) {
      unsafe bind(
        entry.pointee.socket, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self),
        Int32(MemoryLayout<SOCKADDR_IN>.size))
    }
    if bound != 0 {
      return .failure(
        CECNativeError(stage: "bind(client)", code: WSAGetLastError(), retryable: true))
    }
    var remote = unsafe configuration.pointee.remoteAddress
    if unsafe configuration.pointee.options.transport == .udp {
      let connected = withUnsafePointer(to: &remote) {
        unsafe WinSDK.connect(
          entry.pointee.socket, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self),
          Int32(MemoryLayout<SOCKADDR_IN>.size))
      }
      if connected != 0 {
        return .failure(
          CECNativeError(stage: "connect/RQ(UDP client)", code: WSAGetLastError(), retryable: true))
      }
      if let failure = unsafe createRequestQueue(index) {
        cecReport(stage: failure.stage, error: failure.code)
        return .failure(
          CECNativeError(stage: "connect/RQ(UDP client)", code: failure.code, retryable: true))
      }
      return unsafe .success(
        CECPosted(
          completion: CECCompletion(
            index: index,
            generation: entry.pointee.generation, operation: .connect), postedAt: clock.nowTicks()))
    }
    let port = unsafe native.pointee.resources.port.rawValue
    guard
      unsafe CreateIoCompletionPort(
        HANDLE(bitPattern: UInt(entry.pointee.socket)), port,
        CECRioContext.encode(
          index: index, generation: entry.pointee.generation, operation: .connect), 0) == port
    else {
      return .failure(
        CECNativeError(
          stage: "CreateIoCompletionPort(ConnectEx socket)",
          code: Int32(bitPattern: GetLastError()), domain: .win32, retryable: true))
    }
    unsafe entry.pointee.connectOverlapped = OVERLAPPED()
    unsafe entry.pointee.connectOutstanding = true
    let at = unsafe clock.nowTicks()
    let posted = withUnsafePointer(to: &remote) {
      unsafe configuration.pointee.extensions.connectEx!(
        entry.pointee.socket,
        UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self),
        Int32(MemoryLayout<SOCKADDR_IN>.size), nil, 0, nil, cecConnectOverlapped(entry))
    }
    let error = posted.boolValue ? 0 : WSAGetLastError()
    if !posted.boolValue && error != 997 {
      unsafe entry.pointee.connectOutstanding = false
      return .failure(CECNativeError(stage: "ConnectEx", code: error, retryable: true))
    }
    unsafe native.pointee.totalOutstanding += 1
    return .success(CECPosted(postedAt: at))
  }
  package mutating func connected(_ completion: CECCompletion) -> CECPostResult {
    let entry = unsafe slot(completion.index)
    if unsafe configuration.pointee.options.transport == .tcp {
      if unsafe setsockopt(entry.pointee.socket, SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT, nil, 0) != 0
      {
        return .failure(
          CECNativeError(stage: "ConnectEx completion", code: WSAGetLastError(), retryable: true))
      }
      if let failure = unsafe createRequestQueue(completion.index) { return .failure(failure) }
    }
    return .success(CECPosted())
  }
  package mutating func receive(_ index: UInt32, bytes: Int) -> CECPostResult {
    let entry = unsafe slot(index)
    guard unsafe !entry.pointee.closing, unsafe !entry.pointee.receiveOutstanding, bytes > 0,
      unsafe bytes <= configuration.pointee.maximumAttemptBytes
    else { cecFailFast(stage: "client receive posting ownership", error: 13) }
    unsafe entry.pointee.receiveBuffer.Offset = 0
    unsafe entry.pointee.receiveBuffer.Length = UInt32(bytes)
    let flags: DWORD =
      unsafe configuration.pointee.options.transport == .tcp ? DWORD(RIO_MSG_WAITALL) : 0
    let at = unsafe clock.nowTicks()
    let ok = unsafe configuration.pointee.extensions.rio.RIOReceive!(
      entry.pointee.requestQueue, &entry.pointee.receiveBuffer, 1, flags, cecReceiveRequest(entry))
    if !ok.boolValue {
      return .failure(
        CECNativeError(stage: "RIOReceive(client)", code: WSAGetLastError(), retryable: true))
    }
    unsafe entry.pointee.receivePostedBytes = bytes
    unsafe entry.pointee.receiveOutstanding = true
    unsafe native.pointee.totalOutstanding += 1
    unsafe native.pointee.rioOutstanding += 1
    unsafe maybeArm()
    return .success(CECPosted(postedAt: at))
  }
  package mutating func send(_ index: UInt32, bytes: Int) -> CECPostResult {
    let entry = unsafe slot(index)
    unsafe entry.pointee.sendPostedBytes = bytes
    unsafe entry.pointee.sendOffset = 0
    return unsafe sendTail(index)
  }
  private mutating func sendTail(_ index: UInt32) -> CECPostResult {
    let entry = unsafe slot(index)
    guard unsafe !entry.pointee.closing, unsafe !entry.pointee.sendOutstanding,
      unsafe entry.pointee.sendOffset >= 0,
      unsafe entry.pointee.sendOffset < entry.pointee.sendPostedBytes,
      unsafe entry.pointee.sendPostedBytes <= configuration.pointee.maximumAttemptBytes
    else { cecFailFast(stage: "client send posting ownership", error: 13) }
    unsafe entry.pointee.sendBuffer.Offset = UInt32(entry.pointee.sendOffset)
    unsafe entry.pointee.sendBuffer.Length = UInt32(
      entry.pointee.sendPostedBytes - entry.pointee.sendOffset)
    let ok = unsafe configuration.pointee.extensions.rio.RIOSend!(
      entry.pointee.requestQueue, &entry.pointee.sendBuffer, 1, 0, cecSendRequest(entry))
    if !ok.boolValue {
      return .failure(
        CECNativeError(stage: "RIOSend(client)", code: WSAGetLastError(), retryable: true))
    }
    unsafe entry.pointee.sendOutstanding = true
    unsafe native.pointee.totalOutstanding += 1
    unsafe native.pointee.rioOutstanding += 1
    unsafe maybeArm()
    return .success(CECPosted())
  }
  package mutating func retireRio(_ result: RIORESULT) -> CECCompletion? {
    guard let (index, generation, operation) = CECRioContext.decode(result.RequestContext),
      operation == .send || operation == .receive
    else { cecFailFast(stage: "client RIO RequestContext identity", error: 13) }
    guard unsafe index < configuration.pointee.sessionCount else {
      cecFailFast(stage: "client RIO RequestContext range", error: 13)
    }
    let entry = unsafe slot(index)
    guard result.SocketContext == UInt64(UInt(bitPattern: entry)) else {
      cecFailFast(stage: "client RIO SocketContext identity", error: 13)
    }
    guard unsafe entry.pointee.generation == generation else {
      cecFailFast(stage: "client completion generation", error: 13)
    }
    guard unsafe native.pointee.totalOutstanding > 0, unsafe native.pointee.rioOutstanding > 0
    else {
      cecFailFast(stage: "client RIO outstanding count", error: 13)
    }
    let owned =
      unsafe operation == .send ? entry.pointee.sendOutstanding : entry.pointee.receiveOutstanding
    guard owned else { cecFailFast(stage: "client duplicate RIO completion", error: 13) }
    // Validate the operation's original extent before any subtraction or native
    // ownership retirement. Corrupt signed offsets must reach the named boundary
    // in Debug and Release instead of trapping during Swift integer arithmetic.
    let posted: Int
    if operation == .send {
      guard unsafe entry.pointee.sendPostedBytes > 0,
        unsafe entry.pointee.sendPostedBytes <= configuration.pointee.maximumAttemptBytes,
        unsafe entry.pointee.sendOffset >= 0,
        unsafe entry.pointee.sendOffset < entry.pointee.sendPostedBytes
      else {
        cecFailFast(stage: "client completion exceeds posted range", error: 13)
      }
      unsafe posted = entry.pointee.sendPostedBytes - entry.pointee.sendOffset
    } else {
      guard unsafe entry.pointee.receivePostedBytes > 0,
        unsafe entry.pointee.receivePostedBytes <= configuration.pointee.maximumAttemptBytes
      else {
        cecFailFast(stage: "client completion exceeds posted range", error: 13)
      }
      unsafe posted = entry.pointee.receivePostedBytes
    }
    guard Int(result.BytesTransferred) <= posted else {
      cecFailFast(stage: "client completion exceeds posted range", error: 13)
    }
    unsafe native.pointee.totalOutstanding -= 1
    unsafe native.pointee.rioOutstanding -= 1
    if operation == .send {
      unsafe entry.pointee.sendOutstanding = false
    } else {
      unsafe entry.pointee.receiveOutstanding = false
      unsafe entry.pointee.completedReceiveBytes = Int(result.BytesTransferred)
    }
    if unsafe entry.pointee.closing { return unsafe drained(index) }
    var status = result.Status
    var failureStage: CECCompletionFailureStage = .completion
    var bytes = Int(result.BytesTransferred)
    if operation == .send && status == 0 {
      if bytes == 0 {
        status = 10054
      } else {
        unsafe native.pointee.sentBytes &+= UInt64(bytes)
        unsafe entry.pointee.sendOffset += bytes
        if unsafe entry.pointee.sendOffset < entry.pointee.sendPostedBytes {
          switch unsafe sendTail(index) {
          case .success: return nil
          case .failure(let failure):
            cecReport(stage: failure.stage, error: failure.code)
            status = failure.code
            failureStage = .sendPost
          }
        }
        unsafe bytes = entry.pointee.sendOffset
      }
    }
    return CECCompletion(
      index: index, generation: generation, operation: operation, status: status, bytes: bytes,
      failureStage: failureStage)
  }
  package mutating func retireConnect(
    _ entry: UnsafeMutablePointer<CECEngineSession>, ok: Bool, error: DWORD, bytes: DWORD
  ) -> CECCompletion? {
    guard unsafe entry.pointee.connectOutstanding, unsafe native.pointee.totalOutstanding > 0 else {
      cecFailFast(stage: "ConnectEx outstanding count", error: 13)
    }
    guard bytes == 0 else {
      cecFailFast(stage: "ConnectEx completion exceeds posted range", error: 13)
    }
    unsafe entry.pointee.connectOutstanding = false
    unsafe native.pointee.totalOutstanding -= 1
    if unsafe entry.pointee.closing { return unsafe drained(entry.pointee.index) }
    if !ok { cecReport(stage: "ConnectEx completion", error: Int32(bitPattern: error)) }
    return unsafe CECCompletion(
      index: entry.pointee.index, generation: entry.pointee.generation, operation: .connect,
      status: ok ? 0 : Int32(bitPattern: error))
  }
  package mutating func maybeArm() {
    guard unsafe !native.pointee.notificationArmed, unsafe native.pointee.rioOutstanding != 0 else {
      return
    }
    unsafe cecRequireRIONotifySuccess(
      configuration.pointee.extensions.rio.RIONotify!(
        native.pointee.resources.completionQueue.rawValue), stage: "RIONotify(client)")
    guard unsafe cecNotificationMarkRearmed(&native.pointee.notificationArmed) else {
      cecFailFast(stage: "client notification rearm transition", error: 5023)
    }
    unsafe native.pointee.notifyArms &+= 1
  }
}
private func withRuntime<R>(
  _ worker: UnsafeMutablePointer<CECEngineWorker>,
  _ body: (inout CECWorkerRuntime<CECRioAdapter, CECNativeClock>) -> R
) -> R {
  // Borrow the worker's stored configuration in place. Passing the noncopyable value as
  // an argument makes the optimizer materialize a full temporary, which copies all 288
  // bytes on every completion-drain entry.
  unsafe withUnsafeMutablePointer(to: &worker.pointee.configurationStorage) { configuration in
    unsafe withRuntime(worker, configuration: UnsafePointer(configuration), body)
  }
}
private func withRuntime<R>(
  _ worker: UnsafeMutablePointer<CECEngineWorker>,
  configuration: UnsafePointer<CECWorkerConfiguration>,
  _ body: (inout CECWorkerRuntime<CECRioAdapter, CECNativeClock>) -> R
) -> R {
  unsafe withUnsafeMutablePointer(to: &worker.pointee.core) { core in
    unsafe withUnsafeMutablePointer(to: &worker.pointee.transport) { native in
      let clock = unsafe CECNativeClock(
        frequency: UInt64(max(1, worker.pointee.performanceFrequency.QuadPart)))
      var runtime = unsafe CECWorkerRuntime(
        core: core,
        transport: CECRioAdapter(
          native: native, configuration: configuration, ownerKey: UInt(bitPattern: worker),
          clock: clock), clock: clock)
      return unsafe body(&runtime)
    }
  }
}
private func drainBatch(
  _ runtime: inout CECWorkerRuntime<CECRioAdapter, CECNativeClock>, requested: UInt32 = 256
) -> UInt32 {
  var results = InlineArray<256, RIORESULT>(repeating: RIORESULT())
  var view = results.mutableSpan
  let count = view.withUnsafeMutableBufferPointer {
    unsafe cecRequireValidDequeueCount(
      runtime.transport.configuration.pointee.extensions.rio.RIODequeueCompletion!(
        runtime.transport.native.pointee.resources.completionQueue.rawValue, $0.baseAddress,
        requested), stage: "RIODequeueCompletion(client)")
  }
  guard count <= requested else { cecFailFast(stage: "client RIO dequeue extent", error: 13) }
  for index in 0..<Int(count) {
    if let completion = unsafe runtime.transport.retireRio(results[index]) {
      unsafe runtime.handleCompletion(completion)
    }
  }
  return count
}
private func drain(
  _ runtime: inout CECWorkerRuntime<CECRioAdapter, CECNativeClock>, batches: UInt32 = 64
) {
  for _ in 0..<batches { if unsafe drainBatch(&runtime) == 0 { break } }
  unsafe runtime.transport.maybeArm()
}
private func consumePacket(
  _ worker: UnsafeMutablePointer<CECEngineWorker>,
  runtime: inout CECWorkerRuntime<CECRioAdapter, CECNativeClock>, wait: UInt32
) -> Bool {
  var bytes: DWORD = 0
  var key: UInt64 = 0
  var overlap: UnsafeMutablePointer<OVERLAPPED>?
  let ok = unsafe GetQueuedCompletionStatus(
    worker.pointee.resources.port.rawValue, &bytes, &key, &overlap, wait)
  let error = ok ? 0 : GetLastError()
  if unsafe overlap == worker.pointee.notificationAddress {
    guard ok else {
      cecFailFast(
        stage: "GetQueuedCompletionStatus(client notification)", error: Int32(bitPattern: error))
    }
    unsafe cecRequireNotificationPacket(
      key: UInt(key), overlapped: overlap, expectedKey: UInt(bitPattern: worker),
      expectedOverlapped: worker.pointee.notificationAddress, stage: "client RIO notification key")
    guard unsafe cecNotificationMarkDelivered(&runtime.transport.native.pointee.notificationArmed)
    else {
      cecFailFast(stage: "client notification delivery transition", error: 5023)
    }
    unsafe runtime.transport.native.pointee.notifyDeliveries &+= 1
    // Each notification's ordinary bounded CQ pass finishes before the next
    // packet is acquired, including during overdue-timer arbitration.
    unsafe drain(&runtime)
  } else if unsafe overlap == nil {
    if !ok {
      guard error == WAIT_TIMEOUT else {
        cecFailFast(stage: "GetQueuedCompletionStatus(client)", error: Int32(bitPattern: error))
      }
      if unsafe !runtime.core.pointee.stopping,
        unsafe runtime.transport.native.pointee.rioOutstanding != 0,
        unsafe !runtime.transport.native.pointee.notificationArmed
      {
        unsafe runtime.transport.native.pointee.notifyTimeoutWakeups &+= 1
      }
      unsafe observeStop(worker, runtime: &runtime)
      return false
    }
    guard key == 1 else { cecFailFast(stage: "unexpected client IOCP packet", error: 13) }
    unsafe runtime.stopPacketSeen = true
    unsafe runtime.beginStop(
      fatal: worker.pointee.configuration.control.fatal.load(ordering: .acquiring))
  } else {
    guard let (index, generation, operation) = CECRioContext.decode(key), operation == .connect,
      unsafe index < worker.pointee.configuration.sessionCount
    else {
      cecFailFast(stage: "unexpected ConnectEx completion key", error: 13)
    }
    let entry = unsafe worker.pointee.sessionAddress!.advanced(by: Int(index))
    guard unsafe entry.pointee.generation == generation else {
      cecFailFast(stage: "client ConnectEx completion generation", error: 13)
    }
    guard unsafe overlap == cecConnectOverlapped(entry) else {
      cecFailFast(stage: "unexpected ConnectEx completion identity", error: 13)
    }
    if let completion = unsafe runtime.transport.retireConnect(
      entry, ok: ok, error: error, bytes: bytes)
    {
      unsafe runtime.handleCompletion(completion)
    }
  }
  unsafe observeStop(worker, runtime: &runtime)
  return true
}
private func observeStop(
  _ worker: UnsafeMutablePointer<CECEngineWorker>,
  runtime: inout CECWorkerRuntime<CECRioAdapter, CECNativeClock>
) {
  if unsafe runtime.stopPacketSeen
    || worker.pointee.configuration.control.stopRequested.load(ordering: .acquiring)
    || worker.pointee.configuration.control.fatal.load(ordering: .acquiring)
  {
    unsafe runtime.beginStop(
      fatal: worker.pointee.configuration.control.fatal.load(ordering: .acquiring))
  }
}
private func arbitrateTimers(
  _ worker: UnsafeMutablePointer<CECEngineWorker>,
  runtime: inout CECWorkerRuntime<CECRioAdapter, CECNativeClock>
) {
  if unsafe runtime.core.pointee.waitMilliseconds(now: runtime.clock.nowTicks(), maximum: 1) == 0 {
    for _ in unsafe 0..<(Int(worker.pointee.configuration.sessionCount) + 2) {
      if unsafe !consumePacket(worker, runtime: &runtime, wait: 0) { break }
    }
    // Save the timer decision before direct CQ acquisition. Any attempts
    // emitted while handling this finite record budget receive fresh anchors.
    let now = unsafe runtime.clock.nowTicks()
    var remaining = unsafe worker.pointee.configuration.sessionCount * 2
    while remaining != 0 {
      let count = unsafe drainBatch(&runtime, requested: min(256, remaining))
      if count == 0 { break }
      remaining -= count
    }
    unsafe runtime.transport.maybeArm()
    unsafe observeStop(worker, runtime: &runtime)
    unsafe runtime.poll(now: now)
  }
}
@inline(never)
private func publishWorker(_ worker: UnsafeMutablePointer<CECEngineWorker>) {
  unsafe worker.pointee.publication.publish(worker.pointee.core.metrics)
}
@c
package func cecWorkerThread(_ parameter: UnsafeMutableRawPointer?) -> DWORD {
  guard let parameter = unsafe parameter else {
    cecFailFast(stage: "client worker thread input", error: 13)
  }
  return unsafe cecRunWorker(parameter.assumingMemoryBound(to: CECEngineWorker.self))
}
private func cecRunWorker(_ worker: UnsafeMutablePointer<CECEngineWorker>) -> DWORD {
  unsafe worker.pointee.phase = .running
  return unsafe withRuntime(worker) { runtime in
    unsafe runtime.start()
    unsafe runtime.transport.maybeArm()
    while unsafe runtime.core.pointee.liveSessions != 0 {
      let now = unsafe runtime.clock.nowTicks()
      let maximum: UInt32 =
        unsafe worker.pointee.configuration.control.stopRequested.load(ordering: .acquiring)
        || worker.pointee.configuration.control.fatal.load(ordering: .acquiring)
        ? (runtime.core.pointee.stopping ? 1000 : 0) : 1000
      let wait = unsafe runtime.core.pointee.waitMilliseconds(now: now, maximum: maximum)
      _ = unsafe consumePacket(worker, runtime: &runtime, wait: wait)
      unsafe observeStop(worker, runtime: &runtime)
      unsafe arbitrateTimers(worker, runtime: &runtime)
      if unsafe runtime.core.pointee.metrics.fatal {
        unsafe worker.pointee.configuration.control.fatal.store(true, ordering: .releasing)
        unsafe worker.pointee.configuration.control.signalWake()
        unsafe runtime.beginStop(fatal: true)
      }
      if unsafe worker.pointee.configuration.options.reportSeconds != 0,
        unsafe now >= worker.pointee.nextPublication
      {
        unsafe publishWorker(worker)
        unsafe worker.pointee.nextPublication = cecSaturatingDeadline(
          now,
          cecMillisecondsToTicks(
            min(UInt64(worker.pointee.configuration.options.reportSeconds) * 1000, 50),
            frequency: UInt64(worker.pointee.performanceFrequency.QuadPart)))
      }
    }
    unsafe worker.pointee.phase = .draining
    unsafe cecShutdownNotification(worker)
    unsafe worker.pointee.phase = .stopped
    unsafe publishWorker(worker)
    unsafe worker.pointee.publication.finished.store(true, ordering: .releasing)
    unsafe worker.pointee.configuration.control.signalWake()
    return unsafe worker.pointee.configuration.control.fatal.load(ordering: .acquiring) ? 1 : 0
  }
}
package func cecPostWorkerStop(_ worker: UnsafePointer<CECEngineWorker>) {
  let ok = unsafe PostQueuedCompletionStatus(worker.pointee.resources.port.rawValue, 0, 1, nil)
  cecRequireControlPostSuccess(
    ok, error: Int32(bitPattern: GetLastError()), stage: "PostQueuedCompletionStatus(client stop)")
}
package func cecProcessRIOResult(_ worker: UnsafeMutablePointer<CECEngineWorker>, result: RIORESULT)
{
  unsafe withRuntime(worker) { runtime in
    if let completion = unsafe runtime.transport.retireRio(result) {
      unsafe runtime.handleCompletion(completion)
    }
  }
}
package func cecDrainCompletions(_ worker: UnsafeMutablePointer<CECEngineWorker>) {
  unsafe withRuntime(worker) { runtime in
    unsafe drain(&runtime)
    unsafe observeStop(worker, runtime: &runtime)
    unsafe publishWorker(worker)
  }
}
package func cecArbitrateQueuedTimers(_ worker: UnsafeMutablePointer<CECEngineWorker>) {
  unsafe withRuntime(worker) { runtime in unsafe arbitrateTimers(worker, runtime: &runtime) }
}
package func cecStopWorker(_ worker: UnsafeMutablePointer<CECEngineWorker>) {
  unsafe withRuntime(worker) { runtime in
    unsafe runtime.beginStop(
      fatal: worker.pointee.configuration.control.fatal.load(ordering: .acquiring))
  }
}
package func cecConnectionFailed(_ entry: UnsafeMutablePointer<CECEngineSession>) {
  guard let worker = unsafe entry.pointee.owner else {
    cecFailFast(stage: "client session owner", error: 13)
  }
  unsafe withRuntime(worker) { runtime in
    unsafe runtime.deliver(.transportFailure(entry.pointee.index))
  }
}
package func cecPostSend(_ entry: UnsafeMutablePointer<CECEngineSession>) -> Bool {
  guard let worker = unsafe entry.pointee.owner else {
    cecFailFast(stage: "client session owner", error: 13)
  }
  return unsafe withRuntime(worker) { runtime in
    switch unsafe runtime.transport.send(
      entry.pointee.index,
      bytes: runtime.core.pointee.sessions[Int(entry.pointee.index)].attemptBytes)
    {
    case .success: return true
    case .failure(let failure):
      cecReport(stage: failure.stage, error: failure.code)
      return false
    }
  }
}
package func cecJoinWorker(_ worker: UnsafeMutablePointer<CECEngineWorker>) {
  if unsafe worker.pointee.started && !worker.pointee.joined {
    guard
      unsafe WaitForSingleObject(worker.pointee.resources.thread.rawValue, UInt32.max)
        == WAIT_OBJECT_0
    else {
      cecFailFast(
        stage: "WaitForSingleObject(client worker)", error: Int32(bitPattern: GetLastError()))
    }
    unsafe worker.pointee.joined = true
  }
}
package func cecJoinAndCheckWorkers(
  _ workers: UnsafeBufferPointer<UnsafeMutablePointer<CECEngineWorker>?>
) {
  for index in workers.indices {
    if let worker = unsafe workers[index] { unsafe cecJoinWorker(worker) }
  }
  for index in workers.indices {
    if let worker = unsafe workers[index] { unsafe cecRequireWorkerRelease(worker) }
  }
}
package func cecRequireWorkerRelease(_ worker: UnsafePointer<CECEngineWorker>) {
  unsafe worker.pointee.requireRelease()
}
package func cecDestroyWorker(_ worker: UnsafeMutablePointer<CECEngineWorker>) {
  unsafe cecJoinWorker(worker)
  // Unconditional, including never-started and repeated calls. No provider-owned
  // allocation can be released before this internal guard proves all completions.
  unsafe cecRequireWorkerRelease(worker)
  if unsafe worker.pointee.released { return }
  if let first = unsafe worker.pointee.sessionAddress {
    for index in unsafe 0..<Int(worker.pointee.configuration.sessionCount) {
      let entry = unsafe first.advanced(by: index)
      if unsafe entry.pointee.socket != ~SOCKET(0) { unsafe closesocket(entry.pointee.socket) }
      unsafe entry.pointee.socket = ~SOCKET(0)
      unsafe entry.pointee.requestQueue = nil
    }
  }
  unsafe worker.pointee.resources.completionQueue.reset()
  let registeredCount = unsafe worker.pointee.resources.registeredCount
  _ = unsafe cecWithOptionalBorrow(worker.pointee.resources.registrationIDs) { ids in
    for index in 0..<registeredCount {
      if let id = unsafe ids.baseAddress[index] {
        unsafe worker.pointee.configuration.extensions.rio.RIODeregisterBuffer!(id)
      }
      unsafe ids.baseAddress[index] = nil
    }
  }
  unsafe worker.pointee.resources.registeredCount = 0
  unsafe worker.pointee.resources.registrationIDs = nil
  unsafe worker.pointee.resources.arena.reset()
  unsafe worker.pointee.resources.sessions = nil
  unsafe worker.pointee.transport.sessionAddress = nil
  unsafe worker.pointee.transport.memory = nil
  unsafe worker.pointee.transport.sessionRange = 0..<0
  unsafe worker.pointee.transport.notificationArmed = false
  unsafe worker.pointee.transport.notifyArms = worker.pointee.transport.notifyDeliveries
  unsafe worker.pointee.resources.port.reset()
  // Keep the pinned RIONotify OVERLAPPED alive through both CQ and IOCP close.
  unsafe worker.pointee.resources.notification = nil
  unsafe worker.pointee.transport.notificationAddress = nil
  unsafe worker.pointee.resources.thread.reset()
  unsafe worker.pointee.released = true
}
package func cecShutdownNotification(_ worker: UnsafeMutablePointer<CECEngineWorker>) {
  guard unsafe worker.pointee.transport.totalOutstanding == 0,
    unsafe worker.pointee.transport.rioOutstanding == 0
  else { cecFailFast(stage: "client notification shutdown ownership", error: 996) }
  // RIO can retain one empty armed notification. Consume only packets actually
  // delivered by IOCP; CQ close terminates that final arm before its storage dies.
  for _ in unsafe 0..<(Int(worker.pointee.configuration.sessionCount) + 2) {
    var bytes: DWORD = 0
    var key: UInt64 = 0
    var overlap: UnsafeMutablePointer<OVERLAPPED>?
    let ok = unsafe GetQueuedCompletionStatus(
      worker.pointee.resources.port.rawValue, &bytes, &key, &overlap, 0)
    if unsafe !ok && overlap == nil {
      let error = GetLastError()
      guard error == WAIT_TIMEOUT else {
        cecFailFast(stage: "client notification shutdown wait", error: Int32(bitPattern: error))
      }
      break
    }
    if unsafe overlap == nil && key == 1 { continue }
    guard ok else {
      cecFailFast(
        stage: "client notification shutdown wait", error: Int32(bitPattern: GetLastError()))
    }
    unsafe cecRequireNotificationPacket(
      key: UInt(key), overlapped: overlap, expectedKey: UInt(bitPattern: worker),
      expectedOverlapped: worker.pointee.notificationAddress,
      stage: "client notification shutdown packet")
    guard unsafe cecNotificationMarkDelivered(&worker.pointee.transport.notificationArmed) else {
      cecFailFast(stage: "client shutdown transition", error: 5023)
    }
    unsafe worker.pointee.transport.notifyDeliveries &+= 1
  }
  guard unsafe worker.pointee.transport.notifyArms >= worker.pointee.transport.notifyDeliveries,
    unsafe worker.pointee.transport.notifyArms - worker.pointee.transport.notifyDeliveries <= 1
  else {
    cecFailFast(stage: "client notification shutdown residual", error: 996)
  }
}
package func cecPrepareWorker(_ worker: UnsafeMutablePointer<CECEngineWorker>) throws(CECFailure) {
  guard unsafe QueryPerformanceFrequency(&worker.pointee.performanceFrequency),
    unsafe worker.pointee.performanceFrequency.QuadPart > 0
  else {
    throw CECFailure(
      classification: .network, domain: .win32, stage: "QueryPerformanceFrequency",
      code: Int32(bitPattern: GetLastError()))
  }
  unsafe worker.pointee.resources.port.reset(
    CreateIoCompletionPort(HANDLE(bitPattern: -1), nil, 0, 1))
  guard unsafe worker.pointee.resources.port.rawValue != nil else {
    throw CECFailure(
      classification: .network, domain: .win32, stage: "CreateIoCompletionPort(client worker)",
      code: Int32(bitPattern: GetLastError()))
  }
  let sessions = unsafe worker.pointee.configuration.sessionCount
  let maximum = unsafe worker.pointee.configuration.maximumAttemptBytes
  guard sessions > 0, sessions <= 1_048_576, maximum > 0,
    unsafe worker.pointee.configuration.payloadBytes > 0,
    unsafe UInt64(sessions) * 2 <= UInt64(worker.pointee.configuration.options.cqCapacity)
  else {
    throw CECFailure(
      classification: .network, domain: .capacity, stage: "client worker IOCP/CQ/arena capacity",
      code: 8)
  }
  guard
    let bytes = unsafe cecCheckedSharedStorageBytes(
      sessions: UInt64(sessions), workers: 1,
      batchBytes: UInt64(maximum), memoryLimit: worker.pointee.configuration.memoryShare),
    bytes <= UInt32.max
  else {
    throw CECFailure(
      classification: .network, domain: .capacity, stage: "client worker IOCP/CQ/arena capacity",
      code: 8)
  }
  guard
    let memory = unsafe VirtualAlloc(
      nil, bytes, DWORD(UInt32(MEM_RESERVE) | UInt32(MEM_COMMIT)), DWORD(UInt32(PAGE_READWRITE)))
  else {
    throw CECFailure(
      classification: .network, domain: .win32, stage: "VirtualAlloc(client arena)",
      code: Int32(bitPattern: GetLastError()))
  }
  unsafe worker.pointee.resources.arena.reset(memory, byteCount: Int(bytes))
  unsafe worker.pointee.memory = memory.assumingMemoryBound(to: UInt8.self)
  unsafe worker.pointee.core = try CECWorkerCore(
    options: worker.pointee.configuration.options,
    sessionCount: sessions, payloadBytes: worker.pointee.configuration.payloadBytes,
    frequency: UInt64(worker.pointee.performanceFrequency.QuadPart))
  guard
    let storage = unsafe CECPinnedStorage(count: Int(sessions), initialValue: CECEngineSession()),
    let notification = unsafe CECPinnedStorage(count: 1, initialValue: OVERLAPPED()),
    let ids = unsafe CECPinnedStorage<RIO_BUFFERID?>(count: Int(sessions) * 2, initialValue: nil)
  else {
    throw .allocation(stage: "client worker allocation")
  }
  unsafe worker.pointee.sessionAddress = storage.baseAddress
  unsafe worker.pointee.notificationAddress = notification.baseAddress
  let registrationAddress = unsafe ids.baseAddress
  let first = unsafe UInt(bitPattern: storage.baseAddress)
  unsafe worker.pointee.sessionRange =
    first..<(first + UInt(MemoryLayout<CECEngineSession>.stride) * UInt(sessions))
  unsafe worker.pointee.resources.sessions = consume storage
  unsafe worker.pointee.resources.notification = consume notification
  unsafe worker.pointee.resources.registrationIDs = consume ids
  let receiveBase = Int(sessions) * maximum
  for index in 0..<Int(sessions) {
    let entry = unsafe worker.pointee.sessionAddress!.advanced(by: index)
    unsafe entry.pointee.owner = worker
    unsafe entry.pointee.index = UInt32(index)
    unsafe entry.pointee.sendArenaOffset = index * maximum
    unsafe entry.pointee.receiveArenaOffset = receiveBase + index * maximum
    let filled = unsafe worker.pointee.resources.arena.withMutableBytes(
      in: index * maximum..<(index + 1) * maximum
    ) { destination in
      if let fixture = unsafe worker.pointee.configuration.pattern {
        fixture.fill(&destination)
      } else {
        let payloadCount = unsafe worker.pointee.configuration.payloadBytes
        let filled = destination.withUnsafeMutableBufferPointer { output in
          var payload = unsafe MutableSpan(
            _unsafeElements: UnsafeMutableBufferPointer(
              start: output.baseAddress, count: payloadCount))
          do {
            unsafe try cecFillPattern(
              options: worker.pointee.configuration.options, destination: &payload)
          } catch { return false }
          unsafe cecCopyRepeatedBytes(
            destination: output,
            pattern: UnsafeBufferPointer(start: output.baseAddress, count: payloadCount))
          return true
        }
        if !filled { return false }
      }
      return true
    }
    guard filled == true else { throw .invariant(stage: "client pattern initialization") }
    for direction in 0..<2 {
      let offset = direction == 0 ? index * maximum : receiveBase + index * maximum
      guard
        let id = unsafe worker.pointee.configuration.extensions.rio.RIORegisterBuffer!(
          memory.advanced(by: offset).assumingMemoryBound(to: CChar.self), UInt32(maximum))
      else {
        throw CECFailure(
          classification: .network, domain: .winsock, stage: "RIORegisterBuffer(client windows)",
          code: WSAGetLastError())
      }
      unsafe registrationAddress[index * 2 + direction] = id
      unsafe worker.pointee.resources.registeredCount += 1
      if direction == 0 {
        unsafe entry.pointee.sendBuffer.BufferId = id
      } else {
        unsafe entry.pointee.receiveBuffer.BufferId = id
      }
    }
  }
  var notificationRecord = unsafe RIO_NOTIFICATION_COMPLETION()
  unsafe notificationRecord.Type = RIO_IOCP_COMPLETION
  unsafe notificationRecord.Iocp.IocpHandle = worker.pointee.resources.port.rawValue
  unsafe notificationRecord.Iocp.CompletionKey = UnsafeMutableRawPointer(worker)
  unsafe notificationRecord.Iocp.Overlapped = UnsafeMutableRawPointer(
    worker.pointee.notificationAddress!)
  guard
    let cq = unsafe worker.pointee.configuration.extensions.rio.RIOCreateCompletionQueue!(
      worker.pointee.configuration.options.cqCapacity, &notificationRecord)
  else {
    throw CECFailure(
      classification: .network, domain: .winsock, stage: "RIOCreateCompletionQueue(client)",
      code: WSAGetLastError())
  }
  unsafe worker.pointee.resources.completionQueue.reset(
    rio: worker.pointee.configuration.extensions.rio, value: cq)
}
package func cecInitializeWorker(_ worker: UnsafeMutablePointer<CECEngineWorker>) -> Bool {
  do { unsafe try cecPrepareWorker(worker) } catch {
    unsafe worker.pointee.preparationFailure = error
    cecReport(stage: error.stage, error: error.code)
    return false
  }
  // Set before CreateThread: the spawned callback can finish immediately.
  unsafe worker.pointee.started = true
  unsafe worker.pointee.resources.thread.reset(
    CreateThread(nil, 0, cecWorkerThread, worker, 0, nil))
  if unsafe worker.pointee.resources.thread.rawValue == nil {
    unsafe worker.pointee.started = false
    let failure = CECFailure(
      classification: .network, domain: .win32, stage: "CreateThread(client worker)",
      code: Int32(bitPattern: GetLastError()))
    unsafe worker.pointee.preparationFailure = failure
    cecReport(stage: failure.stage, error: failure.code)
    return false
  }
  return true
}
@unsafe
private struct CECWorkerCollection: ~Copyable {
  private let storage: CECPinnedStorage<UnsafeMutablePointer<CECEngineWorker>?>
  private(set) var count = 0
  init(capacity: UInt32) throws(CECFailure) {
    guard
      let storage = unsafe CECPinnedStorage<UnsafeMutablePointer<CECEngineWorker>?>(
        count: Int(capacity), initialValue: nil)
    else { throw .allocation(stage: "client worker allocation") }
    unsafe self.storage = consume storage
  }
  subscript(index: Int) -> UnsafeMutablePointer<CECEngineWorker> {
    unsafe storage.baseAddress[index]!
  }
  mutating func append(_ configuration: consuming CECWorkerConfiguration) throws(CECFailure) {
    guard
      let raw = unsafe HeapAlloc(GetProcessHeap(), 0, UInt64(MemoryLayout<CECEngineWorker>.stride))
    else { throw .allocation(stage: "client worker allocation") }
    let worker = unsafe raw.bindMemory(to: CECEngineWorker.self, capacity: 1)
    unsafe worker.initialize(to: CECEngineWorker(configuration: consume configuration))
    unsafe storage.baseAddress[count] = worker
    unsafe count += 1
  }
  borrowing func joinAndCheck() {
    unsafe cecJoinAndCheckWorkers(UnsafeBufferPointer(start: storage.baseAddress, count: count))
  }
  deinit {
    unsafe cecJoinAndCheckWorkers(UnsafeBufferPointer(start: storage.baseAddress, count: count))
    for index in unsafe 0..<count {
      let worker = unsafe storage.baseAddress[index]!
      unsafe cecDestroyWorker(worker)
      unsafe worker.deinitialize(count: 1)
      unsafe HeapFree(GetProcessHeap(), 0, worker)
    }
  }
}
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
    unsafe extensions = try cecLoadExtensions()
    remote = try cecResolveIPv4(hostUTF16: options.hostUTF16, port: options.remotePort)
  } catch {
    cecReport(stage: error.stage, error: error.code)
    return .network
  }
  let payloadBytes: Int
  do { payloadBytes = try cecPatternByteCount(options: options) } catch {
    cecReport(stage: "payload pattern", error: 13)
    return .usage
  }
  guard let maximum = cecMaximumAttemptBytes(options: options, patternBytes: UInt64(payloadBytes))
  else {
    cecReport(
      stage: options.transport == .udp ? "payload pattern" : "payload batch size",
      error: options.transport == .udp ? 13 : 534)
    return .usage
  }
  let count = UInt32(
    cecResolveWorkerCount(configured: options.workerCount, sessions: options.sessionCount))
  guard
    cecCheckedSharedStorageBytes(
      sessions: UInt64(options.sessionCount), workers: UInt64(count),
      batchBytes: maximum, memoryLimit: options.memoryBytes) != nil
  else {
    cecReport(stage: "registered storage /memory limit", error: 8)
    return .usage
  }
  guard
    let timerResolution = cecPrepareTimerResolution(
      intervalMilliseconds: options.intervalMilliseconds,
      api: CECNativeTimerPeriodAPI())
  else { return .internalFailure }
  defer { timerResolution.keepAlive() }
  var workers: CECWorkerCollection
  do { unsafe workers = try CECWorkerCollection(capacity: count) } catch {
    cecReport(stage: error.stage, error: error.code)
    return .network
  }
  var remaining = options.sessionCount
  for index in 0..<count {
    let left = count - index
    let sessions = (remaining + left - 1) / left
    let configuration = unsafe CECWorkerConfiguration(
      options: copy options, remoteAddress: remote, extensions: extensions,
      pattern: nil, maximumAttemptBytes: Int(maximum), metrics: nil, control: control,
      workerIndex: index, sessionCount: sessions,
      memoryShare: (options.memoryBytes / UInt64(options.sessionCount)) * UInt64(sessions),
      payloadBytes: payloadBytes)
    do { unsafe try workers.append(consume configuration) } catch {
      cecReport(stage: error.stage, error: error.code)
      control.fatal.store(true, ordering: .releasing)
      break
    }
    if unsafe !cecInitializeWorker(workers[Int(index)]) {
      control.fatal.store(true, ordering: .releasing)
      break
    }
    remaining -= sessions
  }
  let start = GetTickCount64()
  let stopDeadline =
    options.runSeconds == 0
    ? UInt64.max : cecSaturatingDeadline(start, UInt64(options.runSeconds) * 1000)
  var nextReport =
    options.reportSeconds == 0
    ? UInt64.max : cecSaturatingDeadline(start, UInt64(options.reportSeconds) * 1000)
  var sentStops = false
  while true {
    control.resetWake()
    let now = GetTickCount64()
    if now >= stopDeadline { control.stopRequested.store(true, ordering: .releasing) }
    if now >= nextReport {
      var snapshot = CECWorkerMetricsSnapshot()
      for index in unsafe 0..<workers.count {
        unsafe snapshot.merge(workers[index].pointee.publication.read())
      }
      print(
        cecMetricsLine(
          phase: "report", options: options, metrics: snapshot, elapsedMilliseconds: now - start))
      nextReport = cecSaturatingDeadline(now, UInt64(options.reportSeconds) * 1000)
    }
    if !sentStops
      && (control.fatal.load(ordering: .acquiring)
        || control.stopRequested.load(ordering: .acquiring))
    {
      for index in unsafe 0..<workers.count {
        if unsafe workers[index].pointee.started { unsafe cecPostWorkerStop(workers[index]) }
      }
      sentStops = true
    }
    var done = true
    for index in unsafe 0..<workers.count {
      if unsafe workers[index].pointee.started
        && !workers[index].pointee.publication.finished.load(ordering: .acquiring)
      {
        done = false
      }
    }
    if done { break }
    control.waitWake(
      cecDeadlineWait(now: now, deadline: sentStops ? nextReport : min(nextReport, stopDeadline)))
  }
  unsafe workers.joinAndCheck()
  var final = CECWorkerMetricsSnapshot()
  for index in unsafe 0..<workers.count { unsafe final.merge(workers[index].pointee.core.metrics) }
  // Opt-in diagnostics borrow joined workers before destroy clears the residual
  // notification arm. A file failure never changes the production exit category.
  unsafe writeNotificationDiagnostics(workers: workers, transport: options.transport)
  for index in unsafe 0..<workers.count { unsafe cecDestroyWorker(workers[index]) }
  if !cecSessionTerminalAccountingValid(
    claimed: final.claimed, echoed: final.echoed, corrupted: final.corrupted,
    lost: final.lost, cancelled: final.cancelled) || final.active != 0
  {
    cecFailFast(stage: "client final claimed accounting", error: 13)
  }
  let controlledStop = control.stopRequested.load(ordering: .acquiring)
  final.accountUnclaimed(
    limit: options.echoCount * UInt64(options.sessionCount), controlledStop: controlledStop)
  if !options.quiet || options.stats {
    print(
      cecMetricsLine(
        phase: "final", options: options, metrics: final,
        elapsedMilliseconds: GetTickCount64() - start))
  }
  return cecClassifyResult(
    echoed: final.echoed, corrupted: final.corrupted, lost: final.lost,
    networkErrors: final.networkErrors, fatal: control.fatal.load(ordering: .acquiring),
    controlledStop: controlledStop)
}
private func writeNotificationDiagnostics(
  workers: borrowing CECWorkerCollection, transport: CECTransport
) {
  guard let file = unsafe CECNotificationDiagnosticFile() else { return }
  for index in unsafe 0..<workers.count {
    let worker = unsafe workers[index]
    if unsafe !worker.pointee.started { continue }
    let snapshot = unsafe CECNotificationSnapshot(
      workerIndex: worker.pointee.configuration.workerIndex,
      arms: worker.pointee.transport.notifyArms,
      deliveries: worker.pointee.transport.notifyDeliveries,
      timeoutWakeups: worker.pointee.transport.notifyTimeoutWakeups)
    if unsafe !file.write(cecNotificationDiagnosticLine(snapshot, transport: transport)) { return }
  }
}
