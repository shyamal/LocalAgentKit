import LocalAgentKitCore
import Testing

@testable import LocalAgentKitProviders

@Suite struct StreamingTextAccumulatorTests {
  @Test func cumulativeSnapshotsBecomeOnlyNewFragments() throws {
    var text = StreamingTextAccumulator()
    #expect(try text.append("") == "")
    #expect(try text.append("Hel") == "Hel")
    #expect(try text.append("Hel") == "")
    #expect(try text.append("Hello") == "lo")
    #expect(text.text == "Hello")
  }

  @Test func fragmentsCanExtendUnicodeGraphemes() throws {
    var text = StreamingTextAccumulator()
    let first = try text.append("e")
    let accent = try text.append("e\u{301}")
    let emoji = try text.append("e\u{301} 👩")
    let family = try text.append("e\u{301} 👩‍👩‍👧‍👦")
    #expect(first + accent + emoji + family == text.text)
  }

  @Test func revisionsAreTypedErrors() throws {
    var text = StreamingTextAccumulator()
    _ = try text.append("Hello")
    #expect(throws: AgentError.self) { try text.append("Hallo") }
    #expect(text.text == "Hello")
  }
}
