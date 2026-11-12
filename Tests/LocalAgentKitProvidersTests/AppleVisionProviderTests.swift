import CoreGraphics
import Foundation
import ImageIO
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitProviders

@Suite struct AppleVisionProviderTests {
  @Test func validatedImageMapsSortsAndLimitsCategories() async throws {
    let data = try Self.imageData()
    let provider = try AppleVisionProvider(resultLimit: 2) { image in
      #expect(image.data == data && image.orientation == .up)
      return [
        .init(identifier: "z", confidence: 0.9), .init(identifier: "a", confidence: 0.9),
        .init(identifier: "low", confidence: 0.2),
      ]
    }
    #expect(!provider.requiresNetwork)
    let result = try await provider.analyze(image: ImageInput(data: data))
    #expect(result.classifications.map(\.identifier) == ["a", "z"])
  }

  @Test func embeddedOrientationAndHostOverrideReachInference() async throws {
    let data = try Self.imageData(orientation: .right)
    for override in [nil, ImageInput.Orientation.left] {
      let provider = try AppleVisionProvider { image in
        #expect(image.orientation == (override ?? .right))
        return []
      }
      #expect(
        try await provider.analyze(image: ImageInput(data: data, orientation: override))
          .classifications.isEmpty)
    }
  }

  @Test func rejectsUnreadableAndOverLimitInputsBeforeInference() async throws {
    let data = try Self.imageData()
    let inputs: [(Data, Int, Int)] = [
      (Data(), 100, 100), (Data([1, 2]), 100, 100),
      (data, data.count - 1, 100), (data, data.count, 31),
    ]
    for (data, bytes, pixels) in inputs {
      let provider = try AppleVisionProvider(maximumBytes: bytes, maximumPixels: pixels) { _ in
        Issue.record("Invalid image reached inference")
        return []
      }
      await #expect(throws: AgentError.self) {
        try await provider.analyze(image: ImageInput(data: data))
      }
    }
    let exact = try AppleVisionProvider(maximumBytes: data.count, maximumPixels: 32) { _ in [] }
    #expect(try await exact.analyze(image: ImageInput(data: data)).classifications.isEmpty)
  }

  @Test func invalidLimitsFailAtConstruction() {
    for limits in [(0, 1, 1), (1, 0, 1), (1, 1, 0)] {
      #expect(
        throws: AgentError.invalidConfiguration(.invalidLimit("Vision limits must be positive"))
      ) {
        try AppleVisionProvider(
          maximumBytes: limits.0, maximumPixels: limits.1, resultLimit: limits.2)
      }
    }
  }

  @Test func rejectsInvalidCategoryValues() async throws {
    let data = try Self.imageData()
    for category in [
      VisionClassification(identifier: "", confidence: 0.5),
      .init(identifier: "invalid", confidence: .nan),
      .init(identifier: "invalid", confidence: -0.1),
      .init(identifier: "invalid", confidence: 1.1),
    ] {
      let provider = try AppleVisionProvider { _ in [category] }
      await #expect(
        throws: AgentError.visionFailure("Vision returned invalid category predictions")
      ) {
        try await provider.analyze(image: ImageInput(data: data))
      }
    }
  }

  @Test func errorsAreTypedAndCancellationDiscardsLateOutput() async throws {
    let data = try Self.imageData()
    let broken = try AppleVisionProvider { _ in throw CocoaError(.fileReadCorruptFile) }
    await #expect(throws: AgentError.visionFailure("Image classification failed")) {
      try await broken.analyze(image: ImageInput(data: data))
    }
    let typed = try AppleVisionProvider { _ in throw AgentError.visionFailure("native failure") }
    await #expect(throws: AgentError.visionFailure("native failure")) {
      try await typed.analyze(image: ImageInput(data: data))
    }
    let cancelled = try AppleVisionProvider { _ in throw CancellationError() }
    await #expect(throws: AgentError.cancelled) {
      try await cancelled.analyze(image: ImageInput(data: data))
    }
    for cancelBefore in [true, false] {
      let provider = try AppleVisionProvider { _ in
        #expect(!cancelBefore)
        withUnsafeCurrentTask { $0?.cancel() }
        return [.init(identifier: "late", confidence: 1)]
      }
      let task = Task {
        if cancelBefore { withUnsafeCurrentTask { $0?.cancel() } }
        return try await provider.analyze(image: ImageInput(data: data))
      }
      await #expect(throws: AgentError.cancelled) { try await task.value }
    }
  }

  /// Generated pixels only; no personal photo or network asset.
  static func imageData(orientation: ImageInput.Orientation = .up) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, image, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEVICE_TESTS"] == "1"))
struct AppleVisionNativeTests {
  @Test func generatedImageRunsThroughNativeVision() async throws {
    let data = try AppleVisionProviderTests.imageData()
    let provider: any VisionProvider = try AppleVisionProvider()
    let result = try await provider.analyze(image: ImageInput(data: data))
    #expect(!result.classifications.isEmpty)
    #expect(result.classifications.count <= 5)
    #expect(result.classifications.allSatisfy { (0...1).contains($0.confidence) })
  }
}
