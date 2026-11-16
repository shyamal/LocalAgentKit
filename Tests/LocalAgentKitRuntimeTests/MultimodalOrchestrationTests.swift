import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private actor InputApproval: PermissionGate {
  let approved: Bool
  var calls: [ToolCall] = []
  init(approved: Bool) { self.approved = approved }
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    calls.append(call)
    return approved ? .approved : .denied
  }
}

private func inputWorkflow(_ source: ArgumentSource) -> Workflow {
  Workflow(
    name: "capture", description: "Use captured source",
    steps: [
      .tool("save", "Save captured text", "save", ["text": source])
    ])
}

private func inputTool(_ type: ToolParameterType = .string) -> MockTool {
  MockTool(
    name: "save",
    schema: ToolSchema(
      parameters: [
        "text": ToolParameter(type, description: "Captured content")
      ], required: ["text"]), permission: .userConfirmation)
}

@Suite struct MultimodalOrchestrationTests {
  static let box = VisionBoundingBox(x: 0, y: 0, width: 1, height: 1)

  @Test(arguments: [true, false])
  func capturedImageReachesOnlyTheApprovedTool(approved: Bool) async throws {
    let vision = MockVisionProvider { _ in
      VisionResult(recognizedText: [
        .init(text: "Invoice 42", confidence: 0.9, boundingBox: Self.box)
      ])
    }
    let model = ScriptedModelProvider(responses: [])
    let tool = inputTool()
    let gate = InputApproval(approved: approved)
    let memory = ConversationMemory()
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model, vision: vision),
      tools: StaticToolSource([tool]),
      planner: StateMachinePlanner(
        workflow: inputWorkflow(.input(attachment: 0, path: "recognizedText.0.text"))),
      gate: gate, memory: memory)
    let input = AgentInput(
      text: "Record this captured image", attachments: [.image(ImageInput(data: Data([42])))])
    if approved {
      _ = try await runtime.run(input)
    } else {
      do {
        _ = try await runtime.run(input)
        Issue.record("Expected denied tool")
      } catch let error as AgentError { #expect(error == .permissionDenied(tool: "save")) }
    }
    #expect(await vision.inputs.count == 1)
    #expect(await gate.calls.first?.arguments.string("text") == "Invoice 42")
    #expect(await tool.executions.count == (approved ? 1 : 0))
    #expect(await model.requests.isEmpty)
    #expect(await runtime.workingMemory().values["input"] == nil)
    #expect(await memory.history().allSatisfy { !$0.content.contains("Invoice 42") })
  }

  @Test func combinedInputsPreserveIndexTypeAndPathsForWorkflowArguments() async throws {
    let captured = MockVisionProvider { _ in
      VisionResult(documents: [
        .init(
          text: "receipt", title: "Store", paragraphs: ["item"],
          tables: [
            .init(
              rowCount: 1, columnCount: 1,
              cells: [
                .init(text: "12.50", rowRange: 0...0, columnRange: 0...0, boundingBox: Self.box)
              ], boundingBox: Self.box)
          ], confidence: 0.8, boundingBox: Self.box)
      ])
    }
    let tool = MockTool(
      name: "save",
      schema: ToolSchema(
        parameters: [
          "audio": ToolParameter(.string, description: "transcript"),
          "cell": ToolParameter(.string, description: "cell"),
          "row": ToolParameter(.integer, description: "row"),
          "document": ToolParameter(.string, description: "text"),
        ], required: ["audio", "cell", "row", "document"]), permission: .userConfirmation)
    let model = ScriptedModelProvider(responses: [])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(
        model: model, vision: captured,
        speechRecognizer: MockSpeechRecognizer { _ in "memo" }), tools: StaticToolSource([tool]),
      planner: StateMachinePlanner(
        workflow: Workflow(
          name: "combined", description: "combined",
          steps: [
            .tool(
              "save", "Save", "save",
              [
                "audio": .input(attachment: 0, path: "text"),
                "cell": .input(attachment: 1, path: "documents.0.tables.0.cells.0.text"),
                "row": .input(attachment: 1, path: "documents.0.tables.0.cells.0.rowStart"),
                "document": .input(attachment: 2, path: "text"),
              ])
          ])), gate: InputApproval(approved: true))
    _ = try await runtime.run(
      AgentInput(attachments: [
        .audio(AudioInput(data: Data([1]))), .image(ImageInput(data: Data([2]))),
        .document(Document(title: "Report", text: "report text")),
      ]))
    #expect(
      await tool.executions == [
        ToolArguments([
          "audio": "memo", "cell": "12.50", "row": 0, "document": "report text",
        ])
      ])
    #expect(await model.requests.isEmpty)
  }

  @Test(arguments: ["missing", "recognizedText.4.text", "recognizedText..text"])
  func missingAndMalformedPathsNeverAskTheModelForReplacement(path: String) async throws {
    let tool = inputTool()
    let model = MockModelProvider()
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([tool]),
      planner: StateMachinePlanner(workflow: inputWorkflow(.input(attachment: 0, path: path))))
    do {
      _ = try await runtime.run(
        AgentInput(attachments: [.document(Document(title: "", text: "source"))]))
      Issue.record("Expected invalid source")
    } catch is AgentError {}
    #expect(await model.requests.isEmpty)
    #expect(await tool.executions.isEmpty)
  }

  @Test func inputTypeMismatchFailsBeforePermissionOrModelRepair() async throws {
    let model = MockModelProvider()
    let gate = InputApproval(approved: true)
    let tool = inputTool(.number)
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model), tools: StaticToolSource([tool]),
      planner: StateMachinePlanner(workflow: inputWorkflow(.input(attachment: 0, path: "text"))),
      gate: gate)
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "save",
        violations: [
          .typeMismatch(path: "text", expected: "a number")
        ])
    ) {
      try await runtime.run(
        AgentInput(attachments: [.document(Document(title: "", text: "not a number"))]))
    }
    #expect(await gate.calls.isEmpty)
    #expect(await model.requests.isEmpty)
  }

  @Test func structuredBudgetIncludesMetadataThatIsAbsentFromPromptExcerpts() async throws {
    let vision = MockVisionProvider { _ in
      VisionResult(documents: [
        .init(
          text: "short", paragraphs: [String(repeating: "x", count: 1000)], confidence: 1,
          boundingBox: Self.box)
      ])
    }
    let tool = inputTool()
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(
        model: MockModelProvider(), vision: vision,
        inputLimits: AgentInputLimits(maximumStructuredBytes: 200)), tools: StaticToolSource([tool])
    )
    await #expect(throws: AgentError.inputFailure("Attachments exceed the structured byte limit")) {
      try await runtime.run(AgentInput(attachments: [.image(ImageInput(data: Data([1])))]))
    }
    #expect(await tool.executions.isEmpty)
    #expect(AgentInputLimits(maximumStructuredBytes: 0).issue != nil)
  }

  @Test func structuredBudgetAccountsForEscapingAndRejectsNonFiniteMetadata() throws {
    var builder = StructuredInput(maximumBytes: 4)
    #expect(throws: AgentError.inputFailure("Attachments exceed the structured byte limit")) {
      try builder.string("\n\n")
    }
    var numeric = StructuredInput(maximumBytes: 1000)
    #expect(throws: AgentError.inputFailure("Non-finite input metadata")) {
      try numeric.image(VisionResult(classifications: [.init(identifier: "bad", confidence: .nan)]))
    }
  }

  @Test func inputLookupCannotResolveOtherNamespacesOrRuns() async throws {
    let context = AgentContext(goal: "test", inputValues: [["text": "source"]])
    #expect(context.inputValue(attachment: 0) == ["text": "source"])
    #expect(context.inputValue(attachment: -1) == nil)
    #expect(context.inputValue(attachment: 1) == nil)
    #expect(context.inputValue(attachment: 0, path: ".text") == nil)
    #expect(context.inputValue(attachment: 0, path: "text.") == nil)
    #expect(context.value(for: "input.0.text") == nil)
    let tool = inputTool()
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: MockModelProvider()),
      tools: StaticToolSource([tool]),
      planner: StateMachinePlanner(workflow: inputWorkflow(.input(attachment: 0, path: "text"))),
      gate: InputApproval(approved: true))
    _ = try await runtime.run(
      AgentInput(attachments: [.document(Document(title: "", text: "first"))]))
    await #expect(
      throws: AgentError.invalidArguments(
        tool: "save", violations: [.missingRequired(path: "text")])
    ) {
      try await runtime.run("second without attachments")
    }
    #expect(await tool.executions.count == 1)
  }
}
