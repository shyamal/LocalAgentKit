import Foundation
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import Testing

@testable import DemoSetup

private func voiceAudio() -> AudioOutput {
  var data = Data()
  func word(_ value: UInt32, bytes: Int) {
    for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
  }
  data.append(contentsOf: "RIFF".utf8)
  word(38, bytes: 4)
  data.append(contentsOf: "WAVEfmt ".utf8)
  word(16, bytes: 4)
  word(1, bytes: 2)
  word(1, bytes: 2)
  word(16000, bytes: 4)
  word(32000, bytes: 4)
  word(2, bytes: 2)
  word(16, bytes: 2)
  data.append(contentsOf: "data".utf8)
  word(2, bytes: 4)
  word(0, bytes: 2)
  return AudioOutput(data: data, sampleRate: 16000, channelCount: 1, frameCount: 1)
}

@MainActor private final class VoicePlaybackProbe {
  var played: [AudioOutput] = []
  var stops = 0
  var fail = false
  func play(_ audio: AudioOutput) throws {
    if fail { throw AgentError.speechFailure("Playback unavailable") }
    played.append(audio)
  }
}

private actor VoiceLatch {
  var entered = false
  var released = false
  var waiter: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    if !released { await withCheckedContinuation { waiter = $0 } }
  }
  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

private struct LateVoiceRecognizer: SpeechRecognizer {
  let gate: VoiceLatch
  func transcribe(audio: AudioInput) async throws -> String {
    await gate.wait()
    return "old question"
  }
}

private struct LateVoiceSynthesizer: SpeechSynthesizer {
  let gate: VoiceLatch
  func synthesize(text: String) async throws -> AudioOutput {
    await gate.wait()
    return voiceAudio()
  }
}

@MainActor @Suite struct VoiceSessionTests {
  private func controller(
    model: any LocalModelProvider, playback: VoicePlaybackProbe,
    recognizer: any SpeechRecognizer = MockSpeechRecognizer { _ in "original question" },
    synthesizer: any SpeechSynthesizer = MockSpeechSynthesizer { _ in voiceAudio() }
  ) throws -> VoiceController {
    try VoiceController(
      recognizer: recognizer, synthesizer: synthesizer,
      makeRuntime: { try VoiceSession.runtime(model: model) },
      play: { try playback.play($0) }, stop: { playback.stops += 1 })
  }

  @Test func reviewedTranscriptFlowsThroughRuntimeThenSynthesisAndPlayback() async throws {
    let model = ScriptedModelProvider(responses: [.text("Four.")])
    let playback = VoicePlaybackProbe()
    let speech = MockSpeechSynthesizer { _ in voiceAudio() }
    let controller = try controller(model: model, playback: playback, synthesizer: speech)
    await controller.transcribe(AudioInput(data: voiceAudio().data)).value
    #expect(controller.stage == .reviewing)
    #expect(await model.requests.isEmpty)
    #expect(await speech.inputs.isEmpty)
    controller.transcript = "What is two plus two?"
    try await #require(controller.askAndSpeak()).value
    #expect(controller.response == "Four.")
    #expect(controller.submittedQuestion == "What is two plus two?")
    #expect(controller.stage == .completed)
    #expect(await speech.inputs == ["Four."])
    #expect(playback.played == [voiceAudio()])
    let requests = await model.requests
    #expect(requests.count == 1)
    #expect(requests[0].messages.contains { $0.content.contains("What is two plus two?") })
  }

  @Test func emptyInputAndEmptyTranscriptsCannotReachTheModel() async throws {
    let model = MockModelProvider()
    let playback = VoicePlaybackProbe()
    let recognizer = MockSpeechRecognizer { _ in "   " }
    let controller = try controller(model: model, playback: playback, recognizer: recognizer)
    await controller.transcribe(AudioInput(data: Data())).value
    #expect(await recognizer.inputs.isEmpty)
    await controller.transcribe(AudioInput(data: voiceAudio().data)).value
    #expect(controller.transcript.isEmpty && controller.failure != nil)
    #expect(controller.askAndSpeak() == nil)
    #expect(await model.requests.isEmpty && playback.played.isEmpty)
  }

  @Test func modelRefusalIsNotSpokenOrRetried() async throws {
    let model = ScriptedModelProvider([
      .fail(.guardrailRefusal(GuardrailRefusal(explanation: "declined")))
    ])
    let playback = VoicePlaybackProbe()
    let synthesizer = MockSpeechSynthesizer { _ in voiceAudio() }
    let controller = try controller(model: model, playback: playback, synthesizer: synthesizer)
    controller.transcript = "question"
    try await #require(controller.askAndSpeak()).value
    #expect(controller.response.isEmpty && controller.failure != nil)
    #expect(await model.requests.count == 1)
    #expect(await synthesizer.inputs.isEmpty && playback.played.isEmpty)
  }

  @Test func playbackFailureRetainsTextAndReplayDoesNotRunTheModelAgain() async throws {
    let model = ScriptedModelProvider(responses: [.text("Answer.")])
    let playback = VoicePlaybackProbe()
    playback.fail = true
    let controller = try controller(model: model, playback: playback)
    controller.transcript = "question"
    try await #require(controller.askAndSpeak()).value
    #expect(controller.response == "Answer." && controller.failure != nil)
    playback.fail = false
    try await #require(controller.replay()).value
    #expect(controller.stage == .completed && playback.played.count == 1)
    #expect(await model.requests.count == 1)
  }

  @Test func aLateRecognizerCannotRestoreTextAfterCancellation() async throws {
    let gate = VoiceLatch()
    let playback = VoicePlaybackProbe()
    let controller = try controller(
      model: MockModelProvider(), playback: playback, recognizer: LateVoiceRecognizer(gate: gate))
    let task = controller.transcribe(AudioInput(data: voiceAudio().data))
    while !(await gate.entered) { await Task.yield() }
    controller.cancel(clearText: true)
    await gate.release()
    await task.value
    #expect(
      controller.transcript.isEmpty && controller.response.isEmpty
        && controller.submittedQuestion.isEmpty)
    #expect(controller.stage == .idle && playback.played.isEmpty)
  }

  @Test func cancelledLateSynthesisCannotStartPlayback() async throws {
    let gate = VoiceLatch()
    let playback = VoicePlaybackProbe()
    let model = ScriptedModelProvider(responses: [.text("Answer.")])
    let controller = try controller(
      model: model, playback: playback, synthesizer: LateVoiceSynthesizer(gate: gate))
    controller.transcript = "question"
    let task = try #require(controller.askAndSpeak())
    while !(await gate.entered) { await Task.yield() }
    controller.cancel()
    await gate.release()
    await task.value
    #expect(playback.played.isEmpty && controller.stage == .reviewing)
    #expect(controller.response == "Answer.")
  }

  @Test func longAnswersAreReadableButNeverSilentlyTruncatedForSpeech() async throws {
    let answer = String(repeating: "a", count: 2001)
    let model = ScriptedModelProvider(responses: [.text(answer)])
    let playback = VoicePlaybackProbe()
    let controller = try controller(model: model, playback: playback)
    controller.transcript = "question"
    try await #require(controller.askAndSpeak()).value
    #expect(controller.response == answer && controller.failure != nil)
    #expect(playback.played.isEmpty)
  }

  @Test func networkRequiringSpeechIsRejectedBeforeUse() throws {
    let playback = VoicePlaybackProbe()
    #expect(throws: AgentError.self) {
      try controller(
        model: MockModelProvider(), playback: playback,
        recognizer: MockSpeechRecognizer(requiresNetwork: true))
    }
    #expect(throws: AgentError.self) {
      try controller(
        model: MockModelProvider(), playback: playback,
        synthesizer: MockSpeechSynthesizer(requiresNetwork: true) { _ in voiceAudio() })
    }
  }
}
