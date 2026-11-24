import LocalAgentKitCore

/// One declared graph action and its explicit prerequisite node identifiers.
public struct TaskNode: Sendable, Hashable {
  /// Existing workflow action, argument sources, guard and recovery policies.
  public var step: WorkflowStep
  /// Node IDs that must finish (or be skipped) before this node is considered.
  /// Result-binding and guard references add dependencies automatically.
  public var dependsOn: Set<String>

  /// Creates a node. Dependencies use node IDs, not binding aliases.
  public init(_ step: WorkflowStep, dependsOn: Set<String> = []) {
    self.step = step
    self.dependsOn = dependsOn
  }
}

/// Application-declared acyclic work. TaskGraphPlanner validates it before execution.
/// Existing ordered workflows are never converted or reordered implicitly.
public struct TaskGraph: Sendable, Hashable {
  /// Prompt/display identity of the declared graph.
  public var name: String
  /// Human-readable purpose of the graph.
  public var description: String
  /// Declaration order breaks ties between nodes in the same topological layer.
  public var nodes: [TaskNode]

  /// Creates a graph; validation occurs at planning time against registered tools.
  public init(name: String, description: String = "", nodes: [TaskNode]) {
    self.name = name
    self.description = description
    self.nodes = nodes
  }

  struct Compiled: Sendable {
    let nodes: [TaskNode]
    let dependencies: [String: Set<String>]
    let workflow: Workflow
  }

  func compile(tools: [ToolDescriptor]) throws -> Compiled {
    func invalid(_ message: String) -> AgentError {
      .invalidConfiguration(.invalidWorkflow("\(name): \(message)"))
    }
    guard name.contains(where: { !$0.isWhitespace }) else { throw invalid("empty graph name") }
    guard !nodes.isEmpty else { throw invalid("no nodes") }
    var byID: [String: TaskNode] = [:]
    var bindingOwners: [String: String] = [:]
    var responses: [String] = []
    for node in nodes {
      if Task.isCancelled { throw AgentError.cancelled }
      guard Self.identifier(node.step.id), Self.identifier(node.step.binds) else {
        throw invalid(
          "node IDs and binding aliases must be nonempty letters, numbers, underscores or hyphens")
      }
      guard byID.updateValue(node, forKey: node.step.id) == nil else {
        throw invalid("duplicate node ID \(node.step.id)")
      }
      guard bindingOwners.updateValue(node.step.id, forKey: node.step.binds) == nil else {
        throw invalid("duplicate binding \(node.step.binds)")
      }
      if case .respond = node.step.action { responses.append(node.step.id) }
    }
    guard responses.count <= 1 else { throw invalid("at most one final response is supported") }
    var dependencies: [String: Set<String>] = [:]
    for node in nodes {
      var edges = node.dependsOn
      guard edges.allSatisfy({ byID[$0] != nil }) else {
        throw invalid("unknown dependency of \(node.step.id)")
      }
      var references = Self.references(node.step.condition)
      var invocations: [ToolInvocation] = []
      if case .tool(let invocation) = node.step.action { invocations.append(invocation) }
      if let alternative = node.step.alternative { invocations.append(alternative) }
      for invocation in invocations {
        for source in invocation.arguments.values {
          if case .binding(let path) = source { references.insert(path) }
        }
        if let descriptor = tools.first(where: { $0.name == invocation.tool }) {
          for (key, source) in invocation.arguments {
            if case .literal(let value) = source, let parameter = descriptor.schema.parameters[key]
            {
              let required: Set<String> = descriptor.schema.required.contains(key) ? [key] : []
              guard
                ToolSchema(parameters: [key: parameter], required: required).validate(
                  ToolArguments([key: value])
                ).isEmpty
              else {
                throw invalid("invalid literal for \(node.step.id).\(key)")
              }
            }
          }
        }
      }
      for reference in references {
        let parts = reference.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.contains(""), let root = parts.first,
          let owner = bindingOwners[String(root)], !responses.contains(owner)
        else { throw invalid("unknown or invalid result reference \(reference)") }
        edges.insert(owner)
      }
      if case .respond = node.step.action {
        edges.formUnion(byID.keys.filter { $0 != node.step.id })
      }
      guard !edges.contains(node.step.id) else {
        throw invalid("self dependency at \(node.step.id)")
      }
      dependencies[node.step.id] = edges
    }
    var degree = dependencies.mapValues(\.count)
    var children: [String: [String]] = [:]
    for node in nodes {
      for parent in dependencies[node.step.id, default: []] {
        children[parent, default: []].append(node.step.id)
      }
    }
    let positions = Dictionary(
      uniqueKeysWithValues: nodes.enumerated().map { ($0.element.step.id, $0.offset) })
    var ready = nodes.filter { degree[$0.step.id] == 0 }.map { $0.step.id }
    var ordered: [TaskNode] = []
    while !ready.isEmpty {
      if Task.isCancelled { throw AgentError.cancelled }
      let wave = ready.sorted { positions[$0, default: 0] < positions[$1, default: 0] }
      ready = []
      for id in wave {
        if let node = byID[id] { ordered.append(node) }
        for child in children[id, default: []] {
          degree[child, default: 0] -= 1
          if degree[child] == 0 { ready.append(child) }
        }
      }
    }
    guard ordered.count == nodes.count else { throw invalid("dependency cycle") }
    let workflow = Workflow(name: name, description: description, steps: ordered.map(\.step))
    let problems = workflow.problems(against: tools)
    guard problems.isEmpty else { throw invalid(problems.joined(separator: "; ")) }
    return Compiled(nodes: ordered, dependencies: dependencies, workflow: workflow)
  }

  private static func identifier(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
  }
  private static func references(_ condition: Guard) -> Set<String> {
    switch condition {
    case .always: []
    case .exists(let path), .isEmpty(let path), .equals(let path, _), .number(let path, _, _):
      [path]
    case .not(let child): references(child)
    case .all(let children), .any(let children):
      children.reduce(into: []) { $0.formUnion(references($1)) }
    }
  }
}
