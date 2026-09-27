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

  public var goal: String
  /// The clock the model is told; it is never left to guess the date (findings §11c).
  public var now: Date
  public var timeZone: TimeZone
  /// Earlier turns, so a follow-up such as "those meetings" can be resolved.
  public var conversation: [ModelMessage]

  public internal(set) var bindings: [String: JSONValue] = [:]
  public internal(set) var bindingOrder: [String] = []
  public internal(set) var emptyBindings: Set<String> = []
  public internal(set) var observations: [ToolObservation] = []
  public internal(set) var skippedSteps: [String] = []
  var mode: Mode = .unplanned
  var cursor = 0
  var pending: PendingStep?
  var callCount = 0
  var failures: [String: Int] = [:]
  var executed: [ExecutedCall] = []
  var notes: [String] = []

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
    let parts = reference.split(separator: ".").map(String.init)
    guard let root = parts.first, var value = bindings[root] else { return nil }
    for part in parts.dropFirst() {
      switch value {
      case .object(let object):
        guard let next = object[part] else { return nil }
        value = next
      case .array(let items):
        guard let index = Int(part), items.indices.contains(index) else { return nil }
        value = items[index]
      default:
        return nil
      }
    }
    return value
  }

  func isEmpty(_ reference: String) -> Bool {
    let root = String(reference.split(separator: ".").first ?? "")
    guard let value = value(for: reference) else { return true }
    if reference == root && emptyBindings.contains(root) { return true }
    switch value {
    case .null: return true
    case .string(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .array(let items): return items.isEmpty
    case .object(let object): return object.isEmpty
    default: return false
    }
  }

  mutating func bind(_ name: String, _ value: JSONValue, isEmpty: Bool) {
    if bindings[name] == nil { bindingOrder.append(name) }
    bindings[name] = value
    if isEmpty { emptyBindings.insert(name) } else { emptyBindings.remove(name) }
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
    if bindingOrder.isEmpty {
      lines = observations.map { observation in
        "- \(observation.call.name): " + Self.clip(observation.result.text, 300)
      }
    } else {
      lines = bindingOrder.map { name in
        let text =
          emptyBindings.contains(name)
          ? "(nothing found)" : Self.clip(PromptText.render(bindings[name] ?? .null), 300)
        return "- \(name): \(text)"
      }
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
