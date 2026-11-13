import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@Suite struct MockSpeechSynthesizerTests {
  @Test func recordsTextAndReturnsScriptedAudio() async throws {
    let audio = AudioOutput(data: Data([1]), sampleRate: 16_000, channelCount: 1, frameCount: 1)
    let provider = MockSpeechSynthesizer(requiresNetwork: true) { _ in audio }
    #expect(provider.requiresNetwork)
    #expect(try await provider.synthesize(text: "Hello") == audio)
    #expect(await provider.inputs == ["Hello"])
  }

  @Test func typedErrorsAndLateCancellationArePreserved() async {
    for mode in 0..<3 {
      let provider = MockSpeechSynthesizer { _ in
        if mode == 0 { throw CocoaError(.fileReadCorruptFile) }
        if mode == 1 { throw AgentError.speechFailure("scripted") }
        withUnsafeCurrentTask { $0?.cancel() }
        return AudioOutput(data: Data(), sampleRate: 16_000, channelCount: 1, frameCount: 0)
      }
      let expected: AgentError =
        mode == 2
        ? .cancelled : .speechFailure(mode == 0 ? "Mock speech synthesis failed" : "scripted")
      await #expect(throws: expected) {
        try await Task { try await provider.synthesize(text: "Hello") }.value
      }
    }
  }
}
