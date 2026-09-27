import Foundation
import FoundationModels
import LocalAgentKitCore

/// Collects the calls the model asked for.
actor CallRecorder {
  private var calls: [ToolCall] = []
  private var counter = 0

  func record(name: String, argumentsJSON: String) {
    counter += 1
    let arguments: ToolArguments
    if let data = argumentsJSON.data(using: .utf8),
      case .object(let values)? = try? JSONDecoder().decode(JSONValue.self, from: data)
    {
      arguments = ToolArguments(values)
    } else {
      arguments = ToolArguments()
    }
    calls.append(
      ToolCall(id: "fm-\(UUID().uuidString.prefix(8))-\(counter)", name: name, arguments: arguments)
    )
  }

  var recorded: [ToolCall] { calls }
}

/// Thrown by ``CapturingTool`` to end the framework's own tool loop.
struct HandBack: Error {}

/// A tool the model can see and call, that **records the call and throws instead of running**.
///
/// The framework would otherwise run the whole tool loop inside one `respond()`. LocalAgentKit
/// needs the call back so the runtime can validate it, put it through the permission gate, and
/// execute it (PRD §19). The framework wraps a tool's thrown error in
/// `LanguageModelSession.ToolCallError`, so throwing ends the loop and the call is handed back.
/// Verified on macOS 26.6.2: the call is captured with well-formed arguments and the session is
/// still usable afterwards, though a session is never reused (findings §9a).
struct CapturingTool: Tool {
  let name: String
  let description: String
  let parameters: GenerationSchema
  let recorder: CallRecorder

  init(_ descriptor: ToolDescriptor, schema: GenerationSchema, recorder: CallRecorder) {
    self.name = descriptor.name
    self.description = descriptor.description
    self.parameters = schema
    self.recorder = recorder
  }

  func call(arguments: GeneratedContent) async throws -> String {
    await recorder.record(name: name, argumentsJSON: arguments.jsonString)
    throw HandBack()
  }
}
