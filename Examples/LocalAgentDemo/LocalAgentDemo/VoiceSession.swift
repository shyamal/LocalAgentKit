import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import Observation

struct VoiceSession {
  static func runtime(model: any LocalModelProvider) throws -> AgentRuntime {
    try AgentRuntime(
      configuration: AgentConfiguration(
        model: model,
        limits: ExecutionLimits(
          maxIterations: 2, maxToolCalls: 0, maxDuration: .seconds(45),
          maxModelCallDuration: .seconds(30))),
      tools: StaticToolSource([]),
      planner: StateMachinePlanner(
        workflow: Workflow(
          name: "voice-answer", description: "Answer a spoken question",
          steps: [
            .respond(
              instruction:
                "Answer the user's question briefly in at most two short sentences suitable for speaking aloud. No formatting."
            )
          ])))
  }
}

@MainActor @Observable final class VoiceController {
  enum Stage: String {
    case idle, transcribing, reviewing, thinking, synthesizing, playing, completed
  }
  var transcript = ""
  private(set) var response = ""
  private(set) var submittedQuestion = ""
  private(set) var stage: Stage = .idle
  private(set) var failure: String?
  var busy: Bool { [.transcribing, .thinking, .synthesizing, .playing].contains(stage) }
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var runtime: AgentRuntime?
  @ObservationIgnored private var revision = UUID()
  private let recognizer: any SpeechRecognizer
  private let synthesizer: any SpeechSynthesizer
  private let makeRuntime: @Sendable () throws -> AgentRuntime
  private let play: @MainActor @Sendable (AudioOutput) async throws -> Void
  private let stop: @MainActor @Sendable () -> Void

  init(
    recognizer: any SpeechRecognizer, synthesizer: any SpeechSynthesizer,
    makeRuntime: @escaping @Sendable () throws -> AgentRuntime,
    play: @escaping @MainActor @Sendable (AudioOutput) async throws -> Void,
    stop: @escaping @MainActor @Sendable () -> Void
  ) throws {
    guard !recognizer.requiresNetwork, !synthesizer.requiresNetwork else {
      throw AgentError.invalidConfiguration(
        .networkRequiredButForbidden(component: "voice speech providers"))
    }
    self.recognizer = recognizer
    self.synthesizer = synthesizer
    self.makeRuntime = makeRuntime
    self.play = play
    self.stop = stop
  }

  @discardableResult func transcribe(_ audio: AudioInput) -> Task<Void, Never> {
    cancel(clearText: true)
    stage = .transcribing
    let token = revision
    let task = Task {
      do {
        guard !audio.data.isEmpty, audio.data.count <= 2 * 1024 * 1024 else {
          throw AgentError.speechFailure("Choose a recording up to 2 MiB and 15 seconds.")
        }
        let text = try await recognizer.transcribe(audio: audio)
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1000, trimmed.utf8.count <= 4000 else {
          throw AgentError.speechFailure(
            "No usable short transcript was recognized. Please try again.")
        }
        guard revision == token else { return }
        transcript = trimmed
        stage = .reviewing
      } catch {
        guard revision == token else { return }
        stage = .idle
        if !Task.isCancelled { failure = String(describing: error) }
      }
      guard revision == token else { return }
      self.task = nil
    }
    self.task = task
    return task
  }

  @discardableResult func askAndSpeak() -> Task<Void, Never>? {
    guard !busy else { return nil }
    let question = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, question.count <= 1000, question.utf8.count <= 4000 else {
      failure = "Review a question of up to 1,000 characters before asking."
      return nil
    }
    cancel()
    response = ""
    submittedQuestion = question
    stage = .thinking
    let token = revision
    let task = Task {
      do {
        let runtime = try makeRuntime()
        self.runtime = runtime
        let answer = try await runtime.run(question)
        try Task.checkCancellation()
        guard revision == token else { return }
        response = answer.text
        self.runtime = nil
        try await speak(answer.text, token: token)
      } catch {
        guard revision == token else { return }
        stage = .reviewing
        if !Task.isCancelled { failure = String(describing: error) }
      }
      guard revision == token else { return }
      runtime = nil
      self.task = nil
    }
    self.task = task
    return task
  }

  @discardableResult func replay() -> Task<Void, Never>? {
    guard !busy, !response.isEmpty else { return nil }
    let text = response
    cancel()
    let token = revision
    let task = Task {
      do { try await speak(text, token: token) } catch {
        guard revision == token else { return }
        stage = .reviewing
        if !Task.isCancelled { failure = String(describing: error) }
      }
      guard revision == token else { return }
      self.task = nil
    }
    self.task = task
    return task
  }

  private func speak(_ text: String, token: UUID) async throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000 else {
      throw AgentError.speechFailure(
        "The answer cannot be spoken within this demo's text limit; read it below.")
    }
    stage = .synthesizing
    let audio = try await synthesizer.synthesize(text: text)
    try Task.checkCancellation()
    guard revision == token else { return }
    stage = .playing
    try await play(audio)
    try Task.checkCancellation()
    guard revision == token else { return }
    stage = .completed
  }

  func cancel(clearText: Bool = false) {
    revision = UUID()
    task?.cancel()
    if let runtime { Task { await runtime.cancelCurrentRun() } }
    task = nil
    runtime = nil
    stop()
    failure = nil
    if clearText {
      transcript = ""
      response = ""
      submittedQuestion = ""
    }
    stage = transcript.isEmpty ? .idle : .reviewing
  }
}
