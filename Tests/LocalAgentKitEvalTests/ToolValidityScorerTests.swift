import Foundation
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitEvalSupport

@Suite struct ToolValidityScorerTests {
  private func row(_ calls: [ProbeResult.Call] = [], outcome: ProbeResult.Outcome = .toolCalls)
    -> ProbeResult
  {
    ProbeResult(
      goalID: "test", repetition: 1, outcome: outcome, text: nil, calls: calls,
      failureKind: nil, error: nil, elapsedSeconds: 0)
  }
  private func score(_ name: String, _ args: [String: JSONValue]) throws -> ToolValidityScore.Call {
    let scorer = try ToolValidityScorer(tools: SuiteLoader.tools())
    return try #require(
      scorer.score([row([.init(name: name, arguments: args)])]).first?.calls.first)
  }

  @Test func validatesRequiredAndUnknownArguments() throws {
    #expect(try score("calculate", ["expression": "1 + 1"]).valid)
    #expect(try score("calculate", [:]).violations == ["expression is required"])
    #expect(try score("calculate", ["expression": .null]).valid == false)
    #expect(try score("calculate", ["expression": "1", "invented": true]).valid == false)
    #expect(try score("invented_tool", [:]).violations == ["unknown tool"])
  }

  @Test func checksTypesEnumsAndOptionalArguments() throws {
    #expect(try score("calculate", ["expression": 12]).valid == false)
    #expect(try score("search_files", ["query": "report", "file_type": "pdf"]).valid)
    #expect(try score("search_files", ["query": "report", "file_type": "video"]).valid == false)
    #expect(try score("create_reminder", ["title": "Call plumber"]).valid)
    #expect(try score("create_reminder", ["title": "Call plumber", "due": .null]).valid)
  }

  @Test func numericAndBooleanCatalogTypesRemainStrict() throws {
    let tool = try JSONDecoder().decode(
      SuiteLoader.Tool.self,
      from: Data(
        #"{"name":"typed","description":"x","permission":"none","arguments":{"i":{"type":"integer","required":true},"n":{"type":"number","required":true},"b":{"type":"boolean","required":true}}}"#
          .utf8))
    let scorer = try ToolValidityScorer(tools: [tool])
    let valid = try scorer.score([
      row([.init(name: "typed", arguments: ["i": 2, "n": .double(2.5), "b": true])])
    ])
    #expect(valid.first?.firstCallValid == true)
    let invalid = try scorer.score([
      row([.init(name: "typed", arguments: ["i": .double(2.5), "n": "2.5", "b": 1])])
    ])
    #expect(invalid.first?.calls.first?.violations.count == 3)
  }

  @Test func patternMustMatchTheEntireString() throws {
    #expect(try score("create_reminder", ["title": "call", "due": "2026-09-22T09:00"]).valid)
    for due in [
      "prefix 2026-09-22T09:00", "2026-09-22T09:00 suffix", "2026-09-22T09:00\n", "tomorrow",
    ] {
      #expect(try score("create_reminder", ["title": "call", "due": .string(due)]).valid == false)
    }
    // Catalog validity checks the pattern, not calendar semantics or goal correctness.
    #expect(try score("create_reminder", ["title": "call", "due": "2026-99-99T99:99"]).valid)
  }

  @Test func alternationAndUnicodeUseWholeValueMatching() throws {
    let tool = try JSONDecoder().decode(
      SuiteLoader.Tool.self,
      from: Data(
        #"{"name":"read_value","description":"x","permission":"none","arguments":{"value":{"type":"string","required":true,"pattern":"a|ab|😀"}}}"#
          .utf8))
    let scorer = try ToolValidityScorer(tools: [tool])
    for text in ["a", "ab", "😀"] {
      let result = try scorer.score([
        row([.init(name: "read_value", arguments: ["value": .string(text)])])
      ])
      #expect(result.first?.firstCallValid == true)
    }
  }

  @Test func summaryKeepsNonToolOutcomesInThePrimaryDenominator() throws {
    let scorer = try ToolValidityScorer(tools: SuiteLoader.tools())
    let results = [
      row([.init(name: "calculate", arguments: ["expression": "1+1"])]),
      row([
        .init(name: "calculate", arguments: [:]),
        .init(name: "calculate", arguments: ["expression": "2"]),
      ]),
      row(outcome: .text), row(outcome: .refused), row(outcome: .failure),
      row(outcome: .clarification),
    ]
    let scores = try scorer.score(results)
    let summary = scorer.summary(scores)
    #expect(summary.attempts == 6)
    #expect(summary.attemptsWithCalls == 2)
    #expect(summary.validFirstCalls == 1)
    #expect(summary.emittedCalls == 3)
    #expect(summary.validCalls == 2)
    #expect(summary.extraCalls == 1)
    #expect(summary.validFirstCallRate == 1.0 / 6)
    #expect(summary.emittedCallValidityRate == 2.0 / 3)
    #expect(scores[2].firstCallValid == nil)
  }

  @Test func missingDenominatorsAreUndefinedRatherThanPerfect() throws {
    let scorer = try ToolValidityScorer(tools: SuiteLoader.tools())
    #expect(scorer.summary([]).validFirstCallRate == nil)
    let scores = try scorer.score([row(outcome: .text)])
    #expect(scorer.summary(scores).validFirstCallRate == 0)
    #expect(scorer.summary(scores).emittedCallValidityRate == nil)
  }

  @Test func malformedCatalogIsASetupFailure() throws {
    let tools = try SuiteLoader.tools()
    #expect(throws: ProbeError.self) { try ToolValidityScorer(tools: [tools[0], tools[0]]) }
    let bad = try JSONDecoder().decode(
      SuiteLoader.Tool.self,
      from: Data(
        #"{"name":"bad","description":"x","permission":"none","arguments":{"value":{"type":"string","required":true,"pattern":"["}}}"#
          .utf8))
    #expect(throws: ProbeError.self) { try ToolValidityScorer(tools: [bad]) }
  }

  @Test func jsonIncludesCallValidityAndBothRates() throws {
    let scorer = try ToolValidityScorer(tools: SuiteLoader.tools())
    let scores = try scorer.score([row([.init(name: "calculate", arguments: ["expression": "1"])])])
    let json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(scores)) as? [[String: Any]])
    #expect(json[0]["firstCallValid"] as? Bool == true)
    let summary = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(scorer.summary(scores)))
        as? [String: Any])
    #expect(summary["validFirstCallRate"] as? Double == 1)
    #expect(summary["emittedCallValidityRate"] as? Double == 1)
  }
}
