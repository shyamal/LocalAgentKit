import Foundation
import LocalAgentKitCore

// Shared bounded file reads for PDF and UTF-8 extraction. No framework objects escape.
enum DocumentFileReader {
  static func read(_ url: URL, maximumBytes: Int, kind: String = "Document") throws -> Data {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else {
        throw AgentError.retrievalFailure("\(kind) input must be a regular local file")
      }
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      var data = Data()
      while true {
        if Task.isCancelled { throw AgentError.cancelled }
        let remaining = maximumBytes - data.count
        // Probe one byte past the limit, without overflowing at Int.max.
        let amount = remaining >= 65_536 ? 65_536 : remaining + 1
        guard let chunk = try file.read(upToCount: amount), !chunk.isEmpty else { return data }
        guard chunk.count <= remaining else {
          throw AgentError.retrievalFailure("\(kind) exceeds its byte limit")
        }
        data.append(chunk)
      }
    } catch let error as AgentError { throw error } catch {
      throw AgentError.retrievalFailure("Could not read \(kind.lowercased()) file")
    }
  }

}
