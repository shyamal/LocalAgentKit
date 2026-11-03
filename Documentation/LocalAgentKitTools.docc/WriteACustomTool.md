# Write a custom tool

Expose a temperature conversion to an agent in fewer than 100 lines of application code.

## Run the complete example

Start with the repository checkout and toolchain described in the first-agent
guide. From the repository root:

```bash
swift run --package-path Examples/CustomTool CustomTool
swift test --package-path Examples/CustomTool
wc -l Examples/CustomTool/Sources/TemperatureTools/TemperatureTool.swift Examples/CustomTool/Sources/CustomTool/CustomTool.swift
```

The executable uses a scripted model, the actual runtime and the custom tool.
It needs no model assets or device. Dependency resolution during the build can
use the network. The expected program output is:

```text
Tool: 68.0 degrees Fahrenheit
20 degrees Celsius is 68 degrees Fahrenheit.
Tool calls: 1
```

The final sentence is scripted; the first line is the tool's computed result.
The two application source files total 76 physical lines, including imports,
blank lines, schema, registration, event handling and the model script. The
package manifest and tests are excluded from that count. The tool itself is
30 lines. This demonstrates the local code-size target; independent newcomer
validation of metric M2 remains pending.

## Choose the permission tier first

Ask what could happen if a manipulated model supplied every argument. This tool
only converts an explicit number: no I/O, user data or side effects, so its tier
is `.none`. It cannot read a document or send information elsewhere.

| Tier | Appropriate capability | Confirmation |
| --- | --- | --- |
| `.none` | Pure computation | No |
| `.readOnly` | Reads authorized app data without mutation or an exfiltration path | No |
| `.userConfirmation` | Creates or changes recoverable user data | Yes |
| `.sensitive` | Reads sensitive personal information | Yes |
| `.destructive` | Deletes, sends, spends or performs another irreversible action | Yes |

Choose the higher tier when uncertain. Confirmation does not replace operating
system authorization. Do not make the tier configurable or turn a read tool's
free-text argument into an arbitrary destination. Schema validity cannot authorize
a write; the permission gate is the injection defense.

## Implement the contract

The complete implementation lives in
`Examples/CustomTool/Sources/TemperatureTools/TemperatureTool.swift`.
It imports only Core and conforms to `LocalAgentKitCore.AgentTool`:

- `name` is `convert_temperature`: unique, verb-first and snake case.
- `description` tells the model what to choose it for.
- `schema` requires a numeric `celsius` value, bounded from -273.15 to 1000.
  Its description states units and limits. Unknown properties are rejected.
- `permission` is fixed at `.none` for this pure function.
- `isParallelSafe` is true because invocations share no mutable state.
- `isCancellable` is true because it checks cancellation on entry and performs
  only a short bounded computation. There is no asynchronous operation to interrupt.

`execute(arguments:)` checks cancellation, validates its input defensively, decodes
the number, computes Fahrenheit and returns compact text plus a structured number.
Failures are typed `AgentError` values. `ToolResult.callID` starts empty; the runtime
executor fills it from the invocation before recording the observation.

If your implementation awaits I/O, check cancellation around those operations and
propagate it. Declare `isCancellable` false if the underlying operation cannot
actually stop. Validate paths, URLs and resource identifiers beyond the schema
before using them; a string parameter is not a safe filesystem capability.

## Register with the runtime

The executable in `Examples/CustomTool/Sources/CustomTool/CustomTool.swift` registers
the tool directly:

```swift
let runtime = try AgentRuntime(
  configuration: AgentConfiguration(model: model, networkPolicy: .never),
  tools: StaticToolSource([TemperatureTool()]))
```

An application can keep this type in its own module; adding a custom tool does not
require editing SDK sources. Use distinct names for all registered tools.
The example's script selects `convert_temperature`, fills
`provide_convert_temperature_arguments`, chooses `finish`, then supplies the
answer. These are the default planner's decision and argument requests, not
additional executable tools you must register.

To try the local Mac's real model, run:

```bash
swift run --package-path Examples/CustomTool CustomTool --device
```

This selects `FoundationModelProvider()` with the same runtime and application
owned tool. It does not deploy to an iPhone. The default mode remains scripted
and needs no model assets. The executable links Providers in both modes, requiring
the Xcode 27 SDK described in the first-agent guide.

Use supported Apple Intelligence hardware with model assets ready. Check the
`Tool:` line for the computed result and the tool-call count; the model's final
wording alone does not prove execution. Model tool selection is not guaranteed.
A local maintainer smoke run on 2026-11-03 executed the converter twice and
returned 68.0 both times, but the generated explanation contained an incorrect
formula. This verifies integration, not explanation accuracy or a reliability rate.

A refusal or execution error ends the run without falling back to a scripted
answer. See the first-agent guide for availability and context-limit failures.

## Verify behavior before exposing a capability

The checked-in tests cover the real custom type:

1. A `MockModelProvider` drives the runtime to execution; the observed structured
   result is 68, there is one tool call and its call ID is populated.
2. Missing, incorrectly typed, out-of-range and unknown arguments are rejected
   by the executor before its recording wrapper is invoked.
3. A denying gate is never consulted for this `.none` tool, which still executes.
4. An already-cancelled task gets `.cancelled` on entry. This tests the cancellation
   boundary of a short computation, not interruption of a long operation.

For any tool above `.readOnly`, also test that a valid call cannot execute without
human confirmation, denial prevents execution, and a call prompted by adversarial
document text still stops at the gate. The pure converter does not exercise those
confirmation paths. The SDK's security tests provide those patterns; never copy
an always-approve gate into an app to make a tutorial run.

When adding a production tool, add a harness scenario describing the expected
tool, arguments and permission outcome. This example's deterministic runtime test
is a smoke scenario for the guide, not a new measured real-model reliability result.
