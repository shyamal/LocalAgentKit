import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders
import LocalAgentKitRuntime
import LocalAgentKitSwiftUI
import LocalAgentKitTools

/// Builds the agent the demo app drives: the real on-device model, the FR-008 tools the four
/// demo turns exercise (PRD §13), and a few bundled notes so the RAG turn has something real to
/// find. `.never` network policy is validated at construction (M1-SE-03) — everything here is
/// genuinely on-device.
enum AgentSetup {
  static func makeViewModel() async throws -> AgentViewModel {
    let conversation = try await DemoConversationSession.open(
      directory: applicationSupportDirectory())
    let embedding = NLEmbeddingProvider()
    let vectorStore = InMemoryVectorStore()
    await seedNotes(embedding: embedding, vectorStore: vectorStore)

    let noteStore = NoteStore(directory: applicationSupportDirectory())
    let tools: [any AgentTool] =
      [
        CalculatorTool(),
        CalendarTool(),
        ReminderTool(),
        DocumentSearchTool(embeddingProvider: embedding, vectorStore: vectorStore, limit: 3),
      ] + NotesTool.tools(store: noteStore)

    // `AgentConfiguration.embedding`/`.vectorStore` are deliberately left unset here — setting
    // both would turn on `AgentRuntime`'s *automatic* per-run retrieval (M1-RG-05: it embeds the
    // goal once per run and injects matching chunks into every model call that run), which would
    // run *in addition to* `DocumentSearchTool` above searching the same store when the model
    // calls it. On a 4096-token on-device window (findings §3) that double-counted the same
    // fixture content and hit `AgentError.contextLimitExceeded` on turn 2 in testing. The
    // explicit tool call is what the demo scenario (PRD §13) actually wants to show; the
    // automatic path is the implicit, always-on one and isn't needed alongside it.
    let configuration = AgentConfiguration(model: FoundationModelProvider(), networkPolicy: .never)
    let runtime = try AgentRuntime(
      configuration: configuration, tools: StaticToolSource(tools),
      planner: DemoPlanner(), memory: conversation.memory,
      thermalStateSource: ProcessInfoThermalStateSource())
    return await conversation.viewModel(runtime: runtime)
  }

  /// A handful of bundled notes representing "the user's notes" for the demo's second turn
  /// ("Find my notes related to those meetings"). These are fixed content, not correlated to
  /// whatever is actually on the device's calendar — the demo proves the retrieval *mechanism*
  /// end to end, not a scripted match between two independent real data sources.
  ///
  /// Best-effort, deliberately: `NLEmbedding.sentenceEmbedding(for:)` returns nil, and
  /// `NLEmbeddingProvider.embed(text:)` throws, when the on-device sentence-embedding *asset*
  /// isn't present — observed on a physical device and in Simulator, logged by the framework
  /// itself as "Unable to locate Asset for sentence embedding model for local en." (a system
  /// asset-download state, not something the app controls or can be verified from a bare
  /// SwiftPM CLI binary the way `NLEmbeddingProviderTests` does — this only showed up in the real
  /// app). Failing here must not take down the rest of the agent: Calendar, Reminders, the
  /// calculator, and note-saving don't depend on RAG at all, and `AgentRuntime`'s own retrieval
  /// wiring (M1-RG-05) treats a retrieval failure as best-effort for exactly this reason.
  private static func seedNotes(
    embedding: NLEmbeddingProvider, vectorStore: InMemoryVectorStore
  ) async {
    guard let url = Bundle.main.url(forResource: "notes", withExtension: "md") else { return }
    do {
      let document = try DocumentLoader.load(contentsOf: url)
      try await RetrievalPipeline(embeddingProvider: embedding, vectorStore: vectorStore)
        .ingest(document)
    } catch {
      print("LocalAgentDemo: could not seed notes for RAG (turn 2 will find nothing): \(error)")
    }
  }

  private static func applicationSupportDirectory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("LocalAgentDemo", isDirectory: true)
  }
}

/// App-owned identity and dedicated local checkpoint file, independent of notes.json.
struct DemoConversationSession: Sendable {
  let memory: ConversationMemory
  private let store: SwiftDataConversationStore
  let conversationID: UUID

  static func open(directory: URL) async throws -> DemoConversationSession {
    guard let id = UUID(uuidString: "D07E0000-0000-4000-8000-000000000001") else {
      throw AgentError.memoryFailure("Invalid built-in demo conversation identity.")
    }
    let store = try SwiftDataConversationStore(
      storage: .file(directory.appendingPathComponent("conversation.store")))
    let memory = try await ConversationMemory.restore(from: store, conversationID: id)
    return DemoConversationSession(memory: memory, store: store, conversationID: id)
  }

  func checkpoint() async throws {
    try await memory.checkpoint(to: store, conversationID: conversationID)
  }

  @MainActor func viewModel(runtime: AgentRuntime) async -> AgentViewModel {
    let turns = await memory.history().compactMap { message -> AgentViewModel.Turn? in
      switch message.role {
      case .user: AgentViewModel.Turn(role: .user, text: message.content)
      case .assistant: AgentViewModel.Turn(role: .assistant, text: message.content)
      default: nil  // Summaries remain model context, not fabricated chat bubbles.
      }
    }
    return AgentViewModel(
      runtime: runtime, initialTurns: turns, onRunCompleted: { try await self.checkpoint() })
  }
}

/// Canonical calendar and related-notes turns use bounded read workflows;
/// the checklist uses one answer step and save carries its exact text through approval.
/// Other prompts retain the general planner.
struct DemoPlanner: AgentPlanner {
  private func planner(_ context: AgentContext) throws -> StateMachinePlanner {
    let words = context.goal.lowercased().split(whereSeparator: { !$0.isLetter }).joined(
      separator: " ")
    if words == "save that as a note" {
      let history = context.conversation
      guard
        let requestIndex = history.lastIndex(where: {
          $0.role == .user
            && $0.content.lowercased().split(whereSeparator: { !$0.isLetter }).joined(
              separator: " ") == "create a preparation checklist"
        }),
        let checklist = history.dropFirst(requestIndex + 1).first(where: { $0.role == .assistant }),
        !checklist.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return StateMachinePlanner(
          workflow: Workflow(
            name: "missing_checklist", description: "Explain the missing checklist.",
            steps: [
              .respond(
                instruction:
                  "There is no completed preparation checklist in this conversation to save. Ask the user to create one first; do not claim to have saved a note."
              )
            ]))
      }
      return StateMachinePlanner(
        workflow: Workflow(
          name: "save_checklist", description: "Save the completed checklist after approval.",
          steps: [
            .tool(
              "save", "Save the checklist", "create_note",
              [
                "title": .literal(.string("Preparation checklist")),
                "body": .literal(.string(checklist.content)),
              ], retries: 0)
          ]))
    }
    if words == "create a preparation checklist" {
      return StateMachinePlanner(
        workflow: Workflow(
          name: "preparation_checklist", description: "Write a checklist from the conversation.",
          steps: [
            .respond(
              instruction:
                "Create a preparation checklist using only the meetings and notes in the recent conversation. If details are missing, say so rather than inventing them."
            )
          ]))
    }
    if words == "find my notes related to those meetings" {
      return StateMachinePlanner(
        workflow: Workflow(
          name: "meeting_notes", description: "Search meeting notes once, then answer.",
          steps: [
            .tool(
              "notes", "Find notes for the meetings", "search_documents",
              [
                "query": .model(
                  hint:
                    "Search terms from the meetings in the recent conversation. Use their titles and topics."
                )
              ], onEmpty: .skip, retries: 0)
          ]))
    }
    guard words == "what meetings do i have tomorrow" else { return StateMachinePlanner() }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = context.timeZone
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: context.now),
      let interval = calendar.dateInterval(of: .day, for: tomorrow)
    else {
      throw AgentError.toolFailed(tool: "list_calendar_events", message: "Cannot resolve tomorrow.")
    }
    let formatter = ISO8601DateFormatter()
    let workflow = Workflow(
      name: "tomorrow_meetings", description: "Read tomorrow's calendar once, then answer.",
      steps: [
        .tool(
          "calendar", "Read tomorrow's meetings", "list_calendar_events",
          [
            "start": .literal(.string(formatter.string(from: interval.start))),
            "end": .literal(.string(formatter.string(from: interval.end))),
          ], onEmpty: .skip, retries: 0)
      ])
    return StateMachinePlanner(workflow: workflow)
  }

  func plan(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    async throws -> AgentPlan
  {
    try await planner(context).plan(context: &context, tools: tools, model: model)
  }
  func next(context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider)
    async throws -> PlannerDecision
  {
    if context.workflowName == "meeting_notes", let observation = context.observations.last {
      let query = observation.call.arguments.string("query") ?? ""
      return .complete("Note search results for “\(query)”:\n\(observation.result.text)")
    }
    if context.workflowName == "tomorrow_meetings", let observation = context.observations.last {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = context.timeZone
      formatter.dateFormat = "yyyy-MM-dd"
      let start = observation.call.arguments.string("start")
        .flatMap { ISO8601DateFormatter().date(from: $0) }
      let day = start.map { formatter.string(from: $0) } ?? "unknown date"
      var text = observation.result.text
      if case .array(let events) = observation.result.structured {
        formatter.dateFormat = "HH:mm"
        let rendered = events.compactMap { event -> String? in
          guard case .object(let fields) = event,
            case .string(let title) = fields["title"],
            case .string(let startText) = fields["start"],
            case .string(let endText) = fields["end"],
            let start = ISO8601DateFormatter().date(from: startText),
            let end = ISO8601DateFormatter().date(from: endText)
          else { return nil }
          return "\(title): \(formatter.string(from: start)) – \(formatter.string(from: end))"
        }
        if rendered.count == events.count, !rendered.isEmpty {
          text = rendered.joined(separator: "\n")
        }
      }
      return .complete("Calendar results for \(day) (\(context.timeZone.identifier)):\n\(text)")
    }
    return try await planner(context).next(context: &context, tools: tools, model: model)
  }
  func observe(_ observation: ToolObservation, context: inout AgentContext) throws -> PlanRevision {
    try planner(context).observe(observation, context: &context)
  }
  func handleFailure(_ error: AgentError, context: inout AgentContext) throws -> PlanRevision {
    try planner(context).handleFailure(error, context: &context)
  }
}
