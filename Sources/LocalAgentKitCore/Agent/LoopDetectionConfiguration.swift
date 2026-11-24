/// Explicit equivalence rules for loop detection. No model or embedding work is performed.
/// Rules should target free-text queries, never case-sensitive IDs or write payloads.
public struct LoopDetectionConfiguration: Sendable, Hashable {
  /// A single tool's top-level string argument whose known meanings may be canonicalized.
  public struct TextRule: Sendable, Hashable {
    /// Exact registered tool name.
    public var tool: String
    /// Exact top-level argument name; nested values remain exact.
    public var argument: String
    /// Known equivalent phrases, grouped by meaning. Case and whitespace are ignored.
    /// Overlapping groups are merged transitively. No synonyms are guessed.
    public var equivalentPhrases: [[String]]

    /// Declares text equivalence for one argument. Even without groups, case and spacing normalize.
    public init(tool: String, argument: String, equivalentPhrases: [[String]] = []) {
      self.tool = tool
      self.argument = argument
      self.equivalentPhrases = equivalentPhrases
    }
  }

  /// Explicit rules; an empty list preserves exact argument matching.
  public var textRules: [TextRule]

  /// Creates an opt-in semantic policy. Exact repetition detection always remains enabled.
  public init(textRules: [TextRule] = []) {
    self.textRules = textRules
  }
}
