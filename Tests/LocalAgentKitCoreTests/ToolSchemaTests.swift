import Testing

@testable import LocalAgentKitCore

@Suite struct ToolSchemaTests {
  let schema = ToolSchema(
    parameters: [
      "title": ToolParameter(.string, description: "Title"),
      "count": ToolParameter(.integer, description: "Count", minimum: 1, maximum: 10),
      "ratio": ToolParameter(.number, description: "Ratio"),
      "unit": ToolParameter(.string, description: "Unit", allowedValues: ["km", "mi"]),
      "tags": ToolParameter(.array(of: .string), description: "Tags"),
      "when": ToolParameter(
        .object(
          ToolSchema(
            parameters: ["day": ToolParameter(.string, description: "Day")],
            required: ["day"])),
        description: "When"),
    ],
    required: ["title"])

  @Test func validCallHasNoViolations() {
    let args = ToolArguments([
      "title": "Lunch", "count": 3, "ratio": 1, "unit": "km", "tags": ["a", "b"],
      "when": ["day": "Monday"],
    ])
    #expect(schema.validate(args).isEmpty)
  }

  @Test func missingRequiredIsReported() {
    #expect(schema.validate(ToolArguments()) == [.missingRequired(path: "title")])
  }

  @Test func nullCountsAsMissing() {
    #expect(schema.validate(ToolArguments(["title": nil])) == [.missingRequired(path: "title")])
  }

  @Test func unknownPropertyIsRejected() {
    let violations = schema.validate(ToolArguments(["title": "x", "colour": "red"]))
    #expect(violations == [.unknownProperty(path: "colour")])
  }

  @Test func typeMismatchIsReported() {
    let violations = schema.validate(ToolArguments(["title": 5]))
    #expect(violations == [.typeMismatch(path: "title", expected: "a string")])
  }

  @Test func wholeNumberDoubleSatisfiesInteger() {
    #expect(schema.validate(ToolArguments(["title": "x", "count": .double(3.0)])).isEmpty)
    #expect(
      schema.validate(ToolArguments(["title": "x", "count": .double(3.5)]))
        == [.typeMismatch(path: "count", expected: "an integer")])
  }

  @Test func rangeIsEnforced() {
    #expect(
      schema.validate(ToolArguments(["title": "x", "count": 0]))
        == [.belowMinimum(path: "count", minimum: 1)])
    #expect(
      schema.validate(ToolArguments(["title": "x", "count": 11]))
        == [.aboveMaximum(path: "count", maximum: 10)])
  }

  @Test func enumIsEnforced() {
    #expect(
      schema.validate(ToolArguments(["title": "x", "unit": "ft"]))
        == [.notAllowed(path: "unit", allowed: ["km", "mi"])])
  }

  @Test func nestedPathsAreReported() {
    let arrays = schema.validate(ToolArguments(["title": "x", "tags": ["a", 2]]))
    #expect(arrays == [.typeMismatch(path: "tags[1]", expected: "a string")])
    let objects = schema.validate(ToolArguments(["title": "x", "when": [:]]))
    #expect(objects == [.missingRequired(path: "when.day")])
  }

  @Test func violationsReadAsRepairFeedback() {
    #expect(ArgumentViolation.missingRequired(path: "title").description == "title is required")
    #expect(
      ArgumentViolation.notAllowed(path: "unit", allowed: ["km", "mi"]).description
        == "unit must be one of: km, mi")
  }

  @Test func emptySchemaAcceptsOnlyNoArguments() {
    #expect(ToolSchema.empty.validate(ToolArguments()).isEmpty)
    #expect(ToolSchema.empty.validate(ToolArguments(["x": 1])) == [.unknownProperty(path: "x")])
  }
}
