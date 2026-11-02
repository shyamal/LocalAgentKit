import Foundation
import LocalAgentKitCore

/// Multicasts `LocalAgentKitCore.AgentEvent`s so a UI and a logger can both subscribe (FR-019).
///
/// A subscriber sees events published after it subscribes; there is no replay. Buffering is
/// unbounded per subscriber, which is safe because a run is short and bounded.
public actor EventBus {
  private var subscribers: [Int: AsyncStream<AgentEvent>.Continuation] = [:]
  private var nextID = 0
  private var isFinished = false
  private var responseChannels: Set<UUID> = []

  func openResponseChannel() -> UUID {
    let id = UUID()
    if !isFinished { responseChannels.insert(id) }
    return id
  }

  func publishResponseToken(_ token: String, channel: UUID) {
    guard responseChannels.contains(channel), !token.isEmpty else { return }
    publish(.responseToken(token))
  }

  func closeResponseChannel(_ channel: UUID) { responseChannels.remove(channel) }

  /// Creates a multicast event bus with no subscribers or replay history.
  public init() {}

  /// Number of currently registered event-stream continuations.
  public var subscriberCount: Int { subscribers.count }

  /// A new stream of events. It ends when the bus finishes or the consumer stops iterating.
  public func subscribe() -> AsyncStream<AgentEvent> {
    let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
    guard !isFinished else {
      continuation.finish()
      return stream
    }
    let id = nextID
    nextID += 1
    subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeSubscriber(id) }
    }
    return stream
  }

  /// Yields an event to all current subscribers; ignores it after the bus is finished.
  public func publish(_ event: AgentEvent) {
    guard !isFinished else { return }
    for continuation in subscribers.values {
      continuation.yield(event)
    }
  }

  /// Ends every subscriber's stream. Later publishes are ignored.
  public func finish() {
    responseChannels.removeAll()
    isFinished = true
    for continuation in subscribers.values {
      continuation.finish()
    }
    subscribers.removeAll()
  }

  private func removeSubscriber(_ id: Int) {
    subscribers[id] = nil
  }
}
