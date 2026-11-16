import Foundation
import LocalAgentKitCore

/// Builds only normalized values, with a conservative JSON byte budget before accumulation.
struct StructuredInput {
  private(set) var remaining: Int

  init(maximumBytes: Int) { remaining = maximumBytes }

  private mutating func consume(_ bytes: Int) throws {
    try Task.checkCancellation()
    guard bytes <= remaining else {
      throw AgentError.inputFailure("Attachments exceed the structured byte limit")
    }
    remaining -= bytes
  }

  mutating func string(_ text: String) throws -> JSONValue {
    // Check before encoding so even an oversized provider string is not copied into JSON data.
    guard text.utf8.count <= remaining else {
      throw AgentError.inputFailure("Attachments exceed the structured byte limit")
    }
    try consume(JSONEncoder().encode(text).count)
    return .string(text)
  }

  private mutating func number(_ value: Double) throws -> JSONValue {
    guard value.isFinite else { throw AgentError.inputFailure("Non-finite input metadata") }
    try consume(JSONEncoder().encode(value).count)
    return .double(value)
  }

  private mutating func integer(_ value: Int) throws -> JSONValue {
    try consume(String(value).utf8.count)
    return .int(value)
  }

  mutating func object(_ values: [String: JSONValue]) throws -> JSONValue {
    try consume(2)
    for key in values.keys {
      // Quoted key, colon and comma; the extra first comma makes this conservative.
      try consume(JSONEncoder().encode(key).count + 2)
    }
    return .object(values)
  }

  private mutating func list<T>(
    _ items: [T], make: (inout Self, T) throws -> JSONValue
  ) throws -> JSONValue {
    try consume(2)
    var values: [JSONValue] = []
    for item in items {
      try consume(1)
      values.append(try make(&self, item))
    }
    return .array(values)
  }

  private mutating func box(_ value: VisionBoundingBox) throws -> JSONValue {
    try object([
      "x": number(value.x), "y": number(value.y),
      "width": number(value.width), "height": number(value.height),
    ])
  }

  private mutating func classification(_ value: VisionClassification) throws -> JSONValue {
    try object([
      "identifier": string(value.identifier), "confidence": number(Double(value.confidence)),
    ])
  }

  private mutating func cell(_ value: VisionDocumentCell) throws -> JSONValue {
    try object([
      "text": string(value.text), "rowStart": integer(value.rowRange.lowerBound),
      "rowEnd": integer(value.rowRange.upperBound),
      "columnStart": integer(value.columnRange.lowerBound),
      "columnEnd": integer(value.columnRange.upperBound), "boundingBox": box(value.boundingBox),
    ])
  }

  private mutating func table(_ value: VisionDocumentTable) throws -> JSONValue {
    try object([
      "rowCount": integer(value.rowCount), "columnCount": integer(value.columnCount),
      "cells": list(value.cells) { try $0.cell($1) }, "boundingBox": box(value.boundingBox),
    ])
  }

  private mutating func document(_ value: VisionDocumentObservation) throws -> JSONValue {
    var fields: [String: JSONValue] = [
      "text": try string(value.text), "confidence": try number(Double(value.confidence)),
      "paragraphs": try list(value.paragraphs) { try $0.string($1) },
      "tables": try list(value.tables) { try $0.table($1) },
      "boundingBox": try box(value.boundingBox),
    ]
    if let title = value.title { fields["title"] = try string(title) }
    return try object(fields)
  }

  mutating func image(_ value: VisionResult) throws -> JSONValue {
    try object([
      "kind": string("image"),
      "classifications": list(value.classifications) { try $0.classification($1) },
      "recognizedText": list(value.recognizedText) { builder, item in
        try builder.object([
          "text": builder.string(item.text), "confidence": builder.number(Double(item.confidence)),
          "boundingBox": builder.box(item.boundingBox),
        ])
      },
      "detectedObjects": list(value.detectedObjects) { builder, item in
        try builder.object([
          "labels": builder.list(item.labels) { try $0.classification($1) },
          "confidence": builder.number(Double(item.confidence)),
          "boundingBox": builder.box(item.boundingBox),
        ])
      },
      "documents": list(value.documents) { try $0.document($1) },
    ])
  }
}
