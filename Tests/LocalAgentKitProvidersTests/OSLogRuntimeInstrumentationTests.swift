import Foundation
import LocalAgentKitCore
import Testing

@testable import LocalAgentKitProviders

@Suite struct OSLogRuntimeInstrumentationTests {
  @Test func duplicateBeginsAndMismatchedEndsDoNotCorruptIntervals() {
    let sink = OSLogRuntimeInstrumentation(subsystem: "org.localagentkit.tests")
    let run = UUID()
    let interval = UUID()
    let begin = RuntimeTraceEvent(runID: run, intervalID: interval, operation: .run, phase: .began)
    sink.record(begin)
    sink.record(begin)
    #expect(sink.activeIntervalCount == 1)
    sink.record(
      RuntimeTraceEvent(runID: UUID(), intervalID: interval, operation: .run, phase: .ended))
    sink.record(
      RuntimeTraceEvent(runID: run, intervalID: interval, operation: .modelCall, phase: .ended))
    #expect(sink.activeIntervalCount == 1)
    let end = RuntimeTraceEvent(runID: run, intervalID: interval, operation: .run, phase: .ended)
    sink.record(end)
    sink.record(end)
    #expect(sink.activeIntervalCount == 0)
  }

  @Test func sharedAdapterPairsConcurrentIntervals() async {
    let sink = OSLogRuntimeInstrumentation(subsystem: "org.localagentkit.tests")
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<40 {
        group.addTask {
          let run = UUID()
          let interval = UUID()
          sink.record(
            RuntimeTraceEvent(
              runID: run, intervalID: interval, operation: .modelCall, phase: .began))
          sink.record(
            RuntimeTraceEvent(
              runID: run, intervalID: interval, operation: .modelCall, phase: .ended))
        }
      }
    }
    #expect(sink.activeIntervalCount == 0)
  }
}
