package struct CECTimerNode {
  package var deadline: UInt64 = 0
  package var sessionIndex: UInt32 = 0
}
package struct CECTimerHeap: ~Copyable {
  package let capacity: Int
  package private(set) var size = 0
  private var nodes = UniqueArray<CECTimerNode>()
  private var positions = UniqueArray<Int>()
  package init(capacity: UInt32) {
    self.capacity = Int(capacity)
    nodes.reserveCapacity(Int(capacity))
    positions.reserveCapacity(Int(capacity))
    for _ in 0..<capacity {
      nodes.append(CECTimerNode())
      positions.append(-1)
    }
  }
  private borrowing func less(_ a: Int, _ b: Int) -> Bool {
    nodes[a].deadline == nodes[b].deadline
      ? nodes[a].sessionIndex < nodes[b].sessionIndex : nodes[a].deadline < nodes[b].deadline
  }
  private mutating func swap(_ a: Int, _ b: Int) {
    let temporary = nodes[a]
    nodes[a] = nodes[b]
    nodes[b] = temporary
    positions[Int(nodes[a].sessionIndex)] = a
    positions[Int(nodes[b].sessionIndex)] = b
  }
  private mutating func siftUp(_ start: Int) -> Int {
    var i = start
    while i > 0 {
      let parent = (i - 1) / 2
      if !less(i, parent) { break }
      swap(i, parent)
      i = parent
    }
    return i
  }
  private mutating func siftDown(_ start: Int) {
    var i = start
    while i * 2 + 1 < size {
      var child = i * 2 + 1
      if child + 1 < size && less(child + 1, child) { child += 1 }
      if !less(child, i) { break }
      swap(child, i)
      i = child
    }
  }
  package mutating func insertOrUpdate(sessionIndex: UInt32, deadline: UInt64) -> Bool {
    guard Int(sessionIndex) < capacity else { return false }
    var i = positions[Int(sessionIndex)]
    if i >= 0 {
      let previous = nodes[i].deadline
      if previous == deadline { return true }
      nodes[i].deadline = deadline
      if deadline < previous { _ = siftUp(i) } else { siftDown(i) }
      return true
    }
    if i < 0 {
      guard size < capacity else { return false }
      i = size
      size += 1
      positions[Int(sessionIndex)] = i
    }
    nodes[i] = CECTimerNode(deadline: deadline, sessionIndex: sessionIndex)
    _ = siftUp(i)
    return true
  }
  package mutating func remove(sessionIndex: UInt32) -> Bool {
    guard Int(sessionIndex) < capacity else { return false }
    let i = positions[Int(sessionIndex)]
    guard i >= 0 else { return false }
    positions[Int(sessionIndex)] = -1
    size -= 1
    if i < size {
      nodes[i] = nodes[size]
      positions[Int(nodes[i].sessionIndex)] = i
      let p = siftUp(i)
      siftDown(p)
    }
    return true
  }
  package mutating func popExpired(now: UInt64) -> UInt32? {
    guard size > 0, nodes[0].deadline <= now else { return nil }
    let index = nodes[0].sessionIndex
    _ = remove(sessionIndex: index)
    return index
  }
  package borrowing func waitMilliseconds(now: UInt64) -> UInt32 {
    guard size > 0 else { return UInt32.max }
    return UInt32(
      min(UInt64(UInt32.max - 1), nodes[0].deadline > now ? nodes[0].deadline - now : 0))
  }
}
