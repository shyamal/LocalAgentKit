import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import Observation

/// Bridges an `AgentRuntime`'s event stream into observable UI state (FR-020, M1-UI-01).
///
/// This is the only place in the SDK that touches `@MainActor` — everything else is
/// UI-framework-agnostic, so a UIKit host can drive `AgentRuntime` directly and never import this
/// target (FR-020: "The framework should not force developers to use SwiftUI").
@MainActor
@Observable
public final class AgentViewModel {
  /// One line of the chat transcript.
  public struct Turn: Identifiable, Sendable, Equatable {
    /// The user or assistant participant shown in a chat turn.
    public enum Role: Sendable, Equatable {
      /// A message entered by the person using the app.
      case user
      /// An answer produced by the agent.
      case assistant
    }
    /// Stable identity for rendering and incremental answer updates.
    public var id = UUID()
    /// Whether this line represents user input or assistant output.
    public var role: Role
    /// Displayed text, appended as response fragments arrive.
    public var text: String

    /// Creates a display turn with an optional identity for stable UI updates.
    public init(id: UUID = UUID(), role: Role, text: String) {
      self.id = id
      self.role = role
      self.text = text
    }
  }

  /// Where the run is. `.awaitingPermission`/`.awaitingClarification` are exactly the two
  /// suspension points `AgentRuntime` exposes (FR-010); everything a host needs to resolve them
  /// is on `AgentViewModel` itself (`approvePermission()`, `answerClarification(_:)`, …).
  public enum RunState: Sendable, Equatable {
    /// No run is active; a new goal may be sent.
    case idle
    /// The agent is planning, generating or executing.
    case running
    /// The runtime has ended; completed-history bookkeeping or a host callback is finishing.
    case finishing
    /// A tool call is suspended until the person approves or denies it.
    case awaitingPermission(ToolCall)
    /// A run is suspended until the person supplies clarification.
    case awaitingClarification(String)
  }

  private let runtime: AgentRuntime
  private let onRunCompleted: (@Sendable () async throws -> Void)?
  private var sendInProgress = false
  // `deinit` on a `@MainActor` class is itself nonisolated (it may run on any thread), so this
  // can't be a normal isolated stored property if `deinit` is to cancel it. Excluded from
  // `@Observable` tracking too, since it's plumbing, not UI state — and observation tracking
  // cannot wrap a `nonisolated` property anyway. It is written once, in `init`, and read only
  // here and in `deinit`, so there is nothing concurrent to race with `nonisolated(unsafe)`.
  @ObservationIgnored
  private nonisolated(unsafe) var eventTask: Task<Void, Never>?
  private var streamingTurnID: UUID?

  /// User input and assistant output, including any completed turns supplied during restoration.
  public private(set) var turns: [Turn] = []
  /// Current execution or human-input suspension state.
  public private(set) var state: RunState = .idle
  /// The tool currently executing, if any — for "visible tool activity" (M1-UI-03).
  public private(set) var activeTool: ToolCall?
  /// Every tool result observed this session, oldest first.
  public private(set) var toolActivity: [ToolResult] = []
  /// Latest ephemeral task facts, reset when a new run starts.
  public private(set) var workingMemory = WorkingMemory()
  /// Most recently observed model-context measurement, or nil before one arrives.
  public private(set) var contextUtilization: ContextUtilization?
  /// Latest sampled thermal pressure and policy cap; nil when monitoring is not configured.
  public private(set) var thermalStatus: ThermalStatus?
  /// Set when a run or its host completion callback fails, or a guardrail refuses, to surface separately
  /// from the chat transcript. Cleared at the start of the next `send`.
  public private(set) var lastFailure: String?

  /// True while executing, waiting for input or finishing the host completion callback.
  public var isRunning: Bool {
    if sendInProgress { return true }
    if case .idle = state { return false } else { return true }
  }

  /// Connects to a runtime, optionally displaying restored completed turns.
  /// `initialTurns` affects display only; restore the runtime memory separately.
  /// `onRunCompleted` runs only after `runtime.run` returns successfully (including history recording).
  /// Sending remains disabled until it returns; failure is surfaced without rolling back the reply.
  /// The host owns callback storage/network policy. No persistence is enabled by default.
  public init(
    runtime: AgentRuntime, initialTurns: [Turn] = [],
    onRunCompleted: (@Sendable () async throws -> Void)? = nil
  ) {
    self.runtime = runtime
    self.turns = initialTurns
    self.onRunCompleted = onRunCompleted
    eventTask = Task { [weak self] in
      guard let stream = await self?.runtime.events() else { return }
      for await event in stream {
        guard !Task.isCancelled else { break }
        self?.handle(event)
      }
    }
  }

  deinit {
    eventTask?.cancel()
  }

  // MARK: Actions

  /// Starts a run. Ignored while a run is already active.
  public func send(_ goal: String) {
    guard !isRunning else { return }
    lastFailure = nil
    turns.append(Turn(role: .user, text: goal))
    state = .running
    sendInProgress = true
    Task { [runtime, onRunCompleted, weak self] in
      do {
        _ = try await runtime.run(goal)
      } catch {
        self?.finishSend()
        return  // The runtime's terminal event supplies its error/refusal presentation.
      }
      do {
        try await onRunCompleted?()
      } catch {
        self?.lastFailure = "The reply is available, but finishing this turn failed: \(error)"
      }
      self?.finishSend()
    }
  }

  /// Approves the tool currently held for confirmation. Does nothing if none is pending.
  public func approvePermission() {
    guard case .awaitingPermission(let call) = state else { return }
    state = .running
    Task { [runtime] in await runtime.resolvePermission(callID: call.id, approved: true) }
  }

  /// Denies the tool currently held for confirmation. Does nothing if none is pending.
  public func denyPermission() {
    guard case .awaitingPermission(let call) = state else { return }
    state = .running
    Task { [runtime] in await runtime.resolvePermission(callID: call.id, approved: false) }
  }

  /// Answers a pending clarification question. Does nothing if none is pending.
  public func answerClarification(_ text: String) {
    guard case .awaitingClarification = state else { return }
    turns.append(Turn(role: .user, text: text))
    state = .running
    Task { [runtime] in await runtime.answerClarification(text) }
  }

  /// Requests cancellation of the runtime's active run, including human-input waits.
  public func cancel() {
    Task { [runtime] in await runtime.cancelCurrentRun() }
  }

  private func finishSend() {
    sendInProgress = false
    if case .finishing = state { state = .idle }
  }

  // MARK: Event handling

  private func handle(_ event: AgentEvent) {
    switch event {
    case .started:
      state = .running
      streamingTurnID = nil
      workingMemory = WorkingMemory()

    case .workingMemoryUpdated(let memory):
      workingMemory = memory

    case .ingestionProgress, .thinking, .planCreated, .toolRequested, .observationReceived,
      .memoriesRetrieved,
      .memoryRetrievalFailed:
      break

    case .contextUtilization(let utilization):
      contextUtilization = utilization
    case .thermalStateChanged(let status):
      thermalStatus = status

    case .toolStarted(let call):
      activeTool = call

    case .toolCompleted(let result):
      activeTool = nil
      toolActivity.append(result)

    case .permissionRequired(let call):
      state = .awaitingPermission(call)

    case .clarificationRequested(let question):
      discardStreamingTurn()
      state = .awaitingClarification(question)
      turns.append(Turn(role: .assistant, text: question))

    case .responseToken(let token):
      appendStreamingToken(token)

    case .guardrailRefused(let refusal):
      discardStreamingTurn()
      lastFailure = refusal.explanation ?? "I can't help with that."
      turns.append(Turn(role: .assistant, text: lastFailure!))
      state = sendInProgress ? .finishing : .idle
      activeTool = nil

    case .completed(let response):
      if let id = streamingTurnID, let index = turns.firstIndex(where: { $0.id == id }) {
        turns[index].text = response.text
      } else {
        turns.append(Turn(role: .assistant, text: response.text))
      }
      streamingTurnID = nil
      state = sendInProgress ? .finishing : .idle
      activeTool = nil

    case .error(let error):
      discardStreamingTurn()
      lastFailure = String(describing: error)
      streamingTurnID = nil
      state = sendInProgress ? .finishing : .idle
      activeTool = nil
    }
  }

  private func discardStreamingTurn() {
    if let id = streamingTurnID { turns.removeAll { $0.id == id } }
    streamingTurnID = nil
  }

  private func appendStreamingToken(_ token: String) {
    if let id = streamingTurnID, let index = turns.firstIndex(where: { $0.id == id }) {
      turns[index].text += token
    } else {
      let turn = Turn(role: .assistant, text: token)
      streamingTurnID = turn.id
      turns.append(turn)
    }
  }
}
