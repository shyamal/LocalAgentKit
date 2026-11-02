# Build your first agent

Run a calculator agent, observe its tool result, then switch to the on-device model.

## Before you start

Use an Apple silicon Mac running macOS 26.4 or later, with full Xcode 27 selected
and Swift 6.2 or later. The checked-in example imports Providers, so it needs the
Xcode 27 SDK even when running with a scripted model. Check `xcodebuild -version`
and `swift --version` in Terminal. Building may download Swift package dependencies;
the scripted agent itself needs neither a model asset nor network access.

The real-model step requires Apple Intelligence enabled and its model assets ready
on a supported Mac. For iPhone UI integration use the separate demo project on a
physical Apple Intelligence-capable iPhone, iOS 26.4 or later. iOS Simulator cannot
run this provider's on-device generation.

## 1. Get the source and run the example

There is no tagged SDK release yet. Use the source checkout so the example and
the API stay together:

```bash
git clone https://github.com/shyamal/LocalAgentKit.git
cd LocalAgentKit
swift run --package-path Examples/FirstAgent FirstAgent
```

If you already have this checkout, run just the last command from its root.
The example is in `Examples/FirstAgent/Sources/FirstAgent/FirstAgent.swift`.
Expected output:

```text
Tool calculate: 60
The result is 60.
Tool calls: 1
```

The scripted provider chooses `calculate`, supplies its expression, then chooses
`finish` and returns a fixed answer. The runtime still validates arguments and
executes the real calculator. The `Tool calculate: 60` line comes from that
execution; the final sentence is scripted and does not prove model reasoning.

## 2. Understand the setup

There is no umbrella `LocalAgentKit` import or `LocalAgent` constructor. Import
the products you use. Core supplies configuration and value types; Runtime runs
the loop; Tools supplies the calculator; Providers supplies the real model;
Testing supplies the deterministic script.

The essential setup in the example is:

```swift
let runtime = try AgentRuntime(
  configuration: AgentConfiguration(model: model, networkPolicy: .never),
  tools: StaticToolSource([CalculatorTool()]))
let response = try await runtime.run("Calculate (12 + 8) * 3.")
print(response.text)
```

The default planner is `StateMachinePlanner`. It asks the model for each decision
and uses a separate request to fill a selected tool's arguments. The scripted
responses mirror those requests. The runtime bounds iterations, tool calls and
time, and fits context before model calls. `.never` rejects components declaring
a network requirement at construction.

The example subscribes to ``AgentRuntime/events()`` before `run` so it can observe
the tool result. It finishes the stream and awaits the consumer on success and
failure. A runtime runs one goal at a time; reuse it sequentially. For follow-up
turns, pass a `ConversationMemory` through its `memory:` initializer argument.

## 3. Try the real model

```bash
swift run --package-path Examples/FirstAgent FirstAgent --device
```

Here `--device` means the local Mac's real model; it does not deploy to an iPhone.
It replaces the script with `FoundationModelProvider()` and keeps the same runtime
and calculator. The wording and number of tool calls may vary. Check the tool
result line to see whether the model actually selected the calculator. Model
accuracy is measured in the evaluation harness and is not guaranteed by this guide.

If generation fails with `modelUnavailable`, check Apple Intelligence availability
and asset readiness in system settings. A `guardrailRefusal` is terminal: offer a
non-agentic path instead of retrying it. For `contextLimitExceeded`, reduce history,
retrieved text or tool descriptions; raising iteration limits does not enlarge the
model window. A loop or execution limit is a failed run, not a successful answer.

Add `--trace` to either example mode to opt into local OSLog and signpost
intervals. It leaves the default output and model selection intact. See the
Providers catalog's Runtime diagnostics article for recording settings and scope.

## 4. Move into an app

Add this checkout as a local Swift package in Xcode. Select the Core, Runtime,
Providers and Tools products, plus SwiftUI for its optional `AgentViewModel` and
permission sheet. `Examples/LocalAgentDemo/README.md` describes the app project,
signing, calendar usage descriptions, RAG fixtures and permission UI.

The calculator has permission `.none`. A tool above `.readOnly` suspends for human
confirmation when no custom gate is supplied. A host must observe
`.permissionRequired` and call `resolvePermission(callID:approved:)` after the
person decides. Clarification requests likewise need an answer or cancellation;
this minimal command-line example is intended for the calculator goal only.

## Validate the 30-minute setup target

M1-DC-02 remains in progress until a developer unfamiliar with the repository tries
this guide. Record their OS, Xcode version and checkout revision, start time at
package setup, time to first successful `run`, whether they used the script or
real model, and every intervention. Measure the real-model path separately from
the scripted smoke check. Do not infer the 30-minute target from a maintainer's
incremental build or claim success if the newcomer needed undocumented help.
