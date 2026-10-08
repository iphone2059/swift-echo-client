import Synchronization
import Testing
import WinSDK

@testable import CECClientCore

private let releaseOrder = Mutex<[String]>([])
@Suite struct CECOwnershipTests {
  @Test func rioTableLifetimeAndReleaseOrder() {
    releaseOrder.withLock { $0 = [] }
    func makeRegistration() -> CECRIORegistrationOwner {
      var table = RIO_EXTENSION_FUNCTION_TABLE()
      table.RIODeregisterBuffer = { _ in releaseOrder.withLock { $0.append("buffer") } }
      return CECRIORegistrationOwner(rio: table, value: RIO_BUFFERID(bitPattern: 16)!)
    }
    var table = RIO_EXTENSION_FUNCTION_TABLE()
    table.RIOCloseCompletionQueue = { _ in releaseOrder.withLock { $0.append("CQ") } }
    let registration = makeRegistration()
    var moved = consume registration
    var queue = CECRIOCQOwner(rio: table, value: RIO_CQ(bitPattern: 32)!)
    queue.reset()
    queue.reset()
    moved.reset()
    moved.reset()
    #expect(releaseOrder.withLock { $0 } == ["CQ", "buffer"])
  }
  @Test func handlesAndPinnedStorage() throws {
    let h = try #require(CreateEventW(nil, true, false, nil))
    let source = CECHandleOwner(h)
    var target = consume source
    var flags: DWORD = 0
    #expect(GetHandleInformation(h, &flags))
    target.reset()
    #expect(!GetHandleInformation(h, &flags))
    guard let storage = CECPinnedStorage(count: 8, initialValue: UInt64(42)) else {
      Issue.record("allocation failed")
      return
    }
    let p = storage.baseAddress
    p[3] = 100
    #expect(storage.baseAddress == p && p[3] == 100 && p[7] == 42)
    var arena = CECVirtualArenaOwner(
      VirtualAlloc(nil, 4096, DWORD(UInt32(MEM_RESERVE) | UInt32(MEM_COMMIT)), DWORD(UInt32(PAGE_READWRITE))))
    let released = arena.release()
    let address = try #require(released)
    #expect(arena.rawValue == nil)
    var moved = CECVirtualArenaOwner(address)
    moved.reset()
    #expect(moved.rawValue == nil)
  }
}
