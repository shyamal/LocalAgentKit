/// The arguments of one tool call, as the model produced them.
public struct ToolArguments: Sendable, Hashable, Codable {
  /// Raw argument names and JSON values supplied by the model.
  public var values: [String: JSONValue]

  /// Creates an argument object, empty by default.
  public init(_ values: [String: JSONValue] = [:]) {
    self.values = values
  }

  /// Returns a named raw value, or nil when the argument is absent.
  public subscript(name: String) -> JSONValue? { values[name] }

  /// Returns a string argument; other JSON types return nil.
  public func string(_ name: String) -> String? {
    if case .string(let value) = values[name] { value } else { nil }
  }

  /// Accepts a whole-number double, since models emit `3.0` as readily as `3`.
  public func int(_ name: String) -> Int? {
    switch values[name] {
    case .int(let value): value
    case .double(let value) where value.rounded() == value && value.isFinite: Int(value)
    default: nil
    }
  }

  /// Returns a numeric argument as Double, accepting both integer and Double values.
  public func double(_ name: String) -> Double? {
    switch values[name] {
    case .double(let value): value
    case .int(let value): Double(value)
    default: nil
    }
  }

  /// Returns a Boolean argument; other JSON types return nil.
  public func bool(_ name: String) -> Bool? {
    if case .bool(let value) = values[name] { value } else { nil }
  }

  /// A stable rendering used for loop detection (FR-028): equal arguments give equal signatures
  /// regardless of dictionary ordering.
  public var signature: String {
    Self.render(.object(values))
  }

  private static func render(_ value: JSONValue) -> String {
    switch value {
    case .null: "null"
    case .bool(let value): String(value)
    case .int(let value): String(value)
    case .double(let value):
      value.rounded() == value && value.isFinite ? String(Int(value)) : String(value)
    case .string(let value): "\"\(value)\""
    case .array(let items): "[" + items.map(render).joined(separator: ",") + "]"
    case .object(let object):
      "{"
        + object.sorted { $0.key < $1.key }.map { "\($0.key):\(render($0.value))" }
        .joined(separator: ",") + "}"
    }
  }
}
