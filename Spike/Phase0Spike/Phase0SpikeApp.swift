import SwiftUI

/// Runs the P0-02 checks on launch and shows the log. With the `--run-and-exit`
/// launch argument it exits when the checks finish, so `devicectl --console`
/// (iOS) or a direct binary launch (macOS) returns and the stdout log is the artifact.
///
/// The run starts from `init`, not from a view's `.task`: a headless launch must not
/// depend on SwiftUI deciding to present a window.
@main
struct Phase0SpikeApp: App {
  @State private var log: Log

  init() {
    let log = Log()
    _log = State(initialValue: log)
    Task {
      await SessionChecks(log: log).runAll()
      if CommandLine.arguments.contains("--run-and-exit") { exit(0) }
    }
  }

  var body: some Scene {
    WindowGroup {
      ScrollView {
        Text(log.lines.joined(separator: "\n"))
          .font(.system(.caption, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
          .textSelection(.enabled)
      }
    }
  }
}

/// Collects result lines for the UI and mirrors each to stdout with a `P0|` prefix
/// so they can be grepped out of console noise.
@MainActor @Observable
final class Log {
  private(set) var lines: [String] = []

  func write(_ line: String) {
    lines.append(line)
    print("P0| \(line)")
    fflush(stdout)
  }
}
