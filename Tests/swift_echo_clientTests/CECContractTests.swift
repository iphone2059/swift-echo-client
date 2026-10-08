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
  /// Every case below is a measured reference diagnostic, so the tokens are the contract rather
  /// than a paraphrase of it.
  @Test func exactErrorsAndHelpOrder() {
    let cases: [([String], String)] = [
      (["/foo", "1"], CECArgumentToken.unknownSwitch),
      (["/r=", "7001"], CECArgumentToken.missingValue),
      (["/q=1"], CECArgumentToken.unexpectedValue),
      (["/r"], CECArgumentToken.missingValue),
      (["/l", "45000", "/c", "2", "/h"], CECArgumentToken.localPortConflict),
      (["/rc", "1", "/l", "45000"], CECArgumentToken.localPortConflict),
      (["/d", "x", "/z", "1"], CECArgumentToken.conflictingPayload),
      (["/n", "18446744073709551616"], CECArgumentToken.invalidNumber),
      (["/n", "+1"], CECArgumentToken.invalidNumber),
      (["/p", "sctp"], CECArgumentToken.outOfRange),
    ]
    for (args, message) in cases {
      do {
        _ = try cecParseOptions(wideArgs(["client", "host", "/p", "tcp"] + args))
        Issue.record("Expected rejection: \(args)")
      } catch { #expect(error.message == message) }
    }
    // A /k on the datagram path is rejected even together with /h, exactly as the reference does:
    // /h suppresses only the two mandatory-argument checks.
    #expect(throws: CECArgumentError.self) {
      try cecParseOptions(wideArgs(["client", "/p", "udp", "/k", "1", "/h"]))
    }
    #expect(throws: Never.self) {
      let o = try cecParseOptions(wideArgs(["client", "/h", "/n", "1", "/d", "x"]))
      #expect(o.help)
    }
    #expect(throws: CECArgumentError.self) {
      try cecParseOptions(wideArgs(["client", "host", "/p", "udp", "/k", "1"]))
    }
  }
  @Test func diagnosticsUseTheReferenceTokens() {
    let cases: [([String], String)] = [
      ([], CECArgumentToken.missingTarget),
      (["127.0.0.1"], CECArgumentToken.missingProtocol),
      (["/p", "tcp"], CECArgumentToken.missingTarget),
      (["127.0.0.1", "127.0.0.2", "/p", "tcp"], CECArgumentToken.unexpectedTarget),
      (["/c", "1", "/threads", "2", "/p", "tcp"], CECArgumentToken.outOfRange),
      (["127.0.0.1", "/p", "udp", "/k", "1"], CECArgumentToken.protocolOption),
      (["127.0.0.1", "/k", "1", "/p", "udp"], CECArgumentToken.protocolOption),
      (["127.0.0.1", "/p", "udp", "/z", "65508"], CECArgumentToken.payloadSize),
      (["127.0.0.1", "/p", "tcp", "/k", "65536", "/z", "65536"], CECArgumentToken.payloadSize),
      (
        ["127.0.0.1", "/p", "tcp", "/n", "18446744073709551615", "/c", "1048576"],
        CECArgumentToken.quotaOverflow
      ),
      (
        ["127.0.0.1", "/p", "tcp", "/c", "200", "/threads", "4", "/cq", "64"],
        CECArgumentToken.cqCapacity
      ),
      (
        ["127.0.0.1", "/p", "tcp", "/k", "2", "/z", "300000", "/memory", "1048576"],
        CECArgumentToken.memoryCapacity
      ),
      // /h suppresses only the mandatory arguments; the budgets still apply.
      (["/h", "/p", "tcp", "/c", "200", "/threads", "4", "/cq", "64"], CECArgumentToken.cqCapacity),
      (["/h", "/d", "x", "/z", "8"], CECArgumentToken.conflictingPayload),
    ]
    for (args, token) in cases {
      do {
        _ = try cecParseOptions(wideArgs(["client"] + args))
        Issue.record("Expected rejection: \(args)")
      } catch { #expect(error.message == token) }
    }
    #expect(throws: Never.self) {
      _ = try cecParseOptions(wideArgs(["client", "/h", "/p", "tcp", "/n", "1", "/d", "x"]))
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
      ("i", 0, UInt64(UInt32.max)), ("b", 0, UInt64(Int32.max)), ("k", 1, 65_536),
      ("z", 1, 67_108_864), ("zt", 1, 67_108_864), ("w", 1, UInt64(UInt32.max)),
      ("rc", 0, UInt64(Int32.max)), ("report", 1, UInt64(UInt32.max)),
      ("c", 1, 1_048_576), ("threads", 1, 64), ("cq", 64, 1_048_576),
      ("memory", 1_048_576, UInt64.max),
    ]
    // The bounds are checked with a command line whose budgets the largest legal value still
    // satisfies: /h does not exempt the capacity rules, so a bare host/protocol pair would make
    // /c 1048576 fail on the completion queue instead of testing its own range.
    // A payload bound of 64 MiB needs room for two batches of it, and the switch under test is
    // always last so the generous defaults cannot mask the value being checked.
    let generous = ["/cq", "1048576", "/memory", "268435456", "/n", "1"]
    for (name, low, high) in bounds {
      for invalid in (low > 0 ? [low - 1] : []) + (high < UInt64.max ? [high + 1] : []) {
        #expect(throws: CECArgumentError.self) {
          try cecParseOptions(
            wideArgs(["client", "host", "/p", "tcp"] + generous + ["/\(name)", String(invalid), "/h"]))
        }
      }
      for valid in [low, high] {
        // /threads may never exceed the session count, so its own bound needs enough sessions.
        let sessions = name == "threads" ? ["/c", "64"] : []
        #expect(throws: Never.self) {
          try cecParseOptions(
            wideArgs(
              ["client", "host", "/p", "tcp"] + generous + ["/\(name)", String(valid)] + sessions
                + ["/h"]))
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
