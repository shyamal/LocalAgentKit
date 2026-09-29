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
    let embedding = NLEmbeddingProvider()
    let vectorStore = InMemoryVectorStore()
    await seedNotes(embedding: embedding, vectorStore: vectorStore)

    let noteStore = NoteStore(directory: applicationSupportDirectory())
    let tools: [any AgentTool] = [
      CalculatorTool(),
      CalendarTool(),
      ReminderTool(),
      DocumentSearchTool(embeddingProvider: embedding, vectorStore: vectorStore, limit: 3),
      CreateNoteTool(store: noteStore),
    ]

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
      memory: ConversationMemory())
    return await AgentViewModel(runtime: runtime)
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
