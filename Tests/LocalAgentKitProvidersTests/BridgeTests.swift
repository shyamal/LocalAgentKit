import Foundation
import FoundationModels
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitProviders

private func descriptor(_ schema: ToolSchema, name: String = "create_reminder") -> ToolDescriptor {
  ToolDescriptor(
    name: name, description: "Creates a reminder.", schema: schema, permission: .userConfirmation,
    isParallelSafe: false, isCancellable: true)
}

@Suite struct SchemaBridgeTests {
  private let everything = ToolSchema(
    parameters: [
      "title": ToolParameter(.string, description: "Title"),
      "count": ToolParameter(.integer, description: "Count", minimum: 1, maximum: 10),
      "ratio": ToolParameter(.number, description: "Ratio", minimum: 0),
      "urgent": ToolParameter(.boolean, description: "Urgent"),
      "unit": ToolParameter(.string, description: "Unit", allowedValues: ["km", "mi"]),
      "tags": ToolParameter(.array(of: .string), description: "Tags"),
      "when": ToolParameter(
        .object(
          ToolSchema(
            parameters: ["day": ToolParameter(.string, description: "Day")], required: ["day"])),
        description: "When"),
    ],
    required: ["title"])

  @Test func everyParameterTypeBecomesAValidGenerationSchema() throws {
    for policy in [OptionalArgumentPolicy.asDeclared, .requireAll, .automatic] {
      _ = try SchemaBridge(optionalPolicy: policy).generationSchema(for: descriptor(everything))
    }
  }

  @Test func aToolWithNoParametersIsFine() throws {
    _ = try SchemaBridge().generationSchema(for: descriptor(.empty, name: "get_time"))
  }

  @Test func theOptionalPolicyResolvesPerOSVersion() {
    #expect(OptionalArgumentPolicy.asDeclared.presentsOptionalAsRequired == false)
    #expect(OptionalArgumentPolicy.requireAll.presentsOptionalAsRequired == true)
    // On this host (macOS 26) automatic must present optional arguments as required.
    if #unavailable(macOS 27, iOS 27) {
      #expect(OptionalArgumentPolicy.automatic.presentsOptionalAsRequired)
    }
  }

  @Test func optionalnessChangesTheSchemaTheModelSees() throws {
    let asDeclared = try SchemaBridge(optionalPolicy: .asDeclared)
      .generationSchema(for: descriptor(everything))
    let required = try SchemaBridge(optionalPolicy: .requireAll)
      .generationSchema(for: descriptor(everything))
    #expect(String(describing: asDeclared) != String(describing: required))
  }
}

@Suite struct CallRecorderTests {
  @Test func recordsArgumentsAsTypedValues() async {
    let recorder = CallRecorder()
    await recorder.record(
      name: "create_reminder",
      argumentsJSON: #"{"title": "Call", "count": 3, "ratio": 1.5, "urgent": true}"#)
    let call = await recorder.recorded[0]
    #expect(call.name == "create_reminder")
    #expect(call.arguments.string("title") == "Call")
    #expect(call.arguments.int("count") == 3)
    #expect(call.arguments.double("ratio") == 1.5)
    #expect(call.arguments.bool("urgent") == true)
  }

  @Test func eachCallGetsADistinctID() async {
    let recorder = CallRecorder()
    await recorder.record(name: "a", argumentsJSON: "{}")
    await recorder.record(name: "a", argumentsJSON: "{}")
    let ids = await recorder.recorded.map(\.id)
    #expect(Set(ids).count == 2)
  }

  @Test func unparseableArgumentsBecomeEmptyOnesForTheRuntimeToRepair() async {
    let recorder = CallRecorder()
    await recorder.record(name: "a", argumentsJSON: "not json")
    await recorder.record(name: "b", argumentsJSON: "[1, 2]")
    let calls = await recorder.recorded
    #expect(calls.count == 2)
    #expect(calls.allSatisfy { $0.arguments.values.isEmpty })
  }
}

@Suite struct OptionalArgumentCleanupTests {
  private let tool = descriptor(
    ToolSchema(
      parameters: [
        "title": ToolParameter(.string, description: "Title"),
        "due": ToolParameter(.string, description: "Due"),
      ], required: ["title"]))

  @Test func anEmptyOptionalArgumentIsDroppedWhenItWasPresentedAsRequired() {
    let provider = FoundationModelProvider(optionalArguments: .requireAll)
    let call = ToolCall(
      id: "1", name: "create_reminder", arguments: ToolArguments(["title": "Call", "due": ""]))
    let response = provider.modelResponse(for: [call], tools: [tool])
    guard case .toolCall(let cleaned) = response else {
      Issue.record("expected a single call")
      return
    }
    #expect(cleaned.arguments.values == ["title": "Call"])
  }

  @Test func aFilledOptionalArgumentIsKept() {
    let provider = FoundationModelProvider(optionalArguments: .requireAll)
    let call = ToolCall(
      id: "1", name: "create_reminder",
      arguments: ToolArguments(["title": "Call", "due": "2026-09-22T09:00"]))
    guard case .toolCall(let kept) = provider.modelResponse(for: [call], tools: [tool]) else {
      return
    }
    #expect(kept.arguments.string("due") == "2026-09-22T09:00")
  }

  @Test func argumentsDeclaredOptionalAreLeftAlone() {
    let provider = FoundationModelProvider(optionalArguments: .asDeclared)
    let call = ToolCall(
      id: "1", name: "create_reminder", arguments: ToolArguments(["title": "Call", "due": ""]))
    guard case .toolCall(let kept) = provider.modelResponse(for: [call], tools: [tool]) else {
      return
    }
    #expect(kept.arguments.values["due"] == "")
  }

  @Test func severalCallsComeBackAsMultipleToolCalls() {
    let provider = FoundationModelProvider()
    let calls = [ToolCall(id: "1", name: "a"), ToolCall(id: "2", name: "b")]
    guard case .multipleToolCalls(let all) = provider.modelResponse(for: calls, tools: []) else {
      Issue.record("expected multiple calls")
      return
    }
    #expect(all.map(\.id) == ["1", "2"])
  }
}

@Suite struct ErrorMappingTests {
  @Test func agentErrorsAndCancellationPassThrough() async {
    #expect(
      await FoundationModelErrors.map(AgentError.contextLimitExceeded).error
        == .contextLimitExceeded)
    #expect(await FoundationModelErrors.map(CancellationError()).error == .cancelled)
  }

  /// Findings §11b/§14: overflow is sometimes reported as an untyped error, not the typed case.
  @Test func anUntypedTokenGenerationFailureIsTheContextError() async {
    let underlying = NSError(
      domain: "ModelManagerServices.ModelManagerError", code: 10,
      userInfo: [NSLocalizedDescriptionKey: "tokengeneration failed"])
    let error = NSError(
      domain: "FoundationModels.LanguageModelSession.GenerationError", code: -1,
      userInfo: [NSUnderlyingErrorKey: underlying])
    let mapped = await FoundationModelErrors.map(error)
    #expect(mapped.error == .contextLimitExceeded)
    #expect(!mapped.isRetryable)
  }

  /// Found by testing, not from findings: running the real model in iOS Simulator (where
  /// on-device generation is not supported at all) throws this exact shape. Its code is 5000,
  /// not 10, so it must not be classified as context overflow — this is the failure the loose
  /// substring match used to misclassify, since "tokengeneration" is also this error's logging
  /// *subsystem name*, not anything about its actual domain or code.
  @Test func aSimulatorNotSupportedErrorIsNotMisreadAsContextOverflow() async {
    let error = NSError(
      domain: "com.apple.UnifiedAssetFramework", code: 5000,
      userInfo: [
        NSLocalizedFailureReasonErrorKey:
          "There are no underlying assets (neither atomic instance nor asset roots) for "
          + "consistency token for asset set com.apple.modelcatalog"
      ])
    let mapped = await FoundationModelErrors.map(error)
    #expect(mapped.error != .contextLimitExceeded)
    guard case .modelUnavailable(let reason) = mapped.error else {
      Issue.record("expected modelUnavailable, got \(mapped.error)")
      return
    }
    #expect(reason?.contains("modelcatalog") == true)
  }

  @Test func anUnknownErrorIsAModelUnavailableErrorNotACrash() async {
    struct Odd: Error {}
    let mapped = await FoundationModelErrors.map(Odd())
    guard case .modelUnavailable = mapped.error else {
      Issue.record("expected modelUnavailable")
      return
    }
    #expect(!mapped.isRetryable)
  }
}
