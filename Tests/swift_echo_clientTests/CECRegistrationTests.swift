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
  var queueCreated = false
  var releaseOrderValid = true
  var memoryAliveAtRelease = true
}
private let registrationTrace = Mutex(RegistrationTrace())
@Suite(.serialized) struct CECRegistrationTests {
  @Test func preparedWorkerReleasesCQBeforeWindowsAndArena() throws {
    registrationTrace.withLock { $0 = RegistrationTrace(failAt: 100) }
    var rio = RIO_EXTENSION_FUNCTION_TABLE()
    rio.RIORegisterBuffer = { pointer, length in
      registrationTrace.withLock { trace in
        trace.regions.append(UInt(bitPattern: pointer))
        trace.lengths.append(length)
        return RIO_BUFFERID(bitPattern: trace.regions.count)
      }
    }
    rio.RIOCreateCompletionQueue = { _, _ in
      registrationTrace.withLock { trace in
        trace.queueCreated = true
        trace.releaseOrderValid = trace.regions.count == 4
      }
      return RIO_CQ(bitPattern: 0x1000)
    }
    rio.RIOCloseCompletionQueue = { _ in registrationTrace.withLock { $0.queueClosed = true } }
    rio.RIODeregisterBuffer = { id in
      registrationTrace.withLock { trace in
        trace.releases.append(UInt(bitPattern: id))
        trace.releaseOrderValid = trace.releaseOrderValid && trace.queueClosed
        var info = MEMORY_BASIC_INFORMATION()
        let address = UnsafeRawPointer(bitPattern: trace.regions[Int(UInt(bitPattern: id)) - 1])
        trace.memoryAliveAtRelease =
          trace.memoryAliveAtRelease
          && VirtualQuery(address, &info, UInt64(MemoryLayout<MEMORY_BASIC_INFORMATION>.size)) != 0
          && info.State == DWORD(UInt32(MEM_COMMIT))
      }
    }
    var pattern = UniqueArray<UInt8>()
    pattern.append(42)
    let owner = CECWorkerOwner(
      configuration: CECWorkerConfiguration(
        options: CECOptions(), remoteAddress: SOCKADDR_IN(),
        extensions: CECNativeExtensions(rio: rio), pattern: CECPatternStorage(consume pattern),
        maximumAttemptBytes: 16, metrics: CECEngineMetrics(), control: CECSharedControl(),
        workerIndex: 0, sessionCount: 2, memoryShare: 64))
    try cecPrepareWorker(owner.baseAddress)
    #expect(owner.baseAddress.pointee.resources.registeredCount == 4)
    #expect(registrationTrace.withLock { $0.queueCreated && !$0.queueClosed })
    cecDestroyWorker(owner.baseAddress)
    let trace = registrationTrace.withLock { $0 }
    #expect(trace.queueClosed && trace.releaseOrderValid && trace.memoryAliveAtRelease)
    #expect(trace.releases == [1, 2, 3, 4])
    #expect(owner.baseAddress.pointee.resources.arena.rawValue == nil)
  }
  @Test func partialRegistrationFailureAndIndependentLayout() {
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
          // Initialization registers before CQ creation. A partial registration
          // failure therefore owns no CQ to close.
          trace.releaseOrderValid = trace.releaseOrderValid && !trace.queueClosed
          var info = MEMORY_BASIC_INFORMATION()
          let address = UnsafeRawPointer(bitPattern: trace.regions[Int(id) - 1])
          let queried = VirtualQuery(
            address, &info, UInt64(MemoryLayout<MEMORY_BASIC_INFORMATION>.size))
          trace.memoryAliveAtRelease =
            trace.memoryAliveAtRelease && queried != 0 && info.State == DWORD(UInt32(MEM_COMMIT))
        }
      }
      rio.RIOCreateCompletionQueue = { _, _ in RIO_CQ(bitPattern: 0x1000) }
      rio.RIOCloseCompletionQueue = { _ in
        registrationTrace.withLock { $0.queueClosed = true }
      }
      var bytes = UniqueArray<UInt8>()
      bytes.append(1)
      bytes.append(0)
      bytes.append(2)
      bytes.append(3)
      let owner = CECWorkerOwner(
        configuration: CECWorkerConfiguration(
          options: CECOptions(), remoteAddress: SOCKADDR_IN(),
          extensions: CECNativeExtensions(rio: rio, connectEx: nil),
          pattern: CECPatternStorage(consume bytes), maximumAttemptBytes: 16,
          metrics: CECEngineMetrics(), control: CECSharedControl(), workerIndex: 0,
          sessionCount: 3, memoryShare: 96))
      let w = owner.baseAddress
      #expect(!cecInitializeWorker(w))
      #expect(w.pointee.resources.thread.rawValue == nil)
      #expect(w.pointee.resources.registeredCount == failAt - 1)
      #expect(w.pointee.resources.arena.byteCount == 96)
      let first = UInt(bitPattern: w.pointee.memory)
      let trace = registrationTrace.withLock { $0 }
      for i in trace.regions.indices {
        #expect(
          trace.regions[i] == first
            + (i.isMultiple(of: 2) ? UInt((i / 2) * 16) : UInt(48 + (i / 2) * 16)))
        #expect(trace.lengths[i] == 16)
      }
      for i in 0..<(failAt - 1) / 2 {
        let s = w.pointee.sessionAddress!.advanced(by: i)
        #expect(UInt(bitPattern: s.pointee.sendBuffer.BufferId) == UInt(i * 2 + 1))
        #expect(UInt(bitPattern: s.pointee.receiveBuffer.BufferId) == UInt(i * 2 + 2))
        #expect(s.pointee.sendArenaOffset == i * 16 && s.pointee.receiveArenaOffset == 48 + i * 16)
      }
      #expect(
        w.pointee.resources.arena.withBytes(in: 0..<16) { view in
          (0..<16).allSatisfy { view[$0] == [UInt8(1), 0, 2, 3][$0 % 4] }
        } == true)
      cecDestroyWorker(w)
      cecDestroyWorker(w)
      let released = registrationTrace.withLock { $0 }
      #expect(Set(released.releases) == Set((1..<failAt).map(UInt.init)))
      #expect(released.releases.count == failAt - 1)
      #expect(!released.queueClosed && released.releaseOrderValid && released.memoryAliveAtRelease)
      #expect(w.pointee.resources.arena.rawValue == nil)
    }
  }
}
