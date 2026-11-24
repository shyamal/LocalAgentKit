import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitSwiftUI

@Suite struct PlanChecklistTests {
  private let first = PlanStep(id: "first", summary: "Read first", toolName: "read")
  private let second = PlanStep(id: "second", summary: "Read second", toolName: "read")
  private func call(_ id: String, step: String? = "first") -> ToolCall {
    ToolCall(id: id, name: "read", planStepID: step)
  }
  private func result(_ id: String) -> AgentEvent {
    .toolCompleted(ToolResult(callID: id, toolName: "read", text: "Result", isEmpty: true))
  }

  @Test func repeatedToolNamesParallelCallsAndRetriesUseExplicitStepIdentity() {
    var checklist = PlanChecklist()
    checklist.receive(.planCreated(AgentPlan(steps: [first, second])))
    checklist.receive(.toolStarted(call("a")))
    checklist.receive(.toolStarted(call("b", step: "second")))
    checklist.receive(result("b"))
    #expect(checklist.rows.map(\.status) == [.running, .resultReceived])
    checklist.receive(result("a"))
    checklist.receive(.toolRequested(call("retry")))
    #expect(checklist.rows.map(\.status) == [.requested, .resultReceived])
    checklist.receive(.permissionRequired(call("retry")))
    #expect(checklist.rows[0].status == .awaitingPermission)
    checklist.receive(.toolStarted(call("retry")))
    checklist.receive(result("retry"))
    #expect(checklist.rows[0].status == .resultReceived)
  }

  @Test func unknownOrAmbiguousCallsCannotCompleteUnrelatedSteps() {
    var checklist = PlanChecklist()
    checklist.receive(.planCreated(AgentPlan(steps: [first, second])))
    checklist.receive(.toolStarted(call("unknown", step: nil)))
    checklist.receive(result("unknown"))
    checklist.receive(.toolStarted(call("missing", step: "absent")))
    #expect(checklist.rows.allSatisfy { $0.status == .pending })
    checklist.receive(.planCreated(AgentPlan(steps: [first, first])))
    checklist.receive(.toolStarted(call("ambiguous")))
    #expect(checklist.rows.allSatisfy { $0.status == .pending })
    #expect(checklist.rows.map(\.id) == [0, 1])
  }

  @Test func revisionsPreserveOnlyUnchangedStepsAndIgnoreRemovedCallResults() {
    var checklist = PlanChecklist()
    checklist.receive(.planCreated(AgentPlan(steps: [first, second])))
    checklist.receive(.toolStarted(call("a")))
    checklist.receive(.toolStarted(call("b", step: "second")))
    checklist.receive(result("a"))
    let replacement = PlanStep(id: "second", summary: "Replacement", toolName: "read")
    checklist.receive(.planCreated(AgentPlan(steps: [first, replacement])))
    checklist.receive(result("b"))
    #expect(checklist.rows.map(\.status) == [.resultReceived, .pending])
  }

  @Test func successfulRunDoesNotInventExecutedOrSkippedSteps() {
    var checklist = PlanChecklist()
    let answer = PlanStep(id: "answer", summary: "Answer")
    checklist.receive(.planCreated(AgentPlan(steps: [first, second, answer])))
    checklist.receive(.toolStarted(call("a")))
    checklist.receive(result("a"))
    checklist.receive(.completed(AgentResponse(text: "Done", iterations: 2, toolCallCount: 1)))
    #expect(checklist.rows.map(\.status) == [.resultReceived, .notObserved, .runFinished])
    checklist.receive(.started)
    #expect(checklist.rows.isEmpty)
  }

  @Test func failureRefusalAndCancellationStopOnlyUnfinishedRows() {
    for event in [
      AgentEvent.error(.cancelled), .error(.modelUnavailable(reason: nil)),
      .guardrailRefused(GuardrailRefusal(explanation: "Refused")),
    ] {
      var checklist = PlanChecklist()
      checklist.receive(.planCreated(AgentPlan(steps: [first, second])))
      checklist.receive(.toolStarted(call("a")))
      checklist.receive(result("a"))
      checklist.receive(event)
      #expect(checklist.rows.map(\.status) == [.resultReceived, .stopped])
    }
  }

  @Test @MainActor func runtimeBridgesCorrelatedPlanToViewModel() async throws {
    let tool = MockTool(name: "read")
    let graph = TaskGraph(name: "read", nodes: [TaskNode(.tool("first", "Read first", "read"))])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: MockModelProvider()),
      tools: StaticToolSource([tool]), planner: TaskGraphPlanner(graph: graph))
    let model = AgentViewModel(runtime: runtime)
    model.send("Read")
    let deadline = ContinuousClock.now + .seconds(2)
    while model.isRunning || model.planChecklist.rows.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.planChecklist.rows.first?.step.id == "first")
    #expect(model.planChecklist.rows.first?.status == .resultReceived)
    await runtime.finishEvents()
  }
  @Test func concurrentCallsForOneStepStayActiveUntilAllReturnAndLateEventsStayTerminal() {
    var checklist = PlanChecklist()
    checklist.receive(.planCreated(AgentPlan(steps: [first])))
    checklist.receive(.toolStarted(call("a")))
    checklist.receive(.toolStarted(call("b")))
    checklist.receive(result("a"))
    #expect(checklist.rows[0].status == .running)
    checklist.receive(.error(.cancelled))
    checklist.receive(result("b"))
    checklist.receive(.toolStarted(call("late")))
    #expect(checklist.rows[0].status == .stopped)
    checklist.receive(.started)
    checklist.receive(.planCreated(AgentPlan(steps: [second])))
    #expect(checklist.rows[0].status == .pending)
  }

}
