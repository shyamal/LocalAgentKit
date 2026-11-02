/// The type of a single tool parameter. JSON-Schema-shaped, and closed: the model is asked a
/// narrow question, and anything outside the declared type is rejected before the permission gate.
public indirect enum ToolParameterType: Sendable, Hashable {
  /// A text parameter, optionally restricted to allowed values.
  case string
  /// A whole-number parameter; integral finite Double values are also accepted.
  case integer
  /// An integer or finite Double parameter.
  case number
  /// A Boolean parameter.
  case boolean
  /// An array whose elements satisfy the given parameter type.
  case array(of: ToolParameterType)
  /// An object validated recursively against the given schema.
  case object(ToolSchema)
}

/// One parameter of a tool.
public struct ToolParameter: Sendable, Hashable {
  /// JSON-shaped type accepted for this parameter.
  public var type: ToolParameterType
  /// Prompt-facing explanation including units, formats and intended meaning.
  public var description: String
  /// If non-nil, a string value must be one of these.
  public var allowedValues: [String]?
  /// Inclusive lower bound for numeric values, when specified.
  public var minimum: Double?
  /// Inclusive upper bound for numeric values, when specified.
  public var maximum: Double?

  /// Creates a parameter with a type, prompt description and optional enum or numeric bounds.
  public init(
    _ type: ToolParameterType,
    description: String,
    allowedValues: [String]? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil
  ) {
    self.type = type
    self.description = description
    self.allowedValues = allowedValues
    self.minimum = minimum
    self.maximum = maximum
  }
}

/// Why an argument failed validation. Fed back to the model verbatim on the repair path.
public enum ArgumentViolation: Sendable, Hashable, CustomStringConvertible {
  /// A required argument is missing or explicitly null.
  case missingRequired(path: String)
  /// An argument name is not declared in the schema.
  case unknownProperty(path: String)
  /// A value has the wrong JSON type for the indicated path.
  case typeMismatch(path: String, expected: String)
  /// A string is outside its allowed set of values.
  case notAllowed(path: String, allowed: [String])
  /// A numeric value is below its inclusive lower bound.
  case belowMinimum(path: String, minimum: Double)
  /// A numeric value is above its inclusive upper bound.
  case aboveMaximum(path: String, maximum: Double)

  /// A repair-oriented explanation of the invalid argument.
  public var description: String {
    switch self {
    case .missingRequired(let path): "\(path) is required"
    case .unknownProperty(let path): "\(path) is not a parameter of this tool"
    case .typeMismatch(let path, let expected): "\(path) must be \(expected)"
    case .notAllowed(let path, let allowed):
      "\(path) must be one of: \(allowed.joined(separator: ", "))"
    case .belowMinimum(let path, let minimum): "\(path) must be at least \(minimum)"
    case .aboveMaximum(let path, let maximum): "\(path) must be at most \(maximum)"
    }
  }
}

/// The argument schema of a tool: a JSON-Schema-shaped object with named parameters.
public struct ToolSchema: Sendable, Hashable {
  /// Parameter definitions keyed by their model-facing argument names.
  public var parameters: [String: ToolParameter]
  /// Names in ``parameters`` that must be present.
  public var required: Set<String>

  /// Creates an object schema; every required name should also have a parameter definition.
  public init(parameters: [String: ToolParameter] = [:], required: Set<String> = []) {
    self.parameters = parameters
    self.required = required
  }

  /// A schema for a tool that takes no arguments.
  public static let empty = ToolSchema()

  /// Validates arguments against the schema. An empty result means the call is schema-valid —
  /// which says nothing about whether it is *allowed*; that is the permission gate's job.
  public func validate(_ arguments: ToolArguments) -> [ArgumentViolation] {
    validate(arguments.values, path: "")
  }

  private func validate(_ values: [String: JSONValue], path: String) -> [ArgumentViolation] {
    var violations: [ArgumentViolation] = []
    for name in required.sorted() where values[name] == nil || values[name] == .null {
      violations.append(.missingRequired(path: path + name))
    }
    for (name, value) in values.sorted(by: { $0.key < $1.key }) {
      guard let parameter = parameters[name] else {
        violations.append(.unknownProperty(path: path + name))
        continue
      }
      if value == .null { continue }
      violations += Self.check(value, against: parameter, path: path + name)
    }
    return violations
  }

  private static func check(
    _ value: JSONValue, against parameter: ToolParameter, path: String
  ) -> [ArgumentViolation] {
    switch (parameter.type, value) {
    case (.string, .string(let text)):
      if let allowed = parameter.allowedValues, !allowed.contains(text) {
        return [.notAllowed(path: path, allowed: allowed)]
      }
      return []
    case (.integer, .int(let number)):
      return range(Double(number), parameter, path)
    case (.integer, .double(let number)) where number.rounded() == number && number.isFinite:
      return range(number, parameter, path)
    case (.number, .int(let number)):
      return range(Double(number), parameter, path)
    case (.number, .double(let number)) where number.isFinite:
      return range(number, parameter, path)
    case (.boolean, .bool):
      return []
    case (.array(let element), .array(let items)):
      let element = ToolParameter(element, description: "")
      return items.enumerated().flatMap { index, item in
        check(item, against: element, path: "\(path)[\(index)]")
      }
    case (.object(let schema), .object(let values)):
      return schema.validate(values, path: path + ".")
    default:
      return [.typeMismatch(path: path, expected: parameter.type.displayName)]
    }
  }

  private static func range(
    _ number: Double, _ parameter: ToolParameter, _ path: String
  ) -> [ArgumentViolation] {
    if let minimum = parameter.minimum, number < minimum {
      return [.belowMinimum(path: path, minimum: minimum)]
    }
    if let maximum = parameter.maximum, number > maximum {
      return [.aboveMaximum(path: path, maximum: maximum)]
    }
    return []
  }
}

extension ToolParameterType {
  fileprivate var displayName: String {
    switch self {
    case .string: "a string"
    case .integer: "an integer"
    case .number: "a number"
    case .boolean: "a boolean"
    case .array(let element): "an array of \(element.displayName.dropFirst(2))s"
    case .object: "an object"
    }
  }
}
