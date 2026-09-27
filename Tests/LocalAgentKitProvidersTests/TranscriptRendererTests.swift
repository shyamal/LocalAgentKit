import FoundationModels
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitProviders

private func text(_ segments: [Transcript.Segment]) -> String {
  segments.compactMap { segment -> String? in
    if case .text(let text) = segment { text.content } else { nil }
  }.joined()
}

private func kind(_ entry: Transcript.Entry) -> String {
  switch entry {
  case .instructions: "instructions"
  case .prompt: "prompt"
  case .toolCalls: "toolCalls"
  case .toolOutput: "toolOutput"
  case .response: "response"
  @unknown default: "other"
  }
}

private func user(_ content: String) -> ModelMessage { ModelMessage(role: .user, content: content) }
private func assistant(_ content: String) -> ModelMessage {
  ModelMessage(role: .assistant, content: content)
}
private func calling(_ id: String, _ name: String, _ args: [String: JSONValue] = [:])
  -> ModelMessage
{
  ModelMessage(
    role: .assistant, content: "",
    toolCalls: [ToolCall(id: id, name: name, arguments: ToolArguments(args))])
}
private func output(_ id: String, _ content: String) -> ModelMessage {
  ModelMessage(role: .tool, content: content, toolCallID: id)
}

@Suite struct TranscriptRendererTests {
  @Test func leadingSystemMessagesBecomeInstructionsAndTheLastUserMessageIsThePrompt() throws {
    let rendered = try TranscriptRenderer.render(
      ModelRequest(messages: [
        ModelMessage(role: .system, content: "Be brief."),
        ModelMessage(role: .system, content: "Today is Monday."), user("Hello"),
      ]))
    #expect(rendered.instructions == "Be brief.\n\nToday is Monday.")
    #expect(rendered.prompt == "Hello")
    #expect(rendered.entries.isEmpty)
  }

  @Test func earlierTurnsBecomeTranscriptEntriesInOrder() throws {
    let rendered = try TranscriptRenderer.render(
      ModelRequest(messages: [user("One?"), assistant("Uno."), user("Two?")]))
    #expect(rendered.entries.map(kind) == ["prompt", "response"])
    #expect(rendered.prompt == "Two?")
  }

  @Test func aCallAndItsOutputStayPairedWithTheSameID() throws {
    let rendered = try TranscriptRenderer.render(
      ModelRequest(messages: [
        user("Find notes"), calling("c1", "search_notes", ["query": "budget"]),
        output("c1", "Found 2"), assistant("Two notes."), user("Thanks"),
      ]))
    #expect(rendered.entries.map(kind) == ["prompt", "toolCalls", "toolOutput", "response"])
    guard case .toolCalls(let calls) = rendered.entries[1],
      case .toolOutput(let result) = rendered.entries[2]
    else {
      Issue.record("wrong entries")
      return
    }
    #expect(calls.first?.id == "c1")
    #expect(calls.first?.toolName == "search_notes")
    #expect(calls.first?.arguments.jsonString.contains("budget") == true)
    // iOS 27 rejects an output that does not carry its call's id (findings §10a).
    #expect(result.id == "c1")
    #expect(result.toolName == "search_notes")
    #expect(text(result.segments) == "Found 2")
  }

  @Test func anOutputWithNoMatchingCallIsRenderedAsTextNotPassedThrough() throws {
    let rendered = try TranscriptRenderer.render(
      ModelRequest(messages: [user("Hi"), output("ghost", "stray"), user("Again")]))
    #expect(rendered.entries.map(kind) == ["prompt", "prompt"])
    guard case .prompt(let prompt) = rendered.entries[1] else { return }
    #expect(text(prompt.segments) == "Result: stray")
  }

  @Test func aCallWhoseOutputIsMissingIsDroppedRatherThanLeftDangling() throws {
    let rendered = try TranscriptRenderer.render(
      ModelRequest(messages: [user("Find"), calling("c1", "search_notes"), user("Never mind")]))
    #expect(rendered.entries.map(kind) == ["prompt"])
  }

  @Test func aCallWithOnlySomeOfItsOutputsIsDropped() throws {
    let both = ModelMessage(
      role: .assistant, content: "",
      toolCalls: [ToolCall(id: "a", name: "t"), ToolCall(id: "b", name: "t")])
    let rendered = try TranscriptRenderer.render(
      ModelRequest(messages: [user("go"), both, output("a", "x"), user("next")]))
    #expect(!rendered.entries.map(kind).contains("toolCalls"))
  }

  @Test func aTrailingToolResultIsFoldedIntoThePrompt() throws {
    // The repair path ends with feedback awaiting the model's next turn.
    let rendered = try TranscriptRenderer.render(
      ModelRequest(messages: [
        user("Save it"), calling("c1", "create_note"),
        output("c1", "text is required. Call the tool again."),
      ]))
    #expect(rendered.entries.map(kind) == ["prompt"])
    #expect(rendered.prompt == "Result: text is required. Call the tool again.")
  }

  @Test func severalTrailingResultsAreAllFolded() throws {
    let two = ModelMessage(
      role: .assistant, content: "",
      toolCalls: [ToolCall(id: "a", name: "t"), ToolCall(id: "b", name: "t")])
    let rendered = try TranscriptRenderer.render(
      ModelRequest(messages: [user("go"), two, output("a", "one"), output("b", "two")]))
    #expect(rendered.prompt == "Result: one\nResult: two")
    #expect(rendered.entries.map(kind) == ["prompt"])
  }

  @Test func aRequestWithNothingToRespondToIsRejected() {
    #expect(throws: AgentError.self) {
      try TranscriptRenderer.render(ModelRequest(messages: []))
    }
    #expect(throws: AgentError.self) {
      try TranscriptRenderer.render(
        ModelRequest(messages: [ModelMessage(role: .system, content: "only instructions")]))
    }
  }

  @Test func aRequestEndingInAnAssistantMessageIsRejected() {
    #expect(throws: AgentError.self) {
      try TranscriptRenderer.render(ModelRequest(messages: [user("hi"), assistant("hello")]))
    }
  }

  @Test func instructionsEntryCarriesToolDefinitionsAndIsOmittedWhenThereIsNothing() throws {
    #expect(TranscriptRenderer.instructionsEntry("", tools: []) == nil)
    let entry = try #require(TranscriptRenderer.instructionsEntry("Be brief.", tools: []))
    guard case .instructions(let instructions) = entry else { return }
    #expect(text(instructions.segments) == "Be brief.")
  }
}
