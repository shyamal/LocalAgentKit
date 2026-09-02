# LocalAgentKit
## Product Requirements Document (PRD)

**Version:** 0.2
**Status:** Draft
**Product Type:** Native iOS/macOS AI Agent SDK
**Primary Platform:** Apple platforms
**Architecture:** Privacy-first, on-device AI
**Target Users:** iOS developers, AI developers, enterprise developers, privacy-sensitive application teams

---

## Changelog — v0.1 → v0.2

This revision does not change the product's ambition. It changes two things: where the SDK's real differentiation sits, and what has to be proven true before the MVP is built rather than assumed.

- **Repositioned the core value proposition.** At WWDC 2026, Apple opened the Foundation Models framework to third-party LLM providers, made MLX a first-class citizen in that same API, shipped a Python SDK, and replaced Core ML with Core AI. Apple is now doing model abstraction itself. v0.1 pitched "abstract Foundation Models, Core AI, and custom runtimes behind one interface" as the headline differentiator — that ground has shrunk. v0.2 keeps the model-provider abstraction (it's still useful) but moves the agent loop, planning, memory, local RAG, and permission-gated tool execution to the front of the pitch, since Apple is not building those.
- **Added a Key Risks & Assumptions section (Section 5)** naming the one assumption the entire product depends on: that a compact on-device model can reliably drive multi-step planning, replanning, and structured tool calls. This was implicit in v0.1's FR-026–028 and untested.
- **Added a Phase 0 feasibility spike** to the roadmap, gating the start of full v0.1 engineering work.
- **Added FR-029 (Tool-Calling Reliability Harness)** and **NFR — Context Window Management**, both direct responses to real, documented developer friction with the on-device model (context-length errors, guardrail restrictiveness).
- **Sharpened the prompt-injection mitigation** in the security threat model — permission gating is named explicitly as the actual backstop, not one item in a list of nouns.
- **Added adoption/DX metrics** alongside the existing engineering metrics, since this is a developer-facing SDK and engineering quality alone doesn't tell you if anyone used it.

Everything else — the protocol-first architecture, the tool registry, the MVP scope discipline, the non-goals — held up and is carried forward largely unchanged.

---

# 1. Executive Summary

LocalAgentKit is a **privacy-first, on-device AI agent framework** for Apple platforms.

It provides developers with a reusable architecture for building AI agents that can understand natural-language goals, reason over local context, retrieve information from local data, invoke tools, maintain memory, process multimodal inputs, and complete multi-step tasks.

The framework is designed around an **offline-first architecture**. The core agent should be capable of operating without requiring cloud AI APIs.

Apple's own platform has moved toward this goal over the past year: the Foundation Models framework now accepts third-party and custom LLM providers (including MLX models) directly, and Core AI has replaced Core ML as the modern on-device ML runtime. That means developers already have a supported way to swap the underlying model. LocalAgentKit's job is no longer to invent that abstraction — it's to provide everything Apple's platform still doesn't: the agent loop, planning and replanning, cross-session memory, local RAG, and a permission system that gates what an autonomous local agent is allowed to do. LocalAgentKit will still provide a thin model-provider interface for convenience and testability, but it is not the product's center of gravity.

### Product vision

> **Make it as easy to build a private, autonomous, on-device AI agent as it is to build a traditional iOS feature.**

---

# 2. Problem Statement

Current AI application development frequently requires developers to integrate cloud-based APIs such as:

- OpenAI
- Anthropic
- Google Gemini
- other hosted LLM providers

This creates several problems:

### Privacy

Sensitive information must potentially leave the user's device.

### Cost

AI applications can incur per-request or per-token infrastructure costs.

### Connectivity

Cloud AI functionality depends on network connectivity.

### Latency

Requests must travel between the device and remote infrastructure.

### Vendor dependency

Applications become tightly coupled to a particular AI provider.

### Agent complexity

Model access is no longer the hard part — Apple's Foundation Models framework and Core AI now provide a supported path to on-device and bring-your-own-model inference. What developers still have to build themselves, on every project, is everything *around* the model:

- agent loops
- multi-step planning and replanning
- tool calling with permission enforcement
- memory (working, conversational, semantic, episodic)
- local RAG
- loop and failure detection
- multimodal orchestration (vision, speech, documents)
- state management and event streaming for UI

LocalAgentKit aims to provide these components as a reusable framework, sitting a layer above whichever model provider a developer chooses.

---

# 3. Product Vision

LocalAgentKit will provide a standard architecture for building:

> **Local AI agents that understand goals, reason over local information, use tools, remember context, and execute multi-step tasks while keeping user data on the device.**

The framework should make the following experience possible:

```text
User
 ↓
Natural-language goal
 ↓
Local AI model
 ↓
Context + Memory + RAG
 ↓
Planning
 ↓
Tool selection
 ↓
Permission
 ↓
Tool execution
 ↓
Observation
 ↓
Re-planning
 ↓
Completion
```

---

# 4. Product Goals

## Primary goals

### G1 — On-device AI

Provide an abstraction over local AI inference, built on top of (not in competition with) Apple's Foundation Models / Core AI bring-your-own-model support.

### G2 — Agent runtime

Provide a reusable agent execution loop. **This is the primary differentiator (see Section 5).**

### G3 — Tool calling

Allow agents to safely interact with application capabilities.

### G4 — Memory

Provide local short-term and long-term memory.

### G5 — Local RAG

Allow agents to reason over locally stored documents.

### G6 — Multimodal AI

Support text, image, document, voice and other input types.

### G7 — Privacy

Make offline execution and local data storage first-class features.

### G8 — Extensibility

Allow developers to add their own models, tools and memory providers.

### G9 — Testability

Allow every component to be mocked and tested independently.

### G10 — Validated capability (new)

Do not ship agentic capabilities (planning, replanning, loop detection) that have not been measured against the real on-device model's actual reliability. See Section 5 and FR-029.

---

# 5. Key Risks & Assumptions

This section did not exist in v0.1. It should be read before the rest of the document, because several functional requirements below (planning, replanning, loop detection) are only as good as the assumptions here hold up.

## R1 — On-device model capability for agentic tool use (highest priority)

Multi-step planning, replanning on unexpected tool results, and loop detection across repeated tool calls are hard problems for large cloud models and have not been demonstrated at the same reliability on a compact on-device model. Small models are generally worse at producing valid structured tool-call arguments and at maintaining planning state across turns.

**Mitigation / validation plan:** before committing engineering time to FR-026 (Planning) and FR-027 (Replanning) as MVP-blocking work, run a feasibility spike (Phase 0, Section 47) that measures structured tool-call validity rate and multi-step task completion rate against the shipping on-device model, across a fixed set of representative goals. If reliability is materially below the M5 target (>95% tool execution success), the planner should be redesigned as a deterministic state machine that *consults* the model for individual decisions rather than one that lets the model freely drive the loop end-to-end.

## R2 — Context window constraints

The on-device model's context window is small enough that real applications have hit context-length errors in production. Conversation memory, RAG context injection, and multi-step planning all compete for the same limited budget.

**Mitigation:** context budgeting is a first-class runtime concern, not an implementation detail — see the new NFR in Section 36 and FR-029.

## R3 — Guardrail restrictiveness

The on-device model ships with built-in content guardrails that developers have publicly reported as restrictive for legitimate use cases. An agent framework aimed at enterprise and general-purpose use cases may hit refusals on ordinary business tasks (e.g., anything touching health, finance, or legal phrasing, even in benign contexts like an expense tool).

**Mitigation:** the framework should surface guardrail refusals as a distinct, typed error (not a generic model failure) so applications can degrade gracefully — e.g., falling back to a non-agentic path or asking the user to complete the step manually — rather than treating a refusal as a bug to retry.

## R4 — Model behavior drift across OS versions

Apple controls when the underlying on-device model changes (tied to OS updates), and developers do not control that cadence. A tool-calling pattern that works reliably on one OS version is not guaranteed to work identically after an update.

**Mitigation:** FR-029's reliability harness should be runnable as a regression suite against OS betas, so developers get an early signal when an OS update changes agent behavior, rather than discovering it from user bug reports.

## R5 — Shrinking model-abstraction differentiation

Apple's own bring-your-own-model support in Foundation Models reduces the uniqueness of LocalAgentKit's model-provider protocol. This is addressed by the repositioning in Sections 1 and 4 (G2 as primary differentiator) rather than by a technical mitigation.

---

# 6. Non-Goals

The initial product will NOT attempt to:

- become a general-purpose ChatGPT replacement
- provide a cloud-hosted AI platform
- train foundation models
- provide a centralized vector database
- automatically access every device capability
- allow unrestricted autonomous device control
- expose hidden model reasoning to users
- guarantee human-level autonomous decision making
- re-implement model abstraction that Apple's platform now provides natively (see Section 5, R5) — LocalAgentKit's model-provider protocol exists for testability and cross-version convenience, not as a claim of unique capability

LocalAgentKit is an **agent infrastructure SDK**, not a consumer chatbot.

---

# 7. Target Users

## Persona 1 — iOS Developer

An experienced Swift developer who wants to add AI agents to an existing application.

Needs:

- simple APIs
- native Swift
- Swift Concurrency
- strong typing
- easy integration
- testability

---

## Persona 2 — AI Developer

Developer experimenting with:

- local LLMs
- RAG
- agent architectures
- tool calling
- multimodal AI

Needs:

- model flexibility
- custom model support
- experimentation capabilities

---

## Persona 3 — Enterprise Developer

Building applications containing sensitive business information.

Needs:

- offline execution
- data privacy
- permission controls
- audit logs
- predictable behavior
- **graceful handling of model guardrail refusals** (new — see R3)

---

## Persona 4 — Independent Developer / Startup

Wants to create AI-powered applications without paying cloud inference costs for every interaction.

Needs:

- low infrastructure cost
- local inference
- reusable agent components
- rapid development

---

# 8. Core Product Architecture

```text
┌──────────────────────────────────────────────┐
│                APPLICATION                   │
│                                              │
│       SwiftUI / UIKit / App Intents          │
└───────────────────────┬──────────────────────┘
                        │
                        ▼
┌──────────────────────────────────────────────┐
│               LOCALAGENTKIT                  │
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │              AGENT CORE                 │ │
│ │      (primary differentiator)           │ │
│ │ Goal → Context → Plan → Execute → Loop  │ │
│ └──────────────────────┬───────────────────┘ │
│                        │                     │
│       ┌────────────────┼────────────────┐    │
│       ▼                ▼                ▼    │
│    MODELS            TOOLS           MEMORY  │
│       │                │                │     │
│ Foundation Models  Calendar        Working   │
│  (incl. BYO-LLM,   Reminder        Semantic  │
│   MLX models)      Contacts        Episodic  │
│ Core AI            Files           Convers.  │
│ Custom LLM         Files           │     │
│       │                │                │     │
│       └────────────────┼────────────────┘     │
│                        ▼                     │
│                  LOCAL RAG                   │
│                        │                     │
│              Documents / Embeddings          │
│                                              │
│ ┌──────────────┐  ┌──────────────┐           │
│ │ Vision       │  │ Speech       │           │
│ └──────────────┘  └──────────────┘           │
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │ Security / Permissions / Audit           │ │
│ └──────────────────────────────────────────┘ │
└───────────────────────┬──────────────────────┘
                        │
                        ▼
┌──────────────────────────────────────────────┐
│          APPLE / LOCAL RUNTIMES              │
│                                              │
│ Foundation Models (BYO-LLM, MLX) / Core AI / │
│ Vision / Speech / SwiftData / Local Models   │
└──────────────────────────────────────────────┘
```

Note the model layer is drawn as a thinner box than in v0.1's diagram: it now sits on top of Apple-provided abstraction rather than replacing it, and the Agent Core box carries the "primary differentiator" label.

---

# 9. Functional Requirements

## FR-001 — Agent Creation

Developers must be able to create an agent with a configuration object.

Example:

```swift
let agent = LocalAgent(
    configuration: .default
)
```

The configuration must support:

- model provider
- memory provider
- RAG provider
- vision provider
- speech provider
- security policy
- execution limits

---

## FR-002 — Natural Language Input

The agent must accept natural-language requests.

Example:

```swift
try await agent.run(
    "What meetings do I have tomorrow?"
)
```

The framework must support:

- text input
- image input
- document input
- audio input
- multimodal input

---

## FR-003 — Agent Runtime

The runtime must support:

```text
Goal
 ↓
Context
 ↓
Model
 ↓
Decision
 ↓
Tool
 ↓
Observation
 ↓
Model
 ↓
Completion
```

The runtime must support multiple iterations.

The runtime must have configurable limits:

- maximum iterations
- maximum tool calls
- maximum execution time
- maximum context size

---

## FR-004 — Model Provider

The framework must define a model abstraction. This exists for testability, portability across OS versions, and convenience — not as a claim of unique capability, since Apple's platform now supports bring-your-own-model natively (see Section 5, R5).

```swift
public protocol LocalModelProvider: Sendable {

    func generate(
        request: ModelRequest
    ) async throws -> ModelResponse
}
```

Initial providers:

### FoundationModelProvider

Wraps Apple's Foundation Models framework, including its current support for third-party and custom LLM providers and MLX models registered through that same API. LocalAgentKit should not duplicate this bring-your-own-model plumbing — it should sit on top of it.

### CoreAIModelProvider

Local/custom models supported through Apple's Core AI framework.

### MockModelProvider

Testing.

Future providers may include:

- direct llama.cpp integration for environments outside the Core AI / Foundation Models umbrella
- other local runtimes as they emerge

---

## FR-005 — Structured Model Output

The agent must distinguish between:

```text
Final answer
Tool request
Clarification
Guardrail refusal
Error
```

Example:

```swift
enum ModelResponse {

    case text(String)

    case toolCall(ToolCall)

    case multipleToolCalls([ToolCall])

    case clarification(String)

    case refused(GuardrailRefusal)
}
```

`refused` is new relative to v0.1 (see R3) — it lets applications distinguish "the model declined for policy reasons" from a generic failure, so they can degrade gracefully instead of retrying a request that will never succeed.

The framework must avoid relying exclusively on free-form text to execute tools.

---

## FR-006 — Tool System

Developers must be able to create custom tools.

```swift
protocol AgentTool {

    var name: String { get }

    var description: String { get }

    var schema: ToolSchema { get }

    var permission: ToolPermission { get }

    func execute(
        arguments: ToolArguments
    ) async throws -> ToolResult
}
```

---

## FR-007 — Tool Registry

Developers must be able to register tools.

```swift
agent.register(
    CalendarTool()
)

agent.register(
    ReminderTool()
)

agent.register(
    CalculatorTool()
)
```

The registry must support:

- registration
- lookup
- removal
- tool metadata
- tool schemas
- permission metadata

---

## FR-008 — Built-in Tools

MVP built-in tools:

### Calculator

Mathematical operations.

### Calendar

Read calendar events.

### Reminder

Create/read reminders.

### Contacts

Search contacts.

### Files

Search local files.

### Notes

Create/search local notes.

Additional tools may be added later.

---

## FR-009 — Permission System

Every tool must declare a permission level.

```swift
enum ToolPermission {

    case none

    case readOnly

    case userConfirmation

    case sensitive

    case destructive
}
```

Example:

```text
Calculator
→ none

Calendar read
→ readOnly

Create reminder
→ userConfirmation

Delete file
→ destructive
```

The framework must prevent unauthorized tool execution. **This permission system — not prompt inspection or heuristic injection detection — is the primary defense against a manipulated model attempting an unintended action.** See Section 46.

---

## FR-010 — Human-in-the-Loop

The agent must pause when a tool requires user approval.

Example:

```text
Agent wants to send message:

"Send this message to John?"

[Cancel] [Approve]
```

The agent resumes only after authorization.

---

## FR-011 — Memory

The framework must provide local memory.

Memory categories:

### Working Memory

Current task state.

### Conversation Memory

Current and previous conversation context.

### Semantic Memory

Persistent facts/preferences.

### Episodic Memory

Past events and actions.

---

## FR-012 — Memory Store

Provide:

```swift
protocol MemoryStore {

    func save(
        _ memory: Memory
    ) async throws

    func search(
        _ query: MemoryQuery
    ) async throws -> [Memory]

    func delete(
        id: UUID
    ) async throws
}
```

Initial implementation:

**SwiftDataMemoryStore**

Future:

**SQLiteMemoryStore**

---

## FR-013 — Local RAG

The framework must support document-based retrieval.

Pipeline:

```text
Document
 ↓
Extraction
 ↓
Chunking
 ↓
Embedding
 ↓
Vector Store
 ↓
Retrieval
 ↓
Context
 ↓
Local Model
```

Supported document types for MVP:

- PDF
- TXT
- Markdown
- plain text

Future:

- DOCX
- PPTX
- HTML
- images

---

## FR-014 — Embedding Provider

```swift
protocol EmbeddingProvider {

    func embed(
        text: String
    ) async throws -> [Float]
}
```

The implementation must be replaceable.

---

## FR-015 — Vector Store

```swift
protocol VectorStore {

    func insert(
        _ documents: [EmbeddedDocument]
    ) async throws

    func search(
        vector: [Float],
        limit: Int
    ) async throws -> [SearchResult]
}
```

The initial implementation should prioritize:

- local storage
- low memory usage
- fast retrieval
- no network dependency

---

## FR-016 — Vision

The framework must support local image processing.

Capabilities:

- OCR
- image classification
- object detection
- document understanding
- image-to-text
- structured extraction

Example:

```text
Receipt
 ↓
Vision
 ↓
Merchant
Date
Items
Tax
Total
```

---

## FR-017 — Speech

The framework must support:

### Speech-to-text

```swift
protocol SpeechRecognizer {

    func transcribe(
        audio: AudioInput
    ) async throws -> String
}
```

### Text-to-speech

```swift
protocol SpeechSynthesizer {

    func synthesize(
        text: String
    ) async throws -> AudioOutput
}
```

---

## FR-018 — Multimodal Agent

The agent must support requests such as:

```text
Image + Text
Audio + Text
Document + Text
Image + Document + Text
```

Example:

> "Read this receipt and add the expense to my records."

Pipeline:

```text
Camera
 ↓
Vision
 ↓
Structured data
 ↓
Agent
 ↓
Expense tool
 ↓
Local database
```

---

## FR-019 — Agent Events

The framework must expose execution events.

```swift
enum AgentEvent {

    case started

    case thinking

    case planCreated(AgentPlan)

    case toolRequested(ToolCall)

    case permissionRequired(ToolCall)

    case toolStarted(ToolCall)

    case toolCompleted(ToolResult)

    case observationReceived(ToolObservation)

    case responseToken(String)

    case guardrailRefused(GuardrailRefusal)

    case completed(AgentResponse)

    case error(Error)
}
```

`guardrailRefused` is new relative to v0.1, mirroring FR-005.

Events must be consumable through `AsyncStream`.

---

## FR-020 — SwiftUI Integration

LocalAgentKit should provide optional SwiftUI integration.

Example:

```swift
for await event in agent.events {

    switch event {

    case .toolStarted(let tool):
        // update UI

    case .responseToken(let token):
        // stream response

    default:
        break
    }
}
```

The framework should not force developers to use SwiftUI.

UIKit applications must also be supported.

---

## FR-021 — App Intents Integration

The framework should provide an integration layer for exposing application capabilities through App Intents.

Example:

```text
Siri / Apple Intelligence
          ↓
       App Intent
          ↓
      LocalAgentKit
          ↓
         Agent
          ↓
         Tool
```

This allows applications to combine their own agent capabilities with Apple's system intelligence ecosystem.

---

## FR-022 — Security

Security must be built into the framework.

Components:

```text
PermissionManager
ToolAuthorization
PrivacyPolicy
AuditLogger
DataPolicy
```

The framework must provide an audit trail for sensitive tool executions.

---

## FR-023 — Offline Mode

Developers must be able to explicitly enforce offline operation.

Example:

```swift
AgentConfiguration(
    networkPolicy: .never
)
```

When offline mode is enabled:

- no network inference
- no external API requests
- no remote document processing
- no cloud embeddings

The framework should make network access explicit rather than implicit.

Note: if a developer configures a bring-your-own-LLM provider through Foundation Models that itself requires network access, `.never` must reject that configuration at startup rather than silently allowing it — offline mode is a guarantee, not a default.

---

## FR-024 — Cancellation

Every long-running agent operation must support cancellation.

Example:

```swift
let task = Task {

    try await agent.run(
        request
    )
}

task.cancel()
```

Cancellation must propagate to:

- model inference
- RAG
- tool execution
- speech
- vision

where supported.

---

## FR-025 — Error Handling

The framework must provide typed errors.

Examples:

```swift
enum AgentError: Error {

    case modelUnavailable

    case toolNotFound

    case permissionDenied

    case executionTimeout

    case maximumIterationsReached

    case contextLimitExceeded

    case guardrailRefusal

    case memoryFailure

    case retrievalFailure

    case cancelled
}
```

`guardrailRefusal` and the emphasis on `contextLimitExceeded` are new relative to v0.1 — both map directly to real, documented on-device model behavior (R2, R3) rather than hypothetical failure modes.

Errors should be recoverable where possible.

---

## FR-026 — Agent Planning

The planner should support multi-step tasks.

Example:

```text
Goal:
"Prepare me for tomorrow's meetings."

Plan:

1. Read calendar.
2. Identify meetings.
3. Search relevant notes.
4. Retrieve project documents.
5. Generate summary.
6. Create preparation checklist.
```

The planner must support:

- sequential tasks
- conditional tasks
- tool dependencies
- retries
- completion detection

**Gate:** this requirement ships as MVP-blocking only if the Phase 0 feasibility spike (Section 47) shows the on-device model can produce valid multi-step plans at an acceptable reliability rate. If not, the planner ships as a deterministic state machine that calls the model for individual step decisions, with model-driven end-to-end planning deferred to a later release. See R1.

---

## FR-027 — Replanning

The agent must be able to change its plan when tool results differ from expectations.

Example:

```text
Plan:
Find meeting
 ↓
Calendar says meeting cancelled
 ↓
Agent detects plan invalid
 ↓
Re-plan
 ↓
Find next relevant meeting
```

Same feasibility gate as FR-026 applies.

---

## FR-028 — Loop Detection

The runtime must detect repeated execution patterns.

Example:

```text
Tool A
 ↓
Tool B
 ↓
Tool A
 ↓
Tool B
 ↓
Tool A
```

The agent must terminate or request user intervention when it detects an execution loop.

---

## FR-029 — Tool-Calling Reliability Harness (new)

The framework must ship an internal evaluation harness, independent of any single application, that measures:

- structured tool-call argument validity rate against the current on-device model
- multi-step task completion rate across a fixed suite of representative goals
- guardrail refusal rate on a suite of ordinary (non-adversarial) business tasks
- context budget exhaustion rate under realistic memory + RAG + conversation load

This harness must be runnable against OS betas so a model or guardrail behavior change surfaces as a regression before it reaches production apps built on the framework (see R1, R4). Results should feed directly into the M5 runtime metric (Section 44) rather than M5 being measured only informally per application.

---

# 10. Non-Functional Requirements

## Performance

The framework should:

- minimize unnecessary model calls
- support streaming
- support parallel tool execution where safe
- avoid blocking the main thread
- use Swift Concurrency
- support cancellation

---

## Privacy

Default behavior should favor:

> **Local processing and local storage.**

The framework must not silently send data to external services. This includes bring-your-own-LLM configurations: if a developer wires in a third-party model provider through Foundation Models, LocalAgentKit must surface that as an explicit, visible configuration choice, not something that quietly changes the app's network profile.

---

## Reliability

Agent execution must be resilient to:

- model errors
- guardrail refusals (see R3)
- tool errors
- timeout
- invalid tool arguments
- missing permissions
- unavailable models
- OS-version-driven model behavior changes (see R4)

---

## Battery

The framework should minimize unnecessary:

- model inference
- background processing
- embedding generation
- vision processing

---

## Memory

Large models and document indexes must be managed carefully.

The framework should support:

- model lifecycle management
- lazy loading
- unloading
- context trimming
- memory limits

---

## Context Window Management (new)

Given documented context-length constraints on the on-device model (R2), the framework must treat context budgeting as a first-class, observable runtime concern:

- conversation memory, RAG retrieval, and planning state must each have a configurable share of the available context budget
- the runtime must trim or summarize lower-priority context (e.g., older conversation turns) before failing a request with `contextLimitExceeded`
- developers must be able to inspect current context utilization through the event stream (FR-019) for debugging

---

# 11. API Design Principles

LocalAgentKit must follow these principles:

### Native Swift

Use:

- protocols
- structs
- actors
- async/await
- AsyncSequence
- Sendable

### Dependency inversion

Core components depend on protocols.

### Replaceable models

Never couple the agent directly to a specific model.

### Replaceable storage

Memory and vector databases must be pluggable.

### Secure by default

Tools require explicit permissions.

### Offline-first

Network functionality must be optional.

### Test-first

Every major component must be independently testable.

### Validated, not assumed (new)

Agentic capabilities (planning, replanning, loop handling) ship only after their reliability has been measured against the real on-device model, not assumed from architecture alone. See Section 5 and FR-029.

---

# 12. MVP Scope

The first public MVP should contain only:

```text
Phase 0 — Feasibility Spike (gate before engineering begins)
    │
    └── Tool-calling reliability + planning capability validation

Agent Core
    │
    ├── Foundation Models provider (incl. current BYO-LLM support)
    │
    ├── Tool calling
    │
    ├── Tool registry
    │
    ├── Permission system
    │
    ├── Calculator
    ├── Calendar
    ├── Reminder
    │
    ├── Conversation memory
    │
    ├── Local RAG
    │
    ├── Agent events
    │
    ├── Tool-calling reliability harness (FR-029)
    │
    └── SwiftUI demo
```

Do NOT attempt to build every capability in version 0.1. Do NOT commit to FR-026/FR-027 as full model-driven planning until Phase 0 results are in — a state-machine fallback is an acceptable, still-shippable MVP outcome.

---

# 13. MVP Demonstration Application

The reference application will be:

# LocalAgent Demo

The demo must demonstrate a complete agent workflow.

### Scenario

User:

> "What meetings do I have tomorrow?"

Agent:

```text
CalendarTool
 ↓
Calendar events
 ↓
Local model
 ↓
Answer
```

Then:

> "Find my notes related to those meetings."

Agent:

```text
DocumentSearchTool
 ↓
Local RAG
 ↓
Relevant documents
 ↓
Local model
```

Then:

> "Create a preparation checklist."

Agent:

```text
Local model
 ↓
Checklist
```

Then:

> "Save that as a note."

Agent:

```text
Permission
 ↓
NotesTool
 ↓
Local storage
```

This demonstrates:

**Reasoning + Tools + Memory + RAG + Permissions + Actions.**

---

# 14. Example Developer Experience

A developer should eventually be able to write:

```swift
import LocalAgentKit

let agent = LocalAgent(
    configuration: .default
)

agent.register(
    CalendarTool()
)

agent.register(
    ReminderTool()
)

agent.register(
    DocumentSearchTool()
)

let response = try await agent.run(
    "Prepare me for tomorrow's meetings."
)

print(response.text)
```

The developer should NOT need to implement:

- agent loops
- context management
- tool routing
- tool schemas
- memory retrieval
- permission workflows
- event streaming

unless they want custom behavior.

---

# 15. Example Custom Tool

```swift
struct ExpenseTool: AgentTool {

    let name = "create_expense"

    let description =
        "Creates an expense record."

    let permission =
        ToolPermission.userConfirmation

    let schema =
        ToolSchema(...)

    func execute(
        arguments: ToolArguments
    ) async throws -> ToolResult {

        // Store expense locally

        return .success(...)
    }
}
```

Then:

```swift
agent.register(
    ExpenseTool()
)
```

The model can discover the tool from its schema.

---

# 16. Reference Use Cases

LocalAgentKit should support applications such as:

### Personal Assistant

Calendar + reminders + notes + contacts.

### Research Assistant

PDF + RAG + local AI.

### Study Assistant

Textbooks + RAG + flashcards + quizzes.

### Expense Assistant

Camera + OCR + local database.

### Field Service Assistant

Camera + documents + voice + local procedures.

### Enterprise Knowledge Assistant

Internal documents + local retrieval + permissions.

### Developer Assistant

Local project documentation + code analysis.

### Offline Industrial Assistant

Technical manuals + vision + voice + local AI.

---

# 17. Success Metrics

## Developer metrics

### M1

Developer can create a basic local agent in **under 30 minutes**.

### M2

Adding a custom tool requires **less than 100 lines of application code**.

### M3

A developer can replace the model provider without modifying AgentCore.

### M4

Core components have **80%+ unit-test coverage**.

---

## Runtime metrics

### M5

Tool execution success rate >95% for supported built-in tools, **as measured continuously by the FR-029 reliability harness**, not just observed informally in the demo app.

### M6

No unauthorized tool execution.

### M7

Agent correctly terminates after completion.

### M8

Agent detects repeated tool loops.

### M9 (new)

Guardrail refusal rate on the ordinary-business-task suite (FR-029) stays below an agreed threshold; refusals above that threshold are treated as a product risk to resolve (via UX fallback per R3), not tracked as a documentation footnote.

---

## Privacy metrics

### M10

Offline mode performs zero network requests.

### M11

User documents remain local unless explicitly exported.

---

## Adoption / developer-experience metrics (new)

The metrics above measure whether the SDK works. They don't measure whether anyone uses it. For a developer-facing SDK, add:

### M12

Time from `git clone` / package add to first successful `agent.run()` call in a fresh project, tracked via onboarding feedback or telemetry opt-in.

### M13

Number of community-contributed tools or model providers within the first two quarters post-launch (a proxy for whether the protocol-first design is actually easy to extend in practice, not just on paper).

### M14

Issue/question volume specifically about guardrail refusals or context-limit errors — an early signal that R2/R3 need more mitigation than currently planned.

---

# 18. Testing Strategy

Testing must exist at multiple levels.

## Unit tests

Test:

- AgentRuntime
- Planner
- ToolRegistry
- ToolExecutor
- MemoryStore
- RAG
- SecurityManager

---

## Model tests

Use `MockModelProvider`.

Example:

```text
Input:
"What is 25 * 4?"

Expected:
CalculatorTool

Tool result:
100

Expected:
"100"
```

---

## Agent evaluation tests

Create scenarios:

```text
Goal
Expected tools
Expected result
Maximum iterations
Permission requirements
```

Example:

```text
Scenario:
"Create a reminder to call John tomorrow."

Expected:
ReminderTool

Permission:
Required

Expected result:
Reminder created
```

---

## Reliability regression tests (new)

Run the FR-029 harness against:

- every LocalAgentKit release
- every OS beta, to catch model-behavior drift (R4) before general availability

---

# 19. Security Threat Model

Potential risks:

### Prompt injection

Malicious text in documents could attempt to manipulate the agent into requesting an unintended tool call. **Structured tool calls alone do not prevent this** — an injected instruction can still produce a syntactically valid tool call. The actual backstop is the permission system (FR-009/FR-010): any tool above `readOnly` requires explicit user confirmation before it executes, regardless of why the model requested it. Sandboxing and context isolation reduce the surface area but are secondary controls, not the primary defense.

### Tool abuse

A model could request an unintended action. Mitigated by the permission tiers above.

### Data leakage

Sensitive local information could be exposed through generated output.

### Infinite loops

Agent may repeatedly execute tools. Mitigated by FR-028.

### Malicious documents

Imported documents may contain adversarial instructions (a specific case of prompt injection, above).

### Unauthorized actions

Agent may attempt sensitive operations. Mitigated by the permission system.

Mitigations, ranked by how much they actually do:

1. **Tool permissions with mandatory user confirmation for anything above `readOnly`** — the primary defense.
2. Structured tool calls (schema-validated arguments) — reduces malformed or ambiguous requests, but does not by itself stop a model from requesting the *wrong* valid action.
3. Maximum iterations / loop detection — bounds the damage from a manipulated or confused agent.
4. Audit logging — after-the-fact visibility, not prevention.
5. Sandboxing, context isolation, input/output validation — defense in depth, secondary to (1).

---

# 20. Privacy Model

LocalAgentKit should follow this hierarchy:

```text
LOCAL DATA
    ↓
LOCAL PROCESSING
    ↓
LOCAL STORAGE
    ↓
LOCAL INFERENCE
```

Cloud services should never be required for core functionality.

If a developer configures a bring-your-own-LLM provider (now natively supported by Foundation Models) that involves network access, that must be an explicit, visible developer configuration — never a silent default. See the Privacy NFR in Section 10.

---

# 21. Roadmap

## Phase 0 — Feasibility Validation (new, gates v0.1)

- Measure structured tool-call validity and multi-step completion rate against the current on-device model (R1)
- Measure guardrail refusal rate on ordinary business tasks (R3)
- Measure context budget behavior under realistic load (R2)
- Go/no-go decision on whether FR-026/FR-027 ship as model-driven planning or as a deterministic state machine for v0.1

## v0.1 — Agent Core

- Agent runtime
- Foundation Models provider (incl. current bring-your-own-LLM support)
- tools
- permissions
- events
- reliability harness (FR-029)
- SwiftUI demo

## v0.2 — Memory

- SwiftData
- conversation memory
- semantic memory

## v0.3 — RAG

- PDF ingestion
- chunking
- embeddings
- vector search

## v0.4 — Multimodal

- Vision
- OCR
- Speech

## v0.5 — Advanced Agents

- planning (full model-driven, if Phase 0 supports it)
- replanning
- parallel tools
- task dependencies
- loop detection

## v1.0 — Production SDK

- stable APIs
- documentation
- examples
- performance optimization
- security audit
- extensive test suite
- reliability harness results published as part of release notes, so developers know what changed in agent behavior between OS versions

---

# 22. Future Advanced Capabilities

Potential future features:

### Agent Teams

```text
Research Agent
      │
      ├── Document Agent
      ├── Vision Agent
      └── Planning Agent
```

### Local Agent Marketplace

Developers could distribute tools and agent capabilities.

### Agent-to-Agent Communication

Multiple local agents could collaborate.

### Long-term Personal Memory

A persistent local personal knowledge graph.

### Edge Robotics

The same LocalAgentKit architecture could eventually control local hardware/robots through approved tools.

### Cross-device Agents

Potential architecture:

```text
iPhone
  ↕
iPad
  ↕
Mac
  ↕
Vision Pro
```

with local model selection based on available hardware.

---

# 23. Technical Principles

LocalAgentKit should follow these principles throughout development:

1. **Privacy first**
2. **Offline first**
3. **Local inference first**
4. **Model agnostic**
5. **Tool controlled**
6. **Permission controlled**
7. **Observable**
8. **Testable**
9. **Composable**
10. **Native Swift**
11. **Battery conscious**
12. **Secure by default**
13. **Validated, not assumed** (new — see Section 5)

---

# 24. Product Definition

LocalAgentKit is successful when a developer can write:

```swift
let agent = LocalAgent()

agent.register(CalendarTool())
agent.register(ReminderTool())
agent.register(DocumentSearchTool())

let result = try await agent.run(
    "Prepare me for tomorrow."
)
```

and obtain a complete local agent experience without having to build the underlying:

```text
Agent loop
+
Planning
+
Tool calling
+
Permissions
+
Memory
+
RAG
+
Multimodal processing
+
Event streaming
+
Security
```

from scratch — with the model integration itself (the one item removed from this list relative to v0.1) increasingly handled by Apple's own platform, which LocalAgentKit builds on rather than re-implements.

---

# 25. Final Product Vision

LocalAgentKit should become the equivalent of an **agent runtime layer for Apple platforms** — the orchestration layer that Apple's model-level APIs (Foundation Models, Core AI) do not themselves provide.

```text
             APPLICATION
                  │
                  ▼
           ┌─────────────┐
           │LocalAgentKit│
           │ (orchestration,
           │  not model access)
           └──────┬──────┘
                  │
        ┌─────────┼─────────┐
        ▼         ▼         ▼
      MODEL      TOOLS    MEMORY
    (via Apple's │         │
     platform    │         │
     APIs)       │         │
        └─────────┼─────────┘
                  ▼
              AGENT
                  │
        ┌─────────┼─────────┐
        ▼         ▼         ▼
      Vision    Speech     RAG
                  │
                  ▼
          LOCAL INTELLIGENCE
                  │
                  ▼
             USER DEVICE
```

### Mission

> **Enable developers to build AI agents that think locally, remember locally, act safely, and keep user data on the user's device.**

### One-line positioning

> **LocalAgentKit — the agent orchestration layer Apple's on-device model APIs don't provide.**
