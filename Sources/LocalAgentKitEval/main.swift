import Foundation

// Seed of the FR-029 reliability harness. Today it only lists and checks the bundled Phase 0
// suites (task P0-18); running them against a model is task M1-EV-01, and until then the
// throwaway spike in `Spike/` is the only runner.

do {
  let tools = try SuiteLoader.tools()
  let suites = try SuiteLoader.phase0Suites()
  print("LocalAgentKitEval — Phase 0 suites (task P0-18)")
  print(
    "Tool catalog: \(tools.count) tools, \(tools.filter(\.needsConfirmation).count) needing confirmation"
  )
  for suite in suites {
    let contents = suite.goals.map { "\($0.count) goals" } ?? "fixture, no goals"
    print("  \(suite.name) (\(suite.task)) — \(contents)")
  }
  print("Running these against a model is task M1-EV-01; see Spike/ for the Phase 0 runner.")
} catch {
  FileHandle.standardError.write(Data("LocalAgentKitEval: \(error)\n".utf8))
  exit(1)
}
