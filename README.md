# LocalAgentKit

**The agent orchestration layer Apple's on-device model APIs don't provide.**

A privacy-first, on-device AI agent framework for Apple platforms. Apple's Foundation Models framework and Core AI now handle on-device model access, including bring-your-own-model and MLX support — so LocalAgentKit's job isn't to abstract the model, it's everything *around* it: the agent loop, planning and replanning, permission-gated tool calling, cross-session memory, and local RAG, all running on-device with no cloud dependency.

> Make it as easy to build a private, autonomous, on-device AI agent as it is to build a traditional iOS feature.

## Status

**Pre-alpha; APIs may change.** Phase 0 has reported and Milestone 1 has a working
runtime, tools, local retrieval, SwiftUI integration and an evaluation harness.
Some capabilities and validation remain unfinished; see [`TASKS.md`](./TASKS.md)
for current gates and measured limitations.

## Why

Cloud-based AI integration (OpenAI, Anthropic, Gemini, and similar) means sensitive data can leave the device, per-request costs, a network dependency, added latency, and vendor lock-in. Apple's platform now offers a supported on-device alternative for model access itself — but every application still has to build the agent loop, planning, tool permissions, memory, and RAG from scratch. LocalAgentKit provides those as a reusable framework, on top of whichever model provider you choose.

## Quick start

Follow [Build your first agent](Documentation/LocalAgentKitRuntime.docc/BuildYourFirstAgent.md)
for setup, an explanation of the loop, and the real-model path. From this checkout:

```bash
swift run --package-path Examples/FirstAgent FirstAgent
```

This runs a scripted model through the real runtime and calculator, without model
assets. Add `--device` to use the local Mac's on-device model. There is no tagged
release yet; the example depends on this checkout as a local Swift package.

## Platform requirements

- iOS 26.4+ / macOS 26.4+
- Xcode 27 SDK and Swift 6.2+ to build the current source
- Apple Intelligence-capable hardware with model assets ready for real generation
- A physical supported iPhone for iOS model, thermal and battery testing; iOS Simulator cannot run real generation

The scripted first-agent example runs on Mac without Apple Intelligence assets.
The platform floor and SDK findings are recorded in `docs/decisions/` and
`docs/phase-0-findings.md`.

## Documentation

- [`LocalAgentKit-PRD-v0.2.md`](./LocalAgentKit-PRD-v0.2.md) — product requirements: vision, functional requirements, risks, non-goals
- [`PLANNING.md`](./PLANNING.md) — architecture, technology stack, package layout, open questions
- [`TASKS.md`](./TASKS.md) — the milestone-by-milestone task list, with stable task IDs
- [`CLAUDE.md`](./CLAUDE.md) — repository guidance for AI coding agents working in this codebase

## Non-goals

LocalAgentKit is an agent infrastructure SDK, not a consumer chatbot. It will not become a general-purpose ChatGPT replacement, provide a cloud-hosted AI platform, train foundation models, provide a centralized vector database, or re-implement the model abstraction Apple's platform now provides natively.

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for contribution and verification guidance.

## License

Not yet decided.


## API documentation

See [documentation catalogs and publishing setup](Documentation/README.md) for the
local DocC build and CI workflow. Hosted publication is not yet verified.
