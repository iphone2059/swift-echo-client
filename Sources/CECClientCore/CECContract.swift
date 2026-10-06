// MARK: - Binary contract (echo-binary-contract-v1)

/// Diagnostic tokens that must follow "Invalid arguments: " on stderr.
package enum CECArgumentToken {
  package static let protocolOption = "protocol-option"
  package static let invalidNumber = "invalid-number"
  package static let outOfRange = "out-of-range"
  package static let unknownSwitch = "unknown-switch"
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
  var i = 1
  while i < arguments.count {
    let token = arguments[i]
    i += 1
    guard let offset = switchOffset(token) else {
      guard o.hostUTF16.isEmpty, !token.isEmpty, token.count < CECConstants.hostCapacity
      else {
        throw CECArgumentError(message: "client requires exactly one valid target host")
      }
      o.hostUTF16 = token
      continue
    }
    let equal = token[offset...].firstIndex(of: 61)
    let name = asciiLower(token[offset..<(equal ?? token.count)])
    let inline = equal.map { Array(token[($0 + 1)...]) }
    if let inline, inline.isEmpty {
      throw CECArgumentError(message: "switch requires a non-empty inline value")
    }
    if ["q", "quiet", "stats", "h", "help"].contains(name) {
      guard inline == nil else {
        throw CECArgumentError(message: "flag switch does not accept a value")
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
      value = inline
    } else {
      guard i < arguments.count, !arguments[i].isEmpty, switchOffset(arguments[i]) == nil
      else { throw CECArgumentError(message: "switch requires a non-empty value") }
      value = arguments[i]
      i += 1
    }
    if name == "p" {
      switch asciiLower(value[...]) {
      case "tcp": o.transport = .tcp
      case "udp": o.transport = .udp
      default: throw CECArgumentError(message: "/p requires tcp or udp")
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
  if o.localPort != 0 && o.sessionCount != 1 {
    throw CECArgumentError(message: "a fixed /l port requires /c 1")
  }
  if o.transport == .udp && pipeline {
    throw CECArgumentError(message: CECArgumentToken.protocolOption)
  }
  if o.help { return o }
  guard !o.hostUTF16.isEmpty, o.transport != .none else {
    throw CECArgumentError(message: "target host and /p tcp or /p udp are required")
  }
  if [literal, binary, printable].filter({ $0 }).count > 1 {
    throw CECArgumentError(message: "use exactly one of /d, /z, or /zt")
  }
  if o.transport == .tcp && o.reconnectSeconds >= 0 && o.localPort != 0 {
    throw CECArgumentError(message: "TCP reconnect cannot use a fixed /l port")
  }
  if o.transport == .udp && o.patternBytes > CECConstants.maximumUDPPayloadBytes {
    throw CECArgumentError(message: "UDP payload must not exceed 65507 bytes")
  }
  if o.patternBytes != 0 {
    guard let batch = cecCheckedProduct(UInt64(o.patternBytes), UInt64(o.pipelineDepth)),
      batch <= CECConstants.maximumTCPBatchBytes
    else {
      throw CECArgumentError(
        message: "TCP payload multiplied by depth must not exceed 64 MiB")
    }
    // Actual worker count (including the automatic setting) determines shared
    // send storage. The engine performs the authoritative /memory check.
  }
  return o
}