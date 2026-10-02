import Testing
import WinSDK

@testable import CECClientCore

@Suite struct CECArenaTests {
  @Test func sharedStorageAndAttemptRanges() {
    #expect(cecCheckedSharedStorageBytes(sessions: 4, workers: 1, batchBytes: 16, memoryLimit: 80) == 80)
    #expect(cecCheckedSharedStorageBytes(sessions: 4, workers: 4, batchBytes: 16, memoryLimit: 128) == 128)
    #expect(cecCheckedSharedStorageBytes(sessions: 4, workers: 1, batchBytes: 16, memoryLimit: 79) == nil)
    #expect(cecCheckedSharedStorageBytes(sessions: 0, workers: 1, batchBytes: 16, memoryLimit: 100) == nil)
    #expect(cecCheckedSharedStorageBytes(sessions: 4, workers: 5, batchBytes: 16, memoryLimit: 100) == nil)
    #expect(cecCheckedSharedStorageBytes(sessions: UInt64.max, workers: 1, batchBytes: 1, memoryLimit: UInt64.max) == nil)
    #expect(cecCheckedSharedStorageBytes(sessions: 4, workers: 1, batchBytes: UInt64.max, memoryLimit: UInt64.max) == nil)
    #expect(cecAttemptBufferRange(offset: 16, maximumBytes: 16, count: 3) == 16..<19)
    #expect(cecAttemptBufferRange(offset: 0, maximumBytes: 16, count: 0) == 0..<0)
    #expect(cecAttemptBufferRange(offset: -1, maximumBytes: 16, count: 3) == nil)
    #expect(cecAttemptBufferRange(offset: 0, maximumBytes: 16, count: 17) == nil)
    #expect(cecAttemptBufferRange(offset: Int.max, maximumBytes: 16, count: 1) == nil)
  }
  @Test func checkedRanges() {
    #expect(cecSessionBufferRange(index: 1, maximumBytes: 16, count: 9, received: false) == 32..<41)
    #expect(cecSessionBufferRange(index: 1, maximumBytes: 16, count: 9, received: true) == 48..<57)
    #expect(cecSessionBufferRange(index: -1, maximumBytes: 16, count: 1, received: false) == nil)
    #expect(cecSessionBufferRange(index: 0, maximumBytes: 16, count: 17, received: false) == nil)
    #expect(
      cecSessionBufferRange(index: Int.max, maximumBytes: 16, count: 1, received: false) == nil)
    #expect(cecSessionBufferRange(index: 0, maximumBytes: Int.max, count: 1, received: true) == nil)
  }
  @Test func viewsAndGuardBytes() throws {
    var arena = CECVirtualArenaOwner(
      try #require(VirtualAlloc(nil, 64, DWORD(MEM_RESERVE | MEM_COMMIT), DWORD(PAGE_READWRITE))),
      byteCount: 64)
    let initialized: Void? = arena.withMutableBytes(in: 0..<64) { bytes in
      for i in bytes.indices { bytes[i] = 0xAB }
    }
    #expect(initialized != nil)
    let filled: Void? = arena.withMutableBytes(in: 1..<19) { bytes in
      cecFillPrintablePattern(&bytes)
    }
    #expect(filled != nil)
    #expect(
      arena.withBytes(in: 0..<64) { $0[0] == 0xAB && $0[19] == 0xAB && $0[63] == 0xAB } == true)
    #expect(arena.withBytes(in: 63..<65) { _ in true } == nil)
    #expect(arena.withBytes(in: -1..<1) { _ in true } == nil)
    #expect(arena.withBytes(in: 64..<64) { $0.isEmpty } == true)
    #expect(
      arena.withBytes(in: 1..<19) { first in
        arena.withBytes(in: 1..<19) { cecBytesEqual(first, $0) }
      } == true)
    let a: [UInt8] = [1, 2, 3]
    let b: [UInt8] = [1, 2, 4]
    let short: [UInt8] = [1, 2]
    let empty: [UInt8] = []
    #expect(!cecBytesEqual(a.span, b.span) && !cecBytesEqual(a.span, short.span))
    let emptyEqual = cecBytesEqual(empty.span, empty.span)
    #expect(emptyEqual)
    arena.reset()
    #expect(arena.byteCount == 0 && arena.withBytes(in: 0..<0) { _ in true } == nil)
  }
}
