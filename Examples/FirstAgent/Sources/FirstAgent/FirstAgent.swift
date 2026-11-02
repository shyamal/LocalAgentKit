import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders
import LocalAgentKitRuntime
import LocalAgentKitTesting
import LocalAgentKitTools

@main
struct FirstAgent {
  static func main() async throws {
    let model: any LocalModelProvider
    if CommandLine.arguments.contains("--device") {
      model = FoundationModelProvider()
    } else {
      model = ScriptedModelProvider(responses: [
        .toolCall(
          ToolCall(
            id: "choose", name: "choose_next_action",
            arguments: ToolArguments(["action": .string("calculate")]))),
        .toolCall(
          ToolCall(
            id: "math", name: "provide_calculate_arguments",
            arguments: ToolArguments(["expression": .string("(12 + 8) * 3")]))),
        .toolCall(
          ToolCall(
            id: "finish", name: "choose_next_action",
            arguments: ToolArguments(["action": .string("finish")]))),
        .text("The result is 60."),
      ])
    }
    let runtime = try AgentRuntime(
      configuration: AgentConfiguration(model: model, networkPolicy: .never),
      tools: StaticToolSource([CalculatorTool()]))
    let stream = await runtime.events()
    let observer = Task {
      for await event in stream {
        if case .toolCompleted(let result) = event {
          print("Tool \(result.toolName): \(result.text)")
        }
      }
    }
    do {
      let response = try await runtime.run("Calculate (12 + 8) * 3.")
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
}
