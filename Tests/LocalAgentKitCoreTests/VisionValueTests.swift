import Foundation
import LocalAgentKitCore
import Testing

@Suite struct VisionValueTests {
  @Test func imageOrientationUsesEXIFValuesAndPreservesBytes() {
    let data = Data([1, 2, 3])
    let image = ImageInput(data: data)
    #expect(image.data == data && image.orientation == nil)
    #expect(ImageInput.Orientation.allCases.map(\.rawValue) == Array(1...8).map(UInt32.init))
    #expect(ImageInput(data: data, orientation: .right) != image)
  }

  @Test func categoryResultAndTypedErrorAreUsableWithoutAppleFrameworks() {
    let category = VisionClassification(identifier: "landscape", confidence: 0.75)
    #expect(VisionResult(classifications: [category]).classifications == [category])
    #expect(VisionResult().classifications.isEmpty)
    #expect(
      AgentError.visionFailure("Invalid image").description
        == "Could not analyze the image: Invalid image")
  }

  @Test func protocolDefaultsToLocalAnalysis() async throws {
    struct Local: VisionProvider {
      func analyze(image: ImageInput) async throws -> VisionResult { VisionResult() }
    }
    let provider: any VisionProvider = Local()
    #expect(!provider.requiresNetwork)
    #expect(try await provider.analyze(image: ImageInput(data: Data())).classifications.isEmpty)
  }
}
