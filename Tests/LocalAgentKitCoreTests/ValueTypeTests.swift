import Foundation
import Testing

@testable import LocalAgentKitCore

@Suite struct JSONValueTests {
  @Test func roundTripsEveryCase() throws {
    let value: JSONValue = [
      "s": "text", "i": 3, "d": 1.5, "b": true, "n": nil, "a": [1, "two"], "o": ["k": "v"],
    ]
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
  }

  @Test func integersStayIntegers() throws {
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("3".utf8))
    #expect(decoded == .int(3))
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data("3.5".utf8)) == .double(3.5))
  }
}

@Suite struct ToolArgumentsTests {
  @Test func typedAccessors() {
    let args = ToolArguments(["s": "x", "i": 2, "d": 1.5, "b": true, "whole": .double(4)])
    #expect(args.string("s") == "x")
    #expect(args.int("i") == 2)
    #expect(args.int("whole") == 4)
    #expect(args.int("d") == nil)
    #expect(args.double("i") == 2)
    #expect(args.bool("b") == true)
    #expect(args.string("i") == nil)
    #expect(args["missing"] == nil)
  }

  @Test func signatureIgnoresKeyOrderAndNumberSpelling() {
    let a = ToolArguments(["x": 1, "y": "z"])
    let b = ToolArguments(["y": "z", "x": .double(1)])
    #expect(a.signature == b.signature)
    #expect(a.signature != ToolArguments(["x": 2, "y": "z"]).signature)
  }
}

@Suite struct PermissionTests {
  @Test func nothingAboveReadOnlyRunsUnconfirmed() {
    #expect(!ToolPermission.none.requiresConfirmation)
    #expect(!ToolPermission.readOnly.requiresConfirmation)
    #expect(ToolPermission.userConfirmation.requiresConfirmation)
    #expect(ToolPermission.sensitive.requiresConfirmation)
    #expect(ToolPermission.destructive.requiresConfirmation)
  }

  @Test func tiersAreOrdered() {
    #expect(ToolPermission.allCases.sorted() == ToolPermission.allCases)
    #expect(ToolPermission.destructive > .sensitive)
  }
}

@Suite struct ConfigurationTests {
  struct StubModel: LocalModelProvider {
    func generate(request: ModelRequest) async throws -> ModelResponse { .text("ok") }
  }

  struct Echo: AgentTool {
    let name = "echo_text"
    let description = "Echo"
    let schema = ToolSchema.empty
    let permission = ToolPermission.none
    let isParallelSafe = true
    let isCancellable = false
    func execute(arguments: ToolArguments) async throws -> ToolResult {
      ToolResult(callID: "1", toolName: name, text: "")
    }
  }

  @Test func defaultsAreOfflineAndDeterministic() {
    let configuration = AgentConfiguration(model: StubModel())
    #expect(configuration.networkPolicy == .never)
    #expect(configuration.planner == .stateMachine)
    #expect(configuration.security.auditSensitiveExecutions)
    #expect(configuration.limits == .default)
  }

  @Test func providerDefaultsAreOnDevice() async {
    let model = StubModel()
    #expect(!model.requiresNetwork)
    #expect(model.contextWindowTokens == nil)
    #expect(await model.tokenCount(for: ModelRequest(messages: [])) == nil)
  }

  @Test func defaultLimitsAreValid() {
    #expect(ExecutionLimits.default.issue == nil)
  }

  @Test func eachLimitIsValidated() {
    #expect(ExecutionLimits(maxIterations: 0).issue != nil)
    #expect(ExecutionLimits(maxToolCalls: -1).issue != nil)
    #expect(ExecutionLimits(maxDuration: .zero).issue != nil)
    #expect(ExecutionLimits(maxModelCallDuration: .seconds(-1)).issue != nil)
    #expect(ExecutionLimits(maxContextTokens: 0).issue != nil)
    #expect(ExecutionLimits(maxToolCalls: 0).issue == nil)
  }

  @Test func utilizationFraction() {
    #expect(ContextUtilization(usedTokens: 1024, limitTokens: 4096).fraction == 0.25)
    #expect(ContextUtilization(usedTokens: 5, limitTokens: 0).fraction == 0)
  }

  @Test func descriptorMirrorsTool() {
    let descriptor = ToolDescriptor(Echo())
    #expect(descriptor.name == "echo_text")
    #expect(descriptor.isParallelSafe)
    #expect(!descriptor.isCancellable)
  }

  @Test func errorsAreDistinguishable() {
    #expect(AgentError.maximumIterationsReached(limit: 3) != .maximumToolCallsReached(limit: 3))
    #expect(AgentError.executionTimeout(.run) != .executionTimeout(.modelCall))
    #expect(AgentError.guardrailRefusal(GuardrailRefusal()) != AgentError.contextLimitExceeded)
  }

  /// `String(describing:)` — what `AgentViewModel.lastFailure` actually calls — must read as a
  /// sentence a person can be shown, not a Swift enum dump like `loopDetected(tool: "x")`. Found
  /// by testing the demo app for real: a loop-detector trip surfaced exactly that raw dump.
  @Test func everyCaseDescribesItselfAsASentenceNotAnEnumDump() {
    #expect(
      String(describing: AgentError.loopDetected(tool: "search_documents"))
        == "\"search_documents\" was called repeatedly without making progress, so the request "
        + "was stopped.")
    #expect(!String(describing: AgentError.loopDetected(tool: "x")).contains("loopDetected"))
    #expect(
      String(describing: AgentError.contextLimitExceeded)
        == "The conversation grew too large for the model's context window.")
    #expect(
      String(describing: AgentError.deviceAuthorizationDenied(.calendar))
        == "Access to Calendar was not authorized. Check Settings to grant access.")
    let refusalWithExplanation = AgentError.guardrailRefusal(
      GuardrailRefusal(explanation: "that touches medical advice"))
    #expect(String(describing: refusalWithExplanation) == "that touches medical advice")
    #expect(
      !String(describing: AgentError.guardrailRefusal(GuardrailRefusal())).isEmpty)
  }
}
