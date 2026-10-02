import WinSDK

package enum CECPatternError: Error, Equatable { case invalidUTF16, empty, allocationFailure }
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
// initialized UInt8s; the initial source and destination must be disjoint.
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
    ? options.literalPatternUTF16 : Array("C++ echo from ".utf16) + options.hostUTF16
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
