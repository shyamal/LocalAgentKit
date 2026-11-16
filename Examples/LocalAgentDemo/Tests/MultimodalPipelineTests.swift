import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LocalAgentKitCore
import LocalAgentKitProviders
import LocalAgentKitRuntime
import LocalAgentKitTesting
import LocalAgentKitTools
import Testing

private func capturedNoteRuntime(
  vision: any VisionProvider, store: NoteStore, model: any LocalModelProvider
) throws -> AgentRuntime {
  let workflow = Workflow(
    name: "captured-note", description: "Save text from the captured image",
    steps: [
      .tool(
        "save", "Save recognized text", "create_note",
        [
          "title": .literal("Captured text"),
          "body": .input(attachment: 0, path: "recognizedText.0.text"),
        ])
    ])
  return try AgentRuntime(
    configuration: AgentConfiguration(model: model, vision: vision),
    tools: StaticToolSource([CreateNoteTool(store: store)]),
    planner: StateMachinePlanner(workflow: workflow))
}

@Suite struct MultimodalPipelineTests {
  @Test(arguments: [true, false])
  func capturedTextWritesOnlyAfterTheUserApproves(approved: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(directory: directory)
    let model = ScriptedModelProvider(responses: [])
    let vision = MockVisionProvider { _ in
      VisionResult(recognizedText: [
        .init(
          text: "Untrusted captured text", confidence: 1,
          boundingBox: .init(x: 0, y: 0, width: 1, height: 1))
      ])
    }
    let runtime = try capturedNoteRuntime(vision: vision, store: store, model: model)
    let stream = await runtime.events()
    let run = Task {
      try await runtime.run(
        AgentInput(
          text: "Save this image as a note",
          attachments: [
            .image(ImageInput(data: Data([1, 2, 3])))
          ]))
    }
    var sawApproval = false
    for await event in stream {
      if case .permissionRequired(let call) = event {
        sawApproval = true
        #expect(try await store.all().isEmpty)
        #expect(call.arguments.string("body") == "Untrusted captured text")
        #expect(await runtime.resolvePermission(callID: call.id, approved: approved))
        break
      }
      if case .error = event { break }
    }
    #expect(sawApproval)
    if approved {
      _ = try await run.value
    } else {
      await #expect(throws: AgentError.permissionDenied(tool: "create_note")) {
        try await run.value
      }
    }
    let persisted = try await NoteStore(directory: directory).all()
    #expect(persisted.map(\.body) == (approved ? ["Untrusted captured text"] : []))
    #expect(await model.requests.isEmpty)
    await runtime.finishEvents()
  }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALAGENTKIT_DEVICE_TESTS"] == "1"))
struct NativeMultimodalPipelineTests {
  @Test func nativeOCRPassesCapturedBytesThroughApprovalToDurableNote() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = ScriptedModelProvider(responses: [])
    let runtime = try capturedNoteRuntime(
      vision: AppleVisionProvider(textRecognition: .init()), store: NoteStore(directory: directory),
      model: model)
    let events = await runtime.events()
    let input = ImageInput(data: try imageData())
    let run = Task {
      try await runtime.run(AgentInput(text: "Save captured text", attachments: [.image(input)]))
    }
    var approvedText: String?
    for await event in events {
      if case .permissionRequired(let call) = event {
        #expect(try await NoteStore(directory: directory).all().isEmpty)
        approvedText = call.arguments.string("body")
        #expect(approvedText?.contains("INVOICE 42") == true)
        #expect(await runtime.resolvePermission(callID: call.id, approved: true))
        break
      }
      if case .error = event { break }
    }
    _ = try await run.value
    #expect(approvedText != nil)
    #expect(try await NoteStore(directory: directory).all().first?.body == approvedText)
    #expect(await model.requests.isEmpty)
    await runtime.finishEvents()
  }

  private func imageData() throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 800, height: 300, bitsPerComponent: 8,
        bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 300))
    context.textPosition = CGPoint(x: 40, y: 150)
    let attributes: [NSAttributedString.Key: Any] = [
      .init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 40, nil),
      .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]
    CTLineDraw(
      CTLineCreateWithAttributedString(
        NSAttributedString(string: "INVOICE 42", attributes: attributes)), context)
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
}
