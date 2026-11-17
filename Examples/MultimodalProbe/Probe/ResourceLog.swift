import Foundation

actor ResourceLog {
  private let file: FileHandle
  init(url: URL) throws {
    try Data().write(to: url, options: .withoutOverwriting)
    file = try FileHandle(forWritingTo: url)
  }
  func append(_ event: ResourceEvent) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(event)
    data.append(10)
    try file.write(contentsOf: data)
  }
  func close() throws {
    try file.synchronize()
    try file.close()
  }
}
