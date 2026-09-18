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
      ("context-size", contextSize),
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
        let history = try await model.tokenCount(for: request.history)
        let chunks = request.chunkText.isEmpty ? 0 : try await model.tokenCount(for: request.chunkText)
        let plan = request.planText.isEmpty ? 0 : try await model.tokenCount(for: request.planText)
        let prompt = try await model.tokenCount(for: request.prompt)
        let total = try await model.tokenCount(for: request.fullTranscript)
        let share = Int((Double(total) / Double(model.contextSize) * 100).rounded())
        log.write(
          "check=context-size result=observed profile=\(profile.id) exchanges=\(profile.exchanges) "
            + "chunks=\(profile.chunks) plan=\(profile.plan) historyEntries=\(request.history.count) "
            + "history=\(history) chunkTokens=\(chunks) planTokens=\(plan) finalPrompt=\(prompt) "
            + "total=\(total) ofContext=\(share)% headroom=\(model.contextSize - total)")
      }
    } catch {
      log.write("check=context-size result=fail error=\(describe(error))")
    }
  }

  /// The case names of a transcript's entries, e.g. `[prompt,response]`.
  private func kinds(_ transcript: Transcript) -> String {
    "[" + transcript.map { Mirror(reflecting: $0).children.first?.label ?? "?" }.joined(separator: ",") + "]"
  }

  // MARK: - Helpers

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
    let detail = String(describing: error).replacingOccurrences(of: "\n", with: " ").prefix(limit)
    return "\(String(reflecting: type(of: error)))/\(caseName(error)) \(detail)"
  }

  private func hardwareModel() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }
}
