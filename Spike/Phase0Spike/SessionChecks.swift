import Foundation
import FoundationModels

// P0-02: availability, session lifecycle, streaming, and structured output against the
// real on-device model. Each check logs `check=<id> result=<pass|fail|observed> ...`.
// N is deliberately tiny: this establishes how the API behaves, not rates (P0-09..P0-14).

@Generable
struct TripPlan {
  @Guide(description: "A short title for the trip")
  var title: String
  @Guide(description: "Total number of days", .range(1...14))
  var days: Int
  @Guide(description: "Exactly three stops, in travel order", .count(3))
  var stops: [Stop]
  var pace: Pace
}

@Generable
struct Stop {
  var city: String
  @Guide(description: "Nights spent here", .range(1...5))
  var nights: Int
}

@Generable
enum Pace {
  case relaxed, moderate, packed
}

/// Outcome of one `respond()` raced against a timeout. Main-actor only.
@MainActor
final class RunState {
  var done = false
  var content: String?
  var error: (any Error)?
}

/// Mutable state shared between a check and the task it spawns. Main-actor only.
@MainActor
final class Box {
  var snapshots = 0
  var firstSnapshot: ContinuousClock.Instant?
}

@MainActor
struct SessionChecks {
  let log: Log
  private let clock = ContinuousClock()

  /// All checks, in run order. `--only a,b` runs just those; `--skip a,b` omits them.
  private var checks: [(id: String, run: () async -> Void)] {
    [
      ("latency", latency), ("multi-turn", multiTurn), ("concurrent", concurrentRequests),
      ("cancellation", cancellation), ("cancellation-break", cancellationByBreak),
      ("abandon-timeline", abandonTimeline),
      ("text-streaming", textStreaming), ("structured", structuredOutput),
      ("structured-streaming", structuredStreaming), ("dynamic-schema", dynamicSchema),
      ("context-size", contextSize), ("p0-09", toolCallValidity), ("p0-10", multiStepCompletion),
      ("p0-11", refusalRate), ("p0-12", contextExhaustion),
    ]
  }

  func runAll(arguments: [String] = CommandLine.arguments) async {
    func list(_ flag: String) -> Set<String>? {
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
      return Set(arguments[index + 1].split(separator: ",").map(String.init))
    }
    let only = list("--only")
    let skip = list("--skip") ?? []
    log.write(
      "run start os=\"\(ProcessInfo.processInfo.operatingSystemVersionString)\" hw=\(hardwareModel())")
    guard availability() else {
      log.write("run end: model unavailable, remaining checks skipped")
      return
    }
    for check in checks where (only?.contains(check.id) ?? true) && !skip.contains(check.id) {
      log.write("begin \(check.id)")
      await check.run()
    }
    log.write("run end")
  }

  // MARK: - Checks

  private func availability() -> Bool {
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
      log.write(
        "check=availability result=pass contextSize=\(model.contextSize) "
          + "supportsCurrentLocale=\(model.supportsLocale()) languages=\(model.supportedLanguages.count)")
      return true
    case .unavailable(let reason):
      log.write("check=availability result=fail reason=\(reason)")
      return false
    }
  }

  /// Cold (fresh session) vs. prewarmed first-response latency, 3 runs each.
  private func latency() async {
    let prompt = "Reply with the single word: ready."
    var cold: [Duration] = []
    var warm: [Duration] = []
    do {
      for _ in 0..<3 {
        let session = LanguageModelSession()
        cold.append(try await clock.measure { _ = try await session.respond(to: prompt) })
      }
      for _ in 0..<3 {
        let session = LanguageModelSession()
        session.prewarm()
        try await Task.sleep(for: .seconds(2))
        warm.append(try await clock.measure { _ = try await session.respond(to: prompt) })
      }
      log.write(
        "check=latency result=observed coldMs=\(cold.map(ms)) prewarmedMs=\(warm.map(ms)) "
          + "coldMedianMs=\(ms(median(cold))) prewarmedMedianMs=\(ms(median(warm)))")
    } catch {
      log.write("check=latency result=fail error=\(describe(error))")
    }
  }

  /// One session reused across turns; then the transcript restored into a new session.
  private func multiTurn() async {
    let session = LanguageModelSession(
      instructions: "You are a concise assistant. Answer in one short sentence.")
    do {
      _ = try await session.respond(to: "Remember this: my project codename is BLUEHERON. Just reply OK.")
      let afterFirst = session.transcript.count
      let second = try await session.respond(to: "What is my project codename?")
      let recalled = second.content.localizedCaseInsensitiveContains("BLUEHERON")
      let tokens = try await SystemLanguageModel.default.tokenCount(for: session.transcript)
      var usage = "n/a(<27)"
      if #available(iOS 27.0, macOS 27.0, *) {
        usage = "in=\(second.usage.input.totalTokenCount) out=\(second.usage.output.totalTokenCount)"
      }
      log.write(
        "check=multi-turn result=\(recalled ? "pass" : "fail") entriesAfterTurn1=\(afterFirst) "
          + "entriesAfterTurn2=\(session.transcript.count) transcriptTokens=\(tokens) "
          + "turn2Usage=\(usage) answer=\(quote(second.content))")

      let encoded = try JSONEncoder().encode(session.transcript)
      let decoded = try JSONDecoder().decode(Transcript.self, from: encoded)
      let restored = LanguageModelSession(transcript: decoded)
      let answer = try await restored.respond(to: "Remind me, what is my project codename?")
      let restoredRecall = answer.content.localizedCaseInsensitiveContains("BLUEHERON")
      log.write(
        "check=transcript-restore result=\(restoredRecall ? "pass" : "fail") "
          + "codableBytes=\(encoded.count) answer=\(quote(answer.content))")
    } catch {
      log.write("check=multi-turn result=fail error=\(describe(error))")
    }
  }

  /// A second request on a session that is still responding.
  private func concurrentRequests() async {
    let session = LanguageModelSession()
    let first = Task { try await session.respond(to: "Write three sentences about lighthouses.") }
    let respondingSeen = await waitUntil { session.isResponding }
    // Reported by case name, not by type: on OS 26 this is GenerationError.concurrentRequests,
    // on OS 27 GenerationError is deprecated in favour of LanguageModelSession.Error.
    do {
      _ = try await session.respond(to: "Say hi.")
      log.write("check=concurrent result=observed isRespondingSeen=\(respondingSeen) secondRequest=succeeded")
    } catch {
      let rejected = caseName(error) == "concurrentRequests"
      log.write(
        "check=concurrent result=\(rejected ? "pass" : "observed") isRespondingSeen=\(respondingSeen) "
          + "secondRequest=\(describe(error))")
    }
    let firstOutcome: String
    do {
      _ = try await first.value
      firstOutcome = "completed"
    } catch {
      firstOutcome = describe(error)
    }
    log.write("check=concurrent-first-request result=observed outcome=\(firstOutcome)")
  }

  /// Cancel a stream after its first snapshot; then check the session is reusable.
  private func cancellation() async {
    let session = LanguageModelSession()
    let beforeStream = session.transcript
    let box = Box()
    let task = Task {
      for try await _ in session.streamResponse(to: "Write a 300-word story about a lighthouse keeper.") {
        box.snapshots += 1
        if box.firstSnapshot == nil { box.firstSnapshot = clock.now }
      }
    }
    let sawSnapshot = await waitUntil { box.firstSnapshot != nil }
    log.write("trace cancellation: firstSnapshotSeen=\(sawSnapshot) snapshots=\(box.snapshots)")
    try? await Task.sleep(for: .milliseconds(300))
    let entriesBefore = session.transcript.count
    let cancelledAt = clock.now
    log.write("trace cancellation: calling task.cancel() after \(box.snapshots) snapshots")
    task.cancel()
    log.write("trace cancellation: task.cancel() returned")
    let outcome: String
    do {
      try await task.value
      outcome = "completedNormally"
    } catch is CancellationError {
      outcome = "CancellationError"
    } catch {
      outcome = describe(error)
    }
    let stopMs = ms(clock.now - cancelledAt)
    let stillResponding = session.isResponding
    let respondingCleared = await waitUntil { !session.isResponding }
    // The framework rolls the abandoned exchange out of the transcript asynchronously, after
    // isResponding is already false (abandon-timeline). Reusing `session` inside that window
    // traps, and copying its transcript can capture the abandoned prompt. So rebuild from the
    // transcript as it was before the stream started.
    let entriesAfterCancel = session.transcript.count
    let rebuilt = LanguageModelSession(transcript: beforeStream)
    do {
      let after = try await rebuilt.respond(to: "Reply with the single word: ok.")
      log.write(
        "check=cancellation result=pass outcome=\(outcome) stopMs=\(stopMs) snapshotsBeforeCancel=\(box.snapshots) "
          + "isRespondingRightAfter=\(stillResponding) isRespondingCleared=\(respondingCleared) "
          + "entriesBeforeCancel=\(entriesBefore) entriesAfterCancel=\(entriesAfterCancel) "
          + "reusedVia=rebuiltFromPreStreamTranscript reuseAnswer=\(quote(after.content))")
    } catch {
      log.write(
        "check=cancellation result=fail outcome=\(outcome) stopMs=\(stopMs) "
          + "reuseError=\(describe(error))")
    }
  }

  /// Stop consuming a stream by breaking out of the loop instead of cancelling the task.
  private func cancellationByBreak() async {
    let session = LanguageModelSession()
    let beforeStream = session.transcript
    let start = clock.now
    var snapshots = 0
    // --break-after-ms N: how far into the stream to abandon it (default 800).
    let breakAfter = Int(value(after: "--break-after-ms") ?? "800") ?? 800
    do {
      for try await _ in session.streamResponse(to: "Write a 300-word story about a lighthouse keeper.") {
        snapshots += 1
        if clock.now - start > .milliseconds(breakAfter) { break }
      }
      let brokeAt = clock.now
      log.write("trace break: left loop after \(snapshots) snapshots, isResponding=\(session.isResponding)")
      let respondingCleared = await waitUntil { !session.isResponding }
      let clearMs = ms(clock.now - brokeAt)
      // By default the next request goes to a session rebuilt from the pre-stream transcript
      // (the safe pattern). --same-session reproduces the reuse race; --idle-ms N delays it.
      let idleMs = Int(value(after: "--idle-ms") ?? "0") ?? 0
      let sameSession = CommandLine.arguments.contains("--same-session")
      log.write("trace break: isResponding cleared=\(respondingCleared) after \(clearMs)ms; idling \(idleMs)ms")
      try await Task.sleep(for: .milliseconds(idleMs))
      log.write("trace break: next request on \(sameSession ? "the same" : "a rebuilt") session")
      let next = sameSession ? session : LanguageModelSession(transcript: beforeStream)
      let after = try await next.respond(to: "Reply with the single word: ok.")
      log.write(
        "check=cancellation-break result=pass snapshotsBeforeBreak=\(snapshots) "
          + "isRespondingCleared=\(respondingCleared) clearMs=\(clearMs) "
          + "idleMs=\(idleMs) sameSession=\(sameSession) entriesAfterAbandon=\(session.transcript.count) "
          + "entriesOnNextSession=\(next.transcript.count) reuseAnswer=\(quote(after.content))")
    } catch {
      log.write("check=cancellation-break result=fail snapshots=\(snapshots) error=\(describe(error))")
    }
  }

  /// Samples the transcript after a stream is abandoned, by task cancel and by break,
  /// to see when (and whether) the abandoned exchange leaves the transcript.
  private func abandonTimeline() async {
    let prompt = "Write a 300-word story about a lighthouse keeper."
    let sampleMs = [0, 25, 50, 100, 250, 500, 1000, 2000]
    for mode in ["cancel", "break"] {
      let session = LanguageModelSession()
      let box = Box()
      let start = clock.now
      if mode == "cancel" {
        let task = Task {
          for try await _ in session.streamResponse(to: prompt) { box.snapshots += 1 }
        }
        _ = await waitUntil { box.snapshots >= 2 }
        task.cancel()
        _ = try? await task.value
      } else {
        do {
          for try await _ in session.streamResponse(to: prompt) {
            box.snapshots += 1
            if clock.now - start > .milliseconds(800) { break }
          }
        } catch {
          log.write("check=abandon-timeline mode=\(mode) streamError=\(describe(error))")
        }
      }
      let stoppedAt = clock.now
      var samples: [String] = []
      for target in sampleMs {
        let wait = stoppedAt + .milliseconds(target) - clock.now
        if wait > .zero { try? await Task.sleep(for: wait) }
        samples.append("t\(target)=\(kinds(session.transcript))/resp=\(session.isResponding)")
      }
      log.write(
        "check=abandon-timeline result=observed mode=\(mode) snapshots=\(box.snapshots) \(samples.joined(separator: " "))")
    }
  }

  /// Plain-text streaming: snapshot count, time to first snapshot, cumulative vs. delta.
  private func textStreaming() async {
    let session = LanguageModelSession()
    let start = clock.now
    var firstMs = -1
    var count = 0
    var cumulative = true
    var previous = ""
    do {
      for try await snapshot in session.streamResponse(to: "List five facts about octopuses, one per line.") {
        if count == 0 { firstMs = ms(clock.now - start) }
        count += 1
        if !snapshot.content.hasPrefix(previous) { cumulative = false }
        previous = snapshot.content
      }
      log.write(
        "check=text-streaming result=pass snapshots=\(count) firstSnapshotMs=\(firstMs) "
          + "totalMs=\(ms(clock.now - start)) cumulativeSnapshots=\(cumulative) finalChars=\(previous.count)")
    } catch {
      log.write("check=text-streaming result=fail error=\(describe(error))")
    }
  }

  /// @Generable output with nested types, an enum, a range guide, and a count guide.
  private func structuredOutput() async {
    let session = LanguageModelSession()
    do {
      let response = try await session.respond(
        to: "Plan a relaxed 7-day trip through Japan.", generating: TripPlan.self)
      let plan = response.content
      let constraintsHeld =
        plan.stops.count == 3 && (1...14).contains(plan.days)
        && plan.stops.allSatisfy { (1...5).contains($0.nights) }
      log.write(
        "check=structured result=\(constraintsHeld ? "pass" : "fail") days=\(plan.days) "
          + "stops=\(plan.stops.count) pace=\(plan.pace) nightsSum=\(plan.stops.map(\.nights).reduce(0, +)) "
          + "json=\(response.rawContent.jsonString)")
    } catch {
      log.write("check=structured result=fail error=\(describe(error))")
    }
  }

  /// Streaming a @Generable type: how PartiallyGenerated fills in.
  private func structuredStreaming() async {
    let session = LanguageModelSession()
    let start = clock.now
    var count = 0
    var firstMs = -1
    var stopProgression: [Int] = []
    var titleBeforeStops = false
    do {
      for try await snapshot in session.streamResponse(
        to: "Plan a packed 5-day trip through Italy.", generating: TripPlan.self)
      {
        if count == 0 { firstMs = ms(clock.now - start) }
        count += 1
        let stops = snapshot.content.stops?.count ?? 0
        if stopProgression.last != stops { stopProgression.append(stops) }
        if snapshot.content.title != nil, stops == 0 { titleBeforeStops = true }
      }
      log.write(
        "check=structured-streaming result=pass snapshots=\(count) firstSnapshotMs=\(firstMs) "
          + "totalMs=\(ms(clock.now - start)) stopsCountProgression=\(stopProgression) "
          + "titleArrivedBeforeStops=\(titleBeforeStops)")
    } catch {
      log.write("check=structured-streaming result=fail error=\(describe(error))")
    }
  }

  /// A schema built at runtime, as the eval runner must do from EvalSuites/phase0/tools.json.
  private func dynamicSchema() async {
    // --schema-variant isolates which part of the schema the framework rejects:
    // unanchored (default) | anchored | no-pattern | required-anchored
    let variant = value(after: "--schema-variant") ?? "unanchored"
    let dateTime = #/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/#
    let unanchored = #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/#
    let dueGuides: [GenerationGuide<String>] =
      switch variant {
      case "no-pattern": []
      case "anchored", "required-anchored": [.pattern(dateTime)]
      default: [.pattern(unanchored)]
      }
    let root = DynamicGenerationSchema(
      name: "create_reminder_arguments",
      properties: [
        .init(
          name: "title", description: "Short title of the reminder.",
          schema: .init(type: String.self)),
        .init(
          name: "due", description: "When the reminder is due, YYYY-MM-DDTHH:MM.",
          schema: .init(type: String.self, guides: dueGuides), isOptional: variant != "required-anchored"),
      ])
    do {
      let schema = try GenerationSchema(root: root, dependencies: [])
      let session = LanguageModelSession(instructions: "Now is Monday 2026-09-21 10:00.")
      let response = try await session.respond(
        to: "Fill in the reminder for: remind me to call the plumber tomorrow at 9am.", schema: schema)
      let title = try response.content.value(String.self, forProperty: "title")
      let due = try response.content.value(String?.self, forProperty: "due")
      let patternHeld = due.map { $0.wholeMatch(of: dateTime) != nil } ?? true
      log.write(
        "check=dynamic-schema result=\(patternHeld ? "pass" : "fail") variant=\(variant) title=\(quote(title)) "
          + "due=\(due ?? "nil") dueIsCorrect=\(due == "2026-09-22T09:00")")
    } catch {
      log.write("check=dynamic-schema result=fail variant=\(variant) error=\(describe(error))")
    }
  }

  /// P0-08: token cost of each context-load profile, by component, on this host. Measures
  /// sizes only; whether requests at these sizes fail or degrade is P0-12.
  private func contextSize() async {
    do {
      let fixture = try loadResource("context-load", as: ContextFixture.self)
      let tools = try loadResource("tools", as: Catalog.self).tools.map(CatalogTool.init)
      let model = SystemLanguageModel.default
      let question = "Why is the team dinner plan stuck?"
      let bareInstructions = Transcript.Entry.instructions(
        .init(segments: [.text(.init(content: fixture.instructions))], toolDefinitions: []))
      let instructionTokens = try await model.tokenCount(for: [bareInstructions])
      let toolTokens = try await model.tokenCount(for: tools)
      log.write(
        "check=context-size result=observed component=fixed contextSize=\(model.contextSize) "
          + "instructions=\(instructionTokens) tools=\(toolTokens) toolCount=\(tools.count)")
      for profile in fixture.profiles {
        let request = try AssembledRequest(
          fixture: fixture, profile: profile, tools: tools, question: question)
        // Each component is counted separately, so one failing count names itself
        // instead of hiding the others.
        func count(_ label: String, _ body: () async throws -> Int) async -> String {
          do { return "\(label)=\(try await body())" } catch { return "\(label)=ERR(\(describe(error)))" }
        }
        let textOnlyHistory = request.history.filter {
          switch $0 {
          case .prompt, .response: true
          default: false
          }
        }
        var fields = [
          await count("history") { try await model.tokenCount(for: request.history) },
          await count("historyTextOnly") { try await model.tokenCount(for: textOnlyHistory) },
          await count("chunkTokens") {
            request.chunkText.isEmpty ? 0 : try await model.tokenCount(for: request.chunkText)
          },
          await count("planTokens") {
            request.planText.isEmpty ? 0 : try await model.tokenCount(for: request.planText)
          },
          await count("finalPrompt") { try await model.tokenCount(for: request.prompt) },
        ]
        var total: Int?
        do { total = try await model.tokenCount(for: request.fullTranscript) } catch {
          fields.append("total=ERR(\(describe(error)))")
        }
        if let total {
          let share = Int((Double(total) / Double(model.contextSize) * 100).rounded())
          fields += ["total=\(total)", "ofContext=\(share)%", "headroom=\(model.contextSize - total)"]
        }
        // Errors go last so a long error message can't hide the numbers.
        let ordered = fields.filter { !$0.contains("=ERR(") } + fields.filter { $0.contains("=ERR(") }
        log.write(
          "check=context-size result=\(total == nil ? "fail" : "observed") profile=\(profile.id) "
            + "exchanges=\(profile.exchanges) chunks=\(profile.chunks) plan=\(profile.plan) "
            + "historyEntries=\(request.history.count) " + ordered.joined(separator: " "))
      }
    } catch {
      log.write("check=context-size result=fail error=\(describe(error))")
    }
  }

  /// P0-09: the single-tool suite, `--runs N` times per goal (default 5), each in a fresh
  /// session. Scores the first tool call; prints one line per run and a summary.
  private func toolCallValidity() async {
    do {
      let suite = try SingleToolSuite.load()
      let specs = try loadResource("tools", as: Catalog.self).tools
      let tools = try specs.map(CatalogTool.init)
      let specByName = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })
      let runs = Int(value(after: "--runs") ?? "5") ?? 5
      log.write("p09 instructions=\(quote(suite.instructions)) runs=\(runs) goals=\(suite.goals.count)")
      var totals = (runs: 0, called: 0, valid: 0, tool: 0, args: 0, clean: 0, extra: 0, errors: 0)
      // --goals a,b limits the run to those goal ids.
      let only = value(after: "--goals").map { Set($0.split(separator: ",").map(String.init)) }
      for goal in suite.goals where only?.contains(goal["id"] as? String ?? "") ?? true {
        let id = goal["id"] as? String ?? "?"
        let expected = goal["expected"] as? [String: Any] ?? [:]
        let expectedTool = expected["tool"] as? String ?? ""
        let matchers = expected["arguments"] as? [String: [String: Any]] ?? [:]
        var goalClean = 0
        for run in 1...runs {
          totals.runs += 1
          let session = LanguageModelSession(tools: tools, instructions: suite.instructions)
          let start = clock.now
          var errorText = ""
          let result = await respondWithTimeout(session, to: goal["goal"] as? String ?? "")
          if result.timedOut {
            errorText = "timeout"
            totals.errors += 1
          } else if let error = result.error {
            errorText = describe(error)
            totals.errors += 1
          }
          let elapsed = ms(clock.now - start)
          let calls = session.transcript.flatMap { entry -> [Transcript.ToolCall] in
            if case .toolCalls(let batch) = entry { return Array(batch) }
            return []
          }
          guard let first = calls.first else {
            log.write("p09 goal=\(id) run=\(run) called=false ms=\(elapsed) error=\(errorText.isEmpty ? "none" : errorText)")
            continue
          }
          totals.called += 1
          let json = first.arguments.jsonString
          let arguments =
            (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
          let violations = specByName[first.toolName].map { schemaViolations(arguments, against: $0) }
            ?? ["unknown tool"]
          let toolCorrect = first.toolName == expectedTool
          let failures = toolCorrect
            ? matchers.compactMap { name, matcher in
              matcherFailure(matcher, value: arguments[name]).map { "\(name):\($0)" }
            } : ["wrong tool"]
          // Scored on the first call, as the suite specifies. Follow-up calls are counted separately:
          // the spike's tools answer "No results found.", which invites a reasonable retry.
          let clean = violations.isEmpty && toolCorrect && failures.isEmpty
          if calls.count > 1 { totals.extra += 1 }
          if violations.isEmpty { totals.valid += 1 }
          if toolCorrect { totals.tool += 1 }
          if toolCorrect && failures.isEmpty { totals.args += 1 }
          if clean {
            totals.clean += 1
            goalClean += 1
          }
          log.write(
            "p09 goal=\(id) run=\(run) called=true tool=\(first.toolName) schemaValid=\(violations.isEmpty) "
              + "toolCorrect=\(toolCorrect) argsCorrect=\(toolCorrect && failures.isEmpty) "
              + "extraCalls=\(calls.count - 1) ms=\(elapsed) args=\(json.replacingOccurrences(of: "\n", with: " ")) "
              + "problems=\((violations + failures).joined(separator: ";"))")
        }
        log.write("p09 goal-summary goal=\(id) clean=\(goalClean)/\(runs)")
      }
      func rate(_ n: Int) -> String {
        String(format: "%d/%d=%.1f%%", n, totals.runs, Double(n) / Double(max(totals.runs, 1)) * 100)
      }
      log.write(
        "check=p0-09 result=observed runs=\(totals.runs) toolCalled=\(rate(totals.called)) "
          + "schemaValid=\(rate(totals.valid)) toolCorrect=\(rate(totals.tool)) "
          + "argsCorrect=\(rate(totals.args)) firstCallFullyCorrect=\(rate(totals.clean)) "
          + "runsWithFollowUpCalls=\(rate(totals.extra)) errors=\(totals.errors)")
    } catch {
      log.write("check=p0-09 result=fail error=\(describe(error))")
    }
  }

  /// P0-10: the multi-step suite, `--runs N` per goal (default 5), each in a fresh session with
  /// the goal's fixtures behind the tools. One line per run and a summary.
  private func multiStepCompletion() async {
    do {
      guard let url = Bundle.main.url(forResource: "multi-step", withExtension: "json"),
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
        let goals = root["goals"] as? [[String: Any]]
      else { throw SpikeResourceError.missing("multi-step") }
      let specs = try loadResource("tools", as: Catalog.self).tools
      let confirmationTools = Set(specs.filter(\.needsConfirmation).map(\.name))
      let defaultResult = root["defaultToolResult"] as? String ?? "No results found."
      let instructions = try SingleToolSuite.load().instructions
      let runs = Int(value(after: "--runs") ?? "5") ?? 5
      let only = value(after: "--goals").map { Set($0.split(separator: ",").map(String.init)) }
      log.write("p10 instructions=\(quote(instructions)) runs=\(runs) goals=\(goals.count)")
      var totals = (runs: 0, completed: 0, matched: 0, required: 0, hitLimit: 0, errors: 0)
      for goal in goals where only?.contains(goal["id"] as? String ?? "") ?? true {
        let id = goal["id"] as? String ?? "?"
        let maxIterations = goal["maxIterations"] as? Int ?? 6
        var goalCompleted = 0
        for run in 1...runs {
          totals.runs += 1
          let router = FixtureRouter(
            fixturesJSON: try JSONSerialization.data(withJSONObject: goal["fixtures"] ?? []),
            defaultResult: defaultResult, maxCalls: maxIterations)
          let tools = try specs.map { try FixtureTool($0, router: router) }
          let session = LanguageModelSession(tools: tools, instructions: instructions)
          let start = clock.now
          var ending = "textAnswer"
          var hitLimit = false
          let result = await respondWithTimeout(session, to: goal["goal"] as? String ?? "")
          if result.timedOut {
            ending = "timeout"
            totals.errors += 1
          } else if let error = result.error {
            if "\(error)".contains("maxIterationsReached") {
              ending = "maxIterations"
              hitLimit = true
              totals.hitLimit += 1
            } else {
              ending = "error:\(describe(error))"
              totals.errors += 1
            }
          }
          let calls = await router.calls
          let outcome = scoreMultiStep(
            goal: goal, calls: calls, confirmationTools: confirmationTools, hitLimit: hitLimit)
          totals.matched += outcome.matched
          totals.required += outcome.required
          if outcome.completed {
            totals.completed += 1
            goalCompleted += 1
          }
          let trace = calls.map { "\($0.tool)\($0.json.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: " > ")
          log.write(
            "p10 goal=\(id) run=\(run) completed=\(outcome.completed) steps=\(outcome.matched)/\(outcome.required) "
              + "firstUnmatched=\(outcome.firstUnmatched ?? "-") forbidden=\(outcome.forbiddenCalled.joined(separator: ",")) "
              + "overConfirmed=\(outcome.overConfirmed.joined(separator: ",")) calls=\(calls.count) "
              + "ending=\(ending) ms=\(ms(clock.now - start)) trace=\(trace)")
        }
        log.write("p10 goal-summary goal=\(id) completed=\(goalCompleted)/\(runs)")
      }
      func rate(_ n: Int, _ d: Int) -> String {
        String(format: "%d/%d=%.1f%%", n, d, Double(n) / Double(max(d, 1)) * 100)
      }
      log.write(
        "check=p0-10 result=observed runs=\(totals.runs) completed=\(rate(totals.completed, totals.runs)) "
          + "stepsMatched=\(rate(totals.matched, totals.required)) hitMaxIterations=\(totals.hitLimit) "
          + "errors=\(totals.errors)")
    } catch {
      log.write("check=p0-10 result=fail error=\(describe(error))")
    }
  }

  /// P0-11: the refusal suite, `--runs N` per goal (default 5). Each run is classified per the
  /// suite's `scoring.outcomes`; soft refusals are only flagged, with the reply logged for manual
  /// review. The M9 threshold (decision 0001) is checked typed-only and with every flag counted.
  private func refusalRate() async {
    do {
      guard let url = Bundle.main.url(forResource: "refusal", withExtension: "json"),
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
        let goals = root["goals"] as? [[String: Any]], let scoring = root["scoring"] as? [String: Any]
      else { throw SpikeResourceError.missing("refusal") }
      let markers = scoring["softRefusalMarkers"] as? [String] ?? []
      let threshold = scoring["threshold"] as? [String: Any] ?? [:]
      let tools = try loadResource("tools", as: Catalog.self).tools.map(CatalogTool.init)
      let instructions = try SingleToolSuite.load().instructions
      let runs = Int(value(after: "--runs") ?? "5") ?? 5
      let only = value(after: "--goals").map { Set($0.split(separator: ",").map(String.init)) }
      log.write("p11 instructions=\(quote(instructions)) runs=\(runs) goals=\(goals.count)")
      // Per goal: typed refusals and soft-refusal flags.
      var typed: [String: Int] = [:]
      var soft: [String: Int] = [:]
      var domainOf: [String: String] = [:]
      var outcomes: [String: Int] = [:]
      for goal in goals where only?.contains(goal["id"] as? String ?? "") ?? true {
        let id = goal["id"] as? String ?? "?"
        let domain = goal["domain"] as? String ?? ""
        domainOf[id] = domain
        let expected = goal["expectedOutcome"] as? [String: Any] ?? [:]
        let expectedTool = expected["tool"] as? String
        for run in 1...runs {
          let session = LanguageModelSession(tools: tools, instructions: instructions)
          let start = clock.now
          let result = await respondWithTimeout(session, to: goal["goal"] as? String ?? "")
          let called = session.transcript.flatMap { entry -> [String] in
            if case .toolCalls(let batch) = entry { return batch.map(\.toolName) }
            return []
          }
          let text = result.content ?? ""
          let declined = markers.contains { text.localizedCaseInsensitiveContains($0) }
          let outcome: String
          if result.timedOut {
            outcome = "otherError:timeout"
          } else if let error = result.error {
            // Case names of untyped errors fall back to their multi-line description; keep the
            // label to one token so each run stays on one log line.
            let name = caseName(error)
            let label = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? "unknown"
            outcome = ["guardrailViolation", "refusal"].contains(name) ? "typedRefusal" : "otherError:\(label)"
          } else if let expectedTool {
            outcome = called.contains(expectedTool) ? "completed" : (declined ? "softRefusal" : "wrongTool")
          } else {
            outcome = declined ? "softRefusal" : (text.isEmpty ? "otherError:emptyText" : "completed")
          }
          if outcome == "typedRefusal" { typed[id, default: 0] += 1 }
          if outcome == "softRefusal" { soft[id, default: 0] += 1 }
          outcomes[outcome.hasPrefix("otherError") ? "otherError" : outcome, default: 0] += 1
          let detail = result.error.map { " error=\(describe($0))" } ?? ""
          log.write(
            "p11 goal=\(id) domain=\(domain) run=\(run) outcome=\(outcome) calls=\(called.joined(separator: ",")) "
              + "ms=\(ms(clock.now - start))\(detail) answer=\(quote(text))")
        }
      }
      // Threshold, per decision 0001, typed-only and with all soft flags counted (upper bound).
      let sensitive = domainOf.filter { $0.value != "control" }.map(\.key)
      let controls = domainOf.filter { $0.value == "control" }.map(\.key)
      let maxRate = threshold["maxSensitiveRefusalRate"] as? Double ?? 0.05
      let maxPerGoal = threshold["maxRefusedRunsPerSensitiveGoal"] as? Int ?? 2
      let maxControl = threshold["maxControlRefusals"] as? Int ?? 0
      func verdict(countSoft: Bool) -> String {
        func refused(_ id: String) -> Int { (typed[id] ?? 0) + (countSoft ? soft[id] ?? 0 : 0) }
        let sensitiveRefused = sensitive.map(refused).reduce(0, +)
        let rate = Double(sensitiveRefused) / Double(max(sensitive.count * runs, 1))
        let worst = sensitive.map { ($0, refused($0)) }.max { $0.1 < $1.1 }
        let controlRefused = controls.map(refused).reduce(0, +)
        let pass = rate <= maxRate && (worst?.1 ?? 0) <= maxPerGoal && controlRefused <= maxControl
        return "\(pass ? "PASS" : "FAIL") sensitiveRefused=\(sensitiveRefused)/\(sensitive.count * runs)"
          + String(format: "=%.1f%%", rate * 100)
          + " worstGoal=\(worst?.0 ?? "-"):\(worst?.1 ?? 0)/\(runs) controlRefused=\(controlRefused)"
      }
      log.write(
        "check=p0-11 result=observed outcomes=\(outcomes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")) "
          + "typedOnly=[\(verdict(countSoft: false))] withSoftFlags=[\(verdict(countSoft: true))]")
    } catch {
      log.write("check=p0-11 result=fail error=\(describe(error))")
    }
  }

  /// P0-12: every context-load profile × probe, `--runs N` times (default 3). Streams the
  /// response so a request rejected up front can be told from one that fails mid-generation,
  /// and classifies the outcome per the fixture's `scoring.outcomes`.
  private func contextExhaustion() async {
    let abstentionMarkers = [
      "don't know", "do not know", "not in", "no information", "couldn't find", "could not find",
      "not mentioned", "isn't mentioned", "unable to find", "not provided", "no mention",
    ]
    do {
      let fixture = try loadResource("context-load", as: ContextFixture.self)
      let specs = try loadResource("tools", as: Catalog.self).tools
      let tools = try specs.map(CatalogTool.init)
      let model = SystemLanguageModel.default
      let runs = Int(value(after: "--runs") ?? "3") ?? 3
      let onlyProfiles = value(after: "--profiles").map { Set($0.split(separator: ",").map(String.init)) }
      // --no-tools is the primary configuration: tools are not registered, but the catalog is
      // inlined into the instructions so the token load stays comparable. With inert tools
      // registered the model searches instead of reading its own context, which measures tool
      // preference rather than context retention. GenerationOptions.toolCallingMode(.disallowed)
      // would be cleaner but is 27-only, so it can't be used for a cross-host comparison.
      let noTools = CommandLine.arguments.contains("--no-tools")
      // The tool definitions stay in the transcript either way, so the token load matches the
      // profile sizes in findings section 10; only the session's callable tools differ.
      let sessionTools = noTools ? [] : tools
      log.write(
        "p12 runs=\(runs) profiles=\(fixture.profiles.count) probes=\(fixture.probes.count) "
          + "config=\(noTools ? "context-only" : "tools-registered")")
      var totals: [String: Int] = [:]
      for profile in fixture.profiles where onlyProfiles?.contains(profile.id) ?? true {
        for probe in fixture.probes {
          let available = fixture.isAvailable(probe, in: profile)
          let request = try AssembledRequest(
            fixture: fixture, profile: profile, tools: tools, question: probe.question)
          let tokens = (try? await model.tokenCount(for: request.fullTranscript)) ?? -1
          if CommandLine.arguments.contains("--dump-prompt") {
            log.write("p12 prompt profile=\(profile.id) probe=\(probe.id) historyEntries=\(request.history.count) text=\(request.prompt.replacingOccurrences(of: "\n", with: " | "))")
          }
          for run in 1...runs {
            let session = LanguageModelSession(
              tools: sessionTools,
              transcript: Transcript(entries: [request.instructions] + request.history))
            let start = clock.now
            var snapshots = 0
            var answer = ""
            var outcome = ""
            var errorDetail = ""
            do {
              for try await snapshot in session.streamResponse(to: request.prompt) {
                snapshots += 1
                answer = snapshot.content
              }
            } catch {
              let name = caseName(error)
              errorDetail = " error=\(describe(error))"
              let exhausted = ["exceededContextWindowSize", "contextSizeExceeded"].contains(name)
                || "\(error)".contains("maximum allowed")
              outcome =
                exhausted
                ? (snapshots == 0 ? "exceeded:atRequest" : "exceeded:midGeneration")
                : "otherError:\(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? "unknown")"
            }
            if outcome.isEmpty {
              let hasFact = probe.answerContainsAny.contains { answer.localizedCaseInsensitiveContains($0) }
              let abstained = abstentionMarkers.contains { answer.localizedCaseInsensitiveContains($0) }
              let detour = session.transcript.dropFirst(request.history.count + 1)
                .contains { if case .toolCalls = $0 { true } else { false } }
              outcome =
                available
                ? (hasFact ? "recalled" : (detour ? "missed:toolDetour" : "missed"))
                : (hasFact ? "leaked" : (abstained ? "abstained" : "hallucinated"))
            }
            totals[outcome.split(separator: ":").first.map(String.init) ?? outcome, default: 0] += 1
            // Only calls this run made: the fixture's history contains tool calls by design.
            let toolCalls = session.transcript.dropFirst(request.history.count + 1)
              .flatMap { entry -> [String] in
                if case .toolCalls(let batch) = entry { return batch.map(\.toolName) }
                return []
              }
            log.write(
              "p12 profile=\(profile.id) probe=\(probe.id) run=\(run) available=\(available) "
                + "outcome=\(outcome) tokens=\(tokens) snapshots=\(snapshots) tools=\(toolCalls.joined(separator: ",")) "
                + "ms=\(ms(clock.now - start))\(errorDetail) answer=\(quote(answer))")
          }
        }
      }
      let summary = totals.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
      let all = totals.values.reduce(0, +)
      let exceeded = totals["exceeded"] ?? 0
      log.write(
        "check=p0-12 result=observed runs=\(all) outcomes=\(summary) "
          + String(format: "exhaustionRate=%d/%d=%.1f%%", exceeded, all, Double(exceeded) / Double(max(all, 1)) * 100))
    } catch {
      log.write("check=p0-12 result=fail error=\(describe(error))")
    }
  }

  /// The case names of a transcript's entries, e.g. `[prompt,response]`.
  private func kinds(_ transcript: Transcript) -> String {
    "[" + transcript.map { Mirror(reflecting: $0).children.first?.label ?? "?" }.joined(separator: ",") + "]"
  }

  // MARK: - Helpers

  /// Runs `respond(to:)` with a deadline (`--run-timeout` seconds, default 120). A hung call
  /// may never honour cancellation, so on timeout the task is cancelled and abandoned rather
  /// than awaited. Each eval run uses a fresh session, so an abandoned one can't leak into the next.
  private func respondWithTimeout(_ session: LanguageModelSession, to prompt: String) async
    -> (content: String?, error: (any Error)?, timedOut: Bool)
  {
    let seconds = Double(value(after: "--run-timeout") ?? "120") ?? 120
    let state = RunState()
    let task = Task {
      do { state.content = try await session.respond(to: prompt).content } catch { state.error = error }
      state.done = true
    }
    if await waitUntil(seconds: seconds, { state.done }) { return (state.content, state.error, false) }
    task.cancel()
    return (nil, nil, true)
  }

  private func value(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  /// Polls `condition` every 20 ms for up to `seconds`. Returns whether it became true.
  private func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = clock.now + .seconds(seconds)
    while clock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  private func ms(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
  }

  private func median(_ values: [Duration]) -> Duration {
    values.sorted()[values.count / 2]
  }

  private func quote(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\n", with: " ").prefix(160) + "\""
  }

  /// The enum case of a framework error, found by reflection so the same code handles the
  /// OS 26 (`GenerationError`) and OS 27 (`LanguageModelError`, `LanguageModelSession.Error`) types.
  private func caseName(_ error: any Error) -> String {
    // OS 27's LanguageModelSession.Error has payload-less cases, which Mirror can't name.
    if #available(iOS 27.0, macOS 27.0, *), let sessionError = error as? LanguageModelSession.Error {
      switch sessionError {
      case .concurrentRequests: return "concurrentRequests"
      case .transcriptMutationWhileResponding: return "transcriptMutationWhileResponding"
      @unknown default: return String(describing: sessionError)
      }
    }
    return Mirror(reflecting: error).children.first?.label ?? String(describing: error)
  }

  private func describe(_ error: any Error) -> String {
    let limit = CommandLine.arguments.contains("--full-errors") ? 4000 : 200
    func oneLine(_ text: String) -> String {
      text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: " ")
    }
    let detail = oneLine(String(describing: error)).prefix(limit)
    return "\(String(reflecting: type(of: error)))/\(oneLine(caseName(error)).prefix(80)) \(detail)"
  }

  private func hardwareModel() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }
}
