import CECClientCore
func invalidated(_ arena: inout CECVirtualArenaOwner) -> UInt8? {
  arena.withBytes(in: 0..<1) { bytes in
    unsafe arena.reset()
    return bytes[0]
  }
}
