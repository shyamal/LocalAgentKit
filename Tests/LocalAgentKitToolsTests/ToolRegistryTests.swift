import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitTools

@Suite struct ToolRegistryTests {
  private func tool(_ name: String) -> MockTool { MockTool(name: name) }

  @Test func registerThenLookUp() async {
    let registry = ToolRegistry()
    #expect(await registry.register(tool("get_time")))
    let found = await registry.tool(named: "get_time")
    #expect(found?.name == "get_time")
    #expect(await registry.tool(named: "missing") == nil)
  }

  @Test func reregisteringTheSameNameReplacesAndReportsNotNew() async {
    let registry = ToolRegistry()
    let first = tool("get_time")
    let second = MockTool(name: "get_time", permission: .destructive)
    #expect(await registry.register(first))
    #expect(await registry.register(second) == false)
    #expect(await registry.tool(named: "get_time")?.permission == .destructive)
    #expect(await registry.count == 1)
  }

  @Test func unregisterRemovesIt() async {
    let registry = ToolRegistry()
    _ = await registry.register(tool("get_time"))
    #expect(await registry.unregister(name: "get_time"))
    #expect(await registry.unregister(name: "get_time") == false)
    #expect(await registry.tool(named: "get_time") == nil)
    #expect(await registry.count == 0)
  }

  @Test func descriptorsAreStableInRegistrationOrder() async {
    let registry = ToolRegistry()
    for name in ["c", "a", "b"] { _ = await registry.register(tool(name)) }
    #expect(await registry.descriptors().map(\.name) == ["c", "a", "b"])
    #expect(await registry.names == ["c", "a", "b"])
  }

  @Test func batchInitializerRegistersEachOnce() async {
    let registry = ToolRegistry([tool("a"), tool("b"), tool("a")])
    #expect(await registry.count == 2)
    #expect(await registry.names == ["a", "b"])
  }

  @Test func descriptorsCarryFullMetadata() async {
    let registry = ToolRegistry()
    let mock = MockTool(
      name: "delete_file",
      schema: ToolSchema(
        parameters: ["path": ToolParameter(.string, description: "Path")], required: ["path"]),
      permission: .destructive, isParallelSafe: false, isCancellable: false)
    _ = await registry.register(mock)
    let descriptor = try! #require(await registry.descriptors().first)
    #expect(descriptor.permission == .destructive)
    #expect(descriptor.schema.required == ["path"])
    #expect(!descriptor.isParallelSafe)
    #expect(!descriptor.isCancellable)
  }
}

@Suite struct ToolPromptFormatterTests {
  @Test func listsAlphabeticallyWithRequiredAndOptionalMarkers() {
    let descriptors = [
      ToolDescriptor(
        name: "search_notes", description: "Search notes",
        schema: ToolSchema(
          parameters: [
            "query": ToolParameter(.string, description: "q"),
            "limit": ToolParameter(.integer, description: "n"),
          ], required: ["query"]),
        permission: .readOnly, isParallelSafe: true, isCancellable: true),
      ToolDescriptor(
        name: "calculate", description: "Math", schema: .empty, permission: .none,
        isParallelSafe: true, isCancellable: true),
    ]
    let listing = ToolPromptFormatter.listing(descriptors)
    let lines = listing.split(separator: "\n").map(String.init)
    #expect(lines[0] == "- calculate: Math")
    #expect(lines[1] == "- search_notes: Search notes (limit?, query)")
  }

  @Test func emptyListingIsAnEmptyString() {
    #expect(ToolPromptFormatter.listing([]).isEmpty)
  }
}
