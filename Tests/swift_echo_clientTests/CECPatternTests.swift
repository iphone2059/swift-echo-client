import Testing

@testable import CECClientCore

@Suite struct CECPatternTests {
  @Test func doublingFillBoundaries() throws {
    for kind in [CECPatternKind.binaryCounter, .printableCounter, .literalText] {
      var o = CECOptions()
      o.patternKind = kind
      o.patternBytes = 9
      o.literalPatternUTF16 = [65, 0, 66]
      let pattern = try cecBuildPattern(options: o)
      for length in [0, 1, 2, 3, 8, 9, 10, 17, 65_537, 1_048_576] {
        var destination = [UInt8](repeating: 0xAB, count: length + 2)
        destination.withUnsafeMutableBufferPointer { buffer in
          var view = MutableSpan(_unsafeElements:
            UnsafeMutableBufferPointer(rebasing: buffer[1..<(length + 1)]))
          cecFillRepeatedPattern(destination: &view, pattern: pattern.span)
        }
        #expect(destination.first == 0xAB && destination.last == 0xAB)
        #expect((0..<length).allSatisfy { destination[$0 + 1] == pattern[$0 % pattern.count] })
      }
    }
    var destination: [UInt8] = [1, 2, 3]
    let empty: [UInt8] = []
    do {
      var view = destination.mutableSpan
      cecFillRepeatedPattern(destination: &view, pattern: empty.span)
    }
    #expect(destination == [1, 2, 3])
  }
  @Test func initializationBoundaries() throws {
    var o = CECOptions()
    o.patternKind = .literalText
    o.literalPatternUTF16 = [0x0041, 0, 0xD83D, 0xDE00, 0x0042]
    let literal = try cecBuildPattern(options: o)
    #expect((0..<literal.count).map { literal[$0] } == [65, 0, 240, 159, 152, 128, 66])
    o.literalPatternUTF16 = [0xDC00]
    #expect(throws: CECPatternError.invalidUTF16) { try cecBuildPattern(options: o) }
    for kind in [CECPatternKind.binaryCounter, .printableCounter] {
      o.patternKind = kind
      for size in [0, 1, 8, 9, 10, 90, 513] {
        o.patternBytes = UInt32(size)
        let pattern = try cecBuildPattern(options: o)
        #expect(pattern.count == size)
      }
    }
    var bytes = [UInt8](repeating: 0xAB, count: 20)
    bytes.withUnsafeMutableBufferPointer { buffer in
      var view = MutableSpan(_unsafeElements: UnsafeMutableBufferPointer(rebasing: buffer[1..<19]))
      cecFillPrintablePattern(&view)
    }
    #expect(bytes.first == 0xAB && bytes.last == 0xAB)
    #expect(Array(bytes[1..<19]) == Array("00000000 00000001 ".utf8))
  }
  @Test func bytes() throws {
    var o = try cecParseOptions(wideArgs(["client", "127.0.0.1", "/p", "tcp"]))
    let p = try cecBuildPattern(options: o)
    #expect((0..<p.count).map { p[$0] } == Array("C++ echo from 127.0.0.1".utf8))
    o.patternKind = .binaryCounter
    o.patternBytes = 513
    let b = try cecBuildPattern(options: o)
    #expect(b[0] == 0 && b[255] == 255 && b[256] == 0 && b[512] == 0)
    o.patternKind = .printableCounter
    o.patternBytes = 18
    let t = try cecBuildPattern(options: o)
    #expect((0..<t.count).map { t[$0] } == Array("00000000 00000001 ".utf8))
    o.patternKind = .literalText
    o.literalPatternUTF16 = Array("中文 😀".utf16)
    let u = try cecBuildPattern(options: o)
    #expect((0..<u.count).map { u[$0] } == Array("中文 😀".utf8))
    o.literalPatternUTF16 = [0xD800]
    #expect(throws: CECPatternError.invalidUTF16) { try cecBuildPattern(options: o) }
    o.literalPatternUTF16 = []
    #expect(throws: CECPatternError.empty) { try cecBuildPattern(options: o) }
  }
  @Test func repetitionAndCapacity() {
    var dest = [UInt8](repeating: 0, count: 11)
    let src: [UInt8] = [1, 2, 3]
    do {
      var view = dest.mutableSpan
      cecFillRepeatedPattern(destination: &view, pattern: src.span)
    }
    #expect(dest == [1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2])
    var o = CECOptions()
    o.transport = .udp
    #expect(cecMaximumAttemptBytes(options: o, patternBytes: 65507) == 65507)
    #expect(cecMaximumAttemptBytes(options: o, patternBytes: 65508) == nil)
    o.transport = .tcp
    #expect(cecMaximumAttemptBytes(options: o, patternBytes: 67_108_864) == 67_108_864)
    o.pipelineDepth = 2
    #expect(cecMaximumAttemptBytes(options: o, patternBytes: 67_108_864) == nil)
  }
}
