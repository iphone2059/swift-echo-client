import Synchronization
import Testing
import WinSDK

@testable import CECClientCore

private struct FeatureCell: ~Copyable {
  var value: UInt64
}

private struct FeatureWrapper: ~Copyable {
  private var storage: FeatureCell
  init(_ value: UInt64) { storage = FeatureCell(value: value) }
  var element: FeatureCell {
    borrow { storage }
    mutate { &storage }
  }
}

@Suite struct CECOwnershipFeatureTests {
  @Test func nativeWidths() {
    #expect(MemoryLayout<UInt>.size == 8)
    #expect(MemoryLayout<SOCKET>.size == 8)
    #expect(MemoryLayout<HANDLE>.size == 8)
    #expect(MemoryLayout<WCHAR>.size == 2)
    #expect(CECConstants.maximumTCPBatchBytes == 67_108_864)
    _ = RIO_BUF()
    _ = RIORESULT()
    _ = RIO_NOTIFICATION_COMPLETION()
    _ = RIO_EXTENSION_FUNCTION_TABLE()
    let connect: LPFN_CONNECTEX? = nil
    #expect(connect == nil)
  }

  @Test func uniqueCollectionsAndBorrowing() {
    var wrapper = FeatureWrapper(7)
    wrapper.element.value = 9
    #expect(wrapper.element.value == 9)
    var values = UniqueArray<FeatureCell>()
    values.append(FeatureCell(value: 42))
    #expect(values.count == 1)
    #expect(values[0].value == 42)
    let box = UniqueBox(FeatureCell(value: 11))
    #expect(box.value.value == 11)
    let bytes: InlineArray<4, UInt8> = [1, 2, 3, 4]
    #expect(bytes.span[2] == 3)
    let results = InlineArray<256, RIORESULT>(repeating: RIORESULT())
    #expect(results.count == 256)
    let atomic = Atomic<UInt64>(0)
    #expect(atomic.wrappingAdd(1, ordering: .relaxed).newValue == 1)
  }
}
