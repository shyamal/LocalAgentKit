import Foundation

/// Loads the durable Phase 0 suites and supplemental capability scenarios.
///
/// The Phase 0 spike that produced these suites was throwaway; the suites are not. This reads
/// what every suite shares — identity, the tool catalog it targets, and its scenario ids — so the
/// data can be listed and checked without a model, a device, or the agent runtime.
///
/// The CLI and probe runner use this metadata. Scoring and matchers are separate harness tasks.
public enum SuiteLoader {
  public enum Error: Swift.Error, CustomStringConvertible {
    case resourceMissing(String)
    case unreadable(name: String, underlying: Swift.Error)

    public var description: String {
      switch self {
      case .resourceMissing(let name): "suite resource '\(name)' is not in the bundle"
      case .unreadable(let name, let underlying): "suite '\(name)' could not be read: \(underlying)"
      }
    }
  }

  /// A tool as the model sees it: name, permission tier, and argument names.
  public struct Tool: Decodable, Sendable {
    public struct Argument: Decodable, Sendable {
      public let type: String
      public let required: Bool
      public let pattern: String?
      public let description: String?
      public let allowedValues: [String]?
      enum CodingKeys: String, CodingKey {
        case type, required, pattern, description
        case allowedValues = "enum"
      }
    }
    public let name: String
    public let description: String
    public let permission: String
    public let arguments: [String: Argument]

    /// Tiers above `readOnly` run only after a human confirms (PRD FR-009).
    public var needsConfirmation: Bool {
      ["userConfirmation", "sensitive", "destructive"].contains(permission)
    }
  }

  /// One scenario file: goals (single-tool, multi-step, refusal) or the context-load fixture.
  public struct Suite: Decodable, Sendable {
    public struct Goal: Decodable, Sendable {
      public let id: String
      public let goal: String
      public let domain: String?
      public let pairedWith: String?
      public let expectedOutcome: ExpectedOutcome?
      public let fixtures: [Fixture]?
      public let steps: [Step]?
      public let forbidden: [String]?
      public let maxIterations: Int?
    }
    public struct ExpectedOutcome: Decodable, Sendable {
      public enum Kind: String, Decodable, Sendable { case tool, text }
      public let kind: Kind
      public let tool: String?
    }
    public struct RefusalScoring: Decodable, Sendable {
      public struct Threshold: Codable, Sendable {
        public let decision: String
        public let maxSensitiveRefusalRate: Double
        public let maxRefusedRunsPerSensitiveGoal: Int
        public let maxControlRefusals: Int
      }
      public let runsPerGoal: Int?
      public let softRefusalMarkers: [String]?
      public let threshold: Threshold?
    }
    public struct Fixture: Decodable, Sendable {
      public let tool: String
      public let when: [String: GoalMatcher]
      public let returns: String
    }
    public struct Step: Decodable, Sendable {
      public let id: String
      public let tool: String
      public let dependsOn: [String]
      public let arguments: [String: GoalMatcher]
      public let optional: Bool?
    }
    /// Present on goal suites.
    public let suite: String?
    /// Present on the context-load fixture instead of `suite`.
    public let fixture: String?
    public struct Context: Codable, Sendable, Hashable {
      public let referenceDateTime: String
      public let referenceWeekday: String
      public let timeZone: String
      public let locale: String
    }
    public let context: Context?
    public let defaultToolResult: String?
    public let scoring: RefusalScoring?
    public let task: String
    public let version: Int
    public let goals: [Goal]?

    public var name: String { suite ?? fixture ?? "unnamed" }
    public var goalCount: Int { goals?.count ?? 0 }
  }

  /// Suite file names bundled under `Suites/phase0`, in the order the tasks produced them.
  public static let phase0Names = ["single-tool", "multi-step", "refusal", "context-load"]

  public static func tools(catalog: String = "tools") throws -> [Tool] {
    struct Catalog: Decodable { let tools: [Tool] }
    return try decode(Catalog.self, named: catalog).tools
  }

  public static func suite(named name: String) throws -> Suite {
    try decode(Suite.self, named: name)
  }

  /// The typed context-pressure corpus, including conversation/tool pairing and load profiles.
  public static func contextFixture() throws -> ContextLoadFixture {
    try decode(ContextLoadFixture.self, named: "context-load")
  }

  public static func phase0Suites() throws -> [Suite] {
    try phase0Names.map(suite(named:))
  }

  private static func decode<T: Decodable>(_ type: T.Type, named name: String) throws -> T {
    guard
      let url = Bundle.module.url(forResource: "Suites/phase0/\(name)", withExtension: "json")
        ?? Bundle.module.url(forResource: "Suites/notes/\(name)", withExtension: "json")
        ?? Bundle.module.url(forResource: "Suites/contacts/\(name)", withExtension: "json")
    else {
      throw Error.resourceMissing(name)
    }
    do {
      return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    } catch {
      throw Error.unreadable(name: name, underlying: error)
    }
  }
}
