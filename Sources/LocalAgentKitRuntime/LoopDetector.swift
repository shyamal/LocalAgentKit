import LocalAgentKitCore

/// What the detector concluded after seeing a call.
public enum LoopVerdict: Sendable, Hashable {
  case proceed
  /// The recent calls repeat with the given period: 1 is the same call again and again,
  /// 2 is A, B, A, B, A.
  case loop(period: Int, toolName: String)
}

/// Detects an agent repeating itself (FR-028) from `(tool, arguments)` signatures.
///
/// A loop is one full cycle plus one more call: `A A A` for period 1, `A B A B A` for period 2.
/// One repeat alone is not a loop, since retrying a call once is legitimate. A value type owned
/// by the runtime actor, so it needs no locking.
public struct LoopDetector: Sendable {
  public let maxPeriod: Int
  private var history: [String] = []

  public init(maxPeriod: Int = 3) {
    self.maxPeriod = max(1, maxPeriod)
  }

  /// Records a call and reports whether the run is now looping.
  public mutating func record(_ call: ToolCall) -> LoopVerdict {
    history.append("\(call.name)(\(call.arguments.signature))")
    let keep = 2 * maxPeriod + 1
    if history.count > keep { history.removeFirst(history.count - keep) }
    for period in 1...maxPeriod {
      let length = 2 * period + 1
      guard history.count >= length else { continue }
      let tail = Array(history.suffix(length))
      if (0..<(length - period)).allSatisfy({ tail[$0] == tail[$0 + period] }) {
        return .loop(period: period, toolName: call.name)
      }
    }
    return .proceed
  }

  public mutating func reset() {
    history.removeAll()
  }
}
