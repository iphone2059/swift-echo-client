import Synchronization
import Testing
import WinSDK

@testable import CECClientCore

private struct RegistrationTrace: Sendable {
  var failAt = 1
  var regions: [UInt] = []
  var lengths: [UInt32] = []
  var releases: [UInt] = []
  var queueClosed = false
  var releaseOrderValid = true
  var memoryAliveAtRelease = true
}
private let registrationTrace = Mutex(RegistrationTrace())

@Suite(.serialized) struct CECRegistrationTests {
  @Test func partialRegistrationFailureAndSharedLayout() {
    // First send, first receive, middle send, and final receive.
    for failAt in [1, 2, 3, 6] {
      registrationTrace.withLock { $0 = RegistrationTrace(failAt: failAt) }
      var rio = RIO_EXTENSION_FUNCTION_TABLE()
      rio.RIORegisterBuffer = { pointer, length in
        registrationTrace.withLock { trace in
          trace.regions.append(UInt(bitPattern: pointer))
          trace.lengths.append(length)
          let call = trace.regions.count
          if call == trace.failAt {
            WSASetLastError(8)
            return nil
          }
          return RIO_BUFFERID(bitPattern: call)
        }
      }
      rio.RIODeregisterBuffer = { buffer in
        registrationTrace.withLock { trace in
          let id = UInt(bitPattern: buffer)
          trace.releases.append(id)
          trace.releaseOrderValid = trace.releaseOrderValid && trace.queueClosed
          var info = MEMORY_BASIC_INFORMATION()
          let address = UnsafeRawPointer(bitPattern: trace.regions[Int(id) - 1])
          let queried = VirtualQuery(address, &info, UInt64(MemoryLayout<MEMORY_BASIC_INFORMATION>.size))
          trace.memoryAliveAtRelease =
            trace.memoryAliveAtRelease && queried != 0 && info.State == DWORD(UInt32(MEM_COMMIT))
        }
      }
      rio.RIOCreateCompletionQueue = { _, _ in RIO_CQ(bitPattern: 0x1000) }
      rio.RIOCloseCompletionQueue = { _ in
        registrationTrace.withLock { $0.queueClosed = true }
      }
      var bytes = UniqueArray<UInt8>()
      bytes.append(1); bytes.append(0); bytes.append(2); bytes.append(3)
      let owner = CECWorkerOwner(configuration: CECWorkerConfiguration(
        options: CECOptions(), remoteAddress: SOCKADDR_IN(),
        extensions: CECNativeExtensions(rio: rio, connectEx: nil),
        pattern: CECPatternStorage(consume bytes), maximumAttemptBytes: 16,
        metrics: CECEngineMetrics(), control: CECSharedControl(), workerIndex: 0,
        sessionCount: 3, memoryShare: 64))
      let w = owner.baseAddress
      #expect(!cecInitializeWorker(w))
      #expect(w.pointee.resources.thread.rawValue == nil)
      #expect(w.pointee.resources.registrations.count == failAt - 1)
      #expect(w.pointee.resources.arena.byteCount == 64)
      let first = UInt(bitPattern: w.pointee.memory)
      let trace = registrationTrace.withLock { $0 }
      for i in trace.regions.indices {
        #expect(trace.regions[i] == first + (i.isMultiple(of: 2) ? 0 : UInt((i / 2 + 1) * 16)))
        #expect(trace.lengths[i] == 16)
      }
      for i in 0..<(failAt - 1) / 2 {
        let s = w.pointee.sessionAddress!.advanced(by: i)
        #expect(UInt(bitPattern: s.pointee.sendBuffer.BufferId) == UInt(i * 2 + 1))
        #expect(UInt(bitPattern: s.pointee.receiveBuffer.BufferId) == UInt(i * 2 + 2))
        #expect(s.pointee.receiveArenaOffset == (i + 1) * 16)
      }
      #expect(w.pointee.resources.arena.withBytes(in: 0..<16) { view in
        (0..<16).allSatisfy { view[$0] == [UInt8(1), 0, 2, 3][$0 % 4] }
      } == true)
      cecDestroyWorker(w)
      cecDestroyWorker(w)
      let released = registrationTrace.withLock { $0 }
      #expect(Set(released.releases) == Set((1..<failAt).map(UInt.init)))
      #expect(released.releases.count == failAt - 1)
      #expect(released.queueClosed && released.releaseOrderValid && released.memoryAliveAtRelease)
      #expect(w.pointee.resources.arena.rawValue == nil)
    }
  }
}
