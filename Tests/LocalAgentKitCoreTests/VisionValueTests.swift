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
  @Test func recognizedTextRetainsRegionsAndJoinsInProviderOrder() {
    let box = VisionBoundingBox(x: 0.1, y: 0.2, width: 0.5, height: 0.1)
    let lines = [
      VisionTextObservation(text: "Café", confidence: 0.9, boundingBox: box),
      VisionTextObservation(text: "42.50", confidence: 0.8, boundingBox: box),
    ]
    let result = VisionResult(recognizedText: lines)
    #expect(result.text == "Café\n42.50")
    #expect(result.recognizedText == lines)
    #expect(result.classifications.isEmpty)
    #expect(result.recognizedText[0].boundingBox.y == 0.2)
    #expect(VisionResult().text.isEmpty)
  }

  @Test func locatedObjectsKeepDetectionAndLabelConfidencesSeparate() {
    let object = VisionObjectObservation(
      labels: [.init(identifier: "person", confidence: 0.9)], confidence: 0.8,
      boundingBox: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    let result = VisionResult(detectedObjects: [object])
    #expect(result.detectedObjects == [object])
    #expect(result.detectedObjects[0].confidence == 0.8)
    #expect(result.detectedObjects[0].labels[0].confidence == 0.9)
    #expect(result.text.isEmpty && result.classifications.isEmpty)
    #expect(VisionResult().detectedObjects.isEmpty)
  }

  @Test func structuredDocumentsPreserveMergedSpansAndJoinedText() {
    let box = VisionBoundingBox(x: 0, y: 0, width: 1, height: 1)
    let cell = VisionDocumentCell(
      text: "Merged", rowRange: 0...1, columnRange: 0...0, boundingBox: box)
    let table = VisionDocumentTable(rowCount: 2, columnCount: 1, cells: [cell], boundingBox: box)
    let document = VisionDocumentObservation(
      text: "Café", title: "Title", paragraphs: ["Café"], tables: [table],
      confidence: 1, boundingBox: box)
    let result = VisionResult(documents: [document, document])
    #expect(result.text == "Café\nCafé")
    #expect(result.documents[0].tables[0].cells[0].rowRange == 0...1)
    #expect(result.documents[0].title == "Title")
    #expect(VisionResult().documents.isEmpty)
  }

}
