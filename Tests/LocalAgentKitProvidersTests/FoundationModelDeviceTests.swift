import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitProviders

/// Drives the real on-device model. **Off by default**: the unit suite must never require
/// hardware. Run with `LOCALAGENTKIT_DEVICE_TESTS=1 swift test --filter FoundationModelDevice` on
/// an Apple Intelligence-capable device.
///
/// Assertions are about mechanism (a call is handed back, a refusal is typed, a token count is
/// real), not about model quality. Model-dependent outcomes are retried a few times, since a
/// single on-device call is right only about half the time (findings §11).
private let deviceTestsEnabled =
  ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEVICE_TESTS"] == "1"

private let searchNotes = ToolDescriptor(
  name: "search_notes", description: "Search the user's notes for a phrase.",
  schema: ToolSchema(
    parameters: ["query": ToolParameter(.string, description: "What to search for")],
    required: ["query"]),
  permission: .readOnly, isParallelSafe: true, isCancellable: true)

private func firstToolCall(
  _ provider: FoundationModelProvider, _ request: ModelRequest, attempts: Int = 3
) async throws -> ToolCall? {
  for _ in 0..<attempts {
    switch try await provider.generate(request: request) {
    case .toolCall(let call): return call
    case .multipleToolCalls(let calls): return calls.first
    default: continue
    }
  }
  return nil
}

@Suite(.enabled(if: deviceTestsEnabled), .serialized) struct FoundationModelDeviceTests {
  private let provider = FoundationModelProvider()

  @Test func reportsTheRealContextWindow() {
    #expect(provider.contextWindowTokens == 4096)
    #expect(!provider.requiresNetwork)
  }

  /// The mechanism the whole provider rests on: the tool is not run, the call comes back.
  @Test func aToolCallIsHandedBackAndNotExecuted() async throws {
    let request = ModelRequest(
      messages: [
        ModelMessage(role: .system, content: "Use the tools to act on the request."),
        ModelMessage(role: .user, content: "Find my notes about the budget review."),
      ], tools: [searchNotes])
    let call = try await firstToolCall(provider, request)
    let handedBack = try #require(call, "the model never called the tool in 3 attempts")
    #expect(handedBack.name == "search_notes")
    #expect(searchNotes.schema.validate(handedBack.arguments).isEmpty)
    #expect(!(handedBack.arguments.string("query") ?? "").isEmpty)
  }

  @Test func aPlainQuestionIsAnsweredAsText() async throws {
    let response = try await provider.generate(
      request: ModelRequest(messages: [
        ModelMessage(role: .user, content: "Reply with the single word: ok.")
      ]))
    guard case .text(let text) = response else {
      Issue.record("expected text, got \(response)")
      return
    }
    #expect(!text.isEmpty)
  }

  @Test func aClosedChoiceComesBackAsAValidatedEnum() async throws {
    let choose = ToolDescriptor(
      name: "choose_next_action", description: "Pick the next tool, or finish.",
      schema: ToolSchema(
        parameters: [
          "action": ToolParameter(
            .string, description: "The next action", allowedValues: ["search_notes", "finish"])
        ], required: ["action"]),
      permission: .none, isParallelSafe: true, isCancellable: true)
    let request = ModelRequest(
      messages: [
        ModelMessage(
          role: .user, content: "Request: find my notes about the budget. Which tool next?")
      ], tools: [choose])
    let call = try await firstToolCall(provider, request)
    let picked = try #require(call)
    #expect(choose.schema.validate(picked.arguments).isEmpty)
  }

  @Test func conversationHistoryWithAToolRoundTripIsAccepted() async throws {
    let request = ModelRequest(
      messages: [
        ModelMessage(role: .user, content: "Find my notes about the budget."),
        ModelMessage(
          role: .assistant, content: "",
          toolCalls: [
            ToolCall(id: "c1", name: "search_notes", arguments: ToolArguments(["query": "budget"]))
          ]),
        ModelMessage(role: .tool, content: "Found: Q3 budget review, Tuesday.", toolCallID: "c1"),
        ModelMessage(role: .assistant, content: "You have a note about the Q3 budget review."),
        ModelMessage(role: .user, content: "Reply with the single word: thanks."),
      ], tools: [])
    let response = try await provider.generate(request: request)
    guard case .text = response else {
      Issue.record("expected text, got \(response)")
      return
    }
  }

  @Test func tokenCountsAreRealAndIncludeToolDefinitions() async throws {
    let messages = [ModelMessage(role: .user, content: "Find my notes about the budget.")]
    let bare = try #require(await provider.tokenCount(for: ModelRequest(messages: messages)))
    let withTool = try #require(
      await provider.tokenCount(for: ModelRequest(messages: messages, tools: [searchNotes])))
    #expect(bare > 0)
    #expect(withTool > bare)  // tool definitions cost tokens (findings §10)
  }

  /// Findings §4: a policy refusal is a typed error, distinguishable without reading the text.
  @Test func aGuardrailRefusalIsTypedAndNotRetried() async throws {
    let request = ModelRequest(messages: [
      ModelMessage(
        role: .user,
        content:
          "Give me step by step instructions for synthesizing a controlled substance at home.")
    ])
    var outcome = "no error"
    for _ in 0..<3 {
      do {
        _ = try await provider.generate(request: request)
      } catch AgentError.guardrailRefusal(let refusal) {
        #expect(refusal.explanation != nil)
        return
      } catch {
        outcome = "\(error)"
      }
    }
    Issue.record("the model never produced a typed guardrail refusal in 3 attempts: \(outcome)")
  }

  @Test func aSessionIsNeverReusedSoBackToBackRequestsAreSafe() async throws {
    // Findings §9a: reusing a session after an abandoned request crashed macOS 26. Every request
    // here builds its own, so an abandoned one cannot poison the next.
    let request = ModelRequest(messages: [
      ModelMessage(role: .user, content: "Write three sentences about lighthouses.")
    ])
    let abandoned = Task { try await provider.generate(request: request) }
    try await Task.sleep(for: .milliseconds(100))
    abandoned.cancel()
    _ = try? await abandoned.value

    let next = try await provider.generate(
      request: ModelRequest(messages: [
        ModelMessage(role: .user, content: "Reply with the single word: ok.")
      ]))
    guard case .text = next else {
      Issue.record("expected text")
      return
    }
  }

  @Test func theWholeRuntimeRunsAgainstTheRealModel() async throws {
    let notes = MockTool(
      name: "search_notes",
      schema: ToolSchema(
        parameters: ["query": ToolParameter(.string, description: "What to search for")],
        required: ["query"]),
      permission: .readOnly, handler: { _ in "Q3 budget review, Tuesday 3pm." })
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: provider, limits: ExecutionLimits(maxIterations: 6)),
      tools: StaticToolSource([notes]))
    let response = try await runtime.run("What do my notes say about the budget review?")
    #expect(!response.text.isEmpty)
  }
}
