// swift-tools-version: 6.2
// PLANNING.md §2.2 documents the target layout this manifest implements.
//
// Layering rule (PLANNING.md §2.2, CLAUDE.md): LocalAgentKitCore and
// LocalAgentKitRuntime must never depend on an Apple framework. Dependency
// direction is one-way: Tools/Providers/SwiftUI/AppIntents -> Runtime -> Core.
// Nothing depends on Providers. Enforced by the layering grep in CI (task M0-13),
// not by this file alone.
//
// Platform floor (iOS 26 / macOS 26) and the Foundation Models / Core AI API
// surface this package will build on are UNVERIFIED against the shipping SDK
// (PLANNING.md §6, open question 1). Confirm before relying on availability
// annotations here — task P0-03 gates that.

import PackageDescription

let package = Package(
  name: "LocalAgentKit",
  platforms: [
    // Final per decision 0004. 26.4, not 26.0: SystemLanguageModel.tokenCount(for:) is 26.4+
    // and ContextBudgeter must budget against real token counts, not estimates (findings §3).
    // OS 27-only API (LanguageModel, LanguageModelError, toolCallingMode) sits behind #available.
    .iOS("26.4"),
    .macOS("26.4"),
  ],
  products: [
    .library(name: "LocalAgentKitCore", targets: ["LocalAgentKitCore"]),
    .library(name: "LocalAgentKitRuntime", targets: ["LocalAgentKitRuntime"]),
    .library(name: "LocalAgentKitProviders", targets: ["LocalAgentKitProviders"]),
    .library(name: "LocalAgentKitTools", targets: ["LocalAgentKitTools"]),
    .library(name: "LocalAgentKitSwiftUI", targets: ["LocalAgentKitSwiftUI"]),
    .library(name: "LocalAgentKitAppIntents", targets: ["LocalAgentKitAppIntents"]),
    .library(name: "LocalAgentKitTesting", targets: ["LocalAgentKitTesting"]),
    .executable(name: "LocalAgentKitEval", targets: ["LocalAgentKitEval"]),
  ],
  // Development-only CLI dependency; no SDK library target depends on ArgumentParser.
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0")
  ],
  targets: [
    // Protocols + value types only. Zero Apple-framework dependencies —
    // enforced by the CI layering check (task M0-13).
    .target(
      name: "LocalAgentKitCore"
    ),

    // The agent loop. Depends on Core only.
    .target(
      name: "LocalAgentKitRuntime",
      dependencies: ["LocalAgentKitCore"]
    ),

    // Concrete model/memory/embedding/vector/vision/speech adapters —
    // the only place Apple frameworks are imported.
    .target(
      name: "LocalAgentKitProviders",
      dependencies: ["LocalAgentKitRuntime"]
    ),

    // Built-in AgentTool conformances (EventKit, Contacts, PDFKit, FileManager).
    .target(
      name: "LocalAgentKitTools",
      dependencies: ["LocalAgentKitRuntime"]
    ),

    // Optional SwiftUI integration.
    .target(
      name: "LocalAgentKitSwiftUI",
      dependencies: ["LocalAgentKitRuntime"]
    ),

    // Optional App Intents bridging.
    .target(
      name: "LocalAgentKitAppIntents",
      dependencies: ["LocalAgentKitRuntime"]
    ),

    // MockModelProvider, ScriptedModelProvider, fixtures. Ships to consumers,
    // and used by this package's own test targets — so it depends on Core
    // only, never on Runtime, to avoid a test-time dependency cycle.
    .target(
      name: "LocalAgentKitTesting",
      dependencies: ["LocalAgentKitCore"]
    ),

    // Testable harness mechanics and durable Phase 0 resources, without CLI dependencies.
    .target(
      name: "LocalAgentKitEvalSupport",
      dependencies: ["LocalAgentKitRuntime"],
      path: "Sources/LocalAgentKitEval",
      resources: [.copy("Suites")]
    ),
    .executableTarget(
      name: "LocalAgentKitEval",
      dependencies: [
        "LocalAgentKitEvalSupport", "LocalAgentKitProviders", "LocalAgentKitTesting",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/LocalAgentKitEvalCLI"
    ),

    .testTarget(
      name: "LocalAgentKitCoreTests",
      dependencies: ["LocalAgentKitCore"]
    ),
    .testTarget(
      name: "LocalAgentKitRuntimeTests",
      dependencies: ["LocalAgentKitRuntime", "LocalAgentKitTesting"]
    ),
    .testTarget(
      name: "LocalAgentKitTestingTests",
      dependencies: ["LocalAgentKitTesting"]
    ),
    .testTarget(
      name: "LocalAgentKitSwiftUITests",
      dependencies: ["LocalAgentKitSwiftUI", "LocalAgentKitTesting"]
    ),
    .testTarget(
      name: "LocalAgentKitProvidersTests",
      dependencies: ["LocalAgentKitProviders", "LocalAgentKitTesting"]
    ),
    .testTarget(
      name: "LocalAgentKitToolsTests",
      dependencies: ["LocalAgentKitTools", "LocalAgentKitTesting"]
    ),
    .testTarget(
      name: "LocalAgentKitEvalTests",
      dependencies: ["LocalAgentKitEvalSupport", "LocalAgentKitTesting"]
    ),
  ]
)
