// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MultimodalProbeChecks", platforms: [.macOS("26.4")],
  targets: [
    .target(name: "MultimodalProbeChecks", path: "Probe"),
    .testTarget(
      name: "MultimodalProbeTests", dependencies: ["MultimodalProbeChecks"], path: "Tests"),
  ])
