import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitEvalSupport

@Suite struct ContextLoadTests {
  @Test func profilesPreservePairedHistoryAndSeparateBudgetSections() throws {
    let fixture = try SuiteLoader.contextFixture()
    #expect(fixture.profiles.count == 4 && fixture.probes.count == 6)
    for profile in fixture.profiles {
      let inputs = try fixture.inputs(profile: profile, probe: fixture.probes[0], tools: [])
      #expect(inputs.retrievedChunks.count == profile.chunks)
      #expect((inputs.planState != nil) == profile.plan)
      let calls = inputs.conversation.flatMap(\.toolCalls).map(\.id)
      let outputs = inputs.conversation.compactMap(\.toolCallID)
      #expect(calls == outputs)
      let full = ContextBudgeter.untrimmedRequest(for: inputs)
      #expect(full.messages.last?.content.contains(fixture.probes[0].question) == true)
      #expect(full.messages.filter { $0.role == .system }.count == 2 + (profile.plan ? 1 : 0))
    }
  }

  @Test func sourceTrackingDoesNotConfuseCoincidentalWordsWithEvidence() throws {
    let fixture = try SuiteLoader.contextFixture()
    let profile = try #require(fixture.profiles.first { $0.id == "stress" })
    for probe in fixture.probes {
      let inputs = try fixture.inputs(profile: profile, probe: probe, tools: [])
      #expect(fixture.sourceIncluded(probe, profile: profile))
      #expect(
        ContextLoadRunner.sourceStatus(
          fixture: fixture, profile: profile, probe: probe,
          request: ContextBudgeter.untrimmedRequest(for: inputs)) == .retained)
      #expect(
        ContextLoadRunner.sourceStatus(
          fixture: fixture, profile: profile, probe: probe,
          request: ModelRequest(messages: [
            ModelMessage(role: .user, content: probe.answerContainsAny[0])
          ])) == .uncertain)
      #expect(
        ContextLoadRunner.sourceStatus(
          fixture: fixture, profile: profile, probe: probe,
          request: ModelRequest(messages: [])) == .removed)
    }
    #expect(!fixture.sourceIncluded(fixture.probes[0], profile: fixture.profiles[0]))
  }

  @Test func actualDeliveredRequestAndRecallAreRecordedWithoutInventedTokenCounts() async throws {
    let model = MockModelProvider(
      contextWindowTokens: 100_000, handler: { _ in .text("Room Kestrel") })
    let result = try #require(
      await ContextLoadRunner.run(
        model: model, profileID: "stress", probeID: "pr-early", toolModes: [.contextOnly]
      ).first)
    #expect(result.outcome == .text && result.recallAssessment == "recalled")
    #expect(result.sourceAtGeneration == .retained)
    #expect(result.beforeFit?.total == nil && result.deliveredTokens == nil)
    #expect(!result.fittedTokensAreMeasured && result.generationStarted)
    #expect(await model.requests.count == 1)
  }

  @Test func measuredCountsAndRequiredToolsSurviveBothBudgetPasses() async throws {
    let model = MockModelProvider(
      contextWindowTokens: 100_000,
      tokenCounter: { $0.messages.reduce(0) { $0 + $1.content.count } + $0.tools.count * 10 })
    let result = try #require(
      await ContextLoadRunner.run(
        model: model, profileID: "light", probeID: "pr-recent", toolModes: [.registered]
      ).first)
    #expect(result.beforeFit?.total != nil && result.deliveredTokens != nil)
    #expect(result.fittedTokensAreMeasured)
    let measured = try #require(result.beforeFit)
    #expect(measured.componentTokens.values.reduce(0, +) == measured.total)
    #expect(measured.prefixTokens["history"] == measured.total)
    let catalogCount = try SuiteLoader.tools().count
    #expect(await model.requests.first?.tools.count == catalogCount)
    #expect(result.recallAssessment == "missed")
  }

  @Test func budgetFailureIsDistinctFromModelOverflow() async throws {
    let small = MockModelProvider(contextWindowTokens: 520)
    let budget = try #require(
      await ContextLoadRunner.run(
        model: small, profileID: "light", probeID: "pr-recent", toolModes: [.contextOnly]
      ).first)
    #expect(budget.outcome == .budgetExceeded && !budget.generationStarted)
    #expect(await small.requests.isEmpty)
    let overflow = MockModelProvider(
      contextWindowTokens: 100_000, handler: { _ in throw AgentError.contextLimitExceeded })
    let generated = try #require(
      await ContextLoadRunner.run(
        model: overflow, profileID: "light", probeID: "pr-recent", toolModes: [.contextOnly]
      ).first)
    #expect(generated.outcome == .modelExceeded && generated.generationStarted)
    let summary = ContextLoadSummary([budget, generated])
    #expect(summary.exhaustionRate == 1 && summary.modelExhaustionRate == 1)
    #expect(summary.budgetExhaustions == 1 && summary.modelExhaustions == 1)
  }

  @Test func trimmingAndAbsentSourcesDoNotEarnRecall() async throws {
    let model = MockModelProvider(handler: { _ in .text("Room Kestrel") })
    let absent = try #require(
      await ContextLoadRunner.run(
        model: model, profileID: "light", probeID: "pr-early", toolModes: [.contextOnly]
      ).first)
    #expect(absent.sourceAtGeneration == .absent)
    #expect(absent.recallAssessment == "answerWithoutRetainedSource")
    let trimmed = try #require(
      await ContextLoadRunner.run(
        model: model, profileID: "stress", probeID: "pr-chunk-late", toolModes: [.contextOnly]
      ).first)
    #expect((trimmed.trim?.droppedChunks ?? 0) > 0)
    #expect(trimmed.sourceAfterFit != .retained)
    #expect(trimmed.recallAssessment != "missed" && trimmed.recallAssessment != "recalled")
  }

  @Test func unexpectedToolCallsAreNotExecutedOrScoredAsRecall() async throws {
    let model = MockModelProvider(
      contextWindowTokens: 100_000,
      handler: { _ in
        .toolCall(ToolCall(id: "probe", name: "create_note", arguments: ToolArguments([:])))
      })
    let result = try #require(
      await ContextLoadRunner.run(
        model: model, profileID: "light", probeID: "pr-recent", toolModes: [.registered]
      ).first)
    #expect(result.outcome == .unexpectedToolCall && result.recallAssessment == "notScored")
    #expect(await model.requests.count == 1)
  }

  @Test func timeoutAndCancellationRemainVisible() async throws {
    let model = ScriptedModelProvider([.hang])
    let result = try #require(
      await ContextLoadRunner.run(
        model: model, profileID: "light", probeID: "pr-recent", toolModes: [.contextOnly],
        timeout: .milliseconds(30)
      ).first)
    #expect(result.outcome == .timeout)
    let cancelled = ScriptedModelProvider([.fail(.cancelled)])
    await #expect(throws: CancellationError.self) {
      try await ContextLoadRunner.run(
        model: cancelled, profileID: "light", probeID: "pr-recent",
        toolModes: [.contextOnly])
    }
  }

  @Test func refusalsRemainTerminalAndUnscored() async throws {
    let model = ScriptedModelProvider([
      .respond(.refused(GuardrailRefusal(explanation: "Declined")))
    ])
    let result = try #require(
      await ContextLoadRunner.run(
        model: model, profileID: "light", probeID: "pr-recent", toolModes: [.contextOnly]
      ).first)
    #expect(result.outcome == .refused && result.recallAssessment == "notScored")
    #expect(await model.requests.count == 1)
    #expect(ContextLoadSummary([result]).refusals == 1)
  }

  @Test func invalidSelectorsAndEmptySummaries() async throws {
    await #expect(throws: ProbeError.self) {
      try await ContextLoadRunner.run(model: MockModelProvider(), profileID: "missing")
    }
    await #expect(throws: ProbeError.self) {
      try await ContextLoadRunner.run(model: MockModelProvider(), toolModes: [])
    }
    #expect(ContextLoadSummary([]).exhaustionRate == nil)
    #expect(ContextLoadSummary([]).modelExhaustionRate == nil)
  }
}
