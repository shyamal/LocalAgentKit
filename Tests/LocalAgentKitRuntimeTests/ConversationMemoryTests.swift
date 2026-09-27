import LocalAgentKitCore
import Testing

@testable import LocalAgentKitRuntime

@Suite struct ConversationMemoryTests {
  @Test func startsEmpty() async {
    let memory = ConversationMemory()
    #expect(await memory.history().isEmpty)
  }

  @Test func recordTurnAppendsUserThenAssistant() async {
    let memory = ConversationMemory()
    await memory.recordTurn(goal: "What meetings do I have?", answer: "Two meetings today.")
    let history = await memory.history()
    #expect(history.count == 2)
    #expect(history[0].role == .user)
    #expect(history[0].content == "What meetings do I have?")
    #expect(history[1].role == .assistant)
    #expect(history[1].content == "Two meetings today.")
  }

  @Test func multipleTurnsAppendInOrder() async {
    let memory = ConversationMemory()
    await memory.recordTurn(goal: "One?", answer: "First answer.")
    await memory.recordTurn(goal: "Two?", answer: "Second answer.")
    let history = await memory.history()
    #expect(history.map(\.content) == ["One?", "First answer.", "Two?", "Second answer."])
  }

  @Test func resetForgetsEverything() async {
    let memory = ConversationMemory()
    await memory.recordTurn(goal: "One?", answer: "First answer.")
    await memory.reset()
    #expect(await memory.history().isEmpty)
  }

  @Test func historyGrowsWithoutPruningUnderTheShare() async {
    let memory = ConversationMemory(approximateShareTokens: 4000, retentionMultiple: 4)
    for index in 0..<10 {
      await memory.recordTurn(goal: "Question \(index)?", answer: "Answer \(index).")
    }
    let history = await memory.history()
    #expect(history.count == 20)  // nothing pruned yet: well under 16,000 tokens
  }

  @Test func historyIsPrunedOnceItExceedsTheRetentionCap() async {
    // A tiny share/multiple so a handful of turns already exceeds the cap.
    let memory = ConversationMemory(approximateShareTokens: 50, retentionMultiple: 2)
    for index in 0..<30 {
      await memory.recordTurn(
        goal: "This is a longer question number \(index) about the quarterly budget review?",
        answer: "This is a longer answer number \(index) with several words in it as well.")
    }
    let history = await memory.history()
    #expect(history.count < 60)  // fewer than the 60 raw messages 30 turns would produce
    #expect(history.first?.role == .system)  // the oldest half became a summary
    #expect(history.first?.content.hasPrefix(ExtractiveSummarizer.header) == true)
  }

  @Test func theMostRecentTurnSurvivesPruningVerbatim() async {
    let memory = ConversationMemory(approximateShareTokens: 50, retentionMultiple: 2)
    for index in 0..<30 {
      await memory.recordTurn(
        goal: "This is a longer question number \(index) about the quarterly budget review?",
        answer: "This is a longer answer number \(index) with several words in it as well.")
    }
    let history = await memory.history()
    #expect(
      history.last?.content == "This is a longer answer number 29 with several words in it as well."
    )
  }
}
