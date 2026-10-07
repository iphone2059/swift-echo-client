import WinSDK

// Unsafe native records expose pinned addresses and function-table entries.
// The coordinator initializes them before CreateThread; the worker owns mutable
// fields until join. Key-path field offsets always describe the actual POD
// layout; native completion identities are checked before these views are used.

package enum CECWorkerPhase: UInt8 { case starting, running, draining, stopped }
package struct CECWorkerLifecycle {
  package var phase: CECWorkerPhase = .starting
  package var liveSessions: UInt32 = 0
  package var totalOutstanding: UInt32 = 0
  package var notificationArmed = false
}
package func cecWorkerMayRelease(_ v: CECWorkerLifecycle) -> Bool {
  v.phase == .stopped && v.liveSessions == 0 && v.totalOutstanding == 0 && !v.notificationArmed
}
package func cecSessionTerminalAccountingValid(
  claimed: UInt64, echoed: UInt64, corrupted: UInt64, lost: UInt64
) -> Bool {
  let (sum, overflow) = echoed.addingReportingOverflow(corrupted)
  let (total, overflow2) = sum.addingReportingOverflow(lost)
  return !overflow && !overflow2 && claimed == total
}
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
package func cecNotificationPacketMatches(
  key: UInt, overlapped: UnsafePointer<OVERLAPPED>?, expectedKey: UInt,
  expectedOverlapped: UnsafePointer<OVERLAPPED>?
) -> Bool { unsafe key == expectedKey && overlapped == expectedOverlapped }

package enum CECEngineOperation: UInt8 { case receive, send }
package enum CECEngineState: UInt8 {
  case dormant, connecting, active, pacing, reconnecting, closing, done
}
package struct CECEngineRequest {
  package var sessionIndex: UInt32 = 0
  package var operation: CECEngineOperation = .receive
}
@unsafe
package struct CECEngineSession {
  package var owner: UnsafeMutablePointer<CECEngineWorker>?
  package var socket: SOCKET = ~SOCKET(0)
  package var requestQueue: RIO_RQ?
  package var connectOverlapped = unsafe OVERLAPPED()
  package var receiveRequest = CECEngineRequest()
  package var sendRequest = CECEngineRequest(operation: .send)
  package var receiveBuffer = unsafe RIO_BUF()
  package var sendBuffer = unsafe RIO_BUF()
  package var state: CECEngineState = .dormant
  package var index: UInt32 = 0
  package var outstanding: UInt32 = 0
  package var requestedEchoes: UInt64 = 0
  package var attemptBytes = 0
  package var sendOffset = 0
  package var receivedBytes = 0
  package var deadline: UInt64 = 0
  package var nextAction: UInt64 = 0
  package var startedAt = LARGE_INTEGER()
  package var sendDone = false
  package var receiveDone = false
  package var attemptAccounted = false
  package var reconnectAfterClose = false
  package var receiveArenaOffset = 0
  package init() {}
}
/// Only POD fields are exposed to Windows; addresses come from the owning allocation.
private func checkedSessionOffset<T>(_ key: KeyPath<CECEngineSession, T>) -> Int {
  guard let offset = unsafe MemoryLayout<CECEngineSession>.offset(of: key) else {
    cecFailFast(stage: "client session stored field layout", error: 13)
  }
  return offset
}
private enum CECSessionLayout {
  static let receiveRequest = unsafe checkedSessionOffset(\CECEngineSession.receiveRequest)
  static let sendRequest = unsafe checkedSessionOffset(\CECEngineSession.sendRequest)
  static let connectOverlapped = unsafe checkedSessionOffset(\CECEngineSession.connectOverlapped)
  static let receiveBuffer = unsafe checkedSessionOffset(\CECEngineSession.receiveBuffer)
  static let sendBuffer = unsafe checkedSessionOffset(\CECEngineSession.sendBuffer)
}
private func sessionField<T>(
  _ s: UnsafeMutablePointer<CECEngineSession>, offset: Int
) -> UnsafeMutablePointer<T> {
  return unsafe UnsafeMutableRawPointer(s).advanced(by: offset).assumingMemoryBound(to: T.self)
}
package func cecReceiveRequest(_ s: UnsafeMutablePointer<CECEngineSession>) -> UnsafeMutablePointer<
  CECEngineRequest
> { unsafe sessionField(s, offset: CECSessionLayout.receiveRequest) }
package func cecSendRequest(_ s: UnsafeMutablePointer<CECEngineSession>) -> UnsafeMutablePointer<
  CECEngineRequest
> { unsafe sessionField(s, offset: CECSessionLayout.sendRequest) }
package func cecConnectOverlapped(_ s: UnsafeMutablePointer<CECEngineSession>)
  -> UnsafeMutablePointer<OVERLAPPED>
{ unsafe sessionField(s, offset: CECSessionLayout.connectOverlapped) }
package func cecReceiveBuffer(_ s: UnsafeMutablePointer<CECEngineSession>) -> UnsafeMutablePointer<
  RIO_BUF
> { unsafe sessionField(s, offset: CECSessionLayout.receiveBuffer) }
package func cecSendBuffer(_ s: UnsafeMutablePointer<CECEngineSession>) -> UnsafeMutablePointer<
  RIO_BUF
> { unsafe sessionField(s, offset: CECSessionLayout.sendBuffer) }
package final class CECPatternStorage {
  private let storage: UniqueArray<UInt8>
  package var bytes: UniqueArray<UInt8> { borrow { storage } }
  package init(_ bytes: consuming UniqueArray<UInt8>) { storage = bytes }
  package func fill(_ destination: inout MutableSpan<UInt8>) {
    // Both owners remain borrowed for the synchronous copy; neither native
    // buffer nor a lifetime-dependent view is returned or retained.
    let pattern = Ref(bytes)
    pattern.value.span.withUnsafeBufferPointer { input in
      destination.withUnsafeMutableBufferPointer { output in
        unsafe cecCopyRepeatedBytes(destination: output, pattern: input)
      }
    }
  }
}
@unsafe
package struct CECWorkerConfiguration: ~Copyable {
  package let options: CECOptions
  package let remoteAddress: SOCKADDR_IN
  package let extensions: CECNativeExtensions
  private let patternStorage: CECPatternStorage
  package var pattern: CECPatternStorage { borrow { unsafe patternStorage } }
  package let maximumAttemptBytes: Int
  package let metrics: CECEngineMetrics
  private let controlStorage: CECSharedControl
  package var control: CECSharedControl { borrow { unsafe controlStorage } }
  package let workerIndex: UInt32
  package let sessionCount: UInt32
  package let memoryShare: UInt64
  package init(
    options: CECOptions, remoteAddress: SOCKADDR_IN, extensions: CECNativeExtensions,
    pattern: CECPatternStorage, maximumAttemptBytes: Int, metrics: CECEngineMetrics,
    control: CECSharedControl, workerIndex: UInt32, sessionCount: UInt32, memoryShare: UInt64
  ) {
    unsafe self.options = options
    unsafe self.remoteAddress = remoteAddress
    unsafe self.extensions = unsafe extensions
    unsafe self.patternStorage = pattern
    unsafe self.maximumAttemptBytes = maximumAttemptBytes
    unsafe self.metrics = metrics
    unsafe self.controlStorage = control
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
  private var registrationStorage = unsafe UniqueArray<CECRIORegistrationOwner>()
  package var registrations: UniqueArray<CECRIORegistrationOwner> {
    borrow { unsafe registrationStorage }
    mutate { unsafe &registrationStorage }
  }
  package var completionQueue = unsafe CECRIOCQOwner()
  private var socketStorage = UniqueArray<CECSocketOwner>()
  package var sockets: UniqueArray<CECSocketOwner> {
    borrow { unsafe socketStorage }
    mutate { unsafe &socketStorage }
  }
  package var sessions: CECPinnedStorage<CECEngineSession>?
  package var notification: CECPinnedStorage<OVERLAPPED>?
}
@unsafe
package struct CECEngineWorker: ~Copyable {
  private let configurationStorage: CECWorkerConfiguration
  package var configuration: CECWorkerConfiguration { borrow { unsafe configurationStorage } }
  package var resources = unsafe CECEngineWorkerResources()
  package var timers: CECTimerHeap
  package var memory: UnsafeMutablePointer<UInt8>?
  package var sessionAddress: UnsafeMutablePointer<CECEngineSession>?
  package var notificationAddress: UnsafeMutablePointer<OVERLAPPED>?
  package var liveSessions: UInt32
  package var performanceFrequency = LARGE_INTEGER()
  package var notificationArmed = false
  package var stopping = false
  package var phase: CECWorkerPhase = .starting
  package var metrics = CECWorkerMetricsSnapshot()
  private let publicationStorage = CECWorkerPublication()
  package var publication: CECWorkerPublication { borrow { unsafe publicationStorage } }
  package var nextPublication: UInt64 = UInt64.max
  package var sessionRange: Range<UInt> = 0..<0
  package init(configuration: consuming CECWorkerConfiguration) {
    unsafe timers = CECTimerHeap(capacity: configuration.sessionCount)
    unsafe liveSessions = configuration.sessionCount
    unsafe self.configurationStorage = consume configuration
  }
}
@unsafe
package struct CECWorkerOwner: ~Copyable {
  package let baseAddress: UnsafeMutablePointer<CECEngineWorker>
  package init(configuration: consuming CECWorkerConfiguration) {
    unsafe baseAddress = .allocate(capacity: 1)
    unsafe baseAddress.initialize(to: CECEngineWorker(configuration: consume configuration))
  }
  deinit {
    unsafe cecDestroyWorker(baseAddress)
    unsafe baseAddress.deinitialize(count: 1)
    unsafe baseAddress.deallocate()
  }
}
