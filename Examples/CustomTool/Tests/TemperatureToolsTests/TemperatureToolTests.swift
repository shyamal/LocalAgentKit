import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import TemperatureTools
import Testing

private actor DenyingGate: PermissionGate {
  var calls = 0
  func decide(for call: ToolCall, tool: ToolDescriptor) async -> PermissionDecision {
    calls += 1
    return .denied
  }
}

@Suite struct TemperatureToolTests {
  @Test func modelSelectedToolExecutesAndProducesTheObservation() async throws {
    let model = MockModelProvider { request in
      switch request.tools.first?.name {
      case "choose_next_action":
        let finished = request.messages.contains { $0.content.contains("degrees Fahrenheit") }
        return .toolCall(
          ToolCall(
            id: "choice", name: "choose_next_action",
            arguments: ToolArguments([
              "action": .string(finished ? "finish" : "convert_temperature")
            ])))
      case "provide_convert_temperature_arguments":
        return .toolCall(
          ToolCall(
            id: "args", name: "provide_convert_temperature_arguments",
            arguments: ToolArguments(["celsius": .int(20)])))
      default:
        return .text("Converted.")
      }
    }
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model),
      tools: StaticToolSource([TemperatureTool()]))
    let stream = await runtime.events()
    let collector = Task { () -> [ToolResult] in
      var results: [ToolResult] = []
      for await event in stream {
        if case .toolCompleted(let result) = event { results.append(result) }
      }
      return results
    }
    do {
      let response = try await runtime.run("Convert 20 Celsius to Fahrenheit.")
      await runtime.finishEvents()
      let results = await collector.value
      #expect(response.toolCallCount == 1)
      #expect(results.count == 1)
      #expect(results.first?.structured == .double(68))
      #expect(results.first?.toolName == "convert_temperature")
      #expect(results.first?.callID.isEmpty == false)
    } catch {
      await runtime.finishEvents()
      _ = await collector.value
      throw error
    }
  }

  @Test func invalidArgumentsNeverReachExecution() async throws {
    let realTool = TemperatureTool()
    let recordingTool = MockTool(
      name: realTool.name, schema: realTool.schema,
      handler: { try await realTool.execute(arguments: $0).text })
    let executor = ToolExecutor(source: StaticToolSource([recordingTool]), events: EventBus())
    let invalid: [ToolArguments] = [
      ToolArguments(), ToolArguments(["celsius": .string("hot")]),
      ToolArguments(["celsius": .double(-274)]),
      ToolArguments(["celsius": .int(1001)]),
      ToolArguments(["celsius": .int(20), "destination": .string("somewhere")]),
    ]
    for arguments in invalid {
      do {
        _ = try await executor.execute(
          ToolCall(id: "bad", name: realTool.name, arguments: arguments))
        Issue.record("Invalid arguments executed")
      } catch let error as AgentError {
        guard case .invalidArguments = error else { throw error }
      }
    }
    #expect(await recordingTool.executions.isEmpty)
  }

  @Test func pureComputationDoesNotAskForPermission() async throws {
    let gate = DenyingGate()
    let executor = ToolExecutor(
      source: StaticToolSource([TemperatureTool()]), gate: gate, events: EventBus())
    let result = try await executor.execute(
      ToolCall(
        id: "conversion", name: "convert_temperature",
        arguments: ToolArguments(["celsius": .int(0)])))
    #expect(result.result.structured == .double(32))
    #expect(await gate.calls == 0)
  }

  @Test func cancellationIsHonoredAtEntry() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await TemperatureTool().execute(arguments: ToolArguments(["celsius": .int(20)]))
    }
    do {
      _ = try await task.value
      Issue.record("Cancelled tool returned a result")
    } catch let error as AgentError {
      #expect(error == .cancelled)
    }
  }
}
