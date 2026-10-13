import WinSDK

package enum CECPatternError: Error, Equatable { case invalidUTF16, empty, allocationFailure }

/// Payload sizing is pure and performs no allocation. Production may allocate the returned extent
/// through a fallible native owner, then fill its synchronous mutable view.
package func cecPatternByteCount(options: borrowing CECOptions) throws(CECPatternError) -> Int {
  let size: UInt64
  switch options.patternKind {
  case .binaryCounter, .printableCounter:
    size = UInt64(options.patternBytes)
  case .literalText:
    guard let bytes = cecUTF8ByteCount(options.literalPatternUTF16) else { throw .invalidUTF16 }
    size = bytes
  case .defaultText:
    guard let bytes = cecUTF8ByteCount(options.hostUTF16) else { throw .invalidUTF16 }
    size = UInt64(CECConstants.defaultTextPrefix.utf8.count) + bytes
  }
  guard size > 0 else { throw .empty }
  let maximum = options.transport == .udp
    ? CECConstants.maximumUDPPayloadBytes : CECConstants.maximumTCPBatchBytes
  guard size <= maximum else { throw .empty }
  return Int(size)
}

package func cecFillPattern(
  options: borrowing CECOptions, destination: inout MutableSpan<UInt8>
) throws(CECPatternError) {
  let count = try cecPatternByteCount(options: options)
  guard destination.count == count else { throw .empty }
  if options.patternKind == .binaryCounter {
    cecFillBinaryPattern(&destination)
    return
  }
  if options.patternKind == .printableCounter {
    cecFillPrintablePattern(&destination)
    return
  }
  let prefix: InlineArray<10, UInt8> = [101, 99, 104, 111, 32, 102, 114, 111, 109, 32]
  let prefixCount = options.patternKind == .defaultText ? prefix.count : 0
  let text = options.patternKind == .literalText ? options.literalPatternUTF16 : options.hostUTF16
  let written = destination.withUnsafeMutableBufferPointer { output in
    for index in 0..<prefixCount { output[index] = prefix[index] }
    if text.isEmpty { return prefixCount }
    let result = text.withUnsafeBufferPointer { input in
      unsafe WideCharToMultiByte(
        UINT(CP_UTF8), DWORD(WC_ERR_INVALID_CHARS), input.baseAddress, Int32(input.count),
        UnsafeMutableRawPointer(output.baseAddress!.advanced(by: prefixCount))
          .assumingMemoryBound(to: CChar.self), Int32(count - prefixCount), nil, nil)
    }
    return result > 0 ? prefixCount + Int(result) : 0
  }
  guard written == count else { throw .invalidUTF16 }
}
private let printableDivisors: InlineArray<8, Int> =
  [10_000_000, 1_000_000, 100_000, 10_000, 1_000, 100, 10, 1]
@inline(__always)
private func printableByte(at i: Int) -> UInt8 {
  i % 9 == 8 ? 32 : UInt8(48 + (i / 9 / printableDivisors[i % 9]) % 10)
}
package func cecFillBinaryPattern(_ output: inout MutableSpan<UInt8>) {
  for i in output.indices { output[i] = UInt8(truncatingIfNeeded: i) }
}
package func cecFillPrintablePattern(_ output: inout MutableSpan<UInt8>) {
  for i in output.indices {
    output[i] = printableByte(at: i)
  }
}
package func cecFillRepeatedPattern(
  destination: inout MutableSpan<UInt8>, pattern: borrowing Span<UInt8>
) {
  guard !pattern.isEmpty else { return }
  guard !destination.isEmpty else { return }
  destination.withUnsafeMutableBufferPointer { output in
    pattern.withUnsafeBufferPointer { input in
      unsafe cecCopyRepeatedBytes(destination: output, pattern: input)
    }
  }
}
// Called only inside the owners' synchronous buffer borrows. Inputs contain
// initialized UInt8s; the initial source and destination must be disjoint or the same initialized prefix.
package func cecCopyRepeatedBytes(
  destination: UnsafeMutableBufferPointer<UInt8>, pattern: UnsafeBufferPointer<UInt8>
) {
  guard !destination.isEmpty && !pattern.isEmpty else { return }
  let first = min(destination.count, pattern.count)
  unsafe destination.baseAddress!.update(from: pattern.baseAddress!, count: first)
  var filled = first
  while filled < destination.count {
    let count = min(filled, destination.count - filled)
    // Copy at most the initialized prefix: source and suffix never overlap.
    unsafe destination.baseAddress!.advanced(by: filled).update(
      from: destination.baseAddress!, count: count)
    filled += count
  }
}
package func cecBuildPattern(options: borrowing CECOptions) throws(CECPatternError) -> UniqueArray<
  UInt8
> {
  _ = try cecPatternByteCount(options: options)
  if options.patternKind == .binaryCounter || options.patternKind == .printableCounter {
    return UniqueArray<UInt8>(capacity: Int(options.patternBytes)) { output in
      for i in 0..<Int(options.patternBytes) {
        output.append(
          options.patternKind == .binaryCounter
            ? UInt8(truncatingIfNeeded: i) : printableByte(at: i))
      }
    }
  }
  let text =
    options.patternKind == .literalText
    ? options.literalPatternUTF16 : Array("echo from ".utf16) + options.hostUTF16
  guard !text.isEmpty else { throw .empty }
  let count = text.withUnsafeBufferPointer {
    unsafe WideCharToMultiByte(
      UINT(CP_UTF8), DWORD(WC_ERR_INVALID_CHARS), $0.baseAddress, Int32($0.count), nil, 0,
      nil, nil)
  }
  guard count > 0 else { throw .invalidUTF16 }
  // OutputSpan owns uninitialized storage. Windows writes each byte once;
  // initializedCount tracks only the successfully written prefix on failure.
  return try UniqueArray<UInt8>(capacity: Int(count)) {
    (outputSpan: inout OutputSpan<UInt8>) throws(CECPatternError) in
    let written = text.withUnsafeBufferPointer { input in
      unsafe outputSpan.withUnsafeMutableBufferPointer { output, initializedCount in
        let written = unsafe WideCharToMultiByte(
          UINT(CP_UTF8), DWORD(WC_ERR_INVALID_CHARS), input.baseAddress, Int32(input.count),
          UnsafeMutableRawPointer(output.baseAddress!).assumingMemoryBound(to: CChar.self),
          count, nil, nil)
        initializedCount = Int(max(0, written))
        return written
      }
    }
    guard written == count else { throw .invalidUTF16 }
  }
}
package func cecMaximumAttemptBytes(options: borrowing CECOptions, patternBytes: UInt64) -> UInt64?
{
  guard patternBytes > 0 else { return nil }
  if options.transport == .udp {
    return patternBytes <= CECConstants.maximumUDPPayloadBytes ? patternBytes : nil
  }
  guard let batch = cecCheckedProduct(patternBytes, UInt64(options.pipelineDepth)),
    batch <= CECConstants.maximumTCPBatchBytes
  else { return nil }
  return batch
}

/// Immutable startup payload. Worker calls borrow it only for synchronous initialization copies;
/// completed RIO requests use each worker's independent registered windows.
package final class CECPatternStorage {
  private let storage: UniqueArray<UInt8>
  package var bytes: UniqueArray<UInt8> { borrow { storage } }
  package init(_ bytes: consuming UniqueArray<UInt8>) { storage = bytes }
  package func fill(_ destination: inout MutableSpan<UInt8>) {
    let pattern = Ref(bytes)
    pattern.value.span.withUnsafeBufferPointer { input in
      destination.withUnsafeMutableBufferPointer { output in
        unsafe cecCopyRepeatedBytes(destination: output, pattern: input)
      }
    }
  }
}
