package enum CECTransport: UInt8, Sendable { case none, tcp, udp }
package enum CECPatternKind: UInt8, Sendable {
  case defaultText, literalText, binaryCounter, printableCounter
}
package enum CECExitCode: Int32, Sendable {
  case success, usage, network, echoFailure, internalFailure
}
package enum CECEngineOperation: UInt8, Sendable {
  case connect, send, receive, generationDrained
}
package enum CECCompletionFailureStage: UInt8 { case completion, sendPost }
package enum CECWorkerPhase: UInt8, Sendable { case starting, running, draining, stopped }
package enum CECFailureClass: UInt8, Sendable { case network, invariant, drainTimeout }
package enum CECFailureDomain: UInt8, Sendable { case win32, winsock, allocation, capacity, invariant }
package enum CECFailureCategory: UInt8, Sendable { case initialization, connection, provider, invariant }
package struct CECFailure: Error, Sendable, Equatable {
  package let classification: CECFailureClass
  package let domain: CECFailureDomain
  package let stage: String
  package let code: Int32
  package let category: CECFailureCategory
  package let retryable: Bool

  package init(
    classification: CECFailureClass, domain: CECFailureDomain, stage: String, code: Int32,
    category: CECFailureCategory = .initialization, retryable: Bool = false
  ) {
    self.classification = classification
    self.domain = domain
    self.stage = stage
    self.code = code
    self.category = category
    self.retryable = retryable
  }

  package static func allocation(stage: String) -> Self {
    Self(classification: .network, domain: .allocation, stage: stage, code: 8)
  }
  package static func invariant(stage: String) -> Self {
    Self(classification: .invariant, domain: .invariant, stage: stage, code: 13,
      category: .invariant)
  }
  package static func timeout(stage: String) -> Self {
    Self(classification: .drainTimeout, domain: .win32, stage: stage, code: 1460,
      category: .invariant)
  }
}
package struct CECArgumentError: Error, Equatable { package let message: String }
package struct CECOptions: Sendable {
  package init() {}
  package var transport: CECTransport = .none
  package var patternKind: CECPatternKind = .defaultText
  package var hostUTF16: [UInt16] = []
  package var literalPatternUTF16: [UInt16] = []
  package var remotePort: UInt16 = 7
  package var localPort: UInt16 = 0
  package var echoCount: UInt64 = 5
  package var timeoutSeconds: UInt32 = 5
  package var intervalMilliseconds: UInt32 = 0
  package var socketBufferBytes: UInt32 = 0
  package var pipelineDepth: UInt32 = 1
  package var patternBytes: UInt32 = 0
  package var runSeconds: UInt32 = 0
  package var reconnectSeconds: Int64 = -1
  package var reportSeconds: UInt32 = 0
  package var sessionCount: UInt32 = 1
  package var workerCount: UInt32 = 0
  package var cqCapacity: UInt32 = 4096
  package var memoryBytes: UInt64 = 1_073_741_824
  package var quiet = false
  package var stats = false
  package var help = false
}

package enum CECConstants {
  package static let contractVersion = "echo-binary-contract-v1"
  package static let hostCapacity = 256
  package static let literalCapacity = 32768
  package static let defaultPort: UInt16 = 7
  package static let defaultCount: UInt64 = 5
  package static let defaultTimeoutSeconds: UInt32 = 5
  package static let defaultCQCapacity: UInt32 = 4096
  package static let defaultMemoryBytes: UInt64 = 1_073_741_824
  package static let defaultTextPrefix = "echo from "
  package static let maximumTCPBatchBytes: UInt64 = 67_108_864
  package static let maximumUDPPayloadBytes: UInt64 = 65_507
  package static let completionBatchSize = 256
  package static let stopKey: UInt = 1
}

/// Strict UTF-16 byte sizing, used before allocation. No replacement characters are accepted.
package func cecUTF8ByteCount(_ units: borrowing [UInt16]) -> UInt64? {
  var result: UInt64 = 0
  var index = 0
  while index < units.count {
    let unit = units[index]
    if unit < 0x80 {
      result += 1
    } else if unit < 0x800 {
      result += 2
    } else if (0xD800...0xDBFF).contains(unit) {
      guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
        return nil
      }
      result += 4
      index += 1
    } else if (0xDC00...0xDFFF).contains(unit) {
      return nil
    } else {
      result += 3
    }
    index += 1
  }
  return result
}

