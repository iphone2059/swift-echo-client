import Testing
import WinSDK

@testable import CECClientCore

@Suite struct CECNativeTests {
  @Test func preparation() throws {
    let winsock = try CECWinSockOwner()
    defer { _ = winsock }
    let ext = try cecLoadExtensions()
    #expect(ext.rio.RIOReceive != nil && ext.rio.RIOSend != nil && ext.connectEx != nil)
    for host in ["127.0.0.1", "localhost"] {
      let address = try cecResolveIPv4(hostUTF16: Array(host.utf16), port: 12345)
      #expect(address.sin_family == AF_INET && address.sin_port == htons(12345))
    }
    #expect(throws: CECNativeError.self) {
      try cecResolveIPv4(hostUTF16: Array("[invalid-ipv4]".utf16), port: 7)
    }
    for transport in [CECTransport.tcp, .udp] {
      let socket = CECSocketOwner(cecRegisteredSocket(transport: transport))
      #expect(socket.rawValue != ~SOCKET(0))
      var options = CECOptions()
      options.transport = transport
      options.socketBufferBytes = 65536
      #expect(cecConfigureSocket(socket.rawValue, options: options))
      var value: Int32 = 0
      var size: Int32 = 4
      let status = withUnsafeMutablePointer(to: &value) {
        getsockopt(
          socket.rawValue, SOL_SOCKET, SO_SNDBUF,
          UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), &size)
      }
      #expect(status == 0 && value >= 65536)
      let receiveStatus = withUnsafeMutablePointer(to:&value) {
        getsockopt(socket.rawValue,SOL_SOCKET,SO_RCVBUF,UnsafeMutableRawPointer($0).assumingMemoryBound(to:CChar.self),&size)
      }
      #expect(receiveStatus == 0 && value >= 65536)
      if transport == .tcp {
        // Winsock returns boolean options as one byte on this SDK. Clear the
        // previous integer buffer result before querying it.
        value = 0; size = 4
        let noDelayStatus = withUnsafeMutablePointer(to:&value) {
          getsockopt(socket.rawValue,Int32(IPPROTO_TCP.rawValue),TCP_NODELAY,UnsafeMutableRawPointer($0).assumingMemoryBound(to:CChar.self),&size)
        }
        #expect(noDelayStatus == 0)
        #expect(value == 1)
        #expect(size == 1 || size == 4)
      }
    }
    let args = try cecWindowsArguments()
    #expect(!args.isEmpty && !args[0].isEmpty)
  }
}
