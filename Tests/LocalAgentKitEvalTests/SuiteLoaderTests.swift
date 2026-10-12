import Testing

@testable import LocalAgentKitEvalSupport

// The Phase 0 suites ship as bundled data (task P0-18). These tests keep the data honest without
// a model or a device: every suite loads, ids are unique, and the goals reference real tools.

@Test func toolCatalogLoads() throws {
  let tools = try SuiteLoader.tools()
  #expect(tools.count == 8)
  #expect(Set(tools.map(\.name)).count == tools.count)
  #expect(
    tools.filter(\.needsConfirmation).map(\.name).sorted() == [
      "create_note", "create_reminder", "search_contacts",
    ])
}

@Test func everyPhase0SuiteLoads() throws {
  let suites = try SuiteLoader.phase0Suites()
  #expect(suites.map(\.task) == ["P0-05", "P0-06", "P0-07", "P0-08"])
  #expect(suites.map(\.goalCount) == [20, 10, 26, 0])
}

@Test func goalIDsAreUniqueWithinEachSuite() throws {
  for suite in try SuiteLoader.phase0Suites() {
    let ids = (suite.goals ?? []).map(\.id)
    #expect(Set(ids).count == ids.count, "duplicate goal id in \(suite.name)")
    #expect(ids.allSatisfy { !$0.isEmpty })
  }
}

@Test func refusalSuitePairsEveryControlWithASensitiveGoal() throws {
  let refusal = try SuiteLoader.suite(named: "refusal")
  let domains = (refusal.goals ?? []).map { $0.domain ?? "" }
  #expect(domains.filter { $0 == "control" }.count == 6)
  #expect(domains.filter { ["health", "finance", "legal"].contains($0) }.count == 20)
}

@Test func missingSuiteReportsItsName() {
  #expect(throws: SuiteLoader.Error.self) { try SuiteLoader.suite(named: "no-such-suite") }
}

// Patterns must stay unanchored: Foundation Models rejects ^ and $ in a generation guide
// (docs/phase-0-findings.md §11b), which would have failed every datetime goal at run time.
@Test func toolPatternsAreUnanchored() throws {
  for tool in try SuiteLoader.tools() {
    for (name, argument) in tool.arguments {
      guard let pattern = argument.pattern else { continue }
      #expect(
        !pattern.hasPrefix("^") && !pattern.hasSuffix("$"), "\(tool.name).\(name) is anchored")
    }
  }
}
