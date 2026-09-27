import Foundation
import FoundationModels
import LocalAgentKitCore

/// Maps the framework's errors onto ``AgentError``.
///
/// Three generations of error have to be handled, and this is the one place that does it:
/// `LanguageModelSession.GenerationError` (OS 26), `LanguageModelError` (OS 27, which deprecates
/// the former), and untyped `NSError`s that appear on OS 26 (findings §9b, §9c, §11b, §14).
enum FoundationModelErrors {
  struct Mapped {
    var error: AgentError
    /// Worth one more attempt on a fresh session: the output was malformed, not refused.
    var isRetryable = false
  }

  static func map(_ error: any Error) async -> Mapped {
    if let error = error as? AgentError { return Mapped(error: error) }
    if error is CancellationError { return Mapped(error: .cancelled) }

    if #available(macOS 27, iOS 27, *) {
      if let error = error as? LanguageModelError {
        return await map(error)
      }
      // OS 27 reports malformed output as `ParsingError`; OS 26 reports it as `.decodingFailure`.
      if error is GeneratedContent.ParsingError {
        return Mapped(
          error: .modelUnavailable(reason: "unparseable model output"), isRetryable: true)
      }
    }
    if let error = error as? LanguageModelSession.GenerationError {
      return await map(error)
    }
    if isTokenGenerationFailure(error) {
      return Mapped(error: .contextLimitExceeded)
    }
    return Mapped(error: .modelUnavailable(reason: String(describing: error)))
  }

  // MARK: OS 27

  @available(macOS 27, iOS 27, *)
  private static func map(_ error: LanguageModelError) async -> Mapped {
    switch error {
    case .contextSizeExceeded:
      return Mapped(error: .contextLimitExceeded)
    case .guardrailViolation(let violation):
      return Mapped(
        error: .guardrailRefusal(GuardrailRefusal(explanation: violation.debugDescription)))
    case .refusal(let refusal):
      let explanation = try? await refusal.explanation.content
      return Mapped(error: .guardrailRefusal(GuardrailRefusal(explanation: explanation)))
    case .timeout:
      return Mapped(error: .executionTimeout(.modelCall))
    case .rateLimited, .unsupportedCapability, .unsupportedTranscriptContent,
      .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
      return Mapped(error: .modelUnavailable(reason: String(describing: error)))
    @unknown default:
      return Mapped(error: .modelUnavailable(reason: String(describing: error)))
    }
  }

  // MARK: OS 26

  private static func map(_ error: LanguageModelSession.GenerationError) async -> Mapped {
    switch error {
    case .exceededContextWindowSize:
      return Mapped(error: .contextLimitExceeded)
    case .guardrailViolation(let context):
      return Mapped(
        error: .guardrailRefusal(GuardrailRefusal(explanation: context.debugDescription)))
    case .refusal(let refusal, _):
      let explanation = try? await refusal.explanation.content
      return Mapped(error: .guardrailRefusal(GuardrailRefusal(explanation: explanation)))
    case .decodingFailure:
      return Mapped(error: .modelUnavailable(reason: "undecodable model output"), isRetryable: true)
    case .assetsUnavailable:
      return Mapped(error: .modelUnavailable(reason: "model assets are unavailable"))
    case .rateLimited:
      return Mapped(error: .modelUnavailable(reason: "rate limited"))
    case .concurrentRequests:
      return Mapped(error: .modelUnavailable(reason: "the session was already responding"))
    case .unsupportedGuide, .unsupportedLanguageOrLocale:
      return Mapped(error: .modelUnavailable(reason: String(describing: error)))
    @unknown default:
      return Mapped(error: .modelUnavailable(reason: String(describing: error)))
    }
  }

  /// Over-budget requests fail as a typed context error *or* as an untyped error wrapping
  /// `tokengeneration` code 10 (findings §11b, §14). The typed case is not the only way the
  /// framework reports overflow.
  static func isTokenGenerationFailure(_ error: any Error) -> Bool {
    let text = String(describing: error) + " " + String(describing: (error as NSError).userInfo)
    return text.localizedCaseInsensitiveContains("tokengeneration")
  }
}
