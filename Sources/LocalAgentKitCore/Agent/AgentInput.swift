/// A goal and host-authorized attachments, normalized by the runtime before planning.
public struct AgentInput: Sendable, Hashable {
  /// Supported attachment values. File access and capture remain host responsibilities.
  public enum Attachment: Sendable, Hashable {
    /// Encoded image processed by the configured VisionProvider.
    case image(ImageInput)
    /// Encoded recording processed by the configured SpeechRecognizer.
    case audio(AudioInput)
    /// Already-extracted document text, such as output from Tools' DocumentExtractor.
    case document(Document)
  }

  /// User request. Empty text with attachments uses a generic analysis request.
  public let text: String
  /// Attachments in host-specified order.
  public let attachments: [Attachment]

  /// Creates a text, attachment-only or combined input.
  public init(text: String = "", attachments: [Attachment] = []) {
    self.text = text
    self.attachments = attachments
  }
}

/// Admission and normalization limits. Context budgeting separately fits extracted excerpts.
public struct AgentInputLimits: Sendable, Hashable {
  /// Maximum attachments per run; zero permits only text.
  public var maximumAttachments: Int
  /// Aggregate encoded image/audio and document title/text UTF-8 bytes.
  public var maximumBytes: Int
  /// Aggregate normalized excerpt UTF-8 bytes, including source labels.
  public var maximumExtractedBytes: Int

  /// Defaults to four attachments, 16 MiB source bytes and 64 KiB extracted excerpts.
  public init(
    maximumAttachments: Int = 4, maximumBytes: Int = 16 * 1024 * 1024,
    maximumExtractedBytes: Int = 64 * 1024
  ) {
    self.maximumAttachments = maximumAttachments
    self.maximumBytes = maximumBytes
    self.maximumExtractedBytes = maximumExtractedBytes
  }

  /// Invalid settings rejected when constructing a runtime.
  public var issue: ConfigurationIssue? {
    guard maximumAttachments >= 0, maximumBytes > 0, maximumExtractedBytes > 0 else {
      return .invalidLimit("Invalid multimodal input limits")
    }
    return nil
  }
}
