import LocalAgentKitCore
import SwiftUI

/// The opt-in convenience answer to PLANNING §6 open question 5: the SDK ships a sheet, but the
/// real extensibility point stays the `PermissionGate` protocol and `.permissionRequired` event
/// (both in `LocalAgentKitRuntime`) — a host that wants its own UI never has to touch this file.
///
/// Shows the tool name and its arguments; it does not show the tool's description or permission
/// tier, since `AgentEvent.permissionRequired` carries only the `ToolCall` (findings-free
/// limitation, not a framework one — enriching the event is a later task if this proves thin).
public struct PermissionConfirmationSheet: View {
  private let call: ToolCall
  private let onApprove: () -> Void
  private let onDeny: () -> Void

  /// Creates a confirmation UI for a pending call with callbacks for each human decision.
  public init(call: ToolCall, onApprove: @escaping () -> Void, onDeny: @escaping () -> Void) {
    self.call = call
    self.onApprove = onApprove
    self.onDeny = onDeny
  }

  /// The tool name, argument preview and approve/deny controls rendered by the sheet.
  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Confirm Action")
        .font(.headline)
      Text(Self.title(for: call))
        .font(.body)
      if !call.arguments.values.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Self.sortedArguments(call), id: \.key) { pair in
            Text("\(pair.key): \(pair.value)")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
      HStack {
        Button("Cancel", role: .cancel, action: onDeny)
        Spacer()
        Button("Approve", action: onApprove)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding()
  }

  private static func title(for call: ToolCall) -> String {
    call.name.replacingOccurrences(of: "_", with: " ").capitalized + "?"
  }

  private static func sortedArguments(_ call: ToolCall) -> [(key: String, value: String)] {
    call.arguments.values.sorted { $0.key < $1.key }.map { ($0.key, render($0.value)) }
  }

  private static func render(_ value: JSONValue) -> String {
    switch value {
    case .null: "none"
    case .bool(let flag): String(flag)
    case .int(let number): String(number)
    case .double(let number): String(number)
    case .string(let text): text
    case .array(let items): "[" + items.map(render).joined(separator: ", ") + "]"
    case .object(let object):
      "{"
        + object.sorted { $0.key < $1.key }.map { "\($0.key): \(render($0.value))" }
        .joined(separator: ", ") + "}"
    }
  }
}

/// Optional permission-confirmation presentation for a host SwiftUI view.
extension View {
  /// Presents `PermissionConfirmationSheet` whenever `viewModel.state` is `.awaitingPermission`.
  /// Dismissing the sheet any other way (a swipe down) denies the pending call — a suspended
  /// confirmation is never silently forgotten.
  public func agentPermissionSheet(for viewModel: AgentViewModel) -> some View {
    sheet(
      isPresented: Binding(
        get: {
          if case .awaitingPermission = viewModel.state { true } else { false }
        },
        set: { isPresented in
          if !isPresented { viewModel.denyPermission() }
        })
    ) {
      if case .awaitingPermission(let call) = viewModel.state {
        PermissionConfirmationSheet(
          call: call, onApprove: viewModel.approvePermission, onDeny: viewModel.denyPermission)
      }
    }
  }
}
