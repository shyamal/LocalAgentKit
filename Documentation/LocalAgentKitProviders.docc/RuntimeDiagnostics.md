# Runtime diagnostics

Enable local debug logs and signposts without importing OSLog into the runtime.

## Opt in

```swift
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitProviders

let runtime = try AgentRuntime(
  configuration: configuration,
  tools: toolSource,
  instrumentation: OSLogRuntimeInstrumentation())
```

Omitting `instrumentation:` uses `NoOpRuntimeInstrumentation`, which emits no logs.
The sink is separate from `AgentEvent` streams: UI and permission handling do not
depend on diagnostics. It receives generated run/interval IDs, fixed operation
labels and begin/end phases. It never receives goals, tool names, arguments,
observations, transcript text or error messages. An end means the scope exited,
not that it succeeded.

The adapter defaults to subsystem `org.localagentkit` and category `Runtime`.
Use static app-specific identifiers if overriding them. Unified log messages use
debug level; visibility and retention depend on system logging settings. Signpost
intervals are named `AgentOperation`, with operation/run/interval metadata.
Record with Instruments' Logging instrument, enable dynamic signpost tracing for
`org.localagentkit`, and filter by subsystem. Without dynamic tracing enabled, a
recording can save successfully yet contain no signpost rows.

## Interval scope

| Operation | Includes |
| --- | --- |
| `run` | Execution through completion/error event, including human waits |
| `planning` | Initial deterministic plan selection or experimental model proposal |
| `modelCall` | Context fitting, token counting and provider generation for one request |
| `toolCall` | A planned invocation, including validation, permission, repair and observation |
| `retrieval` | Automatic goal retrieval when both retrieval components are configured |
| `permission` | A required human decision, including its suspended wait |
| `clarification` | Waiting for the person to answer a clarification question |

Intervals overlap: model calls can be inside planning or a repaired tool call.
Do not sum them for total run time. They share a run ID without a parent/child
tree. Human waits remain excluded from execution deadlines even though these
intervals include wall time. Conversation-history reads and post-run memory
recording are outside `run`. Explicit document search is inside its tool interval;
it does not create an automatic-retrieval interval. Direct ToolExecutor or model
calls outside AgentRuntime have no runtime trace hooks.

Scopes close on success, error, refusal, timeout and cooperative cancellation.
An operation ignoring cancellation can continue after a deadline abandons it;
the interval ends at abandonment and does not claim underlying work stopped.
A process crash cannot emit deferred closing boundaries.

## Try the scripted example

```bash
swift run --package-path Examples/FirstAgent FirstAgent --trace
```

Run from the repository root. The real calculator still prints 60. Use the built
FirstAgent executable as an Instruments launch target with argument `--trace`,
record the Logging instrument and look for `AgentOperation` signposts. This path
needs no model assets. Add `--device` separately for real local-model generation;
real-model profiling and physical-iPhone overhead are not established by a
scripted smoke recording.

## Custom sinks

`LocalAgentKitCore.RuntimeInstrumentation` is synchronous and Sendable. A sink must
be thread-safe, return promptly and avoid reentering the runtime. The OSLog adapter
holds a short mutex only while pairing signpost state; no lock spans an await or
human-input wait. Unique signpost identities support shared sinks and concurrent
runtimes. Duplicate begins and unmatched or mismatched ends do not add or close
signpost intervals.

`LocalAgentKitTesting.MockRuntimeInstrumentation` records boundaries without OSLog.
Network-backed sinks must declare `requiresNetwork` true; the runtime rejects
them under `.never`. The default declaration is false and the OSLog adapter is
local. Do not put user content into subsystem/category identifiers or join trace
IDs to sensitive payloads in exported logs without appropriate app controls.

## Local verification

On 2026-11-02, a macOS scripted calculator recording exported signpost records for
seven distinct interval IDs: one run, one planning interval, four model calls and
one tool call, all with opening and closing boundaries. The CLI Logging template
used `os_signpost.dynamicTracingEnabledSubsystems: ["org.localagentkit"]` in its
recording-options JSON and a one-second shell launch delay for the short executable.
The exported unified-log table was empty at default debug-log settings; this is
not evidence of persistent debug-log retention. The trace binary remains a local
verification artifact rather than a committed SDK resource. No physical-iPhone
trace or overhead measurement is claimed.
