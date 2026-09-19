import Foundation
import FoundationModels

// P0-09: runs EvalSuites/phase0/single-tool.json against the on-device model and scores the
// first tool call of each run on the suite's measures. Matchers follow the suite's `scoring`.

/// Evaluates `+ - * /` arithmetic with parentheses and unary minus. Returns nil for anything
/// else. Written by hand because NSExpression raises an Objective-C exception on malformed
/// input, and the input here is model-written.
struct Arithmetic {
  private let chars: [Character]
  private var index = 0

  static func evaluate(_ expression: String) -> Double? {
    var parser = Arithmetic(chars: Array(expression.filter { !$0.isWhitespace }))
    guard let value = parser.sum(), parser.index == parser.chars.count, value.isFinite else {
      return nil
    }
    return value
  }

  private init(chars: [Character]) { self.chars = chars }

  private mutating func sum() -> Double? {
    guard var value = product() else { return nil }
    while index < chars.count, chars[index] == "+" || chars[index] == "-" {
      let op = chars[index]
      index += 1
      guard let rhs = product() else { return nil }
      value = op == "+" ? value + rhs : value - rhs
    }
    return value
  }

  private mutating func product() -> Double? {
    guard var value = unary() else { return nil }
    while index < chars.count, chars[index] == "*" || chars[index] == "/" {
      let op = chars[index]
      index += 1
      guard let rhs = unary() else { return nil }
      value = op == "*" ? value * rhs : value / rhs
    }
    return value
  }

  private mutating func unary() -> Double? {
    if index < chars.count, chars[index] == "-" {
      index += 1
      return unary().map { -$0 }
    }
    if index < chars.count, chars[index] == "(" {
      index += 1
      guard let value = sum(), index < chars.count, chars[index] == ")" else { return nil }
      index += 1
      return value
    }
    let start = index
    while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
    return Double(String(chars[start..<index]))
  }
}

/// Applies one suite matcher to one argument value. Returns nil on a pass, or the reason it failed.
func matcherFailure(_ matcher: [String: Any], value: Any?) -> String? {
  let kind = matcher["match"] as? String ?? ""
  let text = (value as? String)?.trimmingCharacters(in: .whitespaces)
  let terms = (matcher["terms"] as? [String]) ?? []
  switch kind {
  case "absent":
    return (value == nil || value is NSNull || text == "") ? nil : "present"
  case "exact":
    return text == matcher["value"] as? String ? nil : "not equal"
  case "caseInsensitive":
    return text?.caseInsensitiveCompare(matcher["value"] as? String ?? "") == .orderedSame
      ? nil : "not equal"
  case "containsAll":
    guard let text else { return "missing" }
    return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) } ? nil : "missing a term"
  case "containsAny":
    guard let text else { return "missing" }
    return terms.contains { text.localizedCaseInsensitiveContains($0) } ? nil : "no term"
  case "evaluatesTo":
    guard let text, let result = Arithmetic.evaluate(text) else { return "not evaluable" }
    let targets = (matcher["values"] as? [Double]) ?? [(matcher["value"] as? Double) ?? .nan]
    let tolerance = matcher["tolerance"] as? Double ?? 0
    return targets.contains { abs($0 - result) <= tolerance } ? nil : "evaluates to \(result)"
  case "datetime":
    guard let text, let actual = SuiteClock.dateTime(text),
      let expected = SuiteClock.dateTime(matcher["value"] as? String ?? "")
    else { return "not YYYY-MM-DDTHH:MM" }
    let minutes = abs(actual.timeIntervalSince(expected)) / 60
    return minutes <= (matcher["toleranceMinutes"] as? Double ?? 0) ? nil : "off by \(Int(minutes)) min"
  case "date":
    guard let text, let actual = SuiteClock.date(String(text.prefix(10))),
      let expected = SuiteClock.date(matcher["value"] as? String ?? "")
    else { return "not YYYY-MM-DD" }
    let days = abs(actual.timeIntervalSince(expected)) / 86_400
    return days <= (matcher["toleranceDays"] as? Double ?? 0) ? nil : "off by \(Int(days)) days"
  default:
    return "unknown matcher \(kind)"
  }
}

/// Strict parsing of the suite's date formats, in the suite's UTC clock.
enum SuiteClock {
  static func dateTime(_ text: String) -> Date? { parse(text, "yyyy-MM-dd'T'HH:mm") }
  static func date(_ text: String) -> Date? { parse(text, "yyyy-MM-dd") }

  private static func parse(_ text: String, _ format: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = format
    return formatter.date(from: text)
  }
}

/// Checks call arguments against the catalog schema itself rather than trusting guided
/// generation: unknown or missing arguments, wrong types, enum, and whole-value pattern.
func schemaViolations(_ arguments: [String: Any], against spec: Catalog.ToolSpec) -> [String] {
  var problems: [String] = []
  for key in arguments.keys where spec.arguments[key] == nil { problems.append("unknown \(key)") }
  for (key, argument) in spec.arguments {
    guard let value = arguments[key], !(value is NSNull) else {
      if argument.required { problems.append("missing \(key)") }
      continue
    }
    switch argument.type {
    case "number", "integer":
      if !(value is NSNumber) { problems.append("\(key) not a number") }
    default:
      guard let text = value as? String else {
        problems.append("\(key) not a string")
        continue
      }
      if let allowed = argument.enum, !allowed.contains(text) { problems.append("\(key) outside enum") }
      if let pattern = argument.pattern, let regex = try? Regex(pattern),
        (try? regex.wholeMatch(in: text)) == nil
      {
        problems.append("\(key) fails pattern")
      }
    }
  }
  return problems
}

/// The single-tool suite, read loosely: matchers are heterogeneous, so goals stay as JSON objects.
struct SingleToolSuite {
  let referenceDateTime: String
  let referenceWeekday: String
  let goals: [[String: Any]]

  static func load() throws -> SingleToolSuite {
    guard let url = Bundle.main.url(forResource: "single-tool", withExtension: "json"),
      let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
      let context = root["context"] as? [String: Any], let goals = root["goals"] as? [[String: Any]]
    else { throw SpikeResourceError.missing("single-tool") }
    return SingleToolSuite(
      referenceDateTime: context["referenceDateTime"] as? String ?? "",
      referenceWeekday: context["referenceWeekday"] as? String ?? "", goals: goals)
  }

  /// The runner's instructions. Recorded verbatim in the results so runs are reproducible.
  var instructions: String {
    let parts = referenceDateTime.split(separator: "T")
    return "You are the assistant in a work app. Now is \(referenceWeekday) \(parts.first ?? "") "
      + "\(parts.last ?? "") (UTC). Use the available tools to act on the user's request."
  }
}
