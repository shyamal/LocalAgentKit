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
}
