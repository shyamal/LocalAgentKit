import LocalAgentKitCore

/// What the runtime should do next.
public enum PlannerDecision: Sendable {
  /// Run this call through `ToolExecutor`, then report the outcome with ``AgentPlanner/observe(_:context:)``
  /// or ``AgentPlanner/handleFailure(_:context:)``. The runtime gives each invocation a unique
  /// execution ID; use the observed call ID to correlate runtime events and results.
  case callTool(ToolCall)
  /// The goal is achieved; this is the answer.
  case complete(String)
  /// The model needs the user to say more. The run suspends until they answer.
  case askUser(String)
  /// Publishes a validated replacement plan before the next executable decision.
  /// This decision consumes an iteration like every other planner decision.
  case revisePlan(AgentPlan)
}

/// Whether observing a result or handling a failure changed the displayed plan.
public enum PlanRevision: Sendable {
  /// Continue using the existing plan.
  case `continue`
  /// A synchronous observation handler changed the displayed plan.
  /// Async model revisions use `PlannerDecision.revisePlan` instead.
  case replanned(AgentPlan)
}

/// Decides what an agent does next (FR-026, FR-027). The runtime executes; the planner decides.
///
/// A planner is stateless: everything about the run is in the `AgentContext` passed `inout`.
/// The model it is handed is the runtime's budgeted, deadline-bound one, never a raw provider.
public protocol AgentPlanner: Sendable {
  /// Called once, before the first `next`. Returns the plan the UI shows (`.planCreated`).
  func plan(
    context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider
  ) async throws -> AgentPlan

  /// Chooses a tool invocation, final answer or clarification request using the current run state.
  /// The supplied model enforces the runtime's context budget and deadlines.
  func next(
    context: inout AgentContext, tools: [ToolDescriptor], model: any LocalModelProvider
  ) async throws -> PlannerDecision

  /// A tool call returned. May throw a typed error if the plan cannot continue (FR-027).
  func observe(_ observation: ToolObservation, context: inout AgentContext) throws -> PlanRevision

  /// A tool call failed with `error`. Rethrows what cannot be recovered; a permission denial is
  /// always rethrown, so recovery can never route around a human's "no".
  func handleFailure(_ error: AgentError, context: inout AgentContext) throws -> PlanRevision
}
