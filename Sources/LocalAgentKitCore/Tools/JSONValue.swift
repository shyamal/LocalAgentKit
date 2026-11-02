/// A Sendable, Codable JSON value. Tool arguments and structured results travel as this type so
/// Core needs no framework type to describe them.
public enum JSONValue: Sendable, Hashable, Codable {
  /// An explicit JSON null value.
  case null
  /// A JSON Boolean.
  case bool(Bool)
  /// A JSON integer represented with Swift Int.
  case int(Int)
  /// A JSON number represented with Swift Double.
  case double(Double)
  /// A JSON text value.
  case string(String)
  /// An ordered collection of JSON values.
  case array([JSONValue])
  /// A mapping from string keys to JSON values.
  case object([String: JSONValue])

  /// Decodes a scalar, array or object; integer decoding is attempted before Double.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  /// Encodes the represented JSON scalar or collection through the supplied encoder.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
  ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  /// Creates a JSON string from a Swift string literal.
  public init(stringLiteral value: String) { self = .string(value) }
  /// Creates a JSON integer from a Swift integer literal.
  public init(integerLiteral value: Int) { self = .int(value) }
  /// Creates a JSON number from a Swift floating-point literal.
  public init(floatLiteral value: Double) { self = .double(value) }
  /// Creates a JSON Boolean from a Swift Boolean literal.
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  /// Creates JSON null from a nil literal.
  public init(nilLiteral: ()) { self = .null }
  /// Creates a JSON array from literal elements.
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  /// Creates a JSON object from literal key-value pairs; keys must be unique.
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
