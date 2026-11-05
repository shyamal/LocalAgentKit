import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitSwiftUI
import LocalAgentKitTesting
import LocalAgentKitTools
import Testing

@testable import DemoSetup

@MainActor
@Suite struct ConversationResumeTests {
  @Test func completedTurnRestoresVisibleTranscriptAndModelContextAfterReopening() async throws {
    let directory = resumeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await saveFirstTurn(directory: directory)
    let resumed = try await DemoConversationSession.open(directory: directory)
    let model = ScriptedModelProvider(responses: [.text("Prepare Budget review")])
    let runtime = try responseRuntime(model, memory: resumed.memory)
    let viewModel = await resumed.viewModel(runtime: runtime)
    #expect(viewModel.turns.map(\.text) == ["My meeting?", "Budget review at 10am"])
    #expect(!viewModel.isRunning)
    #expect(viewModel.toolActivity.isEmpty)
    viewModel.send("What should I prepare?")
    await waitForResume { !viewModel.isRunning }
    #expect(
      await model.requests.first?.messages.contains { $0.content == "Budget review at 10am" }
        == true)
    let reopened = try await DemoConversationSession.open(directory: directory)
    #expect(
      await reopened.memory.history().map(\.content) == [
        "My meeting?", "Budget review at 10am", "What should I prepare?", "Prepare Budget review",
      ])
    await runtime.finishEvents()
  }

  @Test func failedTurnDoesNotReplaceTheLastCompletedCheckpoint() async throws {
    let directory = resumeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await saveFirstTurn(directory: directory)
    let resumed = try await DemoConversationSession.open(directory: directory)
    let runtime = try responseRuntime(
      ScriptedModelProvider([.fail(.modelUnavailable(reason: "Stopped"))]), memory: resumed.memory)
    let viewModel = await resumed.viewModel(runtime: runtime)
    viewModel.send("Unfinished question")
    await waitForResume { !viewModel.isRunning }
    #expect(viewModel.lastFailure != nil)
    let reopened = try await DemoConversationSession.open(directory: directory)
    #expect(
      await reopened.memory.history().map(\.content) == ["My meeting?", "Budget review at 10am"])
    await runtime.finishEvents()
  }

  @Test(arguments: [false, true])
  func restoredChecklistStillRequiresApprovalAndSavesExactBody(approve: Bool) async throws {
    let directory = resumeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let checklist = "Budget review preparation\n- Prepare headcount numbers with Priya.\n"
    try await seedChecklist(directory: directory, text: checklist)
    let resumed = try await DemoConversationSession.open(directory: directory)
    let notes = NoteStore(directory: directory)
    let gate = ResumeGate(approve: approve)
    let model = ScriptedModelProvider(responses: [])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model),
      tools: StaticToolSource(NotesTool.tools(store: notes)),
      planner: DemoPlanner(), gate: gate, memory: resumed.memory)
    let viewModel = await resumed.viewModel(runtime: runtime)
    viewModel.send("Save that as a note.")
    await waitForResume { !viewModel.isRunning }
    #expect(await gate.calls == 1)
    let saved = try await notes.all()
    #expect(saved.count == (approve ? 1 : 0))
    if approve {
      #expect(saved.first?.body == checklist)
    } else {
      #expect(viewModel.lastFailure != nil)
    }
    let reopened = try await DemoConversationSession.open(directory: directory)
    #expect(await reopened.memory.history().count == (approve ? 4 : 2))
    #expect(await model.requests.isEmpty)
    await runtime.finishEvents()
  }

  @Test func corruptStorageFailsWithoutBeingReplacedByAnEmptyConversation() async throws {
    let directory = resumeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("conversation.store")
    let corrupt = Data("not a SQLite store".utf8)
    try corrupt.write(to: url)
    do {
      _ = try await DemoConversationSession.open(directory: directory)
      Issue.record("Expected storage failure")
    } catch let error as AgentError {
      guard case .memoryFailure = error else {
        Issue.record("Expected typed memory failure")
        return
      }
    }
    #expect(try Data(contentsOf: url) == corrupt)
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEMO_RESUME_FIXTURE_DIR"] != nil))
  func optionalNativeSmokeFixtureContainsOnlySyntheticCompletedTurns() async throws {
    guard let path = ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEMO_RESUME_FIXTURE_DIR"]
    else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    guard directory.resolvingSymlinksInPath().path.hasPrefix("/private/tmp/lak-demo-resume-") else {
      throw AgentError.memoryFailure(
        "Native smoke fixtures require an isolated /tmp/lak-demo-resume- directory.")
    }
    let session = try await DemoConversationSession.open(directory: directory)
    await session.memory.reset()
    await session.memory.recordTurn(
      goal: "Create a preparation checklist.",
      answer: "Resume verification checklist\n- Synthetic Budget review preparation.")
    try await session.checkpoint()
  }

  private func saveFirstTurn(directory: URL) async throws {
    let session = try await DemoConversationSession.open(directory: directory)
    let runtime = try responseRuntime(
      ScriptedModelProvider(responses: [.text("Budget review at 10am")]), memory: session.memory)
    let viewModel = await session.viewModel(runtime: runtime)
    viewModel.send("My meeting?")
    await waitForResume { !viewModel.isRunning }
    #expect(viewModel.lastFailure == nil)
    await runtime.finishEvents()
  }
  private func seedChecklist(directory: URL, text: String) async throws {
    let session = try await DemoConversationSession.open(directory: directory)
    await session.memory.recordTurn(goal: "Create a preparation checklist.", answer: text)
    try await session.checkpoint()
  }
}
private func resumeDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}
private func responseRuntime(_ model: any LocalModelProvider, memory: ConversationMemory) throws
  -> AgentRuntime
{
  try AgentRuntime(
    configuration: AgentConfiguration(model: model), tools: StaticToolSource([]),
    planner: StateMachinePlanner(
      workflow: Workflow(
        name: "answer", description: "Answer",
        steps: [.respond(instruction: "Use prior conversation")])), memory: memory)
}
@MainActor private func waitForResume(_ condition: () -> Bool) async {
  let deadline = ContinuousClock.now + .seconds(5)
  while !condition(), ContinuousClock.now < deadline { await Task.yield() }
  #expect(condition())
}
private actor ResumeGate: PermissionGate {
  let approve: Bool
  var calls = 0
  init(approve: Bool) { self.approve = approve }
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    calls += 1
    return approve ? .approved : .denied
  }
}
