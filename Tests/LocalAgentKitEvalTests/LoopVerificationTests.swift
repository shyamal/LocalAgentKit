import Foundation
import Testing

@testable import LocalAgentKitEvalSupport

@Suite struct LoopVerificationTests {
  @Test func allLoopAndControlContractsPassAndHistoryResetsAcrossRuns() async throws {
    let report = try await LoopVerification.run(repetitions: 3)
    #expect(report.schemaVersion == 1 && report.protocolVersion == 1 && report.synthetic)
    #expect(report.passed && report.trials.count == 51)
    #expect(Set(report.trials.map(\.scenario)).count == 17)
    #expect(report.trials.filter { $0.category == "loop" }.count == 33)
    #expect(report.trials.filter { $0.category == "control" }.count == 12)
    #expect(report.trials.filter { $0.category == "boundary" }.count == 6)
    for row in report.trials {
      #expect(row.actualStop == row.expectedStop)
      #expect(row.executedCalls == row.expectedExecutions)
      #expect(row.completedCalls == row.observations && row.observations == row.executedCalls)
      #expect(row.terminalEvents == 1 && row.modelCalls == 0)
    }
    let decoded = try JSONDecoder().decode(
      LoopVerificationReport.self,
      from: JSONEncoder().encode(report))
    #expect(decoded.passed && decoded.trials.count == report.trials.count)
  }

  @Test func batchRejectionHappensBeforeExecutionAndWriteApproval() async throws {
    let rows = try await LoopVerification.run(repetitions: 1).trials
    for id in ["whole-batch-exact", "whole-batch-semantic"] {
      let row = try #require(rows.first { $0.scenario == id })
      #expect(row.proposedCalls == 3 && row.requestedCalls == 0 && row.executedCalls == 0)
    }
    let mixed = try #require(rows.first { $0.scenario == "cross-batch-cycle" })
    #expect(mixed.proposedCalls == 5 && mixed.executedCalls == 2)
    let write = try #require(rows.first { $0.scenario == "confirmed-write-loop" })
    #expect(write.proposedCalls == 3 && write.executedCalls == 2 && write.approvals == 2)
  }

  @Test func limitsAreReportedSeparatelyFromLoopDetection() async throws {
    let rows = try await LoopVerification.run(repetitions: 1).trials
    let iteration = try #require(rows.first { $0.scenario == "iteration-limit-before-detection" })
    #expect(iteration.actualStop == "iterationLimit" && iteration.proposedCalls == 2)
    let unsupported = try #require(rows.first { $0.scenario == "outside-default-period" })
    #expect(unsupported.actualStop == "toolLimit" && unsupported.proposedCalls == 9)
    #expect(unsupported.executedCalls == 8)
  }

  @Test(arguments: [0, -1, 101, Int.max])
  func invalidRepetitionBoundsAreRejected(_ count: Int) async {
    await #expect(throws: ProbeError.self) { try await LoopVerification.run(repetitions: count) }
  }

  @Test func preCancelledVerificationDoesNotStartTrials() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await LoopVerification.run()
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
