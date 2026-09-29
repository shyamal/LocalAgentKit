import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTesting
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let controller = ResultViewController()
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window

    Task {
      let text = await Self.runAgentTurn()
      await MainActor.run { controller.label.text = text }
    }
  }

  /// A `MockModelProvider` stands in for the real one — this target verifies the *layering*
  /// claim (full `AgentRuntime` functionality reachable without `LocalAgentKitSwiftUI`), not the
  /// on-device model, which `FoundationModelDeviceTests` already covers.
  private static func runAgentTurn() async -> String {
    let model = MockModelProvider { _ in .text("Two meetings today.") }
    do {
      let runtime = try AgentRuntime(
        configuration: AgentConfiguration(model: model), tools: StaticToolSource([]))
      let response = try await runtime.run("What meetings do I have?")
      return "AgentRuntime works without SwiftUI:\n\(response.text)"
    } catch {
      return "Failed: \(error)"
    }
  }
}

final class ResultViewController: UIViewController {
  let label = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    label.numberOfLines = 0
    label.textAlignment = .center
    label.text = "Running…"
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }
}
