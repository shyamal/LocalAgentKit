import LocalAgentKitCore
import Testing

@testable import LocalAgentKitRuntime

@Suite struct LoopDetectorTests {
  private func call(_ name: String, _ arg: JSONValue = 0) -> ToolCall {
    ToolCall(id: "c", name: name, arguments: ToolArguments(["x": arg]))
  }

  @Test func distinctCallsProceed() {
    var detector = LoopDetector()
    for name in ["a", "b", "c", "d", "e"] {
      #expect(detector.record(call(name)) == .proceed)
    }
  }

  @Test func oneRepeatIsNotALoop() {
    var detector = LoopDetector()
    #expect(detector.record(call("a")) == .proceed)
    #expect(detector.record(call("a")) == .proceed)
  }

  @Test func sameCallThreeTimesIsPeriodOne() {
    var detector = LoopDetector()
    _ = detector.record(call("a"))
    _ = detector.record(call("a"))
    #expect(detector.record(call("a")) == .loop(period: 1, toolName: "a"))
  }

  /// The PRD's example: A, B, A, B, A.
  @Test func alternatingPatternIsDetectedOnTheFifthCall() {
    var detector = LoopDetector()
    let sequence = ["a", "b", "a", "b", "a"]
    var verdicts: [LoopVerdict] = []
    for name in sequence { verdicts.append(detector.record(call(name))) }
    #expect(verdicts.dropLast().allSatisfy { $0 == .proceed })
    #expect(verdicts.last == .loop(period: 2, toolName: "a"))
  }

  @Test func periodThreeIsDetected() {
    var detector = LoopDetector()
    var last = LoopVerdict.proceed
    for name in ["a", "b", "c", "a", "b", "c", "a"] { last = detector.record(call(name)) }
    #expect(last == .loop(period: 3, toolName: "a"))
  }

  @Test func differentArgumentsAreDifferentCalls() {
    var detector = LoopDetector()
    for value in 0..<6 {
      #expect(detector.record(call("search", .int(value))) == .proceed)
    }
  }

  @Test func argumentOrderDoesNotHideALoop() {
    var detector = LoopDetector()
    let first = ToolCall(id: "1", name: "t", arguments: ToolArguments(["p": 1, "q": 2]))
    let second = ToolCall(id: "2", name: "t", arguments: ToolArguments(["q": 2, "p": .double(1)]))
    _ = detector.record(first)
    _ = detector.record(second)
    #expect(detector.record(first) == .loop(period: 1, toolName: "t"))
  }

  @Test func resetForgetsHistory() {
    var detector = LoopDetector()
    _ = detector.record(call("a"))
    _ = detector.record(call("a"))
    detector.reset()
    #expect(detector.record(call("a")) == .proceed)
  }

  @Test func longRunsStayBounded() {
    var detector = LoopDetector(maxPeriod: 2)
    for value in 0..<1000 { _ = detector.record(call("t", .int(value))) }
    #expect(detector.record(call("t", .int(-1))) == .proceed)
  }
  private func semanticDetector() -> LoopDetector {
    LoopDetector(
      configuration: LoopDetectionConfiguration(textRules: [
        .init(
          tool: "search", argument: "x",
          equivalentPhrases: [
            ["budget review notes", "notes for the budget meeting"],
            ["notes for the budget meeting", "budget meeting preparation notes"],
          ])
      ]))
  }

  @Test func knownParaphrasesMeetTheSameLoopThreshold() {
    var detector = semanticDetector()
    #expect(detector.record(call("search", " Budget Review Notes ")) == .proceed)
    #expect(detector.record(call("search", "notes for the budget meeting")) == .proceed)
    #expect(
      detector.record(call("search", "budget meeting preparation notes"))
        == .loop(period: 1, toolName: "search"))
  }

  @Test func semanticAlternationIsDetected() {
    var detector = semanticDetector()
    for value in ["budget review notes", "other", "notes for the budget meeting", "other"] {
      #expect(detector.record(call("search", .string(value))) == .proceed)
    }
    #expect(
      detector.record(call("search", "budget meeting preparation notes"))
        == .loop(period: 2, toolName: "search"))
  }

  @Test func textNormalizationIsExplicitAndPreservesUnknownMeaning() {
    var exact = LoopDetector()
    var semantic = semanticDetector()
    for value in [" NEW\nquery", "new query", "New   Query"] {
      #expect(exact.record(call("search", .string(value))) == .proceed)
      let result = semantic.record(call("search", .string(value)))
      if value == "New   Query" {
        #expect(result == .loop(period: 1, toolName: "search"))
      } else {
        #expect(result == .proceed)
      }
    }
    var distinct = semanticDetector()
    for value in ["budget review notes", "not budget review notes", "budget review notes 2"] {
      #expect(distinct.record(call("search", .string(value))) == .proceed)
    }
  }

  @Test func otherArgumentsTypesToolsAndNestedValuesRemainDistinct() {
    var detector = semanticDetector()
    let values: [JSONValue] = [1, "1", ["a", "b"], ["b", "a"], ["name": "Ada"], ["name": "ada"]]
    for value in values { #expect(detector.record(call("search", value)) == .proceed) }
    for page in 1...4 {
      let next = ToolCall(
        id: "c", name: "search",
        arguments: ToolArguments([
          "x": "budget review notes", "page": .int(page),
        ]))
      #expect(detector.record(next) == .proceed)
    }
    for value in ["A", "a", " A "] {
      #expect(detector.record(call("write", .string(value))) == .proceed)
    }
  }

  @Test func structuralComparisonDoesNotConfuseEscapedStringsAndObjects() {
    var detector = LoopDetector()
    let one = ToolCall(id: "1", name: "t", arguments: ToolArguments(["x": "a\",y:\"b"]))
    let two = ToolCall(id: "2", name: "t", arguments: ToolArguments(["x": "a", "y": "b"]))
    #expect(detector.record(one) == .proceed)
    #expect(detector.record(two) == .proceed)
    #expect(detector.record(one) == .proceed)
    #expect(detector.record(two) == .proceed)
    #expect(detector.record(one) == .loop(period: 2, toolName: "t"))
  }

  @Test func hugeNumbersAndPeriodsCannotOverflow() {
    var detector = LoopDetector(maxPeriod: Int.max)
    #expect(detector.maxPeriod == 64)
    for value in [Double.greatestFiniteMagnitude, Double.infinity, -Double.infinity] {
      #expect(detector.record(call("t", .double(value))) == .proceed)
    }
    var large = LoopDetector()
    _ = large.record(call("t", .double(1e100)))
    _ = large.record(call("t", .double(1e100)))
    #expect(large.record(call("t", .double(1e100))) == .loop(period: 1, toolName: "t"))
  }

  @Test func resetAlsoClearsSemanticHistory() {
    var detector = semanticDetector()
    _ = detector.record(call("search", "budget review notes"))
    _ = detector.record(call("search", "notes for the budget meeting"))
    detector.reset()
    #expect(detector.record(call("search", "budget meeting preparation notes")) == .proceed)
  }

  @Test func overlappingRulesMergeRegardlessOfDeclarationOrder() {
    let rules: [LoopDetectionConfiguration.TextRule] = [
      .init(tool: "search", argument: "x", equivalentPhrases: [[], ["a", "b"]]),
      .init(tool: "search", argument: "x", equivalentPhrases: [["b", "c"]]),
      .init(tool: "search", argument: "x", equivalentPhrases: [["c", "d"]]),
    ]
    for order in [rules, Array(rules.reversed())] {
      var detector = LoopDetector(configuration: .init(textRules: order))
      _ = detector.record(call("search", "a"))
      _ = detector.record(call("search", "d"))
      #expect(detector.record(call("search", "b")) == .loop(period: 1, toolName: "search"))
    }
  }

  @Test func nestedNumericEquivalenceAndSignedZeroRemainCompatible() {
    var detector = LoopDetector()
    let first: JSONValue = ["values": [0, 1, ["number": 2]]]
    let second: JSONValue = ["values": [.double(-0.0), .double(1.0), ["number": .double(2.0)]]]
    _ = detector.record(call("t", first))
    _ = detector.record(call("t", second))
    #expect(detector.record(call("t", first)) == .loop(period: 1, toolName: "t"))
    #expect(LoopDetector(maxPeriod: 0).maxPeriod == 1)
  }

}
