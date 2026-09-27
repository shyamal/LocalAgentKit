import LocalAgentKitCore
import LocalAgentKitTesting
import Testing

@testable import LocalAgentKitRuntime

private struct OnDeviceModel: LocalModelProvider {
  let requiresNetwork = false
  func generate(request: ModelRequest) async throws -> ModelResponse { .text("ok") }
}
private struct NetworkModel: LocalModelProvider {
  let requiresNetwork = true
  func generate(request: ModelRequest) async throws -> ModelResponse { .text("ok") }
}
private struct NetworkEmbedding: EmbeddingProvider {
  let requiresNetwork = true
  func embed(text: String) async throws -> [Float] { [] }
}

@Suite struct NetworkPolicyGuardTests {
  @Test func offlineWithAnOnDeviceModelIsFine() {
    let config = AgentConfiguration(model: OnDeviceModel(), networkPolicy: .never)
    #expect(NetworkPolicyGuard.validate(config) == nil)
  }

  @Test func onlineIsNeverRejectedRegardlessOfTheModel() {
    let config = AgentConfiguration(model: NetworkModel(), networkPolicy: .allowed)
    #expect(NetworkPolicyGuard.validate(config) == nil)
  }

  @Test func offlineWithANetworkModelIsRejected() {
    let config = AgentConfiguration(model: NetworkModel(), networkPolicy: .never)
    #expect(NetworkPolicyGuard.validate(config) == .networkRequiredButForbidden(component: "model"))
  }

  @Test func offlineWithANetworkEmbeddingProviderIsRejected() {
    let config = AgentConfiguration(
      model: OnDeviceModel(), embedding: NetworkEmbedding(), networkPolicy: .never)
    #expect(
      NetworkPolicyGuard.validate(config) == .networkRequiredButForbidden(component: "embedding"))
  }

  @Test func offlineWithNoEmbeddingConfiguredIsFine() {
    let config = AgentConfiguration(model: OnDeviceModel(), embedding: nil, networkPolicy: .never)
    #expect(NetworkPolicyGuard.validate(config) == nil)
  }
}

@Suite struct AgentRuntimeNetworkPolicyTests {
  @Test func constructionFailsAtStartupNotAtRunTime() throws {
    #expect(
      throws: AgentError.invalidConfiguration(.networkRequiredButForbidden(component: "model"))
    ) {
      try AgentRuntime(
        configuration: AgentConfiguration(model: NetworkModel(), networkPolicy: .never),
        tools: StaticToolSource([]))
    }
  }

  @Test func offlineWithAnOnDeviceModelConstructsFine() throws {
    #expect(throws: Never.self) {
      try AgentRuntime(
        configuration: AgentConfiguration(model: OnDeviceModel(), networkPolicy: .never),
        tools: StaticToolSource([]))
    }
  }
}
