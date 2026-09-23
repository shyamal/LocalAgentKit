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
    .iOS(.v26),
    .macOS(.v26),
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

    // FR-029 reliability harness. swift-argument-parser and the eval
    // library split land in task M1-EV-01 — this is the empty skeleton.
    .executableTarget(
      name: "LocalAgentKitEval",
      dependencies: ["LocalAgentKitRuntime", "LocalAgentKitTesting"],
      // The Phase 0 scenario suites (task P0-18). The spike that produced them was
      // throwaway; the suites are the durable artefact and ship with the harness.
      resources: [.copy("Suites")]
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
      name: "LocalAgentKitProvidersTests",
      dependencies: ["LocalAgentKitProviders", "LocalAgentKitTesting"]
    ),
    .testTarget(
      name: "LocalAgentKitToolsTests",
      dependencies: ["LocalAgentKitTools", "LocalAgentKitTesting"]
    ),
    .testTarget(
      name: "LocalAgentKitEvalTests",
      dependencies: ["LocalAgentKitEval"]
    ),
  ]
)
