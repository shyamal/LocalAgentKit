import Foundation
import LocalAgentKitCore

/// All intervals for a run share an identity; this context contains no user data.
struct RuntimeTrace: Sendable {
  let sink: any RuntimeInstrumentation
  let runID = UUID()

  func begin(_ operation: RuntimeOperation) -> RuntimeTraceInterval {
    let interval = RuntimeTraceInterval(
      sink: sink, runID: runID, intervalID: UUID(), operation: operation)
    sink.record(interval.event(.began))
    return interval
  }
}

struct RuntimeTraceInterval: Sendable {
  let sink: any RuntimeInstrumentation
  let runID: UUID
  let intervalID: UUID
  let operation: RuntimeOperation

  func event(_ phase: RuntimeTraceEvent.Phase) -> RuntimeTraceEvent {
    RuntimeTraceEvent(runID: runID, intervalID: intervalID, operation: operation, phase: phase)
  }

  func end() { sink.record(event(.ended)) }
}
