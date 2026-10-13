import Synchronization
import WinSDK
import ucrt

// Synchronous Windows calls borrow stack/buffer addresses only during the call.
// Extension tables are initialized by WSAIoctl and used while Winsock is active.
// GetAddrInfoW owns its result chain until FreeAddrInfoW; the CRT owns argv and
// guarantees NUL termination. No temporary address is used for async requests.

package struct CECNativeError: Error {
  package let stage: String
  package let code: Int32
  package var domain: CECFailureDomain = .winsock
  package var category: CECFailureCategory = .connection
  package var retryable = false
  package var failure: CECFailure {
    CECFailure(classification: .network, domain: domain, stage: stage, code: code,
      category: category, retryable: retryable)
  }
}
@unsafe
package struct CECNativeExtensions {
  package var rio: RIO_EXTENSION_FUNCTION_TABLE
  package var connectEx: LPFN_CONNECTEX?
  package init(rio: RIO_EXTENSION_FUNCTION_TABLE, connectEx: LPFN_CONNECTEX? = nil) {
    unsafe self.rio = rio
    unsafe self.connectEx = unsafe connectEx
  }
}
package struct CECWinSockOwner: ~Copyable {
  package borrowing func keepAlive() {}
  package init() throws(CECNativeError) {
    var data = unsafe WSADATA()
    let status = unsafe WSAStartup(0x0202, &data)
    if status != 0 { throw CECNativeError(stage: "WSAStartup", code: status, category: .initialization) }
  }
  deinit { WSACleanup() }
}
package func cecRegisteredSocket(transport: CECTransport) -> SOCKET {
  WSASocketW(
    AF_INET, transport == .tcp ? SOCK_STREAM : SOCK_DGRAM,
    Int32((transport == .tcp ? IPPROTO_TCP : IPPROTO_UDP).rawValue), nil, 0,
    DWORD(UInt32(WSA_FLAG_OVERLAPPED) | UInt32(WSA_FLAG_REGISTERED_IO)))
}
package func cecLoadExtensions() throws(CECNativeError) -> CECNativeExtensions {
  let owner = CECSocketOwner(cecRegisteredSocket(transport: .tcp))
  guard owner.rawValue != ~SOCKET(0) else {
    throw CECNativeError(stage: "WSASocketW(RIO probe)", code: WSAGetLastError(), category: .initialization)
  }
  var rio = RIO_EXTENSION_FUNCTION_TABLE()
  rio.cbSize = DWORD(MemoryLayout<RIO_EXTENSION_FUNCTION_TABLE>.size)
  var rioID = GUID(
    Data1: 0x8509_e081, Data2: 0x96dd, Data3: 0x4005,
    Data4: (0xb1, 0x65, 0x9e, 0x2e, 0xe8, 0xc7, 0x9e, 0x3f))
  var bytes: DWORD = 0
  guard
    unsafe WSAIoctl(
      owner.rawValue, DWORD(0xC800_0024), &rioID, DWORD(MemoryLayout<GUID>.size), &rio,
      DWORD(MemoryLayout<RIO_EXTENSION_FUNCTION_TABLE>.size), &bytes, nil, nil) == 0
  else {
    throw CECNativeError(
      stage: "SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER(RIO)", code: WSAGetLastError(), category: .initialization)
  }
  guard unsafe rio.RIOReceive != nil, rio.RIOSend != nil, rio.RIOCreateCompletionQueue != nil,
    rio.RIOCloseCompletionQueue != nil, rio.RIOCreateRequestQueue != nil,
    rio.RIORegisterBuffer != nil, rio.RIODeregisterBuffer != nil,
    rio.RIODequeueCompletion != nil, rio.RIONotify != nil else {
    throw CECNativeError(stage: "RIO table entry points", code: 13, domain: .invariant, category: .initialization)
  }
  var connectID = GUID(
    Data1: 0x25a2_07b9, Data2: 0xddf3, Data3: 0x4660,
    Data4: (0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e))
  var connectEx: LPFN_CONNECTEX?
  guard
    unsafe WSAIoctl(
      owner.rawValue, DWORD(0xC800_0006), &connectID, DWORD(MemoryLayout<GUID>.size),
      &connectEx, DWORD(MemoryLayout<LPFN_CONNECTEX?>.size), &bytes, nil, nil) == 0,
    unsafe connectEx != nil
  else {
    throw CECNativeError(
      stage: "SIO_GET_EXTENSION_FUNCTION_POINTER(ConnectEx)", code: WSAGetLastError(), category: .initialization)
  }
  return unsafe CECNativeExtensions(rio: rio, connectEx: connectEx)
}
package func cecResolveIPv4(hostUTF16: [UInt16], port: UInt16) throws(CECNativeError) -> SOCKADDR_IN
{
  var hints = unsafe ADDRINFOW()
  unsafe hints.ai_family = AF_INET
  var results: UnsafeMutablePointer<ADDRINFOW>?
  let host = hostUTF16 + [0]
  let service = Array(String(port).utf16) + [0]
  let status = host.withUnsafeBufferPointer { h in
    service.withUnsafeBufferPointer { s in
      unsafe GetAddrInfoW(h.baseAddress, s.baseAddress, &hints, &results)
    }
  }
  defer { if let results = unsafe results { unsafe FreeAddrInfoW(results) } }
  guard status == 0, let results = unsafe results, let addr = unsafe results.pointee.ai_addr else {
    throw CECNativeError(stage: "GetAddrInfoW(IPv4)", code: status, category: .initialization)
  }
  return unsafe UnsafeRawPointer(addr).load(as: SOCKADDR_IN.self)
}
package func cecConfigureSocketChecked(_ socket: SOCKET, options: borrowing CECOptions) throws(CECNativeError) {
  if options.socketBufferBytes > 0 {
    var size = Int32(options.socketBufferBytes)
    let status = withUnsafePointer(to: &size) { pointer in
      let bytes = unsafe UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self)
      return unsafe setsockopt(socket, SOL_SOCKET, SO_SNDBUF, bytes, 4) == 0
        && setsockopt(socket, SOL_SOCKET, SO_RCVBUF, bytes, 4) == 0
    }
    if !status { throw CECNativeError(stage: "setsockopt(SO_SNDBUF/SO_RCVBUF)", code: WSAGetLastError(), retryable: true) }
  }
  if options.transport == .tcp {
    var enabled: Int32 = 1
    let status = withUnsafePointer(to: &enabled) {
      unsafe setsockopt(socket, Int32(IPPROTO_TCP.rawValue), TCP_NODELAY,
        UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self), 4)
    }
    if status != 0 { throw CECNativeError(stage: "setsockopt(TCP_NODELAY)", code: WSAGetLastError(), retryable: true) }
  }
}
package func cecConfigureSocket(_ socket: SOCKET, options: borrowing CECOptions) -> Bool {
  do { try cecConfigureSocketChecked(socket, options: options); return true }
  catch { cecReport(stage: error.stage, error: error.code); return false }
}
package func cecWindowsArguments() throws(CECNativeError) -> [[UInt16]] {
  guard _configure_wide_argv(_crt_argv_unexpanded_arguments) == 0,
    let argv = unsafe __p___wargv().pointee
  else { throw CECNativeError(stage: "wide argv", code: 87, domain: .invariant, category: .initialization) }
  let count = unsafe __p___argc().pointee
  var result: [[UInt16]] = []
  for i in 0..<Int(count) {
    guard let token = unsafe argv[i] else { throw CECNativeError(stage: "wide argv", code: 87, domain: .invariant, category: .initialization) }
    var value: [UInt16] = []
    var n = 0
    while unsafe token[n] != 0 {
      unsafe value.append(token[n])
      n += 1
    }
    result.append(value)
  }
  return result
}
// Console callbacks may overlap removal. The mutex protects only publication of the
// shared atomic container, whose retained reference outlives each callback.
private let consoleControl = Mutex<CECSharedControl?>(nil)
private func consoleHandler(_ type: DWORD) -> WindowsBool {
  guard
    type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT
  else { return false }
  consoleControl.withLock {
    $0?.stopRequested.store(true, ordering: .releasing)
    $0?.signalWake()
  }
  return true
}
package struct CECConsoleRegistration: ~Copyable {
  package borrowing func keepAlive() {}
  package init(control: CECSharedControl) throws(CECNativeError) {
    consoleControl.withLock { $0 = control }
    guard SetConsoleCtrlHandler(consoleHandler, true) else {
      consoleControl.withLock { $0 = nil }
      throw CECNativeError(
        stage: "SetConsoleCtrlHandler", code: Int32(bitPattern: GetLastError()), domain: .win32, category: .initialization)
    }
  }
  deinit {
    SetConsoleCtrlHandler(consoleHandler, false)
    consoleControl.withLock { $0 = nil }
  }
}

import WinSDK

// Native adoption/reset transfers sole ownership; callers must pass a live
// resource and never reset to its already-owned value. Invalid sentinels are
// never released. RIO table pointers belong to Winsock, which outlives owners.
// Arena/CQ/pinned owners are destroyed only after native cancellation drains
// and the worker joins (cecDestroyWorker enforces the release preconditions).

package struct CECSocketOwner: ~Copyable {
  package private(set) var rawValue: SOCKET
  package init(_ value: SOCKET = ~SOCKET(0)) { rawValue = value }
  package mutating func reset(_ value: SOCKET = ~SOCKET(0)) {
    if rawValue != ~SOCKET(0) { closesocket(rawValue) }
    rawValue = value
  }
  package mutating func release() -> SOCKET {
    let value = rawValue
    rawValue = ~SOCKET(0)
    return value
  }
  deinit { if rawValue != ~SOCKET(0) { closesocket(rawValue) } }
}
@unsafe
package struct CECHandleOwner: ~Copyable {
  package private(set) var rawValue: HANDLE?
  package init(_ value: HANDLE? = nil) { unsafe rawValue = unsafe value }
  package mutating func reset(_ value: HANDLE? = nil) {
    if let rawValue = unsafe rawValue, unsafe rawValue != HANDLE(bitPattern: -1) {
      unsafe CloseHandle(rawValue)
    }
    unsafe rawValue = unsafe value
  }
  package mutating func release() -> HANDLE? {
    let value = unsafe rawValue
    unsafe rawValue = nil
    return unsafe value
  }
  deinit {
    if let rawValue = unsafe rawValue, unsafe rawValue != HANDLE(bitPattern: -1) {
      unsafe CloseHandle(rawValue)
    }
  }
}
// Safe ownership and bounded views; raw adoption/access still has an unsafe
// pointer signature. The extent must match the adopted Windows allocation.
@safe
package struct CECVirtualArenaOwner: ~Copyable {
  package private(set) var rawValue: UnsafeMutableRawPointer?
  package private(set) var byteCount: Int
  // Native allocation adoption requires its actual extent; rawValue alone
  // grants no bounded access. Windows borrows it until deregistration and join.
  package init(_ value: UnsafeMutableRawPointer? = nil, byteCount: Int = 0) {
    unsafe rawValue = unsafe value
    self.byteCount = unsafe value == nil ? 0 : max(0, byteCount)
  }
  package mutating func reset(_ value: UnsafeMutableRawPointer? = nil, byteCount: Int = 0) {
    if let rawValue = unsafe rawValue {
      guard unsafe VirtualFree(rawValue, 0, DWORD(MEM_RELEASE)) else { cecFailFast(stage: "client arena release", error: Int32(bitPattern: GetLastError())) }
    }
    unsafe rawValue = unsafe value
    self.byteCount = unsafe value == nil ? 0 : max(0, byteCount)
  }
  package mutating func release() -> UnsafeMutableRawPointer? {
    let value = unsafe rawValue
    unsafe rawValue = nil
    byteCount = 0
    return unsafe value
  }
  package borrowing func withBytes<Result>(
    in range: Range<Int>, _ body: (borrowing Span<UInt8>) -> Result
  ) -> Result? {
    guard range.lowerBound >= 0, range.upperBound <= byteCount, let rawValue = unsafe rawValue
    else { return nil }
    let buffer = unsafe UnsafeBufferPointer(
      start: rawValue.assumingMemoryBound(to: UInt8.self).advanced(by: range.lowerBound),
      count: range.count)
    return unsafe body(Span(_unsafeElements: buffer))
  }
  package mutating func withMutableBytes<Result>(
    in range: Range<Int>, _ body: (inout MutableSpan<UInt8>) -> Result
  ) -> Result? {
    guard range.lowerBound >= 0, range.upperBound <= byteCount, let rawValue = unsafe rawValue
    else { return nil }
    let buffer = unsafe UnsafeMutableBufferPointer(
      start: rawValue.assumingMemoryBound(to: UInt8.self).advanced(by: range.lowerBound),
      count: range.count)
    var view = unsafe MutableSpan(_unsafeElements: buffer)
    return body(&view)
  }
  deinit {
    if let rawValue = unsafe rawValue {
      guard unsafe VirtualFree(rawValue, 0, DWORD(MEM_RELEASE)) else { cecFailFast(stage: "client arena release", error: Int32(bitPattern: GetLastError())) }
    }
  }
}
@unsafe
package struct CECRIORegistrationOwner: ~Copyable {
  private var rio = RIO_EXTENSION_FUNCTION_TABLE()
  package private(set) var rawValue: RIO_BUFFERID?
  package init() { unsafe rawValue = nil }
  package init(rio: RIO_EXTENSION_FUNCTION_TABLE, value: RIO_BUFFERID) {
    unsafe self.rio = rio
    unsafe rawValue = unsafe value
  }
  package mutating func reset() {
    if let rawValue = unsafe rawValue { unsafe rio.RIODeregisterBuffer!(rawValue) }
    unsafe rawValue = nil
  }
  package mutating func reset(rio: RIO_EXTENSION_FUNCTION_TABLE, value: RIO_BUFFERID) {
    unsafe reset()
    unsafe self.rio = rio
    unsafe rawValue = unsafe value
  }
  package mutating func release() -> RIO_BUFFERID? {
    let value = unsafe rawValue
    unsafe rawValue = nil
    return unsafe value
  }
  deinit { if let rawValue = unsafe rawValue { unsafe rio.RIODeregisterBuffer!(rawValue) } }
}
@unsafe
package struct CECRIOCQOwner: ~Copyable {
  private var rio = RIO_EXTENSION_FUNCTION_TABLE()
  package private(set) var rawValue: RIO_CQ?
  package init() { unsafe rawValue = nil }
  package init(rio: RIO_EXTENSION_FUNCTION_TABLE, value: RIO_CQ) {
    unsafe self.rio = rio
    unsafe rawValue = unsafe value
  }
  package mutating func reset() {
    if let rawValue = unsafe rawValue { unsafe rio.RIOCloseCompletionQueue!(rawValue) }
    unsafe rawValue = nil
  }
  package mutating func reset(rio: RIO_EXTENSION_FUNCTION_TABLE, value: RIO_CQ) {
    unsafe reset()
    unsafe self.rio = rio
    unsafe rawValue = unsafe value
  }
  package mutating func release() -> RIO_CQ? {
    let value = unsafe rawValue
    unsafe rawValue = nil
    return unsafe value
  }
  deinit { if let rawValue = unsafe rawValue { unsafe rio.RIOCloseCompletionQueue!(rawValue) } }
}
/// Owns a stable allocation. Native callbacks borrow this address until their owner joins.
@unsafe
package struct CECPinnedStorage<Element>: ~Copyable {
  package let count: Int
  package let baseAddress: UnsafeMutablePointer<Element>
  package init?(count: Int, initialValue: Element) {
    guard count > 0, MemoryLayout<Element>.alignment <= 16 else { return nil }
    let (bytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
    guard !overflow, let raw = unsafe HeapAlloc(GetProcessHeap(), 0, UInt64(bytes)) else {
      return nil
    }
    unsafe self.count = count
    unsafe baseAddress = unsafe raw.bindMemory(to: Element.self, capacity: count)
    unsafe baseAddress.initialize(repeating: initialValue, count: count)
  }
  deinit {
    unsafe baseAddress.deinitialize(count: count)
    unsafe HeapFree(GetProcessHeap(), 0, baseAddress)
  }
}

import ucrt

// Offsets are cached at startup; each view checks its attempt's logical extent.
package func cecAttemptBufferRange(offset: Int, maximumBytes: Int, count: Int) -> Range<Int>? {
  guard offset >= 0, maximumBytes > 0, count >= 0, count <= maximumBytes else { return nil }
  let (end, overflow) = offset.addingReportingOverflow(count)
  return overflow ? nil : offset..<end
}

// Both offset arithmetic and the allocation extent are checked before a view
// is constructed. These checks preserve the UInt32 RIO arena layout.
package func cecSessionBufferRange(
  index: Int, maximumBytes: Int, count: Int, received: Bool
) -> Range<Int>? {
  guard index >= 0, maximumBytes > 0, count >= 0, count <= maximumBytes else { return nil }
  let (stride, strideOverflow) = maximumBytes.multipliedReportingOverflow(by: 2)
  let (base, baseOverflow) = index.multipliedReportingOverflow(by: stride)
  let (start, startOverflow) = base.addingReportingOverflow(received ? maximumBytes : 0)
  let (end, endOverflow) = start.addingReportingOverflow(count)
  guard !strideOverflow, !baseOverflow, !startOverflow, !endOverflow else { return nil }
  return start..<end
}

// Synchronous native comparison; both spans contain initialized bytes and
// remain borrowed for the complete call. Empty spans never export nil to C.
package func cecBytesEqual(_ lhs: borrowing Span<UInt8>, _ rhs: borrowing Span<UInt8>) -> Bool {
  guard lhs.count == rhs.count else { return false }
  guard !lhs.isEmpty else { return true }
  return lhs.withUnsafeBufferPointer { left in
    rhs.withUnsafeBufferPointer { right in
      unsafe memcmp(left.baseAddress!, right.baseAddress!, left.count) == 0
    }
  }
}

import Foundation
import WinSDK

package func cecReport(stage: String, error: Int32) {
  FileHandle.standardError.write(Data("\(stage) failed: native_error=\(error)\n".utf8))
}
package func cecFailFast(stage: String, error: Int32) -> Never {
  cecReport(stage: stage, error: error)
  while true { unsafe TerminateProcess(GetCurrentProcess(), 4) }
}
package func cecRequireRIONotifySuccess(_ status: Int32, stage: String) {
  if status == 10037 { cecFailFast(stage: "RIONotify duplicate arm", error: status) }
  if status != 0 { cecFailFast(stage: stage, error: status) }
}
package func cecRequireValidDequeueCount(_ count: UInt32, stage: String) -> UInt32 {
  if count == UInt32.max { cecFailFast(stage: stage, error: 13) }
  return count
}
package func cecRequireNotificationPacket(
  key: UInt, overlapped: UnsafePointer<OVERLAPPED>?, expectedKey: UInt,
  expectedOverlapped: UnsafePointer<OVERLAPPED>?, stage: String
) {
  if unsafe !cecNotificationPacketMatches(
    key: key, overlapped: overlapped, expectedKey: expectedKey,
    expectedOverlapped: expectedOverlapped)
  {
    cecFailFast(stage: stage, error: 13)
  }
}
package func cecRequireOutstanding(_ count: UInt32, stage: String) {
  if count == 0 { cecFailFast(stage: stage, error: 13) }
}
package func cecRequireControlPostSuccess(_ succeeded: Bool, error: Int32, stage: String) {
  if !succeeded { cecFailFast(stage: stage, error: error) }
}

// This record contains provider state only. Session decisions live in WorkerCore.
// It is initialized in a pinned allocation before Windows borrows any address.
@unsafe
package struct CECEngineSession {
  package var owner: UnsafeMutablePointer<CECEngineWorker>?
  package var index: UInt32 = 0
  package var generation: UInt32 = 0
  package var socket: SOCKET = ~SOCKET(0)
  package var requestQueue: RIO_RQ?
  package var connectOverlapped = unsafe OVERLAPPED()
  package var connectOutstanding = false
  package var sendOutstanding = false
  package var receiveOutstanding = false
  package var closing = false
  package var drainReported = false
  package var closeStartedAt: UInt64 = 0
  package var sendOffset = 0
  package var sendPostedBytes = 0
  package var receivePostedBytes = 0
  package var completedReceiveBytes = 0
  package var sendArenaOffset = 0
  package var receiveArenaOffset = 0
  package var sendBuffer = unsafe RIO_BUF()
  package var receiveBuffer = unsafe RIO_BUF()
  package var outstanding: UInt32 {
    UInt32(connectOutstanding ? 1 : 0) + UInt32(sendOutstanding ? 1 : 0)
      + UInt32(receiveOutstanding ? 1 : 0)
  }
  package init() {}
}
package struct CECEngineRequest {
  package var sessionIndex: UInt32 = 0
  package var operation: CECEngineOperation = .receive
}
package enum CECRioContext {
  package static func encode(index: UInt32, generation: UInt32, operation: CECEngineOperation) -> UInt64 {
    UInt64(index) | (UInt64(generation) << 20) | (UInt64(operation.rawValue + 1) << 52)
  }
  package static func decode(_ context: UInt64) -> (UInt32, UInt32, CECEngineOperation)? {
    guard context >> 55 == 0 else { return nil }
    let tag = UInt8((context >> 52) & 7)
    guard tag != 0, let operation = CECEngineOperation(rawValue: tag - 1) else { return nil }
    return (UInt32(context & 0xfffff), UInt32((context >> 20) & 0xffffffff), operation)
  }
}
// RequestContext is an opaque integer encoded as an address; it is never
// dereferenced. A completion carries the generation that was posted, rather
// than rereading mutable request metadata from a reused slot.
package func cecReceiveRequest(_ slot: UnsafeMutablePointer<CECEngineSession>) -> UnsafeMutablePointer<CECEngineRequest> {
  unsafe UnsafeMutablePointer(bitPattern: UInt(CECRioContext.encode(index: slot.pointee.index,
    generation: slot.pointee.generation, operation: .receive)))!
}
package func cecSendRequest(_ slot: UnsafeMutablePointer<CECEngineSession>) -> UnsafeMutablePointer<CECEngineRequest> {
  unsafe UnsafeMutablePointer(bitPattern: UInt(CECRioContext.encode(index: slot.pointee.index,
    generation: slot.pointee.generation, operation: .send)))!
}
private let cecConnectOffset: Int = unsafe MemoryLayout<CECEngineSession>.offset(of: \CECEngineSession.connectOverlapped)!
package func cecConnectOverlapped(_ slot: UnsafeMutablePointer<CECEngineSession>) -> UnsafeMutablePointer<OVERLAPPED> {
  unsafe UnsafeMutableRawPointer(slot).advanced(by: cecConnectOffset).assumingMemoryBound(to: OVERLAPPED.self)
}
package func cecNotificationPacketMatches(key: UInt, overlapped: UnsafePointer<OVERLAPPED>?,
  expectedKey: UInt, expectedOverlapped: UnsafePointer<OVERLAPPED>?) -> Bool {
  unsafe key == expectedKey && overlapped == expectedOverlapped
}
package struct CECNativeClock {
  package var frequency: UInt64
  package func nowTicks() -> UInt64 {
    var now = LARGE_INTEGER()
    guard unsafe QueryPerformanceCounter(&now), now.QuadPart >= 0 else {
      cecFailFast(stage: "QueryPerformanceCounter(client timer)", error: Int32(bitPattern: GetLastError()))
    }
    return UInt64(now.QuadPart)
  }
}

/// Fallible fixed capacity owner. Bounded access always borrows the owning value;
/// no escapable pointer view can outlive its allocation.
@safe
package struct CECFixedArray<Element>: ~Copyable {
  private let storage: UnsafeMutablePointer<Element>?
  package let count: Int
  package init() { unsafe storage = nil; count = 0 }
  package init(count: Int, repeating value: Element) throws(CECFailure) {
    guard count >= 0, MemoryLayout<Element>.alignment <= 16 else { throw .allocation(stage: "fixed array allocation") }
    self.count = count
    if count == 0 { unsafe storage = nil; return }
    let (bytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
    guard !overflow, let raw = unsafe HeapAlloc(GetProcessHeap(), 0, UInt64(bytes)) else { throw .allocation(stage: "fixed array allocation") }
    unsafe storage = raw.bindMemory(to: Element.self, capacity: count)
    unsafe storage!.initialize(repeating: value, count: count)
  }
  package var indices: Range<Int> { 0..<count }
  package var isEmpty: Bool { count == 0 }
  package subscript(index: Int) -> Element {
    get { precondition(index >= 0 && index < count); return unsafe storage![index] }
    set { precondition(index >= 0 && index < count); unsafe storage![index] = newValue }
  }
  deinit {
    if let storage = unsafe storage {
      unsafe storage.deinitialize(count: count)
      unsafe HeapFree(GetProcessHeap(), 0, storage)
    }
  }
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
  // The handle crosses the lock as a bit pattern: a raw pointer is not Sendable, so returning the
  // member of the borrowed inout parameter would send a non-Sendable value out of the lock's
  // isolation region. The lock guards adoption, not the caller's later use of the value.
  private func wakeHandle() -> HANDLE? {
    let bits: UInt = unsafe wake.withLock { UInt(bitPattern: unsafe $0.rawValue) }
    guard bits != 0 else { return nil }
    return unsafe HANDLE(bitPattern: bits)
  }
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
/// /n is a per-session quota. The grant is computed against the session's own claimed counter; the
/// run keeps the aggregate of every grant, which is what the final accounting validates.
