package enum CECTransport: UInt8, Sendable { case none, tcp, udp }
package enum CECPatternKind: UInt8, Sendable {
  case defaultText, literalText, binaryCounter, printableCounter
}
package enum CECExitCode: Int32, Sendable {
  case success, usage, network, echoFailure, internalFailure
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
  package var reconnectSeconds: Int32 = -1
  package var reportSeconds: UInt32 = 0
  package var sessionCount: UInt32 = 1
  package var workerCount: UInt32 = 0
  package var cqCapacity: UInt32 = 4096
  package var memoryBytes: UInt64 = 1_073_741_824
  package var quiet = false
  package var stats = false
  package var help = false
}
