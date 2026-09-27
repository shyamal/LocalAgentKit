import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

/// A token counter independent of the runtime's estimator: ~4 characters per token, 60 tokens
/// per tool definition.
private func realCount(_ request: ModelRequest) -> Int {
  request.messages.reduce(0) { $0 + 4 + $1.content.count / 4 } + request.tools.count * 60
}

private func model(
  window: Int = 1000, counter: (@Sendable (ModelRequest) -> Int?)? = realCount
) -> MockModelProvider {
  MockModelProvider(contextWindowTokens: window, tokenCounter: counter)
}

private let config = ContextBudgetConfiguration(responseReserveTokens: 100)

private func tool(_ name: String) -> ToolDescriptor {
  ToolDescriptor(
    name: name, description: String(repeating: "d", count: 180), schema: .empty, permission: .none,
    isParallelSafe: true, isCancellable: true)
}

/// `count` turns, each: user question, assistant tool call, a large tool output, assistant answer.
private func history(turns count: Int, outputCharacters: Int = 400) -> [ModelMessage] {
  (0..<count).flatMap { index -> [ModelMessage] in
    let call = ToolCall(id: "c\(index)", name: "search_notes")
    return [
      ModelMessage(role: .user, content: "Question number \(index)?"),
      ModelMessage(role: .assistant, content: "", toolCalls: [call]),
      ModelMessage(
        role: .tool, content: String(repeating: "x", count: outputCharacters),
        toolCallID: "c\(index)"),
      ModelMessage(role: .assistant, content: "Answer \(index)."),
    ]
  }
}

private func inputs(
  conversation: [ModelMessage], tools: [ToolDescriptor] = [], chunks: [String] = [],
  plan: String? = nil, required: Set<String> = []
) -> ContextInputs {
  ContextInputs(
    instructions: "You are an assistant.", tools: tools, requiredToolNames: required,
    conversation: conversation, retrievedChunks: chunks, planState: plan)
}

/// iOS 27 rejects a tool output whose call is missing (findings §10a).
private func everyToolOutputHasItsCall(_ messages: [ModelMessage]) -> Bool {
  var seen: Set<String> = []
  for message in messages {
    for call in message.toolCalls { seen.insert(call.id) }
    if message.role == .tool, !seen.contains(message.toolCallID ?? "") { return false }
  }
  return true
}

@Suite struct ContextBudgeterTests {
  let budgeter = ContextBudgeter(configuration: config)

  @Test func fitsUntouchedWhenThereIsRoom() async throws {
    let conversation = history(turns: 1, outputCharacters: 40)
    let context = try await budgeter.fit(inputs(conversation: conversation), for: model())
    #expect(!context.report.isTrimmed)
    #expect(context.request.messages.count == conversation.count + 1)
    #expect(context.utilization.usedTokens == realCount(context.request))
    #expect(context.utilization.limitTokens == 1000)
    #expect(!context.utilization.wasTrimmed)
  }

  @Test func publishesUtilization() async throws {
    let bus = EventBus()
    let stream = await bus.subscribe()
    _ = try await budgeter.fit(
      inputs(conversation: history(turns: 1, outputCharacters: 40)), for: model(), events: bus)
    await bus.finish()
    var reported: ContextUtilization?
    for await event in stream {
      if case .contextUtilization(let utilization) = event { reported = utilization }
    }
    #expect(reported?.limitTokens == 1000)
  }

  @Test func shortensOldToolOutputsBeforeDroppingAnyTurn() async throws {
    // 4 turns of ~120 tokens each is over 900 only if the outputs stay long.
    let conversation = history(turns: 6, outputCharacters: 600)
    let context = try await budgeter.fit(inputs(conversation: conversation), for: model())
    #expect(context.report.compactedToolOutputs > 0)
    #expect(context.report.summarizedMessages == 0)
    #expect(context.request.messages.filter { $0.role == .user }.count == 6)
    #expect(realCount(context.request) <= 900)
  }

  @Test func summarizesTheOldestWholeTurnsAndKeepsTheCurrentOne() async throws {
    let conversation = history(turns: 20, outputCharacters: 600)
    let context = try await budgeter.fit(inputs(conversation: conversation), for: model())
    #expect(context.report.summarizedMessages > 0)
    #expect(context.report.summarizedMessages % 4 == 0)  // whole turns only
    let messages = context.request.messages
    #expect(messages.last?.content == "Answer 19.")
    #expect(messages.contains { $0.content.hasPrefix(ExtractiveSummarizer.header) })
    #expect(!messages.contains { $0.content == "Question number 0?" })
    #expect(everyToolOutputHasItsCall(messages))
    #expect(realCount(context.request) <= 900)
    #expect(context.utilization.wasTrimmed)
  }

  @Test func dropsTheLeastRelevantChunksFirst() async throws {
    let chunks = (0..<10).map { "chunk\($0) " + String(repeating: "y", count: 400) }
    let context = try await budgeter.fit(
      inputs(conversation: history(turns: 1, outputCharacters: 40), chunks: chunks),
      for: model())
    #expect(context.report.droppedChunks > 0)
    let block = try #require(
      context.request.messages.first { $0.content.hasPrefix("Relevant documents:") })
    #expect(block.content.contains("chunk0"))
    #expect(!block.content.contains("chunk9"))
    #expect(realCount(context.request) <= 900)
  }

  @Test func dropsLowPriorityToolsButKeepsRequiredOnes() async throws {
    let tools = (0..<15).map { tool("tool_\($0)") }
    // Fifteen tools cost 900 of 900, so with the conversation the request overflows, and the
    // 30% system share is 270.
    let context = try await budgeter.fit(
      inputs(
        conversation: history(turns: 1, outputCharacters: 40), tools: tools, required: ["tool_14"]),
      for: model())
    let kept = context.request.tools.map(\.name)
    #expect(kept.contains("tool_14"))
    #expect(kept.contains("tool_0"))
    #expect(!context.report.droppedToolNames.isEmpty)
    #expect(!context.report.droppedToolNames.contains("tool_14"))
  }

  @Test func truncatesPlanStateToItsShare() async throws {
    let plan = (1...40).map { "Step \($0): do something moderately long here." }.joined(
      separator: "\n")
    let context = try await budgeter.fit(
      inputs(conversation: history(turns: 6, outputCharacters: 400), plan: plan), for: model())
    #expect(context.report.planTruncated)
    let text = context.request.messages.first { $0.content.hasPrefix("Current plan:") }?.content
    #expect(text?.contains("Step 1:") == true)
    #expect(text?.contains("Step 40:") != true)
  }

  @Test func throwsWhenTheCurrentTurnAloneCannotFit() async {
    let huge = [ModelMessage(role: .user, content: String(repeating: "z", count: 8000))]
    await #expect(throws: AgentError.contextLimitExceeded) {
      try await budgeter.fit(inputs(conversation: huge), for: model())
    }
  }

  @Test func throwsWhenRequiredToolsAloneExceedTheWindow() async {
    let tools = (0..<16).map { tool("tool_\($0)") }
    await #expect(throws: AgentError.contextLimitExceeded) {
      try await budgeter.fit(
        inputs(
          conversation: history(turns: 1, outputCharacters: 40), tools: tools,
          required: Set(tools.map(\.name))),
        for: model())
    }
  }

  @Test func throwsWhenTheWindowIsSmallerThanTheReserve() async {
    await #expect(throws: AgentError.contextLimitExceeded) {
      try await budgeter.fit(inputs(conversation: history(turns: 1)), for: model(window: 100))
    }
  }

  @Test func executionLimitsCapTheWindow() async throws {
    let conversation = history(turns: 6, outputCharacters: 400)
    let context = try await budgeter.fit(
      inputs(conversation: conversation), for: model(window: 4000),
      limits: ExecutionLimits(maxContextTokens: 1000))
    #expect(context.utilization.limitTokens == 1000)
    #expect(realCount(context.request) <= 900)
  }

  @Test func usesTheFallbackWindowWhenNoneIsKnown() async throws {
    let context = try await budgeter.fit(
      inputs(conversation: history(turns: 1, outputCharacters: 40)),
      for: MockModelProvider(tokenCounter: realCount))
    #expect(context.utilization.limitTokens == 4096)
  }

  @Test func calibratesAgainstTheRealCounter() async throws {
    // This counter is far stricter than the estimator (twice the tokens), so an uncalibrated
    // estimate would leave the request over budget.
    let strict: @Sendable (ModelRequest) -> Int? = { realCount($0) * 2 }
    let context = try await budgeter.fit(
      inputs(conversation: history(turns: 20, outputCharacters: 600)), for: model(counter: strict))
    #expect(strict(context.request)! <= 900)
    #expect(context.utilization.usedTokens == strict(context.request))
  }

  @Test func givesUpAfterBoundedPassesIfTheCounterNeverAgrees() async {
    let never: @Sendable (ModelRequest) -> Int? = { _ in 5000 }
    await #expect(throws: AgentError.contextLimitExceeded) {
      try await budgeter.fit(
        inputs(conversation: history(turns: 3)), for: model(counter: never))
    }
  }

  @Test func withoutACounterItStillFitsByEstimate() async throws {
    let context = try await budgeter.fit(
      inputs(conversation: history(turns: 20, outputCharacters: 600)),
      for: model(counter: nil))
    #expect(TokenEstimator.tokens(context.request) <= 900)
    #expect(context.report.isTrimmed)
  }

  @Test func neverExceedsTheBudgetAcrossManyShapes() async throws {
    for turns in [1, 3, 8, 15, 30] {
      for chunkCount in [0, 4, 12] {
        let chunks = (0..<chunkCount).map { _ in String(repeating: "c", count: 300) }
        let conversation = history(turns: turns, outputCharacters: 500)
        do {
          let context = try await budgeter.fit(
            inputs(
              conversation: conversation, tools: (0..<3).map { tool("t\($0)") }, chunks: chunks,
              plan: "Step 1\nStep 2"),
            for: model())
          #expect(realCount(context.request) <= 900, "turns \(turns) chunks \(chunkCount)")
          #expect(everyToolOutputHasItsCall(context.request.messages))
          #expect(context.request.messages.last?.content == "Answer \(turns - 1).")
        } catch AgentError.contextLimitExceeded {
          // Acceptable, and typed: never an over-budget request.
        }
      }
    }
  }

  @Test func rejectsUnusableShares() async {
    let bad = ContextBudgeter(
      configuration: ContextBudgetConfiguration(
        systemAndToolsShare: 0, conversationShare: 0, retrievalShare: 0, planShare: 0))
    await #expect(throws: AgentError.self) {
      try await bad.fit(inputs(conversation: history(turns: 1)), for: model())
    }
  }

  @Test func emptyConversationIsFine() async throws {
    let context = try await budgeter.fit(inputs(conversation: []), for: model())
    #expect(context.request.messages.count == 1)
  }
}

@Suite struct AllocationTests {
  @Test func proportionalWhenEveryoneWantsMore() {
    #expect(
      ContextBudgeter.allocate(needs: [900, 900, 900], weights: [1, 2, 1], total: 400)
        == [100, 200, 100])
  }

  @Test func surplusFlowsToTheOthers() {
    let result = ContextBudgeter.allocate(needs: [10, 900, 900], weights: [1, 1, 1], total: 300)
    #expect(result[0] == 10)
    #expect(result[1] == 145)
    #expect(result[2] == 145)
  }

  @Test func neverExceedsTheTotal() {
    let result = ContextBudgeter.allocate(needs: [50, 60, 70], weights: [1, 1, 1], total: 100)
    #expect(result.reduce(0, +) <= 100)
  }

  @Test func zeroWeightGetsNothing() {
    let result = ContextBudgeter.allocate(needs: [50, 50], weights: [0, 1], total: 100)
    #expect(result[0] == 0)
  }
}

@Suite struct SummarizerTests {
  @Test func keepsWhatWasAskedAndWhichToolsRan() async throws {
    let summary = try await ExtractiveSummarizer().summarize(history(turns: 2), maxTokens: 500)
    #expect(summary.hasPrefix(ExtractiveSummarizer.header))
    #expect(summary.contains("User: Question number 0?"))
    #expect(summary.contains("Called search_notes"))
    #expect(!summary.contains("xxxx"))
  }

  @Test func staysWithinItsBoundAndKeepsTheNewestLines() async throws {
    let summary = try await ExtractiveSummarizer().summarize(history(turns: 50), maxTokens: 60)
    #expect(TokenEstimator.tokens(summary) <= 60)
    #expect(summary.contains("Question number 49?"))
    #expect(!summary.contains("Question number 0?"))
  }
}
