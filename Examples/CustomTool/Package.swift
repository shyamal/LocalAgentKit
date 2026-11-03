// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "CustomTool",
  platforms: [.macOS("26.4")],
  dependencies: [.package(path: "../..")],
  targets: [
    .target(
      name: "TemperatureTools",
      dependencies: [.product(name: "LocalAgentKitCore", package: "LocalAgentKit")]),
    .executableTarget(
      name: "CustomTool",
      dependencies: [
        "TemperatureTools",
        .product(name: "LocalAgentKitProviders", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitRuntime", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitTesting", package: "LocalAgentKit"),
      ]),
    .testTarget(
      name: "TemperatureToolsTests",
      dependencies: [
        "TemperatureTools",
        .product(name: "LocalAgentKitRuntime", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitTesting", package: "LocalAgentKit"),
      ]),
  ]
)
