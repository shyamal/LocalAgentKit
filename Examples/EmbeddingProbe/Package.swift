// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "EmbeddingProbeChecks", platforms: [.macOS("26.4")],
  dependencies: [.package(path: "../..")],
  targets: [
    .target(
      name: "EmbeddingProbeChecks",
      dependencies: [
        .product(name: "LocalAgentKitCore", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitProviders", package: "LocalAgentKit"),
      ], path: "Probe"),
    .testTarget(
      name: "EmbeddingProbeTests",
      dependencies: [
        "EmbeddingProbeChecks", .product(name: "LocalAgentKitCore", package: "LocalAgentKit"),
      ], path: "Tests"),
  ])
