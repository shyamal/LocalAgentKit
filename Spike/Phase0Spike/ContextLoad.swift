import Foundation
import FoundationModels

// P0-08: loads EvalSuites/phase0/context-load.json and tools.json (bundled as resources),
// turns the catalog into real Tool values, and assembles each load profile into a real
// transcript so its token cost can be measured per host.

struct Catalog: Decodable {
  struct ToolSpec: Decodable {
    struct Argument: Decodable {
      let type: String
      let required: Bool
      let description: String?
      let pattern: String?
      let `enum`: [String]?
    }
    let name: String
    let description: String
    let permission: String
    let arguments: [String: Argument]

    /// Tiers above readOnly run only after a human confirms (PRD FR-009).
    var needsConfirmation: Bool { ["userConfirmation", "sensitive", "destructive"].contains(permission) }
  }
  let tools: [ToolSpec]
}

struct ContextFixture: Decodable {
  struct Entry: Decodable {
    let kind: String
    let text: String?
    let tool: String?
    let arguments: [String: String]?
  }
  struct Exchange: Decodable {
    let exchange: Int
    let entries: [Entry]
  }
  struct Chunk: Decodable {
    let id: String
    let doc: String
    let section: String
    let text: String
  }
  struct Plan: Decodable {
    struct Step: Decodable {
      let n: Int
      let status: String
      let description: String
      let note: String?
    }
    let goal: String
    let steps: [Step]
  }
  struct Assembly: Decodable {
    let promptSuffix: String
  }
  struct Profile: Decodable {
    let id: String
    let exchanges: Int
    let chunks: Int
    let plan: Bool
  }
  struct Probe: Decodable {
    struct Source: Decodable {
      let exchange: Int?
      let chunk: String?
      let plan: Int?
    }
    let id: String
    let question: String
    let answerContainsAny: [String]
    let source: Source
  }

  let assembly: Assembly
  let instructions: String
  let conversation: [Exchange]
  let chunks: [Chunk]
  let plan: Plan
  let probes: [Probe]
  let profiles: [Profile]

  /// Whether a probe's planted fact is inside the request this profile assembles, per the
  /// fixture's `scoring.availability` rule.
  func isAvailable(_ probe: Probe, in profile: Profile) -> Bool {
    if let exchange = probe.source.exchange {
      return exchange >= conversation.count - profile.exchanges + 1
    }
    if let chunk = probe.source.chunk {
      return (chunks.prefix(profile.chunks).contains { $0.id == chunk })
    }
    return probe.source.plan != nil && profile.plan
  }
}

enum SpikeResourceError: Error {
  case missing(String)
}

func loadResource<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
  guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
    throw SpikeResourceError.missing(name)
  }
  return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

/// A catalog tool the model can see and call. Calls return a fixed string: this spike measures
/// what tool definitions cost and whether calls are well-formed, not what tools do.
struct CatalogTool: Tool {
  let name: String
  let description: String
  let parameters: GenerationSchema

  init(_ spec: Catalog.ToolSpec) throws {
    name = spec.name
    description = spec.description
    let properties = spec.arguments.sorted { $0.key < $1.key }.map { key, argument in
      DynamicGenerationSchema.Property(
        name: key, description: argument.description,
        schema: Self.schema(for: argument, named: "\(spec.name)_\(key)"),
        // --all-required is a diagnostic: it makes optional arguments required, to test
        // whether optionality itself affects generation.
        isOptional: !argument.required && !CommandLine.arguments.contains("--all-required"))
    }
    parameters = try GenerationSchema(
      root: DynamicGenerationSchema(name: "\(spec.name)_arguments", properties: properties),
      dependencies: [])
  }

  private static func schema(for argument: Catalog.ToolSpec.Argument, named name: String)
    -> DynamicGenerationSchema
  {
    if let choices = argument.enum { return DynamicGenerationSchema(name: name, anyOf: choices) }
    switch argument.type {
    case "number": return DynamicGenerationSchema(type: Double.self)
    case "integer": return DynamicGenerationSchema(type: Int.self)
    default:
      // Catalog patterns are unanchored by rule; anchors are rejected (findings §9b).
      // --no-patterns drops them, to isolate whether a pattern guide changes generation.
      if !CommandLine.arguments.contains("--no-patterns"), let pattern = argument.pattern,
        let regex = try? Regex(pattern)
      {
        return DynamicGenerationSchema(type: String.self, guides: [.pattern(regex)])
      }
      return DynamicGenerationSchema(type: String.self)
    }
  }

  func call(arguments: GeneratedContent) async throws -> String {
    // calculate is evaluated for real (EvalSuites README); every other tool is inert here.
    if name == "calculate", let expression = try? arguments.value(String.self, forProperty: "expression") {
      return Arithmetic.evaluate(expression).map { String($0) } ?? "Error: could not evaluate '\(expression)'."
    }
    return "No results found."
  }
}

/// One profile assembled exactly as the fixture's `assembly` rules describe.
struct AssembledRequest {
  let instructions: Transcript.Entry
  let history: [Transcript.Entry]
  let prompt: String
  let chunkText: String
  let planText: String

  init(
    fixture: ContextFixture, profile: ContextFixture.Profile, tools: [CatalogTool], question: String,
    instructionsOverride: String? = nil, registerTools: Bool = true
  ) throws {
    instructions = .instructions(
      Transcript.Instructions(
        segments: [.text(.init(content: instructionsOverride ?? fixture.instructions))],
        toolDefinitions: registerTools ? tools.map { Transcript.ToolDefinition(tool: $0) } : []))

    var entries: [Transcript.Entry] = []
    for exchange in fixture.conversation.suffix(profile.exchanges) {
      // A tool output carries the id of the call it answers, as in a transcript the model wrote.
      var lastCallID = ""
      for entry in exchange.entries {
        let id = UUID().uuidString
        switch entry.kind {
        case "prompt":
          entries.append(.prompt(.init(id: id, segments: [.text(.init(content: entry.text ?? ""))])))
        case "response":
          entries.append(
            .response(.init(id: id, assetIDs: [], segments: [.text(.init(content: entry.text ?? ""))])))
        case "toolCall":
          let json = String(
            decoding: try JSONEncoder().encode(entry.arguments ?? [:]), as: UTF8.self)
          let call = Transcript.ToolCall(
            id: id, toolName: entry.tool ?? "", arguments: try GeneratedContent(json: json))
          lastCallID = id
          entries.append(.toolCalls(.init([call])))
        case "toolOutput":
          entries.append(
            .toolOutput(
              .init(
                id: lastCallID, toolName: entry.tool ?? "",
                segments: [.text(.init(content: entry.text ?? ""))])))
        default:
          continue
        }
      }
    }
    history = entries

    chunkText = fixture.chunks.prefix(profile.chunks)
      .map { "[\($0.doc) - \($0.section)]\n\($0.text)" }
      .joined(separator: "\n\n")
    planText =
      profile.plan
      ? (["Current plan: \(fixture.plan.goal)"]
        + fixture.plan.steps.map { step in
          "\(step.n). [\(step.status)] \(step.description)" + (step.note.map { " - \($0)" } ?? "")
        }).joined(separator: "\n")
      : ""
    var parts: [String] = []
    if !chunkText.isEmpty { parts.append("Relevant documents:\n\(chunkText)") }
    if !planText.isEmpty { parts.append(planText) }
    parts.append("\(question)\n\(fixture.assembly.promptSuffix)")
    prompt = parts.joined(separator: "\n\n")
  }

  /// Everything the model receives for this request, as one transcript.
  var fullTranscript: [Transcript.Entry] {
    [instructions] + history + [.prompt(.init(segments: [.text(.init(content: prompt))]))]
  }
}
