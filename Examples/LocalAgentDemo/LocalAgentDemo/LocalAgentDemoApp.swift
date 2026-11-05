import LocalAgentKitSwiftUI
import SwiftUI

/// The MVP reference application (PRD §13): "Reasoning + Tools + Memory + RAG + Permissions +
/// Actions" in one four-turn conversation. `AgentSetup` builds the real on-device agent; this
/// file only wires it to a window.
@main
struct LocalAgentDemoApp: App {
  @State private var state: AppState = .loading
  @State private var setupInProgress = false

  var body: some Scene {
    WindowGroup {
      Group {
        switch state {
        case .loading:
          ProgressView("Starting the agent…")
        case .ready(let viewModel):
          ContentView(viewModel: viewModel)
        case .failed(let message):
          ContentUnavailableView(
            "Couldn't start the agent", systemImage: "exclamationmark.triangle",
            description: Text(message))
        }
      }
      .task {
        guard case .loading = state, !setupInProgress else { return }
        setupInProgress = true
        defer { setupInProgress = false }
        do {
          state = .ready(try await AgentSetup.makeViewModel())
        } catch {
          state = .failed(String(describing: error))
        }
      }
    }
  }
}

private enum AppState {
  case loading
  case ready(AgentViewModel)
  case failed(String)
}
