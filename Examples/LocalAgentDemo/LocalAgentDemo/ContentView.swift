import LocalAgentKitCore
import LocalAgentKitSwiftUI
import SwiftUI

/// The demo app shell (M1-UI-03): a chat transcript, an input field, visible tool activity, and
/// the opt-in permission sheet from `LocalAgentKitSwiftUI` — all driven by `AgentViewModel`.
struct ContentView: View {
  @State var viewModel: AgentViewModel
  @State private var draft = ""
  @FocusState private var inputFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      Text("Recent completed turns are saved on this device.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(viewModel.turns) { turn in
              TurnView(turn: turn)
                .id(turn.id)
            }
            ForEach(viewModel.toolActivity.indices, id: \.self) { index in
              let result = viewModel.toolActivity[index]
              if result.toolName == "create_note", !result.isEmpty {
                Label(result.text, systemImage: "checkmark.circle.fill")
                  .font(.callout)
                  .foregroundStyle(.green)
                  .textSelection(.enabled)
                  .id("saved-note-\(index)")
              }
            }
            if let activeTool = viewModel.activeTool {
              ToolActivityView(call: activeTool)
            }
          }
          .padding()
        }
        .onChange(of: viewModel.toolActivity.count) {
          if let index = viewModel.toolActivity.indices.last,
            viewModel.toolActivity[index].toolName == "create_note",
            !viewModel.toolActivity[index].isEmpty
          {
            withAnimation { proxy.scrollTo("saved-note-\(index)", anchor: .bottom) }
          }
        }
        .onChange(of: viewModel.turns.count) {
          if let last = viewModel.turns.last?.id {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
          }
        }
      }

      if case .finishing = viewModel.state {
        ProgressView("Saving conversation…")
          .font(.footnote)
          .padding(.horizontal)
      }

      if let failure = viewModel.lastFailure {
        Text(failure)
          .font(.footnote)
          .foregroundStyle(.red)
          .padding(.horizontal)
      }

      HStack {
        TextField("Ask the agent…", text: $draft)
          .textFieldStyle(.roundedBorder)
          .focused($inputFocused)
          .onSubmit(send)
          .disabled(viewModel.isRunning)
        Button(action: send) {
          Image(systemName: "arrow.up.circle.fill")
        }
        .disabled(draft.isEmpty || viewModel.isRunning)
      }
      .padding()
    }
    .agentPermissionSheet(for: viewModel)
    .overlay(alignment: .top) {
      if let utilization = viewModel.contextUtilization {
        ContextUtilizationBar(utilization: utilization)
      }
    }
  }

  private func send() {
    guard !draft.isEmpty else { return }
    if case .awaitingClarification = viewModel.state {
      viewModel.answerClarification(draft)
    } else {
      viewModel.send(draft)
    }
    draft = ""
  }
}

private struct TurnView: View {
  let turn: AgentViewModel.Turn

  var body: some View {
    HStack {
      if turn.role == .assistant { Spacer(minLength: 40) }
      Text(turn.text)
        .padding(10)
        .background(
          turn.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
      if turn.role == .user { Spacer(minLength: 40) }
    }
  }
}

private struct ToolActivityView: View {
  let call: ToolCall

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Running \(call.name)…")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}

private struct ContextUtilizationBar: View {
  let utilization: ContextUtilization

  var body: some View {
    ProgressView(value: min(utilization.fraction, 1))
      .tint(utilization.fraction > 0.9 ? .red : .accentColor)
      .padding(.horizontal)
      .padding(.top, 4)
  }
}
