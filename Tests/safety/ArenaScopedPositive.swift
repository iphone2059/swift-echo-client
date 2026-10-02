import CECClientCore
func scoped(_ arena: borrowing CECVirtualArenaOwner) -> UInt8? {
  arena.withBytes(in: 0..<1) { $0[0] }
}
