import Foundation
import LocalAgentKitCore
import Testing

@Suite struct SpeechValueTests {
  @Test func encodedAudioAndErrorCopyHaveNoNativeTypes() {
    let input = AudioInput(data: Data([1, 2]))
    #expect(input.data == Data([1, 2]))
    #expect(input == AudioInput(data: Data([1, 2])))
    #expect(
      AgentError.speechFailure("Invalid audio").description
        == "Could not process speech: Invalid audio")
  }

  @Test func recognitionProtocolDefaultsToLocalProcessing() async throws {
    struct Local: SpeechRecognizer {
      func transcribe(audio: AudioInput) async throws -> String { "" }
    }
    let recognizer: any SpeechRecognizer = Local()
    #expect(!recognizer.requiresNetwork)
    #expect(try await recognizer.transcribe(audio: AudioInput(data: Data())).isEmpty)
  }
}
