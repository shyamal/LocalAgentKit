// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "DemoPlannerChecks",
  platforms: [.macOS("26.4")],
  dependencies: [.package(path: "../..")],
  targets: [
    .target(
      name: "DemoSetup",
      dependencies: [
        .product(name: "LocalAgentKitCore", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitRuntime", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitProviders", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitTools", package: "LocalAgentKit"),
        .product(name: "LocalAgentKitSwiftUI", package: "LocalAgentKit"),
      ], path: "LocalAgentDemo",
      exclude: ["ContentView.swift", "LocalAgentDemoApp.swift", "Resources"],
      sources: ["AgentSetup.swift"]),
    .testTarget(
      name: "DemoPlannerTests",
      dependencies: [
        "DemoSetup", .product(name: "LocalAgentKitTesting", package: "LocalAgentKit"),
      ],
      path: "Tests"),
  ])
