import Foundation
import Testing

@testable import MultimodalProbeChecks

private actor ClockAndLog {
  var time = 0.0
  var events: [ResourceEvent] = []
  func now() -> Double { time }
  func advance() { time += 0.25 }
  func append(_ event: ResourceEvent) { events.append(event) }
}

private let nominal = ResourceSnapshot(
  thermal: "nominal", batteryLevel: 0.8,
  batteryState: "unplugged", lowPowerMode: false, footprintBytes: 1_000_000, foreground: true)

@Suite struct ResourceProbeTests {
  @Test func completesAllPathsWithOrderedSamplesAndTerminalRecord() async throws {
    let state = ClockAndLog()
    let runner = ResourceProbe(now: { await state.now() }, sleep: { _ in await state.advance() })
    let runID = UUID()
    try await runner.run(
      plan: ResourcePlan(secondsPerPhase: 1),
      workloads: ResourcePath.allCases.map { ResourceWorkload(path: $0) {} }, runID: runID,
      metadata: [:], sample: { nominal }, emit: { await state.append($0) })
    let events = await state.events
    #expect(events.first?.kind == "started")
    #expect(events.last?.kind == "finished")
    #expect(events.map(\.sequence) == Array(events.indices))
    #expect(events.allSatisfy { $0.runID == runID })
    #expect(events.filter { $0.kind == "phaseStarted" }.compactMap(\.path) == ResourcePath.allCases)
    #expect(events.filter { $0.kind == "sample" }.count == 16)
    let data = try JSONEncoder().encode(events[1])
    #expect(try JSONDecoder().decode(ResourceEvent.self, from: data).snapshot?.batteryLevel == 0.8)
  }

  @Test func unavailableAndFailedWorkloadsAreNotSuccessfulPhases() async throws {
    enum Failure: Error { case fixture }
    let state = ClockAndLog()
    let runner = ResourceProbe(now: { await state.now() }, sleep: { _ in await state.advance() })
    let paths = ResourcePath.allCases.map { path in
      ResourceWorkload(
        path: path,
        unavailableReason: path == .transcription ? "missing assets" : nil
      ) {
        if path == .synthesis { throw Failure.fixture }
      }
    }
    try await runner.run(
      plan: ResourcePlan(secondsPerPhase: 1), workloads: paths, runID: UUID(),
      metadata: [:], sample: { nominal }, emit: { await state.append($0) })
    let events = await state.events
    #expect(events.filter { $0.kind == "unavailable" }.compactMap(\.path) == [.transcription])
    #expect(events.filter { $0.kind == "failed" }.compactMap(\.path) == [.synthesis])
    #expect(!events.contains { $0.kind == "sample" && $0.path == .synthesis })
  }

  @Test func lateCancelledOutputNeverBecomesASample() async throws {
    let state = ClockAndLog()
    let runner = ResourceProbe(now: { await state.now() }, sleep: { _ in await state.advance() })
    let paths = ResourcePath.allCases.map { path in
      ResourceWorkload(path: path) {
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    await #expect(throws: CancellationError.self) {
      try await Task {
        try await runner.run(
          plan: ResourcePlan(secondsPerPhase: 1), workloads: paths, runID: UUID(),
          metadata: [:], sample: { nominal }, emit: { await state.append($0) })
      }.value
    }
    let events = await state.events
    #expect(events.last?.kind == "cancelled")
    #expect(!events.contains { $0.kind == "sample" || $0.kind == "finished" })
  }

  @Test(arguments: [true, false])
  func criticalAndBackgroundSnapshotsInterruptTheRun(critical: Bool) async throws {
    let state = ClockAndLog()
    let runner = ResourceProbe(now: { await state.now() }, sleep: { _ in await state.advance() })
    let snapshot = ResourceSnapshot(
      thermal: critical ? "critical" : "nominal", batteryLevel: nil,
      batteryState: "unknown", lowPowerMode: false, footprintBytes: nil,
      foreground: !critical ? false : true)
    await #expect(throws: critical ? ProbeFailure.criticalThermalState : .interrupted) {
      try await runner.run(
        plan: ResourcePlan(secondsPerPhase: 1),
        workloads: ResourcePath.allCases.map { ResourceWorkload(path: $0) {} }, runID: UUID(),
        metadata: [:], sample: { snapshot }, emit: { await state.append($0) })
    }
    #expect(await state.events.last?.kind == "interrupted")
  }

  @Test func invalidPlansAndPathSetsFailBeforeSampling() async throws {
    for seconds in [0, 301] {
      #expect(throws: ProbeFailure.invalidPlan) { try ResourcePlan(secondsPerPhase: seconds) }
    }
    #expect(throws: ProbeFailure.invalidPlan) { try ResourcePlan(intervalMilliseconds: 0) }
    await #expect(throws: ProbeFailure.invalidPlan) {
      try await ResourceProbe().run(
        plan: ResourcePlan(), workloads: [], runID: UUID(), metadata: [:],
        sample: {
          Issue.record("Unexpected sample")
          return nominal
        }, emit: { _ in Issue.record("Unexpected event") })
    }
  }
}
