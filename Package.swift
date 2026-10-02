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
      swiftSettings: [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)],
      linkerSettings: [.linkedLibrary("Ws2_32")]),
    .executableTarget(
      name: "swift_echo_client", dependencies: ["CECClientCore"],
      swiftSettings: [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)]),
    .executableTarget(
      name: "swift_echo_client_fault_driver", dependencies: ["CECClientCore"],
      path: "Tests/CECFaultDriver"),
    .testTarget(name: "swift_echo_clientTests", dependencies: ["CECClientCore"]),
  ],
  swiftLanguageModes: [.v6]
)
