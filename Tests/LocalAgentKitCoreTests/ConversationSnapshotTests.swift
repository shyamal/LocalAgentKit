import Foundation
import LocalAgentKitCore
import Testing

@Suite struct ConversationSnapshotTests {
  @Test func completePairsAndAnOptionalSummaryAreValid() throws {
    let id = UUID()
    try ConversationSnapshot(conversationID: id, messages: []).validate()
    try ConversationSnapshot(
      conversationID: id,
      messages: [
        ModelMessage(role: .system, content: "Earlier context"),
        ModelMessage(role: .user, content: "Question"),
        ModelMessage(role: .assistant, content: "Answer"),
      ]
    ).validate()
  }

  @Test(arguments: [
    [ModelMessage(role: .user, content: "Partial")],
    [
      ModelMessage(role: .assistant, content: "Wrong order"),
      ModelMessage(role: .user, content: "Question"),
    ],
    [
      ModelMessage(role: .user, content: "Question"),
      ModelMessage(role: .system, content: "Misplaced instructions"),
    ],
    [ModelMessage(role: .tool, content: "Result")],
    [
      ModelMessage(role: .user, content: "Question"),
      ModelMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "1", name: "tool")]),
    ],
  ])
  func incompleteOrToolTranscriptsAreRejected(messages: [ModelMessage]) {
    #expect(
      throws: AgentError.memoryFailure("Conversation checkpoint must contain completed text turns.")
    ) {
      try ConversationSnapshot(conversationID: UUID(), messages: messages).validate()
    }
  }
}
