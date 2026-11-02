import LocalAgentKitCore

/// Foundation Models produces cumulative snapshots; the SDK's public stream is append-only.
struct StreamingTextAccumulator {
  private(set) var text = ""

  mutating func append(_ snapshot: String) throws -> String {
    guard snapshot.utf8.starts(with: text.utf8) else {
      throw AgentError.modelUnavailable(reason: "the model revised previously streamed text")
    }
    let delta = String(decoding: snapshot.utf8.dropFirst(text.utf8.count), as: UTF8.self)
    text = snapshot
    return delta
  }
}
