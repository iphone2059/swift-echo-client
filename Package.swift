// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "swift-echo-client",
  products: [
    .executable(name: "swift-echo-client", targets: ["swift_echo_client"]),
    .executable(
      name: "swift-echo-client-fault-driver", targets: ["swift_echo_client_fault_driver"]),
  ],
  targets: [
    .target(
      name: "CECClientCore",
      path: "Sources",
      exclude: ["main.swift"],
      sources: [
        "contract.swift", "types.swift", "payload.swift", "metrics.swift", "native.swift",
        "internal.swift", "engine.swift",
      ],
      swiftSettings: [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)],
      linkerSettings: [.linkedLibrary("Ws2_32"), .linkedLibrary("Winmm")]),
    .executableTarget(
      name: "swift_echo_client", dependencies: ["CECClientCore"],
      path: "Sources",
      exclude: [
        "contract.swift", "types.swift", "payload.swift", "metrics.swift", "native.swift",
        "internal.swift", "engine.swift",
      ],
      sources: ["main.swift"],
      swiftSettings: [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)]),
    .executableTarget(
      name: "swift_echo_client_fault_driver", dependencies: ["CECClientCore"],
      path: "Tests/CECFaultDriver"),
    .testTarget(name: "swift_echo_clientTests", dependencies: ["CECClientCore"]),
  ],
  swiftLanguageModes: [.v6]
)
