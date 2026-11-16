import Foundation
import LocalAgentKitCore

/// Per-run normalized sources, separate from persistent memory.
struct PreparedInput: Sendable {
  var excerpts: [String] = []
  var values: [JSONValue] = []
}

/// Normalizes explicit input without giving providers access to tools or the model.
struct InputPreprocessor {
  let configuration: AgentConfiguration
  let events: EventBus
  let clock: RunClock
  let thermal: ThermalController?

  func process(_ attachments: [AgentInput.Attachment]) async throws -> PreparedInput {
    guard !attachments.isEmpty else { return PreparedInput() }
    try preflight(attachments)
    await events.publish(.inputProcessingProgress(processed: 0, total: attachments.count))
    var groups: [[String]] = []
    var values: [JSONValue] = []
    var structuredRemaining = configuration.inputLimits.maximumStructuredBytes
    var remaining = configuration.inputLimits.maximumExtractedBytes
    for (index, attachment) in attachments.enumerated() {
      try Task.checkCancellation()
      _ = try await thermal?.checkpoint()
      let allowed = await clock.remaining()
      guard allowed > .zero else { throw AgentError.executionTimeout(.run) }
      let configuration = configuration
      let maximumBytes = remaining
      let maximumStructuredBytes = structuredRemaining
      let normalized = try await withDeadline(allowed, scope: .run) {
        try await Self.render(
          attachment, configuration: configuration, maximumBytes: maximumBytes,
          maximumStructuredBytes: maximumStructuredBytes)
      }
      try Task.checkCancellation()
      let body = normalized.text
      structuredRemaining -= normalized.structuredBytes
      values.append(normalized.value)
      var excerpts: [String] = []
      var start = body.startIndex
      repeat {
        let end = body.index(start, offsetBy: 512, limitedBy: body.endIndex) ?? body.endIndex
        let excerpt = "Attachment \(index + 1) (untrusted source data):\n" + body[start..<end]
        guard excerpt.utf8.count <= remaining else {
          throw AgentError.inputFailure("Attachment excerpts exceed the extracted byte limit")
        }
        remaining -= excerpt.utf8.count
        excerpts.append(excerpt)
        start = end
      } while start < body.endIndex
      groups.append(excerpts)
      await events.publish(.inputProcessingProgress(processed: index + 1, total: attachments.count))
    }
    // Prioritize an initial excerpt from every attachment before later excerpts.
    var ordered: [String] = []
    for offset in 0..<(groups.map(\.count).max() ?? 0) {
      for group in groups where offset < group.count { ordered.append(group[offset]) }
    }
    return PreparedInput(excerpts: ordered, values: values)
  }

  private func preflight(_ attachments: [AgentInput.Attachment]) throws {
    guard attachments.count <= configuration.inputLimits.maximumAttachments else {
      throw AgentError.inputFailure("Too many attachments")
    }
    var remaining = configuration.inputLimits.maximumBytes
    func consume(_ size: Int) throws {
      guard size <= remaining else {
        throw AgentError.inputFailure("Attachments exceed the source byte limit")
      }
      remaining -= size
    }
    for attachment in attachments {
      try Task.checkCancellation()
      switch attachment {
      case .image(let image):
        guard configuration.vision != nil else {
          throw AgentError.inputFailure("Image input requires a vision provider")
        }
        guard !image.data.isEmpty else { throw AgentError.inputFailure("Image input is empty") }
        try consume(image.data.count)
      case .audio(let audio):
        guard configuration.speechRecognizer != nil else {
          throw AgentError.inputFailure("Audio input requires a speech recognizer")
        }
        guard !audio.data.isEmpty else { throw AgentError.inputFailure("Audio input is empty") }
        try consume(audio.data.count)
      case .document(let document):
        try consume(document.title.utf8.count)
        try consume(document.text.utf8.count)
      }
    }
  }

  private static func render(
    _ attachment: AgentInput.Attachment, configuration: AgentConfiguration, maximumBytes: Int,
    maximumStructuredBytes: Int
  ) async throws -> (text: String, value: JSONValue, structuredBytes: Int) {
    do {
      var text = InputText(remaining: maximumBytes)
      var structured = StructuredInput(maximumBytes: maximumStructuredBytes)
      let value: JSONValue
      switch attachment {
      case .audio(let audio):
        guard let provider = configuration.speechRecognizer else {
          throw AgentError.inputFailure("Audio input requires a speech recognizer")
        }
        let transcript = try await provider.transcribe(audio: audio)
        try Task.checkCancellation()
        try text.append("Audio transcript:\n")
        try text.append(transcript)
        value = try structured.object([
          "kind": structured.string("audio"), "text": structured.string(transcript),
        ])
      case .document(let document):
        try text.append("Document title: ")
        try text.append(document.title)
        try text.append("\nDocument text:\n")
        try text.append(document.text)
        value = try structured.object([
          "kind": structured.string("document"),
          "title": structured.string(document.title), "text": structured.string(document.text),
        ])
      case .image(let image):
        guard let provider = configuration.vision else {
          throw AgentError.inputFailure("Image input requires a vision provider")
        }
        let result = try await provider.analyze(image: image)
        try Task.checkCancellation()
        value = try structured.image(result)
        try text.append("Image analysis:\n")
        for category in result.classifications {
          try text.append("Category: ")
          try text.append(category.identifier)
          try text.append(" (\(category.confidence))\n")
        }
        for observation in result.recognizedText {
          try text.append("Text \(box(observation.boundingBox)): ")
          try text.append(observation.text)
          try text.append("\n")
        }
        for object in result.detectedObjects {
          try text.append("Object \(box(object.boundingBox)), confidence \(object.confidence): ")
          for label in object.labels {
            try text.append(label.identifier)
            try text.append(" (\(label.confidence)) ")
          }
          try text.append("\n")
        }
        for document in result.documents {
          try text.append("Document text:\n")
          try text.append(document.text)
          try text.append("\n")
          if let title = document.title {
            try text.append("Title: ")
            try text.append(title)
            try text.append("\n")
          }
          for table in document.tables {
            try text.append("Table \(table.rowCount) rows, \(table.columnCount) columns:\n")
            for cell in table.cells {
              try text.append("Cell rows \(cell.rowRange), columns \(cell.columnRange): ")
              try text.append(cell.text)
              try text.append("\n")
            }
          }
        }
      }
      return (text.value, value, maximumStructuredBytes - structured.remaining)
    } catch {
      if Task.isCancelled || error is CancellationError { throw AgentError.cancelled }
      if let error = error as? AgentError { throw error }
      throw AgentError.inputFailure("Attachment provider failed")
    }
  }

  private static func box(_ box: VisionBoundingBox) -> String {
    "[\(box.x),\(box.y),\(box.width),\(box.height)]"
  }
}

private struct InputText {
  var remaining: Int
  private(set) var value = ""

  mutating func append(_ part: String) throws {
    try Task.checkCancellation()
    guard part.utf8.count <= remaining else {
      throw AgentError.inputFailure("Attachment content exceeds the extracted byte limit")
    }
    remaining -= part.utf8.count
    value += part
  }
}
