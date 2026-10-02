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
