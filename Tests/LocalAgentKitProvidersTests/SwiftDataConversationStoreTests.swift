import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import SwiftData
import Testing

@testable import LocalAgentKitProviders

@Suite struct SwiftDataConversationStoreTests {
  @Test(arguments: [false, true])
  func storesIsolateReplaceAndDeleteWholeConversations(useMock: Bool) async throws {
    let store: any ConversationStore
    if useMock {
      store = MockConversationStore()
    } else {
      store = try SwiftDataConversationStore(storage: .inMemory)
    }
    let a = UUID()
    let b = UUID()
    let first = snapshot(a, answer: "Budget review — 準備 📝")
    let second = snapshot(b, answer: "Other session")
    #expect(try await store.load(conversationID: a) == nil)
    try await store.save(first)
    try await store.save(second)
    #expect(try await store.load(conversationID: a) == first)
    let replacement = snapshot(a, answer: "Updated")
    try await store.save(replacement)
    #expect(try await store.load(conversationID: a) == replacement)
    #expect(try await store.load(conversationID: b) == second)
    try await store.delete(conversationID: a)
    try await store.delete(conversationID: a)
    #expect(try await store.load(conversationID: a) == nil)
    #expect(try await store.load(conversationID: b) == second)
  }

  @Test func completedConversationRestoresAfterDiskStoreReopens() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("nested/conversations.store")
    let original = snapshot(UUID(), answer: "Full checklist\nline two")
    try await write(original, to: url)
    let store = try SwiftDataConversationStore(storage: .file(url))
    #expect(try await store.load(conversationID: original.conversationID) == original)
  }

  @Test func invalidReplacementDoesNotDestroyTheCommittedCheckpoint() async throws {
    let store = try SwiftDataConversationStore(storage: .inMemory)
    let original = snapshot(UUID(), answer: "Keep this")
    try await store.save(original)
    let invalid = ConversationSnapshot(
      conversationID: original.conversationID,
      messages: [ModelMessage(role: .user, content: "Partial")])
    await #expect(
      throws: AgentError.memoryFailure("Conversation checkpoint must contain completed text turns.")
    ) {
      try await store.save(invalid)
    }
    #expect(try await store.load(conversationID: original.conversationID) == original)
  }

  @Test(arguments: ["load", "save", "delete"])
  func cancelledOperationsLeaveSavedConversationsIntact(operation: String) async throws {
    let store = try SwiftDataConversationStore(storage: .inMemory)
    let original = snapshot(UUID(), answer: "Keep this")
    try await store.save(original)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await #expect(throws: AgentError.cancelled) {
        switch operation {
        case "save":
          try await store.save(
            ConversationSnapshot(conversationID: original.conversationID, messages: []))
        case "delete": try await store.delete(conversationID: original.conversationID)
        default: _ = try await store.load(conversationID: original.conversationID)
        }
      }
    }
    await task.value
    #expect(try await store.load(conversationID: original.conversationID) == original)
  }

  @MainActor @Test(arguments: ["invalid-json", "version", "identity", "role"])
  func corruptOrUnknownPayloadsFailInsteadOfStartingEmpty(kind: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("conversations.store")
    let id = UUID()
    let payload: Data
    if kind == "invalid-json" {
      payload = Data("invalid".utf8)
    } else {
      payload = try JSONSerialization.data(withJSONObject: [
        "version": kind == "version" ? 99 : 1,
        "conversationID": (kind == "identity" ? UUID() : id).uuidString,
        "entries": kind == "role" ? [["role": "tool", "content": "Unsafe tool transcript"]] : [],
      ])
    }
    do {
      let schema = Schema(versionedSchema: ConversationSchemaV1.self)
      let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
      let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))
      context.autosaveEnabled = false
      context.insert(ConversationSchemaV1.StoredConversation(id: id, payload: payload))
      try context.save()
    }
    let store = try SwiftDataConversationStore(storage: .file(url))
    do {
      _ = try await store.load(conversationID: id)
      Issue.record("Expected a typed memory failure")
    } catch let error as AgentError {
      guard case .memoryFailure = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  private func snapshot(_ id: UUID, answer: String) -> ConversationSnapshot {
    ConversationSnapshot(
      conversationID: id,
      messages: [
        ModelMessage(role: .system, content: "Earlier conversation summary"),
        ModelMessage(role: .user, content: "My meeting?"),
        ModelMessage(role: .assistant, content: answer),
      ])
  }
  private func write(_ snapshot: ConversationSnapshot, to url: URL) async throws {
    let store = try SwiftDataConversationStore(storage: .file(url))
    try await store.save(snapshot)
  }
}
