// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "FirstAgent",
  platforms: [.macOS("26.4")],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "FirstAgent",
      dependencies: [
        .product(name: "LocalAgentKitCore", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitRuntime", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitTools", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitProviders", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitTesting", package: "LocalAgentKit"),
      ])
  ]
)
