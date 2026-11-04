/// Ephemeral task facts shared by planner steps. This value does not write to a MemoryStore.
/// Values retain insertion order and can be resolved through dot-separated object/array paths.
public struct WorkingMemory: Sendable, Hashable {
  /// Current root values. Mutate through set/remove to keep ordering and empty flags consistent.
  public private(set) var values: [String: JSONValue] = [:]
  /// Root keys in insertion order; replacing a value preserves its position.
  public private(set) var orderedKeys: [String] = []
  /// Roots explicitly reported empty by a tool, even when their text contains an explanation.
  public private(set) var emptyKeys: Set<String> = []

  /// Creates empty task memory.
  public init() {}

  /// Stores a root value, optionally marking it as an empty tool result.
  /// Keys are literal roots; dot-separated lookup treats dots as path separators.
  public mutating func set(_ value: JSONValue, forKey key: String, isEmpty: Bool = false) {
    if values[key] == nil { orderedKeys.append(key) }
    values[key] = value
    if isEmpty { emptyKeys.insert(key) } else { emptyKeys.remove(key) }
  }

  /// Removes an exact root key, including its order entry and explicit empty flag.
  public mutating func removeValue(forKey key: String) {
    values[key] = nil
    orderedKeys.removeAll { $0 == key }
    emptyKeys.remove(key)
  }

  /// Clears all task values, ordering and empty markers.
  public mutating func removeAll() {
    values.removeAll()
    orderedKeys.removeAll()
    emptyKeys.removeAll()
  }

  /// Resolves a root or nested path such as `meeting.title` or `matches.0.content`.
  /// Missing keys, invalid indices and traversal through scalar values return nil.
  public func value(for reference: String) -> JSONValue? {
    let parts = reference.split(separator: ".").map(String.init)
    guard let root = parts.first, var value = values[root] else { return nil }
    for part in parts.dropFirst() {
      switch value {
      case .object(let object):
        guard let next = object[part] else { return nil }
        value = next
      case .array(let items):
        guard let index = Int(part), items.indices.contains(index) else { return nil }
        value = items[index]
      default: return nil
      }
    }
    return value
  }

  /// True for missing values, explicitly empty roots, null, or empty strings/collections.
  /// False and zero remain present values. A root's explicit marker does not override subpaths.
  public func isEmpty(_ reference: String) -> Bool {
    let root = String(reference.split(separator: ".").first ?? "")
    guard let value = value(for: reference) else { return true }
    if reference == root && emptyKeys.contains(root) { return true }
    switch value {
    case .null: return true
    case .string(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .array(let items): return items.isEmpty
    case .object(let object): return object.isEmpty
    default: return false
    }
  }
}
