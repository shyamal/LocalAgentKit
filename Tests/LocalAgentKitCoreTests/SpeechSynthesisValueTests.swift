import Foundation
import LocalAgentKitCore
import Testing

@Suite struct SpeechSynthesisValueTests {
  @Test func audioOutputKeepsWAVBytesAndMetadata() async throws {
    let audio = AudioOutput(data: Data([1]), sampleRate: 16_000, channelCount: 1, frameCount: 1)
    struct Local: SpeechSynthesizer {
      let output: AudioOutput
      func synthesize(text: String) async throws -> AudioOutput { output }
    }
    let provider: any SpeechSynthesizer = Local(output: audio)
    #expect(!provider.requiresNetwork)
    #expect(try await provider.synthesize(text: "Hello") == audio)
    #expect(audio.sampleRate == 16_000 && audio.channelCount == 1 && audio.frameCount == 1)
  }
}
