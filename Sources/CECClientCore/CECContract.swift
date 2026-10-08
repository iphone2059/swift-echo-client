import WinSDK

// MARK: - Binary contract (echo-binary-contract-v1)

/// Diagnostic tokens that must follow "Invalid arguments: " on stderr.
package enum CECArgumentToken {
  package static let protocolOption = "protocol-option"
  package static let invalidNumber = "invalid-number"
  package static let outOfRange = "out-of-range"
  package static let unknownSwitch = "unknown-switch"
  package static let unexpectedValue = "unexpected-value"
  package static let missingValue = "missing-value"
  package static let conflictingPayload = "conflicting-payload"
  package static let localPortConflict = "local-port-conflict"
  package static let quotaOverflow = "quota-overflow"
  package static let payloadSize = "payload-size"
  package static let memoryCapacity = "memory-capacity"
  package static let cqCapacity = "cq-capacity"
  package static let missingTarget = "missing-target"
  package static let missingProtocol = "missing-protocol"
  package static let unexpectedTarget = "unexpected-target"
}

/// Which protocol a switch belongs to; a switch used with the wrong one is a usage error.
package enum CECSwitchScope { case both, tcpOnly, udpOnly }

/// One value switch: its name, the range it accepts and the protocol it applies to.
package struct CECSwitch {
  package let name: String
  package let minimum: UInt64
  package let maximum: UInt64
  package let scope: CECSwitchScope
}

/// The accepted value switches, as value data: one place for names, ranges and protocol scope.
package enum CECSwitchTable {
  package static let valueSwitches: [CECSwitch] = [
    CECSwitch(name: "r", minimum: 1, maximum: 65_535, scope: .both),
    CECSwitch(name: "l", minimum: 0, maximum: 65_535, scope: .both),
    CECSwitch(name: "n", minimum: 0, maximum: UInt64.max, scope: .both),
    CECSwitch(name: "t", minimum: 1, maximum: UInt64(UInt32.max), scope: .both),
    CECSwitch(name: "i", minimum: 0, maximum: UInt64(UInt32.max), scope: .both),
    CECSwitch(name: "b", minimum: 0, maximum: UInt64(Int32.max), scope: .both),
    CECSwitch(name: "k", minimum: 1, maximum: 65_536, scope: .tcpOnly),
    CECSwitch(name: "z", minimum: 1, maximum: CECConstants.maximumTCPBatchBytes, scope: .both),
    CECSwitch(name: "zt", minimum: 1, maximum: CECConstants.maximumTCPBatchBytes, scope: .both),
    CECSwitch(name: "w", minimum: 1, maximum: UInt64(UInt32.max), scope: .both),
    CECSwitch(name: "rc", minimum: 0, maximum: UInt64(Int32.max), scope: .both),
    CECSwitch(name: "report", minimum: 1, maximum: UInt64(UInt32.max), scope: .both),
    CECSwitch(name: "c", minimum: 1, maximum: 1_048_576, scope: .both),
    CECSwitch(name: "threads", minimum: 1, maximum: 64, scope: .both),
    CECSwitch(name: "cq", minimum: 64, maximum: 1_048_576, scope: .both),
    CECSwitch(name: "memory", minimum: 1_048_576, maximum: UInt64.max, scope: .both),
  ]

  package static func lookup(_ name: String) -> CECSwitch? {
    valueSwitches.first { $0.name == name }
  }
}

/// The usage text: stdout for a valid /h, stderr for a usage error.
package let cecUsageText = """
Usage: swift-echo-client target /p tcp|udp [/r port] [/l port] [/n count]
       [/t seconds] [/i ms] [/d text | /z bytes | /zt bytes] [/k tcp-depth]
       [/c sessions] [/threads workers] [/w seconds] [/rc [seconds]]
       [/report seconds] [/b bytes] [/cq capacity] [/memory bytes] [/q] [/stats]
Data I/O is always RIO; CQ notification is always IOCP. No fallback backend exists.

"""
package func cecCheckedProduct(_ a: UInt64, _ b: UInt64) -> UInt64? {
  let (value, overflow) = a.multipliedReportingOverflow(by: b)
  return overflow ? nil : value
}
package func cecCheckedStorageBytes(sessions: UInt64, batchBytes: UInt64, memoryLimit: UInt64)
  -> UInt64?
{
  guard let batch = cecCheckedProduct(sessions, batchBytes),
    let bytes = cecCheckedProduct(batch, 2), bytes <= memoryLimit
  else { return nil }
  return bytes
}
package func cecUnclaimedEchoes(limit: UInt64, claimed: UInt64, controlledStop: Bool) -> UInt64 {
  controlledStop || limit == 0 || claimed >= limit ? 0 : limit - claimed
}
package func cecCheckedSharedStorageBytes(
  sessions: UInt64, workers: UInt64, batchBytes: UInt64, memoryLimit: UInt64
) -> UInt64? {
  guard sessions > 0, workers > 0, workers <= sessions, batchBytes > 0 else { return nil }
  let (regions, overflow) = sessions.addingReportingOverflow(workers)
  guard !overflow, let bytes = cecCheckedProduct(regions, batchBytes), bytes <= memoryLimit else {
    return nil
  }
  return bytes
}
package func cecClassifyResult(
  echoed: UInt64, corrupted: UInt64, lost: UInt64, networkErrors: UInt64, fatal: Bool,
  controlledStop: Bool
) -> CECExitCode {
  if fatal { return .internalFailure }
  if corrupted != 0 || lost != 0 { return .echoFailure }
  if controlledStop { return .success }
  return echoed == 0 ? .network : .success
}
private func switchOffset(_ token: [UInt16]) -> Int? {
  guard token.count >= 2, token[0] == 47 || token[0] == 45 else { return nil }
  let i = token.count > 2 && token[0] == 45 && token[1] == 45 ? 2 : 1
  return (65...90).contains(token[i]) || (97...122).contains(token[i]) ? i : nil
}
private func asciiLower(_ value: ArraySlice<UInt16>) -> String {
  String(decoding: value.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF16.self)
}
private func numeric(_ value: [UInt16]) throws(CECArgumentError) -> UInt64 {
  var result: UInt64 = 0
  for char in value {
    guard (48...57).contains(char), let product = cecCheckedProduct(result, 10) else {
      throw CECArgumentError(message: CECArgumentToken.invalidNumber)
    }
    let (next, overflow) = product.addingReportingOverflow(UInt64(char - 48))
    guard !overflow else {
      throw CECArgumentError(message: CECArgumentToken.invalidNumber)
    }
    result = next
  }
  return result
}
package func cecParseOptions(_ arguments: [[UInt16]]) throws(CECArgumentError) -> CECOptions {
  guard !arguments.isEmpty else { throw CECArgumentError(message: "invalid parser arguments") }
  var o = CECOptions()
  var literal = false
  var binary = false
  var printable = false
  var pipeline = false
  // A second positional is reported after the cross-field rules, exactly as the reference does.
  var sawExtraTarget = false
  // UTF-8 byte counts, which is how the reference measures a payload before any session exists.
  var literalBytes: UInt64 = 0
  var hostBytes: UInt64 = 0
  var i = 1
  while i < arguments.count {
    let token = arguments[i]
    i += 1
    guard let offset = switchOffset(token) else {
      if !o.hostUTF16.isEmpty {
        sawExtraTarget = true
        continue
      }
      guard !token.isEmpty, token.count < CECConstants.hostCapacity
      else {
        throw CECArgumentError(message: "client requires exactly one valid target host")
      }
      o.hostUTF16 = token
      hostBytes = UInt64(String(decoding: token, as: UTF16.self).utf8.count)
      continue
    }
    let equal = token[offset...].firstIndex(of: 61)
    let name = asciiLower(token[offset..<(equal ?? token.count)])
    let inline = equal.map { Array(token[($0 + 1)...]) }
    if ["q", "quiet", "stats", "h", "help"].contains(name) {
      guard inline == nil else {
        // A flag never takes a value, and an empty one is still a value.
        throw CECArgumentError(message: CECArgumentToken.unexpectedValue)
      }
      switch name {
      case "q", "quiet": o.quiet = true
      case "stats": o.stats = true
      default: o.help = true
      }
      continue
    }
    if name == "rc", inline == nil, i == arguments.count || switchOffset(arguments[i]) != nil {
      o.reconnectSeconds = 1
      continue
    }
    guard
      [
        "p", "d", "r", "l", "n", "t", "i", "b", "k", "z", "zt", "w", "rc", "report", "c",
        "threads", "cq", "memory",
      ].contains(name)
    else { throw CECArgumentError(message: CECArgumentToken.unknownSwitch) }
    let value: [UInt16]
    if let inline {
      guard !inline.isEmpty else { throw CECArgumentError(message: CECArgumentToken.missingValue) }
      value = inline
    } else {
      guard i < arguments.count, !arguments[i].isEmpty, switchOffset(arguments[i]) == nil
      else { throw CECArgumentError(message: CECArgumentToken.missingValue) }
      value = arguments[i]
      i += 1
    }
    if name == "p" {
      // The reference matches the protocol keyword itself and reports the parse failure as an
      // out-of-range value, not as a protocol-specific message.
      switch asciiLower(value[...]) {
      case "tcp": o.transport = .tcp
      case "udp": o.transport = .udp
      default: throw CECArgumentError(message: CECArgumentToken.outOfRange)
      }
      continue
    }
    if name == "d" {
      guard value.count < CECConstants.literalCapacity else {
        throw CECArgumentError(
          message: "literal text exceeds the Windows command-line limit")
      }
      o.literalPatternUTF16 = value
      o.patternKind = .literalText
      literalBytes = UInt64(String(decoding: value, as: UTF16.self).utf8.count)
      literal = true
      continue
    }
    let n = try numeric(value)
    let range: ClosedRange<UInt64>
    switch name {
    case "r": range = 1...65535
    case "l": range = 0...65535
    case "n": range = 0...UInt64.max
    case "t", "w", "report": range = 1...UInt64(UInt32.max)
    case "k": range = 1...65_536
    case "i": range = 0...UInt64(UInt32.max)
    case "b", "rc": range = 0...UInt64(Int32.max)
    case "z", "zt": range = 1...CECConstants.maximumTCPBatchBytes
    case "c": range = 1...1_048_576
    case "threads": range = 1...64
    case "cq": range = 64...1_048_576
    default: range = 1_048_576...UInt64.max
    }
    guard range.contains(n) else {
      throw CECArgumentError(message: CECArgumentToken.outOfRange)
    }
    switch name {
    case "r": o.remotePort = UInt16(n)
    case "l": o.localPort = UInt16(n)
    case "n": o.echoCount = n
    case "t": o.timeoutSeconds = UInt32(n)
    case "i": o.intervalMilliseconds = UInt32(n)
    case "b": o.socketBufferBytes = UInt32(n)
    case "k":
      o.pipelineDepth = UInt32(n)
      pipeline = true
    case "z":
      o.patternBytes = UInt32(n)
      o.patternKind = .binaryCounter
      binary = true
    case "zt":
      o.patternBytes = UInt32(n)
      o.patternKind = .printableCounter
      printable = true
    case "w": o.runSeconds = UInt32(n)
    case "rc": o.reconnectSeconds = Int32(n)
    case "report": o.reportSeconds = UInt32(n)
    case "c": o.sessionCount = UInt32(n)
    case "threads": o.workerCount = UInt32(n)
    case "cq": o.cqCapacity = UInt32(n)
    default: o.memoryBytes = n
    }
  }
  // The cross-field rules keep the reference's precedence: the worker split first, then the
  // positional arguments, the payload conflict, the protocol options, the local-port rules, the
  // quota and only then the payload and capacity budgets.
  if o.workerCount > o.sessionCount {
    throw CECArgumentError(message: CECArgumentToken.outOfRange)
  }
  if sawExtraTarget {
    throw CECArgumentError(message: CECArgumentToken.unexpectedTarget)
  }
  // The baseline reports the missing target first and the missing protocol second, so a bare
  // invocation and a host-only invocation are different mistakes. /h suppresses only these two
  // checks; every other rule still applies.
  if !o.help && o.hostUTF16.isEmpty {
    throw CECArgumentError(message: CECArgumentToken.missingTarget)
  }
  if !o.help && o.transport == .none {
    throw CECArgumentError(message: CECArgumentToken.missingProtocol)
  }
  if [literal, binary, printable].filter({ $0 }).count > 1 {
    throw CECArgumentError(message: CECArgumentToken.conflictingPayload)
  }
  if o.transport == .udp && pipeline {
    throw CECArgumentError(message: CECArgumentToken.protocolOption)
  }
  if o.localPort != 0 && (o.sessionCount != 1 || (o.transport == .tcp && o.reconnectSeconds >= 0)) {
    throw CECArgumentError(message: CECArgumentToken.localPortConflict)
  }
  if o.sessionCount != 0 && o.echoCount > UInt64.max / UInt64(o.sessionCount) {
    throw CECArgumentError(message: CECArgumentToken.quotaOverflow)
  }
  // Nothing else can be validated without a protocol, which is how /h alone succeeds.
  if o.transport == .none { return o }
  // Each worker owns its own CQ and its own registered arena, so the largest shard decides both
  // budgets.
  let workers = cecResolveWorkerCount(configured: o.workerCount, sessions: o.sessionCount)
  let shard = (UInt64(o.sessionCount) + workers - 1) / workers
  // The effective payload length is known before any session exists.
  let patternBytes: UInt64
  switch o.patternKind {
  case .binaryCounter, .printableCounter: patternBytes = UInt64(o.patternBytes)
  case .literalText: patternBytes = literalBytes
  case .defaultText:
    patternBytes =
      hostBytes == 0 ? 0 : UInt64(CECConstants.defaultTextPrefix.utf8.count) + hostBytes
  }
  if o.transport == .udp && patternBytes > CECConstants.maximumUDPPayloadBytes {
    throw CECArgumentError(message: CECArgumentToken.payloadSize)
  }
  if patternBytes != 0 {
    guard let batch = cecCheckedProduct(patternBytes, UInt64(o.pipelineDepth)),
      batch <= CECConstants.maximumTCPBatchBytes
    else {
      throw CECArgumentError(message: CECArgumentToken.payloadSize)
    }
    guard let perSession = cecCheckedProduct(batch, 2),
      let storage = cecCheckedProduct(perSession, UInt64(o.sessionCount)),
      storage <= o.memoryBytes
    else {
      throw CECArgumentError(message: CECArgumentToken.memoryCapacity)
    }
    // One worker registers its whole shard, and a single registration may not exceed DWORD.
    guard let workerStorage = cecCheckedProduct(perSession, shard),
      workerStorage <= UInt64(UInt32.max)
    else {
      throw CECArgumentError(message: CECArgumentToken.memoryCapacity)
    }
  }
  // One attempt is one receive plus one send whatever /k is, so the largest shard reserves
  // exactly two operations per session against the completion queue.
  guard shard * 2 <= UInt64(o.cqCapacity) else {
    throw CECArgumentError(message: CECArgumentToken.cqCapacity)
  }
  return o
}

/// Workers the reference would create: /threads, or the active processor count clamped to [1, 64],
/// and never more than there are sessions. The contract owns the rule so the parser's capacity
/// budgets and the run's actual split can never disagree.
package func cecResolveWorkerCount(configured: UInt32, sessions: UInt32) -> UInt64 {
  if sessions == 0 { return 1 }
  var workers = UInt64(configured)
  if workers == 0 {
    workers = min(64, max(1, UInt64(GetActiveProcessorCount(0xffff))))
  }
  return min(workers, UInt64(sessions))
}