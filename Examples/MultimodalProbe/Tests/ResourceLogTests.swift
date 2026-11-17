import Foundation
import Testing

@testable import MultimodalProbeChecks

@Test func existingReportCannotBeOverwritten() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("report.jsonl")
  let original = Data("retained observations\n".utf8)
  try original.write(to: url)
  do {
    _ = try ResourceLog(url: url)
    Issue.record("existing report must be rejected")
  } catch {
    #expect(try Data(contentsOf: url) == original)
  }
  let fresh = directory.appendingPathComponent("fresh.jsonl")
  let log = try ResourceLog(url: fresh)
  try await log.close()
  #expect(FileManager.default.fileExists(atPath: fresh.path))
}
