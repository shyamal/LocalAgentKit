import Foundation

public enum ResourcePath: String, Codable, Sendable, CaseIterable {
  case idle, ocr, transcription, synthesis
}

public struct ResourceSnapshot: Codable, Sendable {
  public let thermal: String
  public let batteryLevel: Double?
  public let batteryState: String
  public let lowPowerMode: Bool
  public let footprintBytes: UInt64?
  public let foreground: Bool
  public let brightness: Double?

  public init(
    thermal: String, batteryLevel: Double?, batteryState: String, lowPowerMode: Bool,
    footprintBytes: UInt64?, foreground: Bool, brightness: Double? = nil
  ) {
    self.thermal = thermal
    self.batteryLevel = batteryLevel
    self.batteryState = batteryState
    self.lowPowerMode = lowPowerMode
    self.footprintBytes = footprintBytes
    self.foreground = foreground
    self.brightness = brightness
  }
}

public struct ResourcePlan: Codable, Sendable {
  public let secondsPerPhase: Int
  public let intervalMilliseconds: Int
  public init(secondsPerPhase: Int = 60, intervalMilliseconds: Int = 250) throws {
    guard (1...300).contains(secondsPerPhase), (250...5000).contains(intervalMilliseconds) else {
      throw ProbeFailure.invalidPlan
    }
    self.secondsPerPhase = secondsPerPhase
    self.intervalMilliseconds = intervalMilliseconds
  }
}

public struct ResourceEvent: Codable, Sendable {
  public let schemaVersion: Int
  public let runID: UUID
  public let sequence: Int
  public let kind: String
  public let elapsedSeconds: Double
  public let path: ResourcePath?
  public let iteration: Int?
  public let latencySeconds: Double?
  public let snapshot: ResourceSnapshot?
  public let detail: String?
  public let metadata: [String: String]?
}

public enum ProbeFailure: Error, Equatable {
  case invalidPlan, interrupted, criticalThermalState
}

public struct ResourceWorkload: Sendable {
  public let path: ResourcePath
  public let unavailableReason: String?
  public let operation: @Sendable () async throws -> Void
  public init(
    path: ResourcePath, unavailableReason: String? = nil,
    operation: @escaping @Sendable () async throws -> Void
  ) {
    self.path = path
    self.unavailableReason = unavailableReason
    self.operation = operation
  }
}

/// Serial paced work. Samples between operations; a slow native call can overshoot a phase.
public struct ResourceProbe: Sendable {
  public let now: @Sendable () async -> Double
  public let sleep: @Sendable (Duration) async throws -> Void
  public init(
    now: @escaping @Sendable () async -> Double = { ProcessInfo.processInfo.systemUptime },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.now = now
    self.sleep = sleep
  }

  public func run(
    plan: ResourcePlan, workloads: [ResourceWorkload], runID: UUID,
    metadata: [String: String], sample: @Sendable () async -> ResourceSnapshot,
    emit: @Sendable (ResourceEvent) async throws -> Void
  ) async throws {
    guard workloads.map(\.path) == ResourcePath.allCases else { throw ProbeFailure.invalidPlan }
    let start = await now()
    var sequence = 0
    func write(
      _ kind: String, path: ResourcePath? = nil, iteration: Int? = nil,
      latency: Double? = nil, snapshot: ResourceSnapshot? = nil, detail: String? = nil,
      metadata: [String: String]? = nil
    ) async throws {
      let event = ResourceEvent(
        schemaVersion: 1, runID: runID, sequence: sequence,
        kind: kind, elapsedSeconds: await now() - start, path: path, iteration: iteration,
        latencySeconds: latency, snapshot: snapshot, detail: detail, metadata: metadata)
      sequence += 1
      try await emit(event)
    }
    var header = metadata
    header["secondsPerPhase"] = String(plan.secondsPerPhase)
    header["intervalMilliseconds"] = String(plan.intervalMilliseconds)
    try await write("started", metadata: header)
    do {
      for workload in workloads {
        try Task.checkCancellation()
        if let reason = workload.unavailableReason {
          try await write("unavailable", path: workload.path, detail: reason)
          continue
        }
        let phaseStart = await now()
        var iteration = 0
        let initial = await sample()
        try await write("phaseStarted", path: workload.path, snapshot: initial)
        try check(initial)
        while await now() - phaseStart < Double(plan.secondsPerPhase) {
          try Task.checkCancellation()
          let before = await now()
          do { try await workload.operation() } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            try await write("failed", path: workload.path, detail: String(describing: error))
            break
          }
          try Task.checkCancellation()
          let latency = await now() - before
          iteration += 1
          let snapshot = await sample()
          try await write(
            "sample", path: workload.path, iteration: iteration,
            latency: latency, snapshot: snapshot)
          try check(snapshot)
          try await sleep(.milliseconds(plan.intervalMilliseconds))
        }
        try Task.checkCancellation()
        let closing = await sample()
        try await write("phaseEnded", path: workload.path, iteration: iteration, snapshot: closing)
        try check(closing)
      }
      try Task.checkCancellation()
      try await write("finished")
    } catch {
      // A failed sink can leave a partial file; a missing terminal record is never a complete run.
      try await write(
        Task.isCancelled || error is CancellationError ? "cancelled" : "interrupted",
        detail: String(describing: error))
      throw error
    }
  }

  private func check(_ snapshot: ResourceSnapshot) throws {
    try Task.checkCancellation()
    guard snapshot.foreground else { throw ProbeFailure.interrupted }
    guard snapshot.thermal != "critical" else { throw ProbeFailure.criticalThermalState }
  }
}
