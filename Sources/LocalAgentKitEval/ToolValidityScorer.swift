import Foundation
import LocalAgentKitCore

/// Catalog validity only: a schema-valid call can still select the wrong tool or wrong values.
public struct ToolValidityScore: Encodable, Sendable {
  public struct Call: Encodable, Sendable {
    public let name: String
    public let violations: [String]
    public let valid: Bool
    init(name: String, violations: [String]) {
      self.name = name
      self.violations = violations
      self.valid = violations.isEmpty
    }
  }
  public let goalID: String
  public let repetition: Int
  public let calls: [Call]
  /// Nil means no call was emitted; the primary rate still counts the attempt in its denominator.
  public let firstCallValid: Bool?
  init(goalID: String, repetition: Int, calls: [Call]) {
    self.goalID = goalID
    self.repetition = repetition
    self.calls = calls
    self.firstCallValid = calls.first?.valid
  }
}

/// Rates expose both attempt and emitted-call denominators to avoid hiding non-tool outcomes.
public struct ToolValiditySummary: Encodable, Sendable {
  public let attempts: Int
  public let attemptsWithCalls: Int
  public let validFirstCalls: Int
  public let emittedCalls: Int
  public let validCalls: Int
  public let extraCalls: Int
  /// Primary measure: valid first calls / all attempts, including text, refusals, and failures.
  public let validFirstCallRate: Double?
  /// Conditional measure: valid calls / emitted calls, including additional calls.
  public let emittedCallValidityRate: Double?

  init(scores: [ToolValidityScore]) {
    attempts = scores.count
    attemptsWithCalls = scores.filter { !$0.calls.isEmpty }.count
    validFirstCalls = scores.filter { $0.firstCallValid == true }.count
    emittedCalls = scores.reduce(0) { $0 + $1.calls.count }
    validCalls = scores.reduce(0) { $0 + $1.calls.filter(\.valid).count }
    extraCalls = scores.reduce(0) { $0 + max(0, $1.calls.count - 1) }
    validFirstCallRate = attempts == 0 ? nil : Double(validFirstCalls) / Double(attempts)
    emittedCallValidityRate = emittedCalls == 0 ? nil : Double(validCalls) / Double(emittedCalls)
  }
}

/// Validates types, required/unknown arguments, enums and whole-value catalog patterns.
/// Invalid catalog definitions throw rather than being counted as model failures.
public struct ToolValidityScorer: Sendable {
  private struct Definition: Sendable {
    let schema: ToolSchema
    let patterns: [String: String]
  }
  private let definitions: [String: Definition]

  public init(tools: [SuiteLoader.Tool]) throws {
    var definitions: [String: Definition] = [:]
    for tool in tools {
      guard definitions[tool.name] == nil else {
        throw ProbeError.invalidCatalog("duplicate tool \(tool.name)")
      }
      let descriptor = try ProbeRunner.descriptor(tool)
      var patterns: [String: String] = [:]
      for (name, argument) in tool.arguments {
        if let pattern = argument.pattern {
          do { _ = try NSRegularExpression(pattern: "\\A(?:\(pattern))\\z") } catch {
            throw ProbeError.invalidCatalog("invalid pattern for \(tool.name).\(name)")
          }
          patterns[name] = pattern
        }
      }
      definitions[tool.name] = Definition(schema: descriptor.schema, patterns: patterns)
    }
    self.definitions = definitions
  }

  public func score(_ results: [ProbeResult]) throws -> [ToolValidityScore] {
    try results.map { result in
      ToolValidityScore(
        goalID: result.goalID, repetition: result.repetition,
        calls: try result.calls.map { call in
          guard let definition = definitions[call.name] else {
            return ToolValidityScore.Call(name: call.name, violations: ["unknown tool"])
          }
          var violations = definition.schema.validate(ToolArguments(call.arguments)).map(
            \.description)
          for (name, pattern) in definition.patterns.sorted(by: { $0.key < $1.key }) {
            guard case .string(let value)? = call.arguments[name] else { continue }
            let regex = try NSRegularExpression(pattern: "\\A(?:\(pattern))\\z")
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if regex.firstMatch(in: value, range: range) == nil {
              violations.append("\(name) does not match the whole-value pattern")
            }
          }
          return ToolValidityScore.Call(name: call.name, violations: violations)
        })
    }
  }

  public func summary(_ scores: [ToolValidityScore]) -> ToolValiditySummary {
    ToolValiditySummary(scores: scores)
  }
}
