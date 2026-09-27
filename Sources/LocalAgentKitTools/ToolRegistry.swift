import LocalAgentKitCore
import LocalAgentKitRuntime

/// Registers and looks up the tools an agent has (FR-007): registration, lookup, removal, and the
/// metadata/schema/permission surface via ``ToolDescriptor``.
///
/// Conforms to `ToolSource` (Runtime), so a registry can be handed to ``AgentRuntime`` directly.
public actor ToolRegistry: ToolSource {
  private var tools: [String: any AgentTool] = [:]
  /// Insertion order, so `descriptors()` is stable across calls (and across runs, for prompts
  /// that show a tool listing to a person).
  private var order: [String] = []

  public init() {}

  public init(_ tools: [any AgentTool]) {
    for tool in tools {
      if self.tools[tool.name] == nil { order.append(tool.name) }
      self.tools[tool.name] = tool
    }
  }

  /// Registers `tool`, replacing any existing tool of the same name.
  /// - Returns: True if this name was not already registered.
  @discardableResult
  public func register(_ tool: some AgentTool) -> Bool {
    let isNew = tools[tool.name] == nil
    if isNew { order.append(tool.name) }
    tools[tool.name] = tool
    return isNew
  }

  /// - Returns: True if a tool of that name was registered.
  @discardableResult
  public func unregister(name: String) -> Bool {
    guard tools.removeValue(forKey: name) != nil else { return false }
    order.removeAll { $0 == name }
    return true
  }

  public func tool(named name: String) -> (any AgentTool)? {
    tools[name]
  }

  /// Every registered tool's descriptor, in registration order.
  public func descriptors() -> [ToolDescriptor] {
    order.compactMap { name in tools[name].map { ToolDescriptor($0) } }
  }

  public var count: Int { tools.count }
  public var names: [String] { order }
}
