import UIKit

/// M1-UI-08: proves a UIKit consumer gets full `AgentRuntime` functionality without linking
/// `LocalAgentKitSwiftUI` — the actual agent call lives in `SceneDelegate`, which is what sets up
/// the window (the scene-based lifecycle, not the deprecated `UIScreen.main`/`UIWindow(frame:)`
/// pair — both throw a deprecation error under this project's `SWIFT_TREAT_WARNINGS_AS_ERRORS`
/// at the iOS 26 floor, found by building, not assumed).
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    true
  }

  func application(
    _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: "Default Configuration", sessionRole: connectingSceneSession.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}
