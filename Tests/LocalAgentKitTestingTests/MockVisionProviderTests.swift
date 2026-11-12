import Foundation
import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@Suite struct MockVisionProviderTests {
  @Test func recordsInputsAndReturnsScriptedResult() async throws {
    let result = VisionResult(classifications: [.init(identifier: "document", confidence: 0.9)])
    let image = ImageInput(data: Data([1]), orientation: .left)
    let provider = MockVisionProvider(requiresNetwork: true) { input in
      #expect(input == image)
      return result
    }
    #expect(provider.requiresNetwork)
    #expect(try await provider.analyze(image: image) == result)
    #expect(await provider.inputs == [image])
    #expect(try await MockVisionProvider().analyze(image: image) == VisionResult())
  }

  @Test func foreignAndTypedFailuresAreReportedAsAgentErrors() async {
    for typed in [true, false] {
      let provider = MockVisionProvider { _ in
        if typed { throw AgentError.visionFailure("scripted") }
        throw CocoaError(.fileReadCorruptFile)
      }
      await #expect(
        throws: AgentError.visionFailure(typed ? "scripted" : "Mock image analysis failed")
      ) {
        try await provider.analyze(image: ImageInput(data: Data()))
      }
    }
  }

  @Test func cancellationPreventsOrDiscardsHandlerWork() async {
    for cancelBefore in [true, false] {
      let provider = MockVisionProvider { _ in
        #expect(!cancelBefore)
        withUnsafeCurrentTask { $0?.cancel() }
        return VisionResult()
      }
      let task = Task {
        if cancelBefore { withUnsafeCurrentTask { $0?.cancel() } }
        return try await provider.analyze(image: ImageInput(data: Data()))
      }
      await #expect(throws: AgentError.cancelled) { try await task.value }
      #expect(await provider.inputs.count == (cancelBefore ? 0 : 1))
    }
  }
}
