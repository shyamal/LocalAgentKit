import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@Suite struct MockSpeechRecognizerTests {
  @Test func recordsAudioAndReturnsScriptedText() async throws {
    let input = AudioInput(data: Data([1]))
    let recognizer = MockSpeechRecognizer(requiresNetwork: true) { audio in
      #expect(audio == input)
      return "Scripted"
    }
    #expect(recognizer.requiresNetwork)
    #expect(try await recognizer.transcribe(audio: input) == "Scripted")
    #expect(await recognizer.inputs == [input])
    #expect(try await MockSpeechRecognizer().transcribe(audio: input).isEmpty)
  }

  @Test func errorsAndCancellationRemainTyped() async {
    for mode in 0..<3 {
      let recognizer = MockSpeechRecognizer { _ in
        switch mode {
        case 0: throw CocoaError(.fileReadCorruptFile)
        case 1: throw AgentError.speechFailure("scripted")
        default:
          withUnsafeCurrentTask { $0?.cancel() }
          return "Late"
        }
      }
      let expected: AgentError =
        mode == 2
        ? .cancelled : .speechFailure(mode == 0 ? "Mock speech recognition failed" : "scripted")
      await #expect(throws: expected) {
        try await Task { try await recognizer.transcribe(audio: AudioInput(data: Data())) }.value
      }
    }
  }
}
