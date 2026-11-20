# Experimental model planning

Opt into a model-proposed conditional workflow while retaining runtime enforcement.

## Select the planner

```swift
let configuration = AgentConfiguration(model: model, planner: .modelDriven)
let runtime = try AgentRuntime(configuration: configuration, tools: toolSource)
```

The default remains `.stateMachine`, per the Phase 0 findings. Supplying a `planner:`
instance directly overrides either configured choice. To customize the experimental
length and repair bounds, pass `ModelDrivenPlanner(maxSteps: 4, maxRepairs: 1)`.
The `workflows:` argument configures only the built-in state-machine planner.

## What the model proposes

The initial `propose_tool_plan` query asks for an ordered array of registered tool
names, brief step summaries, per-step instructions and one final-answer instruction.
This is a planning schema, not an executable tool registered with the runtime.
The proposal is validated before any step runs. Unknown tool names, too many
steps, malformed fields and blank instructions are rejected as invalid arguments.
Schema-shape errors have bounded repair attempts; semantic plan failures end the run.
Refusals are terminal, including during repair.

The validated plan is compiled into an internal workflow. Results bind to `step_1`,
`step_2`, and so on. A later step can use an exact result or a dot-separated path
such as `step_1.0.title`, without asking the model to reconstruct it. References
must name earlier generated steps; forward, self, memory and arbitrary input
references are rejected before any proposed tool executes.

Each step optionally proposes:

- `arguments`: an array of `name`, `source`, `value` objects. `source` is `binding`,
  `literal` or `model`; `value` is respectively an earlier-result path, JSON literal
  text or a model hint. Duplicate/unknown parameter names and malformed or
  schema-incompatible literals are rejected. JSON literal text is limited to
  16,384 UTF-8 bytes. Unspecified parameters keep the existing per-step model
  generation behavior.
- `conditions`: up to eight flat guards with `reference`, `operator` and, for
  comparisons, `value_json`. Operators are `exists`, `is_empty`, `not_empty`,
  `equals`, `less_than`, `at_most`, `at_least` and `greater_than`. Comparisons use
  JSON literal text; numeric operators require a finite number. `condition_mode`
  selects `all` (default) or `any`. No conditions means unconditional execution.
- `retries`: zero (default) through two extra attempts for recoverable failures.
- `on_empty`: `fail` (default) or `skip`, allowing later guarded fallback steps.

For example, a later step can copy the observed count only when it is large enough:

```json
{
  "tool": "record_count",
  "summary": "Record the observed count",
  "instruction": "Use the exact count returned by the first step.",
  "arguments": [{"name": "count", "source": "binding", "value": "step_1.count"}],
  "conditions": [{"reference": "step_1.count", "operator": "at_least", "value_json": "10"}],
  "retries": 0
}
```

Conditions run in code against observed results. Complementary guards can select
conditional paths within the ordered plan; this is not parallel/DAG scheduling.
A missing or incompatible binding fails before runtime argument repair can invent
a replacement. A condition on a missing/unusable value follows the declared guard
semantics, rather than a model interpreting an instruction. Skipped steps produce
no binding; later required dependencies on those steps fail unless also guarded.

The default permits seven tool steps plus a final-answer step. Runtime limits,
including loop detection, can stop earlier. In particular, a third consecutive
identical call is a loop even if the plan allows two retries. Empty-result skip
and retries never bypass permission denial or turn failed results into facts.

## Enforcement remains in the runtime

Planning, argument generation, repair and answering all use the budgeted model
passed by the runtime. Context fitting, model-call deadlines, cancellation and
the run's limits apply to those requests. Every proposed execution still goes
through argument validation and the permission gate. A model-written instruction
cannot grant authorization. The initial sequence is published with `.planCreated`;
ordinary tool events and final completion remain available to observers.

## Limits and evidence

This implementation proposes a complete bounded workflow once. It does not revise
that workflow from unexpected observations, introduce new tools after execution,
or generate unbounded/recursive expressions. Open-ended replanning remains M5-02;
parallel execution and dependency scheduling remain M5-04/05. Declared workflows
remain available when application code should own the plan shape.

Unit tests demonstrate proposal validation, structured-result grounding, conditional
execution and runtime enforcement with scripted/mock providers. They establish no
real-model success rate. Existing state-machine evaluation reports must not be
attributed to this configuration. M5-03 still gates promotion with fresh per-OS
measurements above the >95% target. The default is unchanged.
