import LocalAgentKitCore

/// What the detector concluded after seeing a call.
public enum LoopVerdict: Sendable, Hashable {
  /// No repeated cycle has yet met the detection threshold.
  case proceed
  /// The recent calls repeat with the given period: 1 is the same call again and again,
  /// 2 is A, B, A, B, A.
  case loop(period: Int, toolName: String)
}

/// Detects exact or explicitly declared semantic repetition (FR-028).
///
/// A loop is one full cycle plus one more call: `A A A` for period 1, `A B A B A` for period 2.
/// One repeat alone is not a loop, since retrying a call once is legitimate. A value type owned
/// by the runtime actor, so it needs no locking.
public struct LoopDetector: Sendable {
  /// Largest repeating cycle length checked, clamped to 1...64.
  public let maxPeriod: Int
  private struct Signature: Sendable, Equatable {
    let tool: String
    let arguments: JSONValue
  }
  private var history: [Signature] = []
  private let rules: [String: [String: [String: String]]]

  /// Creates an empty detector, clamping the maximum period to 1...64.
  public init(
    maxPeriod: Int = 3,
    configuration: LoopDetectionConfiguration = LoopDetectionConfiguration()
  ) {
    // A finite cap bounds retained history and cycle-check work even for untrusted settings.
    self.maxPeriod = min(64, max(1, maxPeriod))
    var compiled: [String: [String: [String: String]]] = [:]
    for rule in configuration.textRules {
      var aliases = compiled[rule.tool]?[rule.argument] ?? [:]
      for group in rule.equivalentPhrases {
        let phrases = Set(group.map(Self.normalizedText))
        let existing = Set(phrases.compactMap { aliases[$0] })
        let members = phrases.union(aliases.filter { existing.contains($0.value) }.map(\.key))
        guard let canonical = members.sorted().first else { continue }
        for member in members { aliases[member] = canonical }
      }
      compiled[rule.tool, default: [:]][rule.argument] = aliases
    }
    rules = compiled
  }

  /// Records a call and reports whether the run is now looping.
  public mutating func record(_ call: ToolCall) -> LoopVerdict {
    var arguments = call.arguments.values
    for (key, aliases) in rules[call.name, default: [:]] {
      if case .string(let text) = arguments[key] {
        let normalized = Self.normalizedText(text)
        arguments[key] = .string(aliases[normalized] ?? normalized)
      }
    }
    history.append(Signature(tool: call.name, arguments: Self.canonical(.object(arguments))))
    let keep = 2 * maxPeriod + 1
    if history.count > keep { history.removeFirst(history.count - keep) }
    for period in 1...maxPeriod {
      let length = 2 * period + 1
      guard history.count >= length else { continue }
      let tail = Array(history.suffix(length))
      if (0..<(length - period)).allSatisfy({ tail[$0] == tail[$0 + period] }) {
        return .loop(period: period, toolName: call.name)
      }
    }
    return .proceed
  }

  private static func normalizedText(_ text: String) -> String {
    text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  // Structural comparison avoids delimiter collisions in rendered JSON signatures.
  // Integer/double equivalence is retained without overflowing Int on large doubles.
  private static func canonical(_ value: JSONValue) -> JSONValue {
    switch value {
    case .double(let number):
      if let integer = Int(exactly: number) { return .int(integer) }
      return value
    case .array(let values): return .array(values.map(canonical))
    case .object(let values): return .object(values.mapValues(canonical))
    default: return value
    }
  }

  /// Clears recorded call signatures before a new independent run.
  public mutating func reset() {
    history.removeAll()
  }
}
