import FoundationModels
import LocalAgentKitCore

/// How optional tool arguments are presented to the model.
public enum OptionalArgumentPolicy: Sendable, Hashable {
  /// Optional stays optional on OS 27 and later, and is presented as required before that.
  case automatic
  /// Preserves declared optionality on every OS, bypassing the compatibility policy.
  case asDeclared
  /// Every argument is presented as required. An optional one the model has nothing for comes
  /// back empty and is dropped before the runtime sees it.
  case requireAll

  var presentsOptionalAsRequired: Bool {
    switch self {
    case .asDeclared: return false
    case .requireAll: return true
    case .automatic:
      // Evidence (findings §11b): macOS 26 never filled an optional argument (0 of 20+), and the
      // same field declared required was correct 8 of 8. iOS 27 filled optional ones correctly.
      // macOS 27 is unmeasured, so this assumes it behaves like iOS 27.
      if #available(macOS 27, iOS 27, *) { return false }
      return true
    }
  }
}

/// Turns a ``ToolSchema`` into the framework's `GenerationSchema`.
///
/// Deliberately emits **no pattern guides**. Anchored patterns are rejected on every OS version
/// (findings §9b), and a pattern on a date field produced unparseable JSON on iOS 27 in 25 of 25
/// runs (§11a). Format is checked by the runtime's schema validation and by the tool, not by
/// constrained generation.
struct SchemaBridge: Sendable {
  var optionalPolicy: OptionalArgumentPolicy = .automatic

  func generationSchema(for tool: ToolDescriptor) throws -> GenerationSchema {
    let root = objectSchema(tool.schema, named: "\(tool.name)_arguments")
    return try GenerationSchema(root: root, dependencies: [])
  }

  private func objectSchema(_ schema: ToolSchema, named name: String) -> DynamicGenerationSchema {
    let properties = schema.parameters.sorted { $0.key < $1.key }.map { key, parameter in
      DynamicGenerationSchema.Property(
        name: key, description: Self.describe(parameter),
        schema: self.schema(for: parameter, named: "\(name)_\(key)"),
        isOptional: !schema.required.contains(key) && !optionalPolicy.presentsOptionalAsRequired)
    }
    return DynamicGenerationSchema(name: name, properties: properties)
  }

  private func schema(for parameter: ToolParameter, named name: String) -> DynamicGenerationSchema {
    if let allowed = parameter.allowedValues, case .string = parameter.type {
      return DynamicGenerationSchema(name: name, anyOf: allowed)
    }
    return schema(for: parameter.type, named: name)
  }

  private func schema(for type: ToolParameterType, named name: String) -> DynamicGenerationSchema {
    switch type {
    case .string: DynamicGenerationSchema(type: String.self)
    case .integer: DynamicGenerationSchema(type: Int.self)
    case .number: DynamicGenerationSchema(type: Double.self)
    case .boolean: DynamicGenerationSchema(type: Bool.self)
    case .array(let element): DynamicGenerationSchema(arrayOf: schema(for: element, named: name))
    case .object(let nested): objectSchema(nested, named: name)
    }
  }

  /// Range limits go in the description: they are advice to the model, and the runtime enforces
  /// them on the way back.
  private static func describe(_ parameter: ToolParameter) -> String {
    var text = parameter.description
    switch (parameter.minimum, parameter.maximum) {
    case (let minimum?, let maximum?): text += " (from \(format(minimum)) to \(format(maximum)))"
    case (let minimum?, nil): text += " (at least \(format(minimum)))"
    case (nil, let maximum?): text += " (at most \(format(maximum)))"
    case (nil, nil): break
    }
    return text
  }

  private static func format(_ number: Double) -> String {
    number.rounded() == number ? String(Int(number)) : String(number)
  }
}
