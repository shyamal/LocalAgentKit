import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import TemperatureTools

@main
struct CustomTool {
  static func main() async throws {
    let model = ScriptedModelProvider(responses: [
      call("choose_next_action", ["action": .string("convert_temperature")]),
      call("provide_convert_temperature_arguments", ["celsius": .int(20)]),
      call("choose_next_action", ["action": .string("finish")]),
      .text("20 degrees Celsius is 68 degrees Fahrenheit."),
    ])
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model, networkPolicy: .never),
      tools: StaticToolSource([TemperatureTool()]))
    let stream = await runtime.events()
    let observer = Task {
      for await event in stream {
        if case .toolCompleted(let result) = event { print("Tool: \(result.text)") }
      }
    }
    do {
      let response = try await runtime.run("Convert 20 degrees Celsius to Fahrenheit.")
      await runtime.finishEvents()
      await observer.value
      print(response.text)
      print("Tool calls: \(response.toolCallCount)")
    } catch {
      await runtime.finishEvents()
      await observer.value
      throw error
    }
  }

  static func call(_ name: String, _ arguments: [String: JSONValue]) -> ModelResponse {
    .toolCall(ToolCall(id: name, name: name, arguments: ToolArguments(arguments)))
  }
}
