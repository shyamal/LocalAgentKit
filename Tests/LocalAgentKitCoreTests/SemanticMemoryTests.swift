import Foundation
import Testing

@testable import LocalAgentKitCore

@Suite struct SemanticMemoryTests {
  @Test(arguments: SemanticMemory.Kind.allCases)
  func versionedRoundTripPreservesIdentityAndAppMetadata(kind: SemanticMemory.Kind) throws {
    let original = SemanticMemory(
      kind: kind, content: "Use concise answers", metadata: ["source": "settings"])
    let record = try original.memory()
    #expect(record.id == original.id)
    #expect(record.createdAt == original.createdAt)
    #expect(record.metadata[SemanticMemory.categoryKey] == "semantic")
    #expect(record.metadata[SemanticMemory.kindKey] == kind.rawValue)
    #expect(try SemanticMemory(memory: record) == original)
    #expect(try JSONDecoder().decode(Memory.self, from: JSONEncoder().encode(record)) == record)
  }

  @Test(arguments: ["", " \n\t "])
  func blankStatementsCannotBeEncodedOrDecoded(content: String) throws {
    let value = SemanticMemory(kind: .fact, content: content)
    #expect(throws: AgentError.memoryFailure("Semantic memory content must not be blank.")) {
      try value.memory()
    }
    var record = try SemanticMemory(kind: .fact, content: "Valid").memory()
    record.content = content
    #expect(throws: AgentError.memoryFailure("Semantic memory content must not be blank.")) {
      try SemanticMemory(memory: record)
    }
  }

  @Test(arguments: [SemanticMemory.categoryKey, SemanticMemory.kindKey, SemanticMemory.versionKey])
  func reservedKeysCannotBeOverridden(key: String) {
    let value = SemanticMemory(kind: .fact, content: "Valid", metadata: [key: "spoofed"])
    #expect(throws: AgentError.memoryFailure("Semantic memory metadata uses a reserved key.")) {
      try value.memory()
    }
  }

  @Test(arguments: ["category", "kind", "version", "missing"])
  func invalidEnvelopesAreTypedFailures(field: String) throws {
    var record = try SemanticMemory(kind: .fact, content: "Valid").memory()
    switch field {
    case "category": record.metadata[SemanticMemory.categoryKey] = "episodic"
    case "kind": record.metadata[SemanticMemory.kindKey] = "unknown"
    case "version": record.metadata[SemanticMemory.versionKey] = "2"
    default: record.metadata.removeValue(forKey: SemanticMemory.versionKey)
    }
    #expect(throws: AgentError.memoryFailure("Invalid or unsupported semantic memory record.")) {
      try SemanticMemory(memory: record)
    }
  }
}
