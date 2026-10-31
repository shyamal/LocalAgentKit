# LocalAgentKit

**The agent orchestration layer Apple's on-device model APIs don't provide.**

A privacy-first, on-device AI agent framework for Apple platforms. Apple's Foundation Models framework and Core AI now handle on-device model access, including bring-your-own-model and MLX support — so LocalAgentKit's job isn't to abstract the model, it's everything *around* it: the agent loop, planning and replanning, permission-gated tool calling, cross-session memory, and local RAG, all running on-device with no cloud dependency.

> Make it as easy to build a private, autonomous, on-device AI agent as it is to build a traditional iOS feature.

## Status

**Pre-alpha. There is no shipped functionality yet.** This repository currently contains a buildable but empty package skeleton — every target compiles, but holds only a placeholder file. Real implementation is gated on a feasibility spike (Phase 0) that has not yet run: see [`TASKS.md`](./TASKS.md) for the full plan and [`PLANNING.md`](./PLANNING.md) §5 for why that gate exists. Do not depend on this package yet.

## Why

Cloud-based AI integration (OpenAI, Anthropic, Gemini, and similar) means sensitive data can leave the device, per-request costs, a network dependency, added latency, and vendor lock-in. Apple's platform now offers a supported on-device alternative for model access itself — but every application still has to build the agent loop, planning, tool permissions, memory, and RAG from scratch. LocalAgentKit provides those as a reusable framework, on top of whichever model provider you choose.

## Quick start (target API — not yet implemented)

This is the developer experience the SDK is being built toward. None of it runs yet.

```swift
import LocalAgentKit

let agent = LocalAgent(configuration: .default)

agent.register(CalendarTool())
agent.register(ReminderTool())
agent.register(DocumentSearchTool())

let response = try await agent.run("Prepare me for tomorrow's meetings.")
print(response.text)
```

You should not need to implement the agent loop, context management, tool routing, tool schemas, memory retrieval, permission workflows, or event streaming yourself — unless you want custom behavior.

### Install (once published)

```swift
.package(url: "<repository URL>", from: "1.0.0")
```

No version has been tagged yet.

## Platform requirements

- iOS 26+ / macOS 26+ (visionOS and iPadOS to follow)
- Apple silicon Mac for development
- A physical Apple Intelligence-capable device for on-device model, thermal, and battery testing — the simulator can't measure any of these
- Swift 6.x, strict concurrency

The iOS/macOS 26 floor and the exact Foundation Models / Core AI API surface are described from the PRD's account of WWDC 2026 announcements and are **not yet verified** against a shipping SDK — see `PLANNING.md` §6, open question 1.

## Documentation

- [`LocalAgentKit-PRD-v0.2.md`](./LocalAgentKit-PRD-v0.2.md) — product requirements: vision, functional requirements, risks, non-goals
- [`PLANNING.md`](./PLANNING.md) — architecture, technology stack, package layout, open questions
- [`TASKS.md`](./TASKS.md) — the milestone-by-milestone task list, with stable task IDs
- [`CLAUDE.md`](./CLAUDE.md) — repository guidance for AI coding agents working in this codebase

## Non-goals

LocalAgentKit is an agent infrastructure SDK, not a consumer chatbot. It will not become a general-purpose ChatGPT replacement, provide a cloud-hosted AI platform, train foundation models, provide a centralized vector database, or re-implement the model abstraction Apple's platform now provides natively.

## Contributing

Not yet open for contributions — see [`TASKS.md`](./TASKS.md) Milestone 0 for the remaining bootstrap work (`CONTRIBUTING.md`, `LICENSE`, and CI are still pending).

## License

Not yet decided.


## API documentation

See [documentation catalogs and publishing setup](Documentation/README.md) for the
local DocC build and CI workflow. Hosted publication is not yet verified.
