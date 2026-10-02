import Testing

@testable import CECClientCore

@Suite struct CECTimerHeapTests {
  @Test func equalEarlierLaterAndTies() {
    var heap = CECTimerHeap(capacity: 4)
    for i: UInt32 in 0..<4 {
      let inserted = heap.insertOrUpdate(sessionIndex: i, deadline: 100)
      #expect(inserted)
    }
    let same = heap.insertOrUpdate(sessionIndex: 0, deadline: 100)
    #expect(same)
    #expect(heap.size == 4)
    let earlier = heap.insertOrUpdate(sessionIndex: 3, deadline: 50)
    #expect(earlier)
    let first = heap.popExpired(now: 50)
    #expect(first == 3)
    let later = heap.insertOrUpdate(sessionIndex: 0, deadline: 150)
    #expect(later)
    let second = heap.popExpired(now: 100)
    let third = heap.popExpired(now: 100)
    let none = heap.popExpired(now: 100)
    #expect(second == 1 && third == 2 && none == nil)
    let removed = heap.remove(sessionIndex: 0)
    #expect(removed)
    #expect(heap.size == 0)
  }
  @Test func referenceModel() {
    var heap = CECTimerHeap(capacity: 64)
    #expect(heap.waitMilliseconds(now: 0) == UInt32.max)
    var reference: [UInt32: UInt64] = [:]
    var seed: UInt32 = 0xC0FF_EE11
    func next() -> UInt32 {
      seed ^= seed << 13
      seed ^= seed >> 17
      seed ^= seed << 5
      return seed
    }
    var now: UInt64 = 0
    for _ in 0..<100000 {
      let index = next() % 64
      let op = next() % 3
      if op == 0 {
        let deadline = now + UInt64(next() % 1000)
        let result = heap.insertOrUpdate(sessionIndex: index, deadline: deadline)
        #expect(result)
        reference[index] = deadline
      } else if op == 1 {
        let result = heap.remove(sessionIndex: index)
        #expect(result == (reference.removeValue(forKey: index) != nil))
      } else {
        now += UInt64(next() % 30)
        let first = reference.min { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
        let expected = first.flatMap { $0.value <= now ? $0.key : nil }
        let actual = heap.popExpired(now: now)
        #expect(actual == expected)
        if let expected { reference.removeValue(forKey: expected) }
      }
      #expect(heap.size == reference.count && heap.capacity == 64)
      let deadline = reference.values.min()
      #expect(
        heap.waitMilliseconds(now: now) == deadline.map {
          UInt32(min(UInt64(UInt32.max - 1), $0 > now ? $0 - now : 0))
        } ?? UInt32.max)
    }
    for index in reference.keys { _ = heap.remove(sessionIndex: index) }
    #expect(heap.size == 0)
    _ = heap.insertOrUpdate(sessionIndex: 2, deadline: UInt64.max)
    #expect(heap.waitMilliseconds(now: 0) == UInt32.max - 1)
    #expect(heap.waitMilliseconds(now: UInt64.max - 5) == 5)
  }
}
