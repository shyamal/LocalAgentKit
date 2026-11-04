import Foundation
import LocalAgentKitCore

struct FileMetadata: Sendable {
  var root: Int
  var name: String
  var path: String
  var size: Int?
  var modified: Date?
  var json: JSONValue {
    .object([
      "root_index": .int(root + 1), "name": .string(name), "relative_path": .string(path),
      "size_bytes": size.map(JSONValue.int) ?? .null,
      "modified_at": modified.map { .string(String(describing: $0)) } ?? .null,
    ])
  }
}

/// The host owns sandbox/security-scope grants and exclusive root management. This is a bounded
/// metadata walk, not a kernel sandbox or a defense against concurrent filesystem replacement.
actor LocalFileSearch {
  let roots: [URL]
  let limit: Int
  let maxEntries: Int
  init(roots: [URL], limit: Int, maxEntries: Int) {
    self.roots = roots
    self.limit = limit
    self.maxEntries = maxEntries
  }

  func search(query: String, kind: FileKind) throws -> (files: [FileMetadata], partial: Bool) {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey,
      .isUbiquitousItemKey, .fileSizeKey, .contentModificationDateKey,
    ]
    var files: [FileMetadata] = []
    var seen = Set<String>()
    var visited = 0
    do {
      for (index, root) in roots.enumerated() {
        try checkCancellation()
        guard root.resolvingSymlinksInPath().path == root.path,
          try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory
            == true,
          try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
        else {
          throw AgentError.toolFailed(
            tool: "search_files",
            message:
              "Search roots must remain local non-ubiquitous directories at their approved locations."
          )
        }
        var scanError: (any Error)?
        guard
          let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
              scanError = error
              return false
            })
        else {
          throw AgentError.toolFailed(
            tool: "search_files", message: "Could not enumerate an approved search root.")
        }
        for case let url as URL in enumerator {
          try checkCancellation()
          if visited >= maxEntries { return (files, true) }
          visited += 1
          let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
          let prefix = root.path == "/" ? "/" : root.path + "/"
          guard canonical.path.hasPrefix(prefix) else {
            enumerator.skipDescendants()
            continue
          }
          let values = try url.resourceValues(forKeys: keys)
          if values.isSymbolicLink == true || values.isAliasFile == true || values.isPackage == true
            || values.isUbiquitousItem == true
          {
            enumerator.skipDescendants()
            continue
          }
          guard values.isRegularFile == true,
            kind.matches(url.pathExtension.lowercased()),
            url.lastPathComponent.localizedStandardContains(query),
            seen.insert(canonical.path).inserted
          else { continue }
          let relative = String(canonical.path.dropFirst(prefix.count))
          // Omit unusually long paths rather than returning truncated, unusable locations.
          guard relative.count <= 1000, url.lastPathComponent.count <= 255 else { continue }
          files.append(
            FileMetadata(
              root: index, name: url.lastPathComponent, path: relative,
              size: values.fileSize, modified: values.contentModificationDate))
          if files.count == limit { return (files, true) }
        }
        if let scanError { throw scanError }
      }
      try checkCancellation()
      return (files, false)
    } catch let error as AgentError { throw error } catch is CancellationError {
      throw AgentError.cancelled
    } catch {
      throw AgentError.toolFailed(
        tool: "search_files",
        message: "Could not read approved file metadata: \(error.localizedDescription)")
    }
  }

  private func checkCancellation() throws { if Task.isCancelled { throw AgentError.cancelled } }
}
