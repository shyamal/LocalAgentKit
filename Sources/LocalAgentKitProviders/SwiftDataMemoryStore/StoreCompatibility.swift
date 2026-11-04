import CoreData
import Foundation
import LocalAgentKitCore
import SwiftData

/// Check version/family metadata before SwiftData can infer an unintended downgrade.
/// Keep this inside Providers: no Core Data types cross the framework-neutral store seam.
enum StoreCompatibility {
  static func validate(_ url: URL, schemas: [any VersionedSchema.Type]) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
      ofType: NSSQLiteStoreType, at: url, options: [NSReadOnlyPersistentStoreOption: true])
    guard let versions = metadata[NSStoreModelVersionIdentifiersKey] as? [String],
      versions.count == 1,
      let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Data]
    else {
      throw AgentError.memoryFailure("Unsupported memory store version or schema family.")
    }
    let entityNames = Set(hashes.keys)
    let supported = schemas.contains { version in
      versions[0] == version.versionIdentifier.description
        && entityNames == Set(Schema(versionedSchema: version).entities.map(\.name))
    }
    guard supported else {
      throw AgentError.memoryFailure("Unsupported memory store version or schema family.")
    }
  }
}
