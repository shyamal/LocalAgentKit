import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private actor CancellationProbe {
  private var started = false
  private var cancelled = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var cancelWaiter: CheckedContinuation<Void, Never>?
  func suspend() async throws {
    started = true
    startWaiter?.resume()
    startWaiter = nil
    do { try await Task.sleep(for: .seconds(60)) } catch {
      cancelled = true
      cancelWaiter?.resume()
      cancelWaiter = nil
      throw error
    }
  }
  func awaitStart() async {
    if !started { await withCheckedContinuation { startWaiter = $0 } }
  }
  func awaitCancellation() async {
    if !cancelled { await withCheckedContinuation { cancelWaiter = $0 } }
  }
}

private func cancellationWorkflow() -> StateMachinePlanner {
  StateMachinePlanner(
    workflow: Workflow(
      name: "source", description: "Use source",
      steps: [
        .tool("write", "Write source", "write", ["text": .input(attachment: 0, path: "text")])
      ]))
}

private func cancellationTool() -> MockTool {
  MockTool(
    name: "write",
    schema: ToolSchema(
      parameters: [
        "text": ToolParameter(.string, description: "Source")
      ], required: ["text"]), permission: .userConfirmation)
}

@Suite struct MultimodalCancellationTests {
  @Test(arguments: [true, false])
  func explicitRuntimeCancellationReachesAnActiveInputProvider(image: Bool) async throws {
    let probe = CancellationProbe()
    let model = ScriptedModelProvider(responses: [])
    let vision = MockVisionProvider { _ in
      try await probe.suspend()
      return VisionResult()
    }
    let speech = MockSpeechRecognizer { _ in
      try await probe.suspend()
      return "late"
    }
    let tool = cancellationTool()
    let memory = ConversationMemory()
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model, vision: vision, speechRecognizer: speech),
      tools: StaticToolSource([tool]), planner: cancellationWorkflow(), memory: memory)
    let events = await runtime.events()
    let attachment: AgentInput.Attachment =
      image
      ? .image(ImageInput(data: Data([1]))) : .audio(AudioInput(data: Data([2])))
    let run = Task {
      try await runtime.run(AgentInput(text: "Use source", attachments: [attachment]))
    }
    await probe.awaitStart()
    await runtime.cancelCurrentRun()
    await #expect(throws: AgentError.cancelled) { try await run.value }
    await probe.awaitCancellation()
    #expect(await model.requests.isEmpty)
    #expect(await tool.executions.isEmpty)
    #expect(await memory.history().isEmpty)
    await runtime.finishEvents()
    var processed: [Int] = []
    var errors: [AgentError] = []
    var completed = false
    for await event in events {
      if case .inputProcessingProgress(let count, _) = event { processed.append(count) }
      if case .error(let error) = event { errors.append(error) }
      if case .completed = event { completed = true }
    }
    #expect(processed == [0])
    #expect(errors == [.cancelled])
    #expect(!completed)
  }

  @Test func cancellationWhileAwaitingInputToolApprovalInvalidatesTheOldRequest() async throws {
    let tool = cancellationTool()
    let model = ScriptedModelProvider(responses: [])
    let memory = ConversationMemory()
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model),
      tools: StaticToolSource([tool]), planner: cancellationWorkflow(), memory: memory)
    let input = AgentInput(
      text: "Write", attachments: [.document(Document(title: "", text: "source"))])
    let events = await runtime.events()
    let first = Task { try await runtime.run(input) }
    var oldCallID: String?
    for await event in events {
      if case .permissionRequired(let call) = event {
        oldCallID = call.id
        break
      }
      if case .error = event { break }
    }
    let callID = try #require(oldCallID)
    first.cancel()
    await #expect(throws: AgentError.cancelled) { try await first.value }
    #expect(!(await runtime.resolvePermission(callID: callID, approved: true)))
    #expect(await tool.executions.isEmpty)
    #expect(await memory.history().isEmpty)
    // A fresh run still requires its own approval after cancellation has fully returned.
    let nextEvents = await runtime.events()
    let next = Task { try await runtime.run(input) }
    var sawNewApproval = false
    for await event in nextEvents {
      if case .permissionRequired(let call) = event {
        sawNewApproval = true
        #expect(call.id != callID)
        #expect(!(await runtime.resolvePermission(callID: callID, approved: true)))
        #expect(await tool.executions.isEmpty)
        #expect(await runtime.resolvePermission(callID: call.id, approved: true))
        break
      }
      if case .error = event { break }
    }
    #expect(sawNewApproval)
    _ = try await next.value
    #expect(await tool.executions.count == 1)
    #expect(await model.requests.isEmpty)
    await runtime.finishEvents()
  }
}
