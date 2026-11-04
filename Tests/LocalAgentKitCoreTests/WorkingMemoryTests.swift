import LocalAgentKitCore
import Testing

@Suite struct WorkingMemoryValueTests {
  @Test func orderedReplacementRemovalAndCopiesStayConsistent() {
    var memory = WorkingMemory()
    memory.set(.string("first"), forKey: "a", isEmpty: true)
    memory.set(.int(2), forKey: "b")
    memory.set(.string("updated"), forKey: "a")
    #expect(memory.orderedKeys == ["a", "b"])
    #expect(memory.emptyKeys.isEmpty)
    var copy = memory
    copy.removeValue(forKey: "a")
    copy.set(.bool(true), forKey: "a")
    #expect(copy.orderedKeys == ["b", "a"])
    #expect(memory.value(for: "a") == .string("updated"))
    copy.removeAll()
    #expect(copy.values.isEmpty && copy.orderedKeys.isEmpty && copy.emptyKeys.isEmpty)
    #expect(memory.values.count == 2)
  }

  @Test func nestedLookupsRejectMissingOrInvalidPaths() {
    var memory = WorkingMemory()
    memory.set(.array([.object(["title": .string("Budget review")])]), forKey: "meetings")
    #expect(memory.value(for: "meetings.0.title") == .string("Budget review"))
    for path in [
      "", "missing", "meetings.-1", "meetings.5", "meetings.no", "meetings.0.missing",
      "meetings.0.title.child",
    ] {
      #expect(memory.value(for: path) == nil)
    }
  }

  @Test func emptyMarkersDoNotConfuseFalseZeroOrNestedFacts() {
    var memory = WorkingMemory()
    for (key, value) in [
      "null": JSONValue.null, "text": .string("  "), "array": .array([]), "object": .object([:]),
    ] {
      memory.set(value, forKey: key)
      #expect(memory.isEmpty(key))
    }
    memory.set(.bool(false), forKey: "false")
    memory.set(.int(0), forKey: "zero")
    #expect(!memory.isEmpty("false") && !memory.isEmpty("zero"))
    memory.set(.object(["reason": .string("No matches")]), forKey: "search", isEmpty: true)
    #expect(memory.isEmpty("search"))
    #expect(!memory.isEmpty("search.reason"))
    #expect(memory.isEmpty("missing"))
    memory.removeValue(forKey: "search")
    #expect(!memory.emptyKeys.contains("search"))
  }
}
