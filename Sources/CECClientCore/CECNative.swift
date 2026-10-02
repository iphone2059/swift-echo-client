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
    if status != 0 { throw CECNativeError(stage: "WSAStartup", code: status) }
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
    throw CECNativeError(stage: "WSASocketW(RIO probe)", code: WSAGetLastError())
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
      stage: "SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER(RIO)", code: WSAGetLastError())
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
      stage: "SIO_GET_EXTENSION_FUNCTION_POINTER(ConnectEx)", code: WSAGetLastError())
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
    throw CECNativeError(stage: "GetAddrInfoW(IPv4)", code: status)
  }
  return unsafe UnsafeRawPointer(addr).load(as: SOCKADDR_IN.self)
}
package func cecConfigureSocket(_ socket: SOCKET, options: borrowing CECOptions) -> Bool {
  if options.socketBufferBytes > 0 {
    var size = Int32(options.socketBufferBytes)
    let status = withUnsafePointer(to: &size) { p in
      let bytes = unsafe UnsafeRawPointer(p).assumingMemoryBound(to: CChar.self)
      return unsafe setsockopt(socket, SOL_SOCKET, SO_SNDBUF, bytes, 4) == 0
        && setsockopt(socket, SOL_SOCKET, SO_RCVBUF, bytes, 4) == 0
    }
    if !status {
      cecReport(stage: "setsockopt(SO_SNDBUF/SO_RCVBUF)", error: WSAGetLastError())
      return false
    }
  }
  if options.transport == .tcp {
    var enabled: Int32 = 1
    let status = withUnsafePointer(to: &enabled) {
      unsafe setsockopt(
        socket, Int32(IPPROTO_TCP.rawValue), TCP_NODELAY,
        UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self), 4)
    }
    if status != 0 {
      cecReport(stage: "setsockopt(TCP_NODELAY)", error: WSAGetLastError())
      return false
    }
  }
  return true
}
package func cecWindowsArguments() throws(CECNativeError) -> [[UInt16]] {
  guard _configure_wide_argv(_crt_argv_unexpanded_arguments) == 0,
    let argv = unsafe __p___wargv().pointee
  else { throw CECNativeError(stage: "wide argv", code: 87) }
  let count = unsafe __p___argc().pointee
  var result: [[UInt16]] = []
  for i in 0..<Int(count) {
    guard let token = unsafe argv[i] else { throw CECNativeError(stage: "wide argv", code: 87) }
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
        stage: "SetConsoleCtrlHandler", code: Int32(bitPattern: GetLastError()))
    }
  }
  deinit {
    SetConsoleCtrlHandler(consoleHandler, false)
    consoleControl.withLock { $0 = nil }
  }
}
