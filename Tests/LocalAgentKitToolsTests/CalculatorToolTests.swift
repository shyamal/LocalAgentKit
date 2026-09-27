import LocalAgentKitCore
import Testing

@testable import LocalAgentKitTools

@Suite struct CalculatorToolTests {
  private let tool = CalculatorTool()

  @Test func propertiesMatchFR008() {
    #expect(tool.name == "calculate")
    #expect(tool.permission == .none)
    #expect(tool.schema.required == ["expression"])
  }

  @Test func evaluatesAndReturnsStructuredResult() async throws {
    let result = try await tool.execute(arguments: ToolArguments(["expression": "2 + 3 * 4"]))
    #expect(result.text == "14")
    #expect(result.structured == .double(14))
    #expect(!result.isEmpty)
  }

  @Test func nonIntegerResultsAreFormattedAsDecimals() async throws {
    let result = try await tool.execute(arguments: ToolArguments(["expression": "9 / 2"]))
    #expect(result.text == "4.5")
  }

  @Test func missingExpressionIsInvalidArguments() async {
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "calculate", violations: [.missingRequired(path: "expression")])
    ) {
      try await self.tool.execute(arguments: ToolArguments())
    }
  }

  @Test func unevaluableExpressionIsAnEmptyResultNotAThrow() async throws {
    let result = try await tool.execute(arguments: ToolArguments(["expression": "not math"]))
    #expect(result.isEmpty)
    #expect(result.text.contains("not math"))
  }
}
