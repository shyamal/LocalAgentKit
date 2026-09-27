/// The permission tier every tool must declare (FR-009).
///
/// This is the primary defense against a manipulated model, so it is deliberately not
/// configurable: nothing above ``readOnly`` executes without explicit human confirmation, and no
/// configuration flag may lower a tier.
public enum ToolPermission: Int, Sendable, Hashable, Codable, Comparable, CaseIterable {
  /// Pure computation with no side effects and no personal data (a calculator).
  case none
  /// Reads user data without changing anything (calendar read).
  case readOnly
  /// Changes something the user can easily undo (create a reminder).
  case userConfirmation
  /// Touches data the user would consider private, or reaches outside the app.
  case sensitive
  /// Removes or overwrites data irreversibly.
  case destructive

  public static func < (lhs: ToolPermission, rhs: ToolPermission) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// Whether a call at this tier must be confirmed by a human before it executes.
  public var requiresConfirmation: Bool { self > .readOnly }
}
