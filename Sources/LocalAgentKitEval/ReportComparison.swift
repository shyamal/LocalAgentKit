import Foundation
import LocalAgentKitCore

/// Saved-run comparison. Changes describe observations, not statistical significance or causality.
public struct ReportComparison: Encodable, Sendable {
  public struct Identity: Encodable, Sendable {
    public let schemaVersion: Int
    public let model: String
    public let operatingSystem: String
    public let createdAt: String
    public let synthetic: Bool
  }
  public struct Value: Encodable, Sendable {
    public let numerator: Double
    public let denominator: Int
    public let value: Double?
    init(numerator: Double, denominator: Int) {
      self.numerator = numerator
      self.denominator = denominator
      value = denominator == 0 ? nil : numerator / Double(denominator)
    }
  }
  public struct Change: Encodable, Sendable {
    public let metric: String
    public let unit: String
    public let higherIsBetter: Bool
    public let baseline: Value
    public let candidate: Value
    /// Candidate minus baseline; rates use percentage points, latency uses seconds.
    public let delta: Double?
    public let adverse: Bool
  }
  public let schemaVersion = 1
  /// comparable, provisional, synthetic, or incompatible; only comparable can flag regression.
  public let status: String
  public let baseline: Identity
  public let candidate: Identity
  public let reasons: [String]
  public let warnings: [String]
  public let changes: [Change]
  public let observedRegression: Bool

  /// Accepts saved report schemas 2–5. Aggregates are rebuilt from per-trial evidence, not totals.
  public static func compare(baseline: Data, candidate: Data) throws -> ReportComparison {
    let old = try Snapshot(data: baseline)
    let new = try Snapshot(data: candidate)
    var reasons: [String] = []
    var warnings: [String] = []
    for field in Set(old.protocolFields.keys).union(new.protocolFields.keys).sorted() {
      if old.protocolFields[field] != new.protocolFields[field] {
        reasons.append("Protocol differs: \(field).")
      }
    }
    if Set(old.rows.map(\.key)) != Set(new.rows.map(\.key)) {
      reasons.append("Trial identities differ (goal/profile/tool mode/repetition).")
    }
    warnings += Array(Set(old.warnings + new.warnings)).sorted()
    if old.identity.operatingSystem != new.identity.operatingSystem {
      warnings.append(
        "OS versions differ; deltas do not isolate OS effects from model or hardware changes.")
    }
    warnings.append(
      "Observed differences are descriptive; no statistical significance or causal attribution is established."
    )
    let provisional = !old.warnings.isEmpty || !new.warnings.isEmpty
    let status =
      !reasons.isEmpty
      ? "incompatible"
      : old.identity.synthetic ? "synthetic" : provisional ? "provisional" : "comparable"
    var changes: [Change] = []
    if reasons.isEmpty {
      let before = old.metrics()
      let after = new.metrics()
      for name in Set(before.keys).union(after.keys).sorted() {
        let a = before[name] ?? Counter()
        let b = after[name] ?? Counter()
        let rate = !name.hasSuffix("/meanLatency")
        let better =
          name.hasSuffix("/validFirstCall") || name.hasSuffix("/validEmittedCall")
          || name.hasSuffix("/completed") || name.hasSuffix("/retainedSourceRecall")
          || name.hasSuffix("/groundedToolSuccess") || name.hasSuffix("/fixtureExecution")
          || name.hasSuffix("/requiredStepMatch")
        let delta = a.value.value.flatMap { av in b.value.value.map { ($0 - av) * (rate ? 100 : 1) }
        }
        let adverse = delta.map { better ? $0 < -1e-12 : $0 > 1e-12 } ?? false
        changes.append(
          Change(
            metric: name, unit: rate ? "percentagePoints" : "seconds",
            higherIsBetter: better, baseline: a.value, candidate: b.value, delta: delta,
            adverse: adverse))
      }
    }
    return ReportComparison(
      status: status, baseline: old.identity, candidate: new.identity,
      reasons: reasons, warnings: warnings, changes: changes,
      observedRegression: status == "comparable" && changes.contains(where: \.adverse))
  }
}

private struct Counter {
  var numerator: Double = 0
  var denominator = 0
  var value: ReportComparison.Value { .init(numerator: numerator, denominator: denominator) }
}
private struct Observation {
  let key: String
  let group: String
  var metrics: [String: Counter]
}
private struct Snapshot {
  let identity: ReportComparison.Identity
  var protocolFields: [String: JSONValue]
  var warnings: [String] = []
  var rows: [Observation] = []

  init(data: Data) throws {
    let root = try object(JSONDecoder().decode(JSONValue.self, from: data))
    let schema = try integer(root, "schemaVersion")
    guard (2...5).contains(schema) else { throw invalid("Unsupported report schema \(schema).") }
    identity = try .init(
      schemaVersion: schema, model: string(root, "model"),
      operatingSystem: string(root, "operatingSystem"), createdAt: string(root, "createdAt"),
      synthetic: boolean(root, "synthetic"))
    guard ISO8601DateFormatter().date(from: identity.createdAt) != nil else {
      throw invalid("Invalid createdAt.")
    }
    let expectedMode = [
      2: "single-call-probe", 3: "agent-run", 4: "refusal-probe", 5: "sdk-budgeted-context",
    ][schema]
    guard try string(root, "mode") == expectedMode else { throw invalid("Mode/schema mismatch.") }
    _ = try string(root, schema == 5 ? "fixture" : "suite")
    guard try integer(root, schema == 5 ? "fixtureVersion" : "suiteVersion") > 0 else {
      throw invalid("Invalid suite/fixture version.")
    }
    if let version = root["measurementProtocolVersion"], version != .int(1) {
      throw invalid("Unsupported measurement protocol version.")
    }
    if root["timeoutSeconds"] != nil {
      let timeout = try number(root, "timeoutSeconds")
      guard timeout > 0, timeout <= 3600 else {
        throw invalid("Invalid timeout metadata.")
      }
    }
    if root["repetitions"] != nil {
      guard try (1...100).contains(integer(root, "repetitions")) else {
        throw invalid("Invalid repetition metadata.")
      }
    }
    if let context = root["context"], context != .null { _ = try object(context) }
    if schema == 3 { _ = try string(root, "planner") }
    if schema == 5 {
      if let budget = root["budget"], budget != .null {
        let shares = try object(budget)
        var total = 0.0
        for key in ["systemAndTools", "conversation", "rag", "plan"] {
          let share = try number(shares, key)
          guard share >= 0 else { throw invalid("Negative budget share.") }
          total += share
        }
        guard total.isFinite, total > 0 else { throw invalid("Invalid budget shares.") }
      }
      if root["outputReserveTokens"] != nil {
        guard try integer(root, "outputReserveTokens") >= 0 else {
          throw invalid("Negative output reserve.")
        }
      }
    }
    let fields =
      schema == 5
      ? [
        "fixture", "fixtureVersion", "budget", "outputReserveTokens", "repetitions",
        "timeoutSeconds",
      ]
      : ["suite", "suiteVersion", "context"]
        + (schema == 3
          ? ["planner", "repetitions", "timeoutSeconds"] : ["repetitions", "timeoutSeconds"])
    protocolFields = [
      "schemaVersion": .int(schema), "mode": .string(try string(root, "mode")),
      "model": .string(identity.model), "synthetic": .bool(identity.synthetic),
    ]
    for field in fields + ["measurementProtocolVersion"] {
      if let value = root[field], value != .null {
        protocolFields[field] = value
      } else {
        warnings.append("Missing protocol metadata: \(field).")
      }
    }
    let results = try array(root, "results").map(object)
    guard !results.isEmpty else { throw invalid("Empty reports cannot be compared.") }
    var seen: Set<String> = []
    var validity: [String: [String: JSONValue]] = [:]
    if schema == 2 {
      for score in try array(root, "validity").map(object) {
        let key = try trialKey(score)
        guard validity.updateValue(score, forKey: key) == nil else {
          throw invalid("Duplicate validity row.")
        }
      }
    }
    var refusal: [String: RefusalScore] = [:]
    if schema == 4 {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let report = try decoder.decode(RefusalReport.self, from: data)
      let suite = try SuiteLoader.suite(named: "refusal")
      guard report.suite == suite.name, report.suiteVersion == suite.version,
        report.context == suite.context
      else {
        throw invalid("Refusal report needs the matching bundled scoring protocol.")
      }
      let assessment = try RefusalScorer.assess(
        report.results, synthetic: report.synthetic, decisions: report.reviews)
      let encoder = JSONEncoder()
      guard
        try JSONDecoder().decode(JSONValue.self, from: encoder.encode(assessment))
          == JSONDecoder().decode(JSONValue.self, from: encoder.encode(report.assessment))
      else {
        throw invalid("Refusal assessment is stale or inconsistent with raw evidence.")
      }
      protocolFields["threshold"] = try JSONDecoder().decode(
        JSONValue.self, from: encoder.encode(assessment.threshold))
      for score in assessment.scores {
        refusal[
          try trialKey(["goalID": .string(score.goalID), "repetition": .int(score.repetition)])] =
          score
      }
      if assessment.sensitive.pendingReviews + assessment.control.pendingReviews > 0 {
        warnings.append("Unresolved soft-refusal reviews; known-refusal deltas are provisional.")
      }
      if assessment.sensitive.otherErrors + assessment.control.otherErrors > 0 {
        warnings.append(
          "Refusal run includes other errors; known-refusal rates are incomplete evidence.")
      }
    }
    for row in results {
      let key = try trialKey(row, context: schema == 5)
      guard seen.insert(key).inserted else { throw invalid("Duplicate trial \(key).") }
      let elapsed = try number(row, "elapsedSeconds")
      guard elapsed >= 0 else { throw invalid("Negative elapsed time.") }
      var metrics = ["meanLatency": Counter(numerator: elapsed, denominator: 1)]
      var group =
        (schema == 5 ? "profile/" : "goal/")
        + (try string(row, schema == 5 ? "profileID" : "goalID"))
      switch schema {
      case 2:
        guard let score = validity.removeValue(forKey: key) else {
          throw invalid("Missing validity row.")
        }
        let calls = try array(score, "calls").map(object)
        let emitted = try array(row, "calls").map(object)
        guard calls.count == emitted.count else { throw invalid("Validity/call count mismatch.") }
        var valid = 0
        for (call, raw) in zip(calls, emitted) {
          guard try string(call, "name") == string(raw, "name"),
            try boolean(call, "valid") == array(call, "violations").isEmpty
          else { throw invalid("Inconsistent call validity.") }
          if try boolean(call, "valid") { valid += 1 }
        }
        metrics["validFirstCall"] = Counter(
          numerator: try calls.first.map { try boolean($0, "valid") ? 1 : 0 } ?? 0, denominator: 1)
        metrics["validEmittedCall"] = Counter(numerator: Double(valid), denominator: calls.count)
        let outcome = try string(row, "outcome")
        guard ["text", "toolCalls", "clarification", "refused", "failure"].contains(outcome) else {
          throw invalid("Unknown probe outcome.")
        }
        metrics["failures"] = Counter(numerator: outcome == "failure" ? 1 : 0, denominator: 1)
        metrics["refusals"] = Counter(numerator: outcome == "refused" ? 1 : 0, denominator: 1)
      case 3:
        let score = try object(try required(row, "score"))
        metrics["completed"] = Counter(
          numerator: try boolean(score, "completed") ? 1 : 0, denominator: 1)
        let calls = try array(row, "calls").map(object)
        let indices = try object(try required(score, "matchedCallIndices"))
        var matched: Set<Int> = []
        for value in indices.values {
          guard case .int(let index) = value, calls.indices.contains(index),
            try boolean(calls[index], "completed")
          else { throw invalid("Invalid matched call index.") }
          matched.insert(index)
        }
        let executed = try calls.filter { try boolean($0, "completed") }.count
        let expected = try integer(score, "stepsExpected")
        let matchedSteps = try integer(score, "stepsMatched")
        guard expected > 0, (0...expected).contains(matchedSteps) else {
          throw invalid("Invalid required-step counts.")
        }
        metrics["groundedToolSuccess"] = Counter(
          numerator: Double(matched.count), denominator: calls.count)
        metrics["fixtureExecution"] = Counter(numerator: Double(executed), denominator: calls.count)
        metrics["requiredStepMatch"] = Counter(
          numerator: Double(matchedSteps), denominator: expected)
        let stop = try string(row, "stopReason")
        guard
          [
            "answer", "clarification", "limit", "timeout", "refused", "loop", "modelUnavailable",
            "error",
          ].contains(stop)
        else { throw invalid("Unknown agent stop reason.") }
        metrics["failures"] = Counter(
          numerator: ["error", "timeout", "modelUnavailable"].contains(stop) ? 1 : 0, denominator: 1
        )
        metrics["loops"] = Counter(numerator: stop == "loop" ? 1 : 0, denominator: 1)
        metrics["limits"] = Counter(numerator: stop == "limit" ? 1 : 0, denominator: 1)
      case 4:
        guard let score = refusal[key] else { throw invalid("Missing refusal score.") }
        group = score.domain == "control" ? "cohort/control" : "cohort/sensitive"
        metrics["knownRefusals"] = Counter(
          numerator: score.typedRefusal || score.reviewedSoftRefusal == true ? 1 : 0, denominator: 1
        )
        metrics["pendingReviews"] = Counter(
          numerator: !score.matchedMarkers.isEmpty && score.reviewedSoftRefusal == nil ? 1 : 0,
          denominator: 1)
        metrics["failures"] = Counter(numerator: score.otherError ? 1 : 0, denominator: 1)
      default:
        group += "/" + (try string(row, "toolMode"))
        let outcome = try string(row, "outcome")
        guard ContextLoadResult.Outcome(rawValue: outcome) != nil else {
          throw invalid("Unknown context outcome.")
        }
        guard ContextLoadResult.ToolMode(rawValue: try string(row, "toolMode")) != nil else {
          throw invalid("Unknown tool mode.")
        }
        if let source = row["sourceAtGeneration"],
          !["retained", "removed", "absent", "uncertain"].map(JSONValue.string).contains(source)
        {
          throw invalid("Unknown source status.")
        }
        let started = try boolean(row, "generationStarted")
        let overflow = outcome == "modelExceeded"
        guard !overflow || started else { throw invalid("Model overflow without generation.") }
        metrics["exhaustion"] = Counter(
          numerator: overflow || outcome == "budgetExceeded" ? 1 : 0, denominator: 1)
        metrics["modelExhaustion"] = Counter(
          numerator: overflow ? 1 : 0, denominator: started ? 1 : 0)
        metrics["failures"] = Counter(
          numerator: ["timeout", "otherError"].contains(outcome) ? 1 : 0, denominator: 1)
        metrics["unexpectedToolCalls"] = Counter(
          numerator: outcome == "unexpectedToolCall" ? 1 : 0, denominator: 1)
        // Derive recall from evidence fields, not the saved aggregate or assessment label.
        let retained = row["sourceAtGeneration"] == .string("retained") && outcome == "text"
        let answerMatches = try boolean(row, "answerMatches")
        metrics["retainedSourceRecall"] = Counter(
          numerator: retained && answerMatches ? 1 : 0,
          denominator: retained ? 1 : 0)
      }
      rows.append(Observation(key: key, group: group, metrics: metrics))
    }
    guard validity.isEmpty else { throw invalid("Extra validity rows.") }
  }

  func metrics() -> [String: Counter] {
    var values: [String: Counter] = [:]
    for row in rows {
      for scope in ["all", row.group] {
        for (name, value) in row.metrics {
          let key = scope + "/" + name
          var total = values[key] ?? Counter()
          total.numerator += value.numerator
          total.denominator += value.denominator
          values[key] = total
        }
      }
    }
    return values
  }
}

private func invalid(_ message: String) -> ProbeError { .invalidOptions(message) }
private func object(_ value: JSONValue) throws -> [String: JSONValue] {
  guard case .object(let result) = value else { throw invalid("Expected JSON object.") }
  return result
}
private func required(_ object: [String: JSONValue], _ key: String) throws -> JSONValue {
  guard let value = object[key] else { throw invalid("Missing field \(key).") }
  return value
}
private func string(_ object: [String: JSONValue], _ key: String) throws -> String {
  guard case .string(let value) = try required(object, key), !value.isEmpty else {
    throw invalid("Invalid string \(key).")
  }
  return value
}
private func boolean(_ object: [String: JSONValue], _ key: String) throws -> Bool {
  guard case .bool(let value) = try required(object, key) else {
    throw invalid("Invalid boolean \(key).")
  }
  return value
}
private func number(_ object: [String: JSONValue], _ key: String) throws -> Double {
  switch try required(object, key) {
  case .int(let value): return Double(value)
  case .double(let value) where value.isFinite: return value
  default: throw invalid("Invalid number \(key).")
  }
}
private func integer(_ object: [String: JSONValue], _ key: String) throws -> Int {
  guard case .int(let value) = try required(object, key) else {
    throw invalid("Invalid integer \(key).")
  }
  return value
}
private func array(_ object: [String: JSONValue], _ key: String) throws -> [JSONValue] {
  guard case .array(let value) = try required(object, key) else {
    throw invalid("Invalid array \(key).")
  }
  return value
}
private func trialKey(_ row: [String: JSONValue], context: Bool = false) throws -> String {
  let repetition = try integer(row, "repetition")
  guard (1...100).contains(repetition) else { throw invalid("Invalid repetition.") }
  let parts =
    context
    ? try [string(row, "profileID"), string(row, "toolMode"), string(row, "probeID")]
    : try [string(row, "goalID")]
  // JSON encoding avoids collisions from delimiters embedded in future fixture identifiers.
  return try String(decoding: JSONEncoder().encode(parts), as: UTF8.self) + "#\(repetition)"
}
