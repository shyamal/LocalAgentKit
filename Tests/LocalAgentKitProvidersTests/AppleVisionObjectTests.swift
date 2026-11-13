import Foundation
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitProviders

@Suite struct AppleVisionObjectTests {
  typealias Options = AppleVisionProvider.ObjectDetectionConfiguration

  static func object(_ label: String, confidence: Float = 0.8) -> VisionObjectObservation {
    .init(
      labels: [.init(identifier: label, confidence: 0.9)], confidence: confidence,
      boundingBox: .init(x: 0.1, y: 0.2, width: 0.4, height: 0.3))
  }

  @Test func forwardsTargetsAndOrientationAndPreservesLocatedLabels() async throws {
    let options = try Options(targets: [.animals], minimumConfidence: 0.5, resultLimit: 2)
    let object = Self.object("Dog")
    let provider = try AppleVisionProvider(objectDetection: options) { image, received in
      #expect(received == options && image.orientation == .right)
      return [object, Self.object("Cat", confidence: 0.1)]
    }
    let data = try AppleVisionProviderTests.imageData(orientation: .right)
    let result = try await provider.analyze(image: ImageInput(data: data))
    #expect(result.detectedObjects == [object])
    #expect(result.classifications.isEmpty && result.recognizedText.isEmpty)
    #expect(!provider.requiresNetwork)
  }

  @Test func inclusiveThresholdAndStableTiesApplyBeforeResultLimit() async throws {
    let options = try Options(minimumConfidence: 0.8, resultLimit: 2)
    let first = Self.object("first")
    let second = Self.object("second")
    let provider = try AppleVisionProvider(objectDetection: options) { _, _ in
      [Self.object("below", confidence: 0.79), first, second, Self.object("last")]
    }
    let data = try AppleVisionProviderTests.imageData()
    #expect(
      try await provider.analyze(image: ImageInput(data: data)).detectedObjects == [first, second])
    let ranked = try AppleVisionProvider(objectDetection: options) { _, _ in
      [first, Self.object("higher", confidence: 1), second]
    }
    #expect(
      try await ranked.analyze(image: ImageInput(data: data)).detectedObjects.map {
        $0.labels[0].identifier
      } == ["higher", "first"])
  }

  @Test func emptyAndFilteredResultsAreSuccessful() async throws {
    let data = try AppleVisionProviderTests.imageData()
    for objects in [[], [Self.object("below", confidence: 0.1)]] {
      let provider = try AppleVisionProvider(
        objectDetection: Options(minimumConfidence: 0.5)
      ) { _, _ in objects }
      #expect(try await provider.analyze(image: ImageInput(data: data)) == VisionResult())
    }
  }

  @Test func invalidDetectorConfigurationFailsAtConstruction() {
    for (targets, score, limit) in [
      (Set<Options.Target>(), Float(0), 1), ([.people], Float.nan, 1),
      ([.animals], Float(-0.1), 1), ([.people], Float(1.1), 1), ([.animals], Float(0), 0),
    ] {
      #expect(
        throws: AgentError.invalidConfiguration(
          .invalidLimit("Invalid object detection configuration"))
      ) {
        try Options(targets: targets, minimumConfidence: score, resultLimit: limit)
      }
    }
  }

  @Test func malformedObjectsFailEvenBelowTheConfidenceCutoff() async throws {
    let valid = Self.object("Dog")
    let invalid = [
      VisionObjectObservation(labels: [], confidence: 0.1, boundingBox: valid.boundingBox),
      .init(
        labels: [.init(identifier: "", confidence: 1)], confidence: 0.1,
        boundingBox: valid.boundingBox),
      .init(
        labels: [.init(identifier: "bad", confidence: .nan)], confidence: 0.1,
        boundingBox: valid.boundingBox),
      .init(labels: valid.labels, confidence: .nan, boundingBox: valid.boundingBox),
      .init(labels: valid.labels, confidence: -1, boundingBox: valid.boundingBox),
      .init(labels: valid.labels, confidence: 2, boundingBox: valid.boundingBox),
      .init(
        labels: valid.labels, confidence: 0.1,
        boundingBox: .init(x: 0, y: 0.9, width: 1, height: 0.2)),
    ]
    let data = try AppleVisionProviderTests.imageData()
    for object in invalid {
      let provider = try AppleVisionProvider(
        objectDetection: Options(minimumConfidence: 0.9)
      ) { _, _ in [object] }
      await #expect(throws: AgentError.visionFailure("Vision returned invalid object observations"))
      {
        try await provider.analyze(image: ImageInput(data: data))
      }
    }
  }

  @Test func imageAdmissionStopsDetectionBeforeNativeWork() async throws {
    let provider = try AppleVisionProvider(
      objectDetection: Options(), maximumPixels: 31
    ) { _, _ in
      Issue.record("Invalid input reached detection")
      return []
    }
    let data = try AppleVisionProviderTests.imageData()
    await #expect(
      throws: AgentError.visionFailure("Image is unreadable or exceeds the pixel limit")
    ) {
      try await provider.analyze(image: ImageInput(data: data))
    }
  }

  @Test func errorsStayTypedAndCancelledCallsCannotPublishDetections() async throws {
    let data = try AppleVisionProviderTests.imageData()
    let broken = try AppleVisionProvider(objectDetection: Options()) { _, _ in
      throw CocoaError(.fileReadCorruptFile)
    }
    await #expect(throws: AgentError.visionFailure("Object detection failed")) {
      try await broken.analyze(image: ImageInput(data: data))
    }
    let typed = try AppleVisionProvider(objectDetection: Options()) { _, _ in
      throw AgentError.visionFailure("scripted detection failure")
    }
    await #expect(throws: AgentError.visionFailure("scripted detection failure")) {
      try await typed.analyze(image: ImageInput(data: data))
    }
    let cancelled = try AppleVisionProvider(objectDetection: Options()) { _, _ in
      throw CancellationError()
    }
    await #expect(throws: AgentError.cancelled) {
      try await cancelled.analyze(image: ImageInput(data: data))
    }
    for cancelBefore in [true, false] {
      let provider = try AppleVisionProvider(objectDetection: Options()) { _, _ in
        #expect(!cancelBefore)
        withUnsafeCurrentTask { $0?.cancel() }
        return [Self.object("late")]
      }
      let task = Task {
        if cancelBefore { withUnsafeCurrentTask { $0?.cancel() } }
        return try await provider.analyze(image: ImageInput(data: data))
      }
      await #expect(throws: AgentError.cancelled) { try await task.value }
    }
  }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEVICE_TESTS"] == "1"))
struct AppleVisionObjectNativeTests {
  @Test(arguments: [
    Set<AppleVisionProvider.ObjectDetectionConfiguration.Target>([.people]),
    [.animals], [.people, .animals],
  ])
  func blankImageRunsEachNativeDetectorAndTheirCombination(
    targets: Set<AppleVisionProvider.ObjectDetectionConfiguration.Target>
  ) async throws {
    let provider = try AppleVisionProvider(objectDetection: .init(targets: targets))
    let data = try AppleVisionOCRTests.imageData(lines: [])
    let result = try await provider.analyze(image: ImageInput(data: data))
    #expect(result.detectedObjects.isEmpty)
  }
}
