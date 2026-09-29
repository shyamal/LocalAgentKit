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
    try await seedNotes(embedding: embedding, vectorStore: vectorStore)

    let noteStore = NoteStore(directory: applicationSupportDirectory())
    let tools: [any AgentTool] = [
      CalculatorTool(),
      CalendarTool(),
      ReminderTool(),
      DocumentSearchTool(embeddingProvider: embedding, vectorStore: vectorStore),
      CreateNoteTool(store: noteStore),
    ]

    let configuration = AgentConfiguration(
      model: FoundationModelProvider(), embedding: embedding, vectorStore: vectorStore,
      networkPolicy: .never)
    let runtime = try AgentRuntime(
      configuration: configuration, tools: StaticToolSource(tools),
      memory: ConversationMemory())
    return await AgentViewModel(runtime: runtime)
  }

  /// A handful of bundled notes representing "the user's notes" for the demo's second turn
  /// ("Find my notes related to those meetings"). These are fixed content, not correlated to
  /// whatever is actually on the device's calendar — the demo proves the retrieval *mechanism*
  /// end to end, not a scripted match between two independent real data sources.
  private static func seedNotes(
    embedding: NLEmbeddingProvider, vectorStore: InMemoryVectorStore
  ) async throws {
    guard let url = Bundle.main.url(forResource: "notes", withExtension: "md") else { return }
    let document = try DocumentLoader.load(contentsOf: url)
    try await RetrievalPipeline(embeddingProvider: embedding, vectorStore: vectorStore)
      .ingest(document)
  }

  private static func applicationSupportDirectory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("LocalAgentDemo", isDirectory: true)
  }
}
