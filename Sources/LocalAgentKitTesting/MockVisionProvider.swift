import LocalAgentKitCore

/// Records image analysis calls and returns an injected result without loading native model assets.
public actor MockVisionProvider: VisionProvider {
  /// Explicit network declaration for host-policy tests.
  public nonisolated let requiresNetwork: Bool
  private let handler: @Sendable (ImageInput) async throws -> VisionResult
  private var images: [ImageInput] = []

  /// Creates a mock that returns an empty result by default.
  public init(
    requiresNetwork: Bool = false,
    handler: @escaping @Sendable (ImageInput) async throws -> VisionResult = { _ in VisionResult() }
  ) {
    self.requiresNetwork = requiresNetwork
    self.handler = handler
  }

  /// Images received by calls that were not already cancelled.
  public var inputs: [ImageInput] { images }

  /// Records the input and checks cancellation before and after the handler.
  public func analyze(image: ImageInput) async throws -> VisionResult {
    do {
      try Task.checkCancellation()
      images.append(image)
      let result = try await handler(image)
      try Task.checkCancellation()
      return result
    } catch {
      if Task.isCancelled || error is CancellationError { throw AgentError.cancelled }
      if let error = error as? AgentError { throw error }
      throw AgentError.visionFailure("Mock image analysis failed")
    }
  }
}
