import Testing

@testable import CECClientCore

func wideArgs(_ values: [String]) -> [[UInt16]] { values.map { Array($0.utf16) } }

@Suite struct CECContractTests {
  @Test func defaults() throws {
    let o = try cecParseOptions(wideArgs(["client", "127.0.0.1", "/p", "tcp"]))
    #expect(o.remotePort == 7 && o.echoCount == 5 && o.timeoutSeconds == 5)
    #expect(o.workerCount == 0 && o.pipelineDepth == 1 && o.sessionCount == 1)
    #expect(o.cqCapacity == 4096 && o.memoryBytes == 1_073_741_824)
    #expect(o.runSeconds == 0 && o.reconnectSeconds == -1)
  }
  @Test(arguments: ["/P=TCP", "-p=tcp", "--p=tcp"])
  func switchForms(_ token: String) throws {
    #expect(try cecParseOptions(wideArgs(["client", "127.0.0.1", token])).transport == .tcp)
  }
  @Test func exactErrorsAndHelpOrder() {
    let cases: [([String], String)] = [
      (["/foo", "1"], "unknown switch"),
      (["/r=", "7001"], "switch requires a non-empty inline value"),
      (["/q=1"], "flag switch does not accept a value"),
      (["/r"], "switch requires a non-empty value"),
      (["/l", "45000", "/c", "2", "/h"], "a fixed /l port requires /c 1"),
      (["/rc", "1", "/l", "45000"], "TCP reconnect cannot use a fixed /l port"),
      (["/d", "x", "/z", "1"], "use exactly one of /d, /z, or /zt"),
      (["/n", "18446744073709551616"], "numeric switch has an invalid value"),
      (["/n", "+1"], "numeric switch has an invalid value"),
    ]
    for (args, message) in cases {
      do {
        _ = try cecParseOptions(wideArgs(["client", "host", "/p", "tcp"] + args))
        Issue.record("Expected rejection: \(args)")
      } catch { #expect(error.message == message) }
    }
    #expect(throws: Never.self) {
      let o = try cecParseOptions(wideArgs(["client", "/p", "udp", "/k", "1", "/h"]))
      #expect(o.help)
    }
    #expect(throws: CECArgumentError.self) {
      try cecParseOptions(wideArgs(["client", "host", "/p", "udp", "/k", "1"]))
    }
  }
  @Test func rangesAndOwnership() throws {
    var args = wideArgs(["client", "host", "/p", "tcp", "/d", "owned"])
    let o = try cecParseOptions(args)
    args[5][0] = 0
    #expect(o.literalPatternUTF16 == Array("owned".utf16))
    #expect(
      try cecParseOptions(wideArgs(["client", "host", "/p", "tcp", "/n", "18446744073709551615"]))
        .echoCount == UInt64.max)
    let bounds: [(String, UInt64, UInt64)] = [
      ("r", 1, 65535), ("l", 0, 65535), ("t", 1, UInt64(UInt32.max)),
      ("i", 0, UInt64(UInt32.max)), ("b", 0, UInt64(Int32.max)), ("k", 1, UInt64(UInt32.max)),
      ("z", 1, 67_108_864), ("zt", 1, 67_108_864), ("w", 1, UInt64(UInt32.max)),
      ("rc", 0, UInt64(Int32.max)), ("report", 1, UInt64(UInt32.max)),
      ("c", 1, 1_048_576), ("threads", 1, 64), ("cq", 64, 1_048_576),
      ("memory", 1_048_576, UInt64.max),
    ]
    for (name, low, high) in bounds {
      for invalid in (low > 0 ? [low - 1] : []) + (high < UInt64.max ? [high + 1] : []) {
        #expect(throws: CECArgumentError.self) {
          try cecParseOptions(
            wideArgs(["client", "host", "/p", "tcp", "/\(name)", String(invalid), "/h"]))
        }
      }
      for valid in [low, high] {
        #expect(throws: Never.self) {
          try cecParseOptions(
            wideArgs(["client", "host", "/p", "tcp", "/\(name)", String(valid), "/h"]))
        }
      }
    }
    #expect(throws: CECArgumentError.self) {
      try cecParseOptions(wideArgs(["client", String(repeating: "a", count: 256), "/p", "tcp"]))
    }
    let raw = try cecParseOptions(wideArgs(["client", "host", "/p", "tcp", "/d"]) + [[0xD800]])
    #expect(raw.literalPatternUTF16 == [0xD800])
  }
  @Test func arithmeticAndClassification() {
    #expect(cecCheckedProduct(8, 65536) == 524288)
    #expect(cecCheckedProduct(UInt64.max, 2) == nil)
    #expect(
      cecCheckedStorageBytes(sessions: 32, batchBytes: 4096, memoryLimit: 1_048_576) == 262144)
    #expect(cecCheckedStorageBytes(sessions: 32, batchBytes: 4096, memoryLimit: 131072) == nil)
    #expect(cecUnclaimedEchoes(limit: 10, claimed: 4, controlledStop: false) == 6)
    #expect(cecUnclaimedEchoes(limit: 10, claimed: 4, controlledStop: true) == 0)
    #expect(
      cecClassifyResult(
        echoed: 0, corrupted: 0, lost: 0, networkErrors: 2, fatal: false, controlledStop: false)
        == .network)
    #expect(
      cecClassifyResult(
        echoed: 0, corrupted: 0, lost: 0, networkErrors: 0, fatal: false, controlledStop: true)
        == .success)
    #expect(
      cecClassifyResult(
        echoed: 0, corrupted: 1, lost: 0, networkErrors: 0, fatal: false, controlledStop: true)
        == .echoFailure)
    #expect(
      cecClassifyResult(
        echoed: 10, corrupted: 0, lost: 0, networkErrors: 2, fatal: false, controlledStop: false)
        == .success)
  }
}
