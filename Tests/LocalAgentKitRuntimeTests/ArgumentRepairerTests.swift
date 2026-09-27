import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

@Suite struct ArgumentRepairerTests {
  private let descriptor = ToolDescriptor(
    name: "create_note",
    description: "Create a note",
    schema: ToolSchema(
      parameters: ["text": ToolParameter(.string, description: "Text")], required: ["text"]),
    permission: .userConfirmation, isParallelSafe: false, isCancellable: true)

  private func bad() -> ToolCall { ToolCall(id: "1", name: "create_note") }
  private func good() -> ToolCall {
    ToolCall(id: "2", name: "create_note", arguments: ToolArguments(["text": "hi"]))
  }
  private let violations: [ArgumentViolation] = [.missingRequired(path: "text")]

  @Test func repairsOnTheFirstRetry() async throws {
    let model = ScriptedModelProvider(responses: [.toolCall(good())])
    let repaired = try await ArgumentRepairer().repair(
      bad(), violations: violations, descriptor: descriptor, history: [], model: model)
    #expect(repaired == good())
  }

  @Test func feedbackNamesTheViolation() async throws {
    let model = ScriptedModelProvider(responses: [.toolCall(good())])
    _ = try await ArgumentRepairer().repair(
      bad(), violations: violations, descriptor: descriptor, history: [], model: model)
    let request = try #require(await model.requests.first)
    let feedback = try #require(request.messages.last)
    #expect(feedback.role == .tool)
    #expect(feedback.toolCallID == "1")
    #expect(feedback.content.contains("text is required"))
  }

  @Test func retriesAreBounded() async {
    let model = ScriptedModelProvider(responses: [
      .toolCall(bad()), .toolCall(bad()), .toolCall(bad()),
    ])
    await #expect(throws: AgentError.invalidArguments(tool: "create_note", violations: violations))
    {
      try await ArgumentRepairer(maxAttempts: 2).repair(
        bad(), violations: violations, descriptor: descriptor, history: [], model: model)
    }
    #expect(await model.requests.count == 2)
  }

  @Test func zeroAttemptsFailsWithoutCallingTheModel() async {
    let model = ScriptedModelProvider([])
    await #expect(throws: AgentError.self) {
      try await ArgumentRepairer(maxAttempts: 0).repair(
        bad(), violations: violations, descriptor: descriptor, history: [], model: model)
    }
    #expect(await model.requests.isEmpty)
  }

  @Test func refusalIsTerminalNotRetried() async {
    let refusal = GuardrailRefusal(explanation: "no")
    let model = ScriptedModelProvider(responses: [.refused(refusal), .toolCall(good())])
    await #expect(throws: AgentError.guardrailRefusal(refusal)) {
      try await ArgumentRepairer().repair(
        bad(), violations: violations, descriptor: descriptor, history: [], model: model)
    }
    #expect(await model.remainingSteps == 1)
  }

  @Test func modelGivingUpOnTheToolFails() async {
    let model = ScriptedModelProvider(responses: [.text("I cannot")])
    await #expect(throws: AgentError.invalidArguments(tool: "create_note", violations: violations))
    {
      try await ArgumentRepairer().repair(
        bad(), violations: violations, descriptor: descriptor, history: [], model: model)
    }
  }

  @Test func historyIsPreservedAhead() async throws {
    let model = ScriptedModelProvider(responses: [.toolCall(good())])
    let history = [ModelMessage(role: .user, content: "take a note")]
    _ = try await ArgumentRepairer().repair(
      bad(), violations: violations, descriptor: descriptor, history: history, model: model)
    let request = try #require(await model.requests.first)
    #expect(request.messages.first == history[0])
    #expect(request.tools == [descriptor])
  }
}
