# Experimental model planning

Opt into a model-proposed linear sequence while retaining runtime enforcement.

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

The validated sequence is compiled into an internal workflow. Each tool's arguments
are requested separately using its schema and earlier observations; those values
are not guaranteed to be grounded correctly merely because the sequence is valid.
The default permits up to seven tool steps plus one final-answer step, matching
the default eight-iteration execution bound. Runtime limits can stop it earlier.

## Enforcement remains in the runtime

Planning, argument generation, repair and answering all use the budgeted model
passed by the runtime. Context fitting, model-call deadlines, cancellation and
the run's limits apply to those requests. Every proposed execution still goes
through argument validation and the permission gate. A model-written instruction
cannot grant authorization. The initial sequence is published with `.planCreated`;
ordinary tool events and final completion remain available to observers.

## Limits and evidence

This implementation proposes a linear sequence once. It does not invent conditional
guards, binding expressions, alternative branches or revised plans after a failure.
Empty results and tool failures end the proposed sequence; steps have no automatic
execution retries or alternatives. Argument repair is still separately bounded.
For conditions and deterministic value dependencies, use declared workflows with
`StateMachinePlanner`.

Unit tests demonstrate integration and enforcement with scripted/mock providers.
No real-model success rate is established for this planner. Existing evaluation
reports measure the state-machine configuration and must not be attributed to it.
M5-01 and M5-02 retain richer model-driven planning/replanning work; M5-03 still gates
any promotion to the default with new measured evidence above the >95% target.
