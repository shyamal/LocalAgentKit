import LocalAgentKitCore

/// Renders tool descriptors as prose (M1-TL-02): a stable listing for anywhere a tool needs to be
/// shown as text — a planner prompt, a log line, a debug view — independent of how any one
/// provider encodes tool definitions for the model itself (that is `SchemaBridge` in Providers).
public enum ToolPromptFormatter {
  /// `- name: description (param, optional?)`, one tool per line, alphabetical.
  public static func listing(_ descriptors: [ToolDescriptor]) -> String {
    descriptors.sorted { $0.name < $1.name }.map(line).joined(separator: "\n")
  }

  private static func line(_ descriptor: ToolDescriptor) -> String {
    "- \(descriptor.name): \(descriptor.description)" + parameterSummary(descriptor.schema)
  }

  private static func parameterSummary(_ schema: ToolSchema) -> String {
    guard !schema.parameters.isEmpty else { return "" }
    let names = schema.parameters.keys.sorted().map { name in
      schema.required.contains(name) ? name : "\(name)?"
    }
    return " (\(names.joined(separator: ", ")))"
  }
}
