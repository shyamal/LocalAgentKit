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
  @Test func mockCanReturnOCRThroughTheExistingProtocol() async throws {
    let result = VisionResult(recognizedText: [
      VisionTextObservation(
        text: "Scripted receipt", confidence: 1,
        boundingBox: .init(x: 0, y: 0, width: 1, height: 1))
    ])
    let provider: any VisionProvider = MockVisionProvider { _ in result }
    #expect(try await provider.analyze(image: ImageInput(data: Data())).text == "Scripted receipt")
  }

  @Test func mockCanReturnLocatedObjectsThroughTheExistingProtocol() async throws {
    let object = VisionObjectObservation(
      labels: [.init(identifier: "Dog", confidence: 0.9)], confidence: 0.8,
      boundingBox: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    let provider: any VisionProvider = MockVisionProvider { _ in
      VisionResult(detectedObjects: [object])
    }
    let result = try await provider.analyze(image: ImageInput(data: Data()))
    #expect(result.detectedObjects == [object])
  }

  @Test func mockCanReturnStructuredDocumentsThroughTheExistingProtocol() async throws {
    let document = VisionDocumentObservation(
      text: "Invoice", confidence: 1, boundingBox: .init(x: 0, y: 0, width: 1, height: 1))
    let provider: any VisionProvider = MockVisionProvider { _ in VisionResult(documents: [document])
    }
    let result = try await provider.analyze(image: ImageInput(data: Data()))
    #expect(result.documents == [document])
    #expect(result.text == "Invoice")
  }

}
