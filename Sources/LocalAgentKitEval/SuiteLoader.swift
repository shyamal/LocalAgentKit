import Foundation

/// Loads the bundled Phase 0 scenario suites (task P0-18).
///
/// The Phase 0 spike that produced these suites was throwaway; the suites are not. This reads
/// what every suite shares — identity, the tool catalog it targets, and its scenario ids — so the
/// data can be listed and checked without a model, a device, or the agent runtime.
///
/// Scoring, matchers and execution belong to the FR-029 harness proper (task M1-EV-01) and are
/// deliberately absent here: until then the spike in `Spike/` remains the only runner.
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
    }
    /// Present on goal suites.
    public let suite: String?
    /// Present on the context-load fixture instead of `suite`.
    public let fixture: String?
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

  public static func phase0Suites() throws -> [Suite] {
    try phase0Names.map(suite(named:))
  }

  private static func decode<T: Decodable>(_ type: T.Type, named name: String) throws -> T {
    guard let url = Bundle.module.url(forResource: "Suites/phase0/\(name)", withExtension: "json")
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
