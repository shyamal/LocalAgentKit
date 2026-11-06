// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "RetrievalScale",
  platforms: [.macOS("26.4")],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "RetrievalScale",
      dependencies: [
        .product(name: "LocalAgentKitCore", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitProviders", package: "LocalAgentKit"),
      ])
  ])
