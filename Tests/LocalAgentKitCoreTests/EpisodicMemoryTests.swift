import Foundation
import Testing

@testable import LocalAgentKitCore

@Suite struct EpisodicMemoryTests {
  @Test(arguments: EpisodicMemory.Kind.allCases)
  func roundTripPreservesBothDatesAndAppMetadata(kind: EpisodicMemory.Kind) throws {
    let episode = EpisodicMemory(
      kind: kind, content: "Prepared the Budget review",
      occurredAt: Date(timeIntervalSinceReferenceDate: 815_222_333.1234567),
      createdAt: Date(timeIntervalSinceReferenceDate: 815_222_999.9876543),
      metadata: ["source": "user"])
    let record = try episode.memory()
    #expect(record.createdAt == episode.createdAt)
    #expect(record.metadata[EpisodicMemory.categoryKey] == "episodic")
    let transported = try JSONDecoder().decode(Memory.self, from: JSONEncoder().encode(record))
    #expect(try EpisodicMemory(memory: transported) == episode)
  }

  @Test(arguments: ["", " \n\t "])
  func blankContentIsRejectedOnEncodeAndDecode(content: String) throws {
    let episode = EpisodicMemory(kind: .event, content: content, occurredAt: Date())
    #expect(throws: AgentError.memoryFailure("Episodic memory content must not be blank.")) {
      try episode.memory()
    }
    var record = try EpisodicMemory(kind: .event, content: "Valid", occurredAt: Date()).memory()
    record.content = content
    #expect(throws: AgentError.memoryFailure("Episodic memory content must not be blank.")) {
      try EpisodicMemory(memory: record)
    }
  }

  @Test(arguments: [
    EpisodicMemory.categoryKey, EpisodicMemory.kindKey,
    EpisodicMemory.versionKey, EpisodicMemory.occurrenceKey,
  ])
  func reservedMetadataCannotBeOverridden(key: String) {
    let episode = EpisodicMemory(
      kind: .action, content: "Saved note", occurredAt: Date(), metadata: [key: "spoofed"])
    #expect(throws: AgentError.memoryFailure("Episodic memory metadata uses a reserved key.")) {
      try episode.memory()
    }
  }

  @Test(arguments: ["category", "kind", "version", "missing", "date", "nan", "infinity"])
  func invalidEnvelopesAreTypedFailures(field: String) throws {
    var record = try EpisodicMemory(kind: .event, content: "Met", occurredAt: Date()).memory()
    switch field {
    case "category": record.metadata[EpisodicMemory.categoryKey] = "semantic"
    case "kind": record.metadata[EpisodicMemory.kindKey] = "unknown"
    case "version": record.metadata[EpisodicMemory.versionKey] = "2"
    case "missing": record.metadata.removeValue(forKey: EpisodicMemory.occurrenceKey)
    case "nan": record.metadata[EpisodicMemory.occurrenceKey] = "nan"
    case "infinity": record.metadata[EpisodicMemory.occurrenceKey] = "inf"
    default: record.metadata[EpisodicMemory.occurrenceKey] = "yesterday"
    }
    #expect(throws: AgentError.memoryFailure("Invalid or unsupported episodic memory record.")) {
      try EpisodicMemory(memory: record)
    }
  }

  @Test(arguments: [false, true])
  func nonFiniteDatesCannotBeStored(creationDate: Bool) throws {
    var episode = EpisodicMemory(kind: .event, content: "Met", occurredAt: Date())
    let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
    if creationDate { episode.createdAt = invalid } else { episode.occurredAt = invalid }
    #expect(throws: AgentError.memoryFailure("Episodic memory dates must be finite.")) {
      try episode.memory()
    }
    var record = try EpisodicMemory(kind: .event, content: "Met", occurredAt: Date()).memory()
    record.createdAt = invalid
    #expect(throws: AgentError.memoryFailure("Episodic memory dates must be finite.")) {
      try EpisodicMemory(memory: record)
    }
  }
}
