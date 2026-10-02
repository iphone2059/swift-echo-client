import CECClientCore
func escaped(_ arena: borrowing CECVirtualArenaOwner) -> Span<UInt8> {
  arena.withBytes(in: 0..<1) { $0 }!
}
