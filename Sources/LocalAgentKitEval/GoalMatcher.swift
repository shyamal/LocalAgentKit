import Foundation
import LocalAgentKitCore
import LocalAgentKitTools

/// Typed matcher shared by fixture routing and completion scoring; unknown kinds fail decoding.
public struct GoalMatcher: Decodable, Sendable {
  public enum Kind: String, Decodable, Sendable {
    case exact, caseInsensitive, containsAll, containsAny, evaluatesTo, datetime, date, absent
  }
  public let match: Kind
  public let value: JSONValue?
  public let values: [Double]?
  public let terms: [String]?
  public let tolerance: Double?
  public let toleranceMinutes: Double?
  public let toleranceDays: Double?
  public let groundedIn: String?

  public func matches(_ actual: JSONValue?) async throws -> Bool {
    try validate()
    let text: String?
    if case .string(let string)? = actual {
      text = string.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      text = nil
    }
    let expected: String?
    if case .string(let string)? = value { expected = string } else { expected = nil }
    switch match {
    case .absent: return actual == nil || actual == .null || text == ""
    case .exact: return text != nil ? text == expected : actual == value
    case .caseInsensitive:
      return text != nil && expected != nil && text?.lowercased() == expected?.lowercased()
    case .containsAll:
      return text.map { t in (terms ?? []).allSatisfy { t.lowercased().contains($0.lowercased()) } }
        ?? false
    case .containsAny:
      return text.map { t in (terms ?? []).contains { t.lowercased().contains($0.lowercased()) } }
        ?? false
    case .evaluatesTo:
      guard let text else { return false }
      let result = try await CalculatorTool().execute(
        arguments: ToolArguments(["expression": .string(text)]))
      guard case .double(let number)? = result.structured else { return false }
      var targets = values ?? []
      if case .double(let number)? = value { targets.append(number) }
      if case .int(let number)? = value { targets.append(Double(number)) }
      return targets.contains { abs($0 - number) <= (tolerance ?? 0) }
    case .datetime:
      guard let text, let expected, let actual = Self.parse(text, format: "yyyy-MM-dd'T'HH:mm"),
        let target = Self.parse(expected, format: "yyyy-MM-dd'T'HH:mm")
      else { return false }
      return abs(actual.timeIntervalSince(target)) <= (toleranceMinutes ?? 0) * 60
    case .date:
      guard let text, let expected,
        let actual = Self.parse(String(text.prefix(10)), format: "yyyy-MM-dd"),
        let target = Self.parse(expected, format: "yyyy-MM-dd")
      else { return false }
      return abs(actual.timeIntervalSince(target)) <= (toleranceDays ?? 0) * 86400
    }
  }

  func validate() throws {
    func reject() throws { throw ProbeError.invalidOptions("Malformed \(match.rawValue) matcher.") }
    switch match {
    case .absent: break
    case .exact: if value == nil { try reject() }
    case .caseInsensitive:
      if case .string? = value {} else { try reject() }
    case .containsAll, .containsAny:
      if terms?.isEmpty != false { try reject() }
    case .evaluatesTo:
      var targets = values ?? []
      if case .int(let n)? = value { targets.append(Double(n)) }
      if case .double(let n)? = value { targets.append(n) }
      if targets.isEmpty || targets.contains(where: { !$0.isFinite })
        || !(tolerance ?? 0).isFinite || (tolerance ?? 0) < 0
      {
        try reject()
      }
    case .date, .datetime:
      guard case .string(let target)? = value else {
        try reject()
        return
      }
      let format = match == .date ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
      let delta = match == .date ? toleranceDays ?? 0 : toleranceMinutes ?? 0
      if Self.parse(target, format: format) == nil || !delta.isFinite || delta < 0 { try reject() }
    }
  }

  static func parse(_ text: String, format: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    formatter.isLenient = false
    guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
      return nil
    }
    return date
  }

  static func all(_ matchers: [String: GoalMatcher], arguments: [String: JSONValue]) async throws
    -> Bool
  {
    for (name, matcher) in matchers.sorted(by: { $0.key < $1.key }) {
      if try await !matcher.matches(arguments[name]) { return false }
    }
    return true
  }
}
