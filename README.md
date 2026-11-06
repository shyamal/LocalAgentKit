# LocalAgentKit

**Build on-device agents with tools, local retrieval, and permission-gated actions.**

LocalAgentKit is a Swift SDK for iOS and macOS. It connects a model to an agent
loop that plans work, executes tools, carries conversation context, and asks for
human approval before sensitive actions. Use Apple's on-device model or supply
your own provider.

[API documentation](https://shyamal.github.io/LocalAgentKit/documentation/) ·
[First-agent guide](https://shyamal.github.io/LocalAgentKit/documentation/localagentkitruntime/buildyourfirstagent/) ·
[Custom-tool guide](https://shyamal.github.io/LocalAgentKit/documentation/localagentkittools/writeacustomtool/)

## Status

**Pre-alpha. No tagged release; APIs may change.** The runtime, built-in tools,
local RAG, SwiftUI integration, and evaluation harness are implemented. Milestone 1
validation is still in progress; see [TASKS.md](TASKS.md) for remaining gates.

The real model can repeat tools, refuse requests, or produce incorrect explanations.
Runtime limits and permissions bound execution; they do not guarantee answer
accuracy. The demo includes a deterministic workflow for its canonical calendar
question. Experimental model-driven planning is opt-in.

## What it provides

- **Agent execution:** deterministic workflows and open tool selection, cancellation,
  deadlines, execution limits, and loop detection.
- **Permission gates:** argument validation precedes approval and execution. Tools
  above `.readOnly` wait for explicit human confirmation.
- **Context management:** budgeting before model calls, trimming and summarization,
  and conversation memory across turns within a runtime session.
- **Durable memory:** explicit conversation checkpoints, facts/preferences and past
  events/actions through SwiftData stores. Configured memory is retrieved under the
  context budget. The demo restores recent completed turns after restart.
- **Local retrieval:** unified PDF/TXT/Markdown and in-memory text extraction, bounded file reads,
  structure-aware paragraph/section chunking, Natural Language embeddings with
  a word-vector fallback, in-memory or file-backed vector storage, and document search.
  Explicit retrieval settings add candidate limits, optional score filtering and
  deduplication; no answerability cutoff is calibrated.
- **Contact search:** explicit approval before local contact reads, separate OS
  authorization, and bounded contact-card results.
- **File search:** bounded, read-only filename/metadata search inside host-supplied
  folders, with explicit partial-scan results.
- **Local notes:** confirmed creation and read-only search of app-owned saved notes,
  with bounded search previews and compatible JSON persistence.
- **App integration:** observable SwiftUI state, permission sheets, streamed answers,
  and optional local diagnostics and thermal-policy handling.
- **Audit snapshots:** bounded local execution records and versioned JSON export
  that omits arguments by default; durable retention stays host-owned.
- **Testing:** mock and scripted providers, plus a CLI harness for measuring tool
  calling, multi-step completion, refusals, and context limits.

SDK library targets have no third-party runtime dependencies. The evaluation CLI
uses Swift Argument Parser. With `.never` network policy, the runtime rejects
components that declare a network requirement. Custom implementations must report
that requirement honestly; the policy is not an OS-level network sandbox.

## Quick start

On a Mac with the toolchain below:

```bash
git clone https://github.com/shyamal/LocalAgentKit.git
cd LocalAgentKit
swift run --package-path Examples/FirstAgent FirstAgent
```

Expected output:

```text
Tool calculate: 60
The result is 60.
Tool calls: 1
```

This uses a **scripted model** with the real runtime and calculator. The tool
computes 60; the final sentence is scripted. No model assets are required.
Initial package dependency resolution may use the network.

To try the local Mac's on-device model:

```bash
swift run --package-path Examples/FirstAgent FirstAgent --device
```

`--device` runs on the Mac; it does not deploy to an iPhone. Model output and tool
selection may vary. Follow the [first-agent guide](Documentation/LocalAgentKitRuntime.docc/BuildYourFirstAgent.md)
for setup and troubleshooting.

## Use in your app

In Xcode, add `https://github.com/shyamal/LocalAgentKit.git` as a package dependency
and select the `main` branch. For reproducible builds, pin a reviewed commit.
There is no versioned release to select yet.

Select the products you need; there is no umbrella `LocalAgentKit` module.

| Product | Purpose |
| --- | --- |
| `LocalAgentKitCore` | Protocols, configuration, tool schemas, events, and errors |
| `LocalAgentKitRuntime` | Agent loop, planners, context budgets, and permission enforcement |
| `LocalAgentKitProviders` | On-device model adapter, custom model adapter, embeddings, vector store, and diagnostics |
| `LocalAgentKitTools` | Calculator, calendar, reminders, document search, and app-owned note saving |
| `LocalAgentKitSwiftUI` | Optional view model and permission UI |
| `LocalAgentKitTesting` | Mock and scripted implementations for deterministic tests |

The generic `LanguageModelProvider` adapter requires iOS/macOS 27 and an
application-supplied model backend; no MLX model or weights are bundled.
`LocalAgentKitAppIntents` is a reserved placeholder, not a working integration.
Conversation checkpoints are available through explicit restore/save calls;
broader multimodal support remains roadmap work.

## Examples

- [FirstAgent](Examples/FirstAgent): calculator agent, scripted by default; supports
  `--device` and opt-in `--trace` diagnostics.
- [CustomTool](Examples/CustomTool): application-owned temperature converter with
  runtime integration in 76 source lines, tests, and optional `--device` mode.
- [LocalAgentDemo](Examples/LocalAgentDemo/README.md): iPhone/macOS chat app covering
  calendar lookup, note retrieval, checklist generation, and approved note saving.
  Its RAG notes are bundled fixtures, not the user's Apple Notes library.

## Requirements

- **Build:** Xcode 27 SDK and Swift 6.2 or later.
- **Deployment:** iOS 26.4+ or macOS 26.4+ for the system model provider.
- **Real system-model generation:** supported Apple Intelligence hardware, Apple
  Intelligence enabled, and model assets ready.
- **iPhone testing:** a physical supported iPhone. iOS Simulator cannot run Apple's
  on-device generative model. Scripted tests and custom model executors do not
  require that system model.

See the [SDK decision record](docs/decisions/0004-model-provider-seam-and-platform-floor.md)
and [Phase 0 findings](docs/phase-0-findings.md) for the verified platform boundaries.

## Development

```bash
swift build
swift test
bash Scripts/check-coverage.sh
bash Scripts/check-offline-tests.sh
bash Scripts/check-layering.sh
xcrun swift-format lint --configuration .swift-format --strict --recursive Sources Tests Package.swift
```

The default unit suite uses mocks and runs without model assets or a connected
device. The offline check denies socket networking to the already-built tests;
building and resolving dependencies happen beforehand. Coverage must reach 80%
for Core and Runtime.

[CONTRIBUTING.md](CONTRIBUTING.md) describes contribution and verification rules.
Report vulnerabilities through [GitHub's private reporting form](https://github.com/shyamal/LocalAgentKit/security/advisories/new);
see [SECURITY.md](SECURITY.md).

## Project documents

- [Published API documentation](https://shyamal.github.io/LocalAgentKit/documentation/)
- [Local documentation build and publishing](Documentation/README.md)
- [Product requirements](LocalAgentKit-PRD-v0.2.md)
- [Architecture and decisions](PLANNING.md)
- [Tasks and validation gates](TASKS.md)
- [Evaluation harness](docs/evaluation-harness.md)
- [Embedding-quality measurements](Benchmarks/EmbeddingQuality) and [provider policy](docs/decisions/0009-embedding-quality-and-provider-policy.md) — M3-04 benchmark complete; opt-in integration tracked separately.

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for project attribution.
