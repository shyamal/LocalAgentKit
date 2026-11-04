import Foundation
import LocalAgentKitCore

/// Everything a planner knows about the run in progress. A value type owned by the runtime and
/// passed `inout`: planners hold no mutable state, so one planner serves many runs.
///
/// **Values live here, not in the model's head.** Ungrounded values, right tool but a wrong number
/// from the previous result, were the largest model-side failure in Phase 0 (findings §12).
public struct AgentContext: Sendable {
  enum Mode: Sendable {
    case unplanned
    case workflow(Workflow)
    case open
  }

  struct PendingStep: Sendable {
    var stepID: String
    var invocation: ToolInvocation
    var attempt: Int
    var isAlternative: Bool
  }

  struct ExecutedCall: Sendable {
    var tool: String
    var signature: String
  }

  /// The user's current goal, updated if clarification expands it.
  public var goal: String
  /// The clock the model is told; it is never left to guess the date (findings §11c).
  public var now: Date
  /// Time zone used when formatting the planner's reference clock.
  public var timeZone: TimeZone
  /// Earlier turns, so a follow-up such as "those meetings" can be resolved.
  public var conversation: [ModelMessage]

  /// Current task facts. Each runtime run starts with an empty value; custom planners may
  /// mutate it, and workflow bindings share this same storage.
  public var workingMemory = WorkingMemory()
  /// Structured workflow results, backed by workingMemory.
  public var bindings: [String: JSONValue] { workingMemory.values }
  /// Workflow root keys in insertion order.
  public var bindingOrder: [String] { workingMemory.orderedKeys }
  /// Workflow roots explicitly reported empty by a tool.
  public var emptyBindings: Set<String> { workingMemory.emptyKeys }
  /// Completed tool calls and results observed so far, oldest first.
  public internal(set) var observations: [ToolObservation] = []
  /// Identifiers of workflow steps skipped by guards or recovery.
  public internal(set) var skippedSteps: [String] = []
  var mode: Mode = .unplanned
  var cursor = 0
  var pending: PendingStep?
  var callCount = 0
  var failures: [String: Int] = [:]
  var executed: [ExecutedCall] = []
  var notes: [String] = []

  /// Creates a fresh run context with a reference clock, time zone and earlier transcript.
  public init(
    goal: String, now: Date = Date(), timeZone: TimeZone = .current,
    conversation: [ModelMessage] = []
  ) {
    self.goal = goal
    self.now = now
    self.timeZone = timeZone
    self.conversation = conversation
  }

  /// The name of the workflow being followed, or nil in open mode or before planning.
  public var workflowName: String? {
    if case .workflow(let workflow) = mode { workflow.name } else { nil }
  }

  // MARK: Bindings

  /// Resolves `"name"` or `"name.path.0"` to a value.
  public func value(for reference: String) -> JSONValue? {
    workingMemory.value(for: reference)
  }

  func isEmpty(_ reference: String) -> Bool { workingMemory.isEmpty(reference) }

  mutating func bind(_ name: String, _ value: JSONValue, isEmpty: Bool) {
    workingMemory.set(value, forKey: name, isEmpty: isEmpty)
  }

  mutating func nextCallID(_ stepID: String) -> String {
    callCount += 1
    return "\(stepID)#\(callCount)"
  }

  // MARK: Prompt text

  /// "Today is Monday 2026-09-21, 10:00 (UTC)."
  var referenceLine: String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
    let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    return String(
      format: "Today is %@ %04d-%02d-%02d, %02d:%02d (%@).",
      weekdays[(parts.weekday ?? 1) - 1], parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
      parts.hour ?? 0, parts.minute ?? 0, timeZone.identifier)
  }

  /// The most recent turns, clipped. Tool traffic is left out: it is what the bindings are for.
  var recentConversationText: String {
    let lines = conversation.suffix(6).compactMap { message -> String? in
      switch message.role {
      case .user: "User: " + Self.clip(message.content, 200)
      case .assistant where !message.content.isEmpty:
        "Assistant: " + Self.clip(message.content, 200)
      default: nil
      }
    }
    return lines.isEmpty ? "" : "Recent conversation:\n" + lines.joined(separator: "\n")
  }

  /// What has been found so far, newest last, clipped so a planner prompt stays small.
  func factsText(characterLimit: Int = 1500) -> String {
    var lines: [String] = []
    if bindingOrder.isEmpty || workflowName == nil {
      lines = observations.map { observation in
        "- \(observation.call.name): " + Self.clip(observation.result.text, 300)
      }
    }
    // Open-mode bindings retain typed values; observations retain their human-readable units
    // and explanations. Include custom facts without duplicating observed call IDs.
    let observedIDs = Set(observations.map { $0.call.id })
    let keys =
      workflowName == nil
      ? bindingOrder.filter { !observedIDs.contains($0) } : bindingOrder
    lines += keys.map { name in
      let text =
        emptyBindings.contains(name)
        ? "(nothing found)" : Self.clip(PromptText.render(bindings[name] ?? .null), 300)
      return "- \(name): \(text)"
    }
    lines += notes.map { "- note: " + $0 }
    var kept: [String] = []
    var size = 0
    for line in lines.reversed() {
      size += line.count + 1
      if size > characterLimit { break }
      kept.insert(line, at: 0)
    }
    return kept.isEmpty ? "" : "What has been found so far:\n" + kept.joined(separator: "\n")
  }

  static func clip(_ text: String, _ limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
  }
}

/// Renders values for a prompt: plain strings unquoted, structures compact.
enum PromptText {
  static func render(_ value: JSONValue) -> String {
    switch value {
    case .null: "none"
    case .bool(let flag): String(flag)
    case .int(let number): String(number)
    case .double(let number):
      number.rounded() == number && number.isFinite ? String(Int(number)) : String(number)
    case .string(let text): text
    case .array(let items): "[" + items.map(render).joined(separator: ", ") + "]"
    case .object(let object):
      "{"
        + object.sorted { $0.key < $1.key }.map { "\($0.key): \(render($0.value))" }
        .joined(separator: ", ") + "}"
    }
  }
}

extension JSONValue {
  /// A number, from a numeric value or from text such as `"12.50"`. Tools return text as often
  /// as structure, and a guard should not depend on which.
  var numericValue: Double? {
    switch self {
    case .int(let number): Double(number)
    case .double(let number): number
    case .string(let text):
      Double(
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
      )
    default: nil
    }
  }
}
