import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private struct SemanticCalls: AgentPlanner {
  let calls: [ToolCall]
  let batch: Bool
  func plan(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    -> AgentPlan
  { AgentPlan(steps: []) }
  func next(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    -> PlannerDecision
  {
    let index = context.observations.count
    if index >= calls.count { return .complete("Done") }
    return batch ? .callTools(calls) : .callTool(calls[index])
  }
  func observe(_ observation: ToolObservation, context: inout AgentContext) -> PlanRevision {
    context.observations.append(observation)
    return .continue
  }
  func handleFailure(_ error: AgentError, context: inout AgentContext) throws -> PlanRevision {
    throw error
  }
}

@Suite struct SemanticLoopRuntimeTests {
  private func runtime(_ tool: MockTool, batch: Bool, enabled: Bool = true) throws -> AgentRuntime {
    let phrases = ["find budget notes", "notes about the budget", "budget meeting notes"]
    let policy = LoopDetectionConfiguration(
      textRules: enabled
        ? [
          .init(tool: "search", argument: "query", equivalentPhrases: [phrases])
        ] : [])
    let calls = phrases.enumerated().map {
      ToolCall(
        id: "\($0.offset)", name: "search", arguments: ToolArguments(["query": .string($0.element)])
      )
    }
    return try AgentRuntime(
      configuration: AgentConfiguration(model: MockModelProvider(), loopDetection: policy),
      tools: StaticToolSource([tool]), planner: SemanticCalls(calls: calls, batch: batch))
  }

  @Test func serialSemanticLoopStopsBeforeThirdExecutionAndResetsBetweenRuns() async throws {
    let tool = MockTool(
      name: "search",
      schema: ToolSchema(
        parameters: ["query": .init(.string, description: "Search text")], required: ["query"]))
    let agent = try runtime(tool, batch: false)
    for _ in 0..<2 {
      await #expect(throws: AgentError.loopDetected(tool: "search")) {
        try await agent.run("Find notes")
      }
    }
    #expect(await tool.executions.count == 4)
    // Normalization is detection-only; tools still receive the original argument text.
    #expect(await tool.executions.first?.string("query") == "find budget notes")
  }

  @Test func semanticBatchIsRejectedBeforeAnyMemberExecutes() async throws {
    let tool = MockTool(name: "search")
    let agent = try runtime(tool, batch: true)
    await #expect(throws: AgentError.loopDetected(tool: "search")) {
      try await agent.run("Find notes")
    }
    #expect(await tool.executions.isEmpty)
  }

  @Test func defaultPolicyDoesNotGuessParaphraseEquivalence() async throws {
    let tool = MockTool(
      name: "search",
      schema: ToolSchema(
        parameters: ["query": .init(.string, description: "Search text")], required: ["query"]))
    let agent = try runtime(tool, batch: false, enabled: false)
    _ = try await agent.run("Find notes")
    #expect(await tool.executions.count == 3)
  }
}
