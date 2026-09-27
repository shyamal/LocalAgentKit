import LocalAgentKitCore

/// Validates the whole configuration at construction (FR-023, M1-SE-03): `.never` with a
/// component that itself requires the network is a startup error, not a runtime surprise.
/// Offline mode is a guarantee, not a default.
enum NetworkPolicyGuard {
  static func validate(_ configuration: AgentConfiguration) -> ConfigurationIssue? {
    guard configuration.networkPolicy == .never else { return nil }
    if configuration.model.requiresNetwork {
      return .networkRequiredButForbidden(component: "model")
    }
    if configuration.embedding?.requiresNetwork == true {
      return .networkRequiredButForbidden(component: "embedding")
    }
    return nil
  }
}
