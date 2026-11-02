# Thermal management

Sample thermal pressure at work boundaries and reduce the next request's resource budget.

## Enable device sampling

```swift
let runtime = try AgentRuntime(
  configuration: configuration,
  tools: toolSource,
  thermalStateSource: ProcessInfoThermalStateSource())
```

The adapter is in Providers and maps Foundation's `ProcessInfo.thermalState` into
Core's `AgentThermalState`. Runtime has no platform thermal API dependency.
`Examples/LocalAgentDemo` enables this source. Other runtimes default to nil, so
existing applications must opt in; there is no claim of automatic monitoring
without a configured source.

The source is sampled when a run starts, before planner iterations, before each
model request, after token counting/context fitting, and after required human
permission immediately before tool execution. It does not retain a notification
observer or poll continuously while idle or suspended. Consequently a critical
transition does not interrupt a model call, tool or human wait already in progress.
It is acted on at the next work checkpoint.

## Default policy

| State | Behavior |
| --- | --- |
| nominal | Original model and configured limits |
| fair | Additional context-window cap of 3072 tokens |
| serious | Additional context-window cap of 2048 tokens |
| unknown | Same reduced cap as serious pressure |
| critical | Reject new model/tool work with `AgentError.thermalPressureTooHigh` |

Caps include the answer reserve and are intersected with the model's window and
existing execution limits. They never enlarge a smaller window. A cap too small
for the request and reply reserve can produce `contextLimitExceeded` after fitting.
Configure `ThermalPolicy(fairContextTokens:seriousContextTokens:)` to choose other
positive, ordered caps; critical pressure always prevents new work. These defaults
are conservative choices, not a measured device cooling or battery guarantee.

If pressure increases during token counting, the wrapper refits before generation
using the tighter cap. Refit only moves toward smaller caps within that call; the
next model call can restore the original window after cooling. The existing
trim/summarize sequence, model-call and run deadlines still apply. There is no
automatic retry after a thermal error: let the device cool and allow a new
user-initiated run.

The current runtime executes one tool at a time and makes no speculative model
calls. Those constraints remain in place at elevated pressure. No new parallelism
or background prewarming is introduced. Thermal-aware parallel scheduling is a
future concern when M5-04 adds parallel tool execution.

## Observe changes and test them

`AgentEvent.thermalStateChanged` reports the initial status and subsequent sampled
changes, deduplicated within each run. `ThermalStatus.contextTokenCap` is the policy
cap; actual context utilization can be lower because of model or app limits.
`AgentViewModel.thermalStatus` exposes the latest status, and critical admission
errors follow the existing typed error and UI failure path.

Use `MockThermalStateSource` from Testing to drive transitions without heating a
device. Tests cover context caps, cooling, changes during token counting,
prevention of side effects when pressure becomes critical during human permission,
offline-policy rejection and UI state delivery. Direct ToolExecutor or provider
calls outside AgentRuntime do not receive this runtime policy automatically.

The local adapter API was checked against the installed SDK and sampled on macOS.
No physical-iPhone transition, battery improvement or performance overhead is
claimed by these tests. Real thermal and battery profiling remains M6-05.
