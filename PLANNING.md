# LocalAgentKit — PLANNING

**Status:** Pre-Phase 0 (no code yet — this repo currently contains only the PRD)
**Companion document:** [`LocalAgentKit-PRD-v0.2.md`](./LocalAgentKit-PRD-v0.2.md) — the PRD is the source of truth for *what* and *why*; this document is the source of truth for *how*.
**Last updated:** 2026-09-02

---

## 1. Vision

> **Make it as easy to build a private, autonomous, on-device AI agent as it is to build a traditional iOS feature.**

LocalAgentKit is the **agent orchestration layer Apple's on-device model APIs don't provide.**

Apple now handles model access. Since WWDC 2026, the Foundation Models framework accepts third-party and custom LLM providers (including MLX models) directly, and Core AI has replaced Core ML as the modern on-device runtime. Model abstraction is no longer a differentiator — it is table stakes that ships with the OS.

What every team still rebuilds by hand, on every project, is the layer *above* the model:

- the agent loop (goal → context → decide → act → observe → repeat)
- multi-step planning and replanning
- tool calling with schema validation and **permission enforcement**
- memory across turns and across sessions
- local RAG over the user's own documents
- loop and failure detection
- multimodal orchestration (vision, speech, documents)
- observable state and event streaming for UI

That is LocalAgentKit's product. The model provider protocol stays, but it exists for **testability and portability**, not as a claim of unique capability.

### What success looks like

```swift
import LocalAgentKit

let agent = LocalAgent(configuration: .default)
agent.register(CalendarTool())
agent.register(ReminderTool())
agent.register(DocumentSearchTool())

let result = try await agent.run("Prepare me for tomorrow's meetings.")
print(result.text)
```

…with no application code implementing the agent loop, tool routing, tool schemas, context budgeting, memory retrieval, permission workflows, or event streaming.

### Design commitments (non-negotiable)

| Principle | What it means in code |
|---|---|
| **Privacy first** | Local data → local processing → local storage → local inference. No silent network calls, ever. |
| **Offline first** | `networkPolicy: .never` is a *guarantee*, validated at configuration time — including rejecting a BYO-LLM provider that needs the network. |
| **Secure by default** | Anything above `readOnly` requires explicit user confirmation. This is the primary defense against prompt injection, not a checkbox. |
| **Model agnostic** | `AgentCore` never imports a concrete model framework. Swapping providers requires zero changes to core. |
| **Observable** | Every state transition is an `AgentEvent` on an `AsyncStream`, including context-budget utilization. |
| **Testable** | Every seam is a protocol. Every protocol has a mock. No component requires a device to unit-test. |
| **Validated, not assumed** | Planning/replanning ship only after measured reliability against the real on-device model. See Phase 0. |

### Anti-goals

Not a chatbot. Not a cloud platform. Not a model trainer. Not a centralized vector database. Not unrestricted device control. And explicitly **not** a re-implementation of the model abstraction Apple now ships natively.

---

## 2. Architecture

### 2.1 Layering

```text
┌──────────────────────────────────────────────────────────────┐
│  APPLICATION            SwiftUI · UIKit · App Intents        │
└───────────────────────────────┬──────────────────────────────┘
                                ▼
┌──────────────────────────────────────────────────────────────┐
│  LOCALAGENTKIT                                               │
│                                                              │
│   ┌────────────────────────────────────────────────────┐     │
│   │  AGENT CORE  ← primary differentiator              │     │
│   │  Runtime · Planner · ContextBudgeter · Executor    │     │
│   │  LoopDetector · EventBus                           │     │
│   └───────────────────────┬────────────────────────────┘     │
│                           │  (protocols only — no concrete   │
│                           │   framework imports below here)  │
│      ┌──────────┬─────────┼─────────┬──────────┐             │
│      ▼          ▼         ▼         ▼          ▼             │
│   MODELS      TOOLS    MEMORY      RAG    MULTIMODAL         │
│      │          │         │         │          │             │
│      │      Registry   Working   Embedding  Vision           │
│      │      Permission Convers.  VectorSt.  Speech           │
│      │      Executor   Semantic  Chunker                     │
│      │      Audit      Episodic  Ingestion                   │
│      └──────────┴─────────┴─────────┴──────────┘             │
│                                                              │
│   ┌────────────────────────────────────────────────────┐     │
│   │  SECURITY  PermissionManager · AuditLogger ·       │     │
│   │            PrivacyPolicy · NetworkPolicyGuard      │     │
│   └────────────────────────────────────────────────────┘     │
└───────────────────────────────┬──────────────────────────────┘
                                ▼
┌──────────────────────────────────────────────────────────────┐
│  APPLE / LOCAL RUNTIMES                                      │
│  Foundation Models (incl. BYO-LLM, MLX) · Core AI ·          │
│  Vision · Speech · SwiftData · EventKit · Contacts · PDFKit  │
└──────────────────────────────────────────────────────────────┘
```

The rule that keeps this honest: **`AgentCore` compiles without importing `FoundationModels`, `CoreAI`, `Vision`, `Speech`, `SwiftData`, or `EventKit`.** If it can't, the abstraction has leaked. This is enforced as a build check, not a convention (§4.4).

### 2.2 Package structure (SwiftPM)

Multi-target from day one — a single blob target makes the layering rule unenforceable.

```text
LocalAgentKit/
├── Package.swift
├── Sources/
│   ├── LocalAgentKitCore/          # protocols + value types ONLY. Zero Apple-framework deps.
│   │   ├── Agent/                  #   LocalAgent, AgentConfiguration, AgentEvent, AgentError
│   │   ├── Model/                  #   LocalModelProvider, ModelRequest/Response, GuardrailRefusal
│   │   ├── Tools/                  #   AgentTool, ToolSchema, ToolPermission, ToolResult
│   │   ├── Memory/                 #   MemoryStore, Memory, MemoryQuery
│   │   ├── RAG/                    #   EmbeddingProvider, VectorStore, Chunker, Document
│   │   └── Multimodal/             #   VisionProvider, SpeechRecognizer, SpeechSynthesizer
│   │
│   ├── LocalAgentKitRuntime/       # the agent loop. Depends on Core only.
│   │   ├── AgentRuntime.swift      #   the actor that owns execution
│   │   ├── Planner/                #   StateMachinePlanner + ModelDrivenPlanner (Phase 0 decides default)
│   │   ├── ContextBudgeter.swift   #   first-class context-window accounting
│   │   ├── ToolExecutor.swift      #   validation → permission → execute → observe
│   │   ├── LoopDetector.swift
│   │   └── EventBus.swift
│   │
│   ├── LocalAgentKitProviders/     # concrete adapters — the only place Apple frameworks are imported
│   │   ├── FoundationModelProvider/
│   │   ├── CoreAIModelProvider/
│   │   ├── SwiftDataMemoryStore/
│   │   ├── NLEmbeddingProvider/
│   │   ├── InMemoryVectorStore/
│   │   └── AppleVisionProvider/ , AppleSpeechProvider/
│   │
│   ├── LocalAgentKitTools/         # built-in tools (EventKit, Contacts, FileManager, …)
│   ├── LocalAgentKitSwiftUI/       # optional. AgentViewModel, event→state bridging.
│   ├── LocalAgentKitAppIntents/    # optional. AgentIntent bridging.
│   ├── LocalAgentKitTesting/       # MockModelProvider, ScriptedModel, fixtures. Ships to consumers.
│   └── LocalAgentKitEval/          # FR-029 reliability harness (executable + library)
│
├── Tests/                          # mirrors Sources 1:1
├── Examples/
│   └── LocalAgentDemo/             # the SwiftUI reference app (Xcode project)
└── Benchmarks/                     # latency / memory / battery measurement
```

**Dependency direction is strictly one-way:** `Tools`/`Providers`/`SwiftUI` → `Runtime` → `Core`. Nothing depends on `Providers`. `Core` depends on nothing.

### 2.3 The agent loop

`AgentRuntime` is an `actor`. It owns all mutable execution state; nothing else mutates it.

```text
run(goal, attachments)
  │
  ├─▶ .started ────────────────────────────────────▶ event stream
  │
  ▼
ASSEMBLE CONTEXT ── ContextBudgeter allocates the window:
  │                  system+tools │ conversation │ RAG │ plan state
  │                  (configurable shares; trim/summarize before failing)
  ▼
PLAN (or re-plan) ─▶ .planCreated
  │
  ▼
┌── ITERATE (bounded: maxIterations, maxToolCalls, maxDuration, maxContext) ──┐
│                                                                            │
│  MODEL CALL ─▶ .thinking / .responseToken                                  │
│      │                                                                     │
│      ├─ .text            ──▶ done                                          │
│      ├─ .clarification   ──▶ surface to app, suspend                       │
│      ├─ .refused         ──▶ .guardrailRefused (TYPED — never a retry)     │
│      └─ .toolCall(s)                                                       │
│              │                                                             │
│              ▼                                                             │
│         VALIDATE ARGS against ToolSchema ── invalid ──▶ repair prompt (n×)  │
│              │                                                             │
│              ▼                                                             │
│         PERMISSION GATE (PermissionManager)                                │
│              ├─ none / readOnly ──────────────▶ proceed                    │
│              └─ userConfirmation / sensitive / destructive                 │
│                        └─▶ .permissionRequired ──▶ SUSPEND until resolved  │
│              │                                                             │
│              ▼                                                             │
│         EXECUTE ─▶ .toolStarted / .toolCompleted / AuditLogger              │
│              │     (parallel only where tools declare themselves safe)     │
│              ▼                                                             │
│         OBSERVE ─▶ .observationReceived                                    │
│              │                                                             │
│              ▼                                                             │
│         LOOP DETECTOR ── repeated (tool, args) signature? ──▶ terminate     │
│                                                or ask the user             │
│              │                                                             │
│              ▼                                                             │
│         PLAN STILL VALID? ── no ──▶ back to PLAN (replan)                  │
└────────────────────────────────────────────────────────────────────────────┘
  │
  ▼
.completed(AgentResponse)   ·   or typed .error(AgentError)
```

Four design decisions worth stating explicitly:

1. **Suspension, not blocking.** Permission prompts and clarifications suspend the loop via a continuation. The runtime holds no thread and no lock while waiting on a human.
2. **Guardrail refusals are terminal, not retryable.** R3 says the on-device model refuses ordinary business tasks (health, finance, legal phrasing). Retrying a refusal burns battery and context to fail again. It surfaces as `GuardrailRefusal` so the app can fall back to a non-agentic path.
3. **Context budgeting happens before every model call, not on failure.** R2 says apps hit context-length errors in production. `contextLimitExceeded` is the outcome after trimming and summarization have both failed — not the first line of defense.
4. **The permission gate sits between argument validation and execution.** A schema-valid tool call from an injected instruction is still stopped there. That ordering *is* the prompt-injection mitigation.

### 2.4 Planner: two implementations behind one protocol

The single biggest open risk (R1) is whether a compact on-device model can drive multi-step planning. The architecture refuses to bet on the answer:

```swift
protocol AgentPlanner: Sendable {
    func plan(goal: Goal, context: AgentContext, tools: [ToolDescriptor]) async throws -> AgentPlan
    func revise(plan: AgentPlan, observation: ToolObservation) async throws -> PlanRevision
}
```

- **`StateMachinePlanner`** — deterministic control flow; the model is consulted for *individual* decisions ("which tool for this step?", "is this step satisfied?"). Robust, dull, and always shippable.
- **`ModelDrivenPlanner`** — the model emits and revises a whole plan. More capable, unproven on-device.

**Phase 0 chooses which one is `.default` in v0.1.** Both ship either way; the config picks. This is a one-line change if the spike goes badly, instead of an architecture rewrite.

### 2.5 Concurrency model

Swift 6 strict concurrency, full checking, no exceptions:

- `AgentRuntime` — `actor`. Sole owner of execution state.
- `ToolRegistry` — `actor`. Registration and lookup are serialized.
- `AgentTool`, `LocalModelProvider`, `MemoryStore`, `VectorStore` — `Sendable` protocols with `async throws` requirements.
- Events — `AsyncStream<AgentEvent>`, multicast so UI and logging can both subscribe.
- Cancellation — cooperative `Task` cancellation propagating to model inference, RAG, tool execution, vision, and speech. Every `await` in the loop is a cancellation point; tools that can't be cancelled must say so in their descriptor.
- Nothing in the SDK touches `@MainActor` except `LocalAgentKitSwiftUI`.

### 2.6 Data flow: RAG

```text
Document (PDF/TXT/MD) ─▶ Extractor ─▶ Chunker ─▶ EmbeddingProvider ─▶ VectorStore
                                                                          │
Query ─▶ EmbeddingProvider ─▶ similarity search ─▶ top-k ─▶ ContextBudgeter ─▶ prompt
```

Ingestion is explicitly a background, batchable, cancellable operation with progress events — embedding a 300-page PDF on a phone is a battery event, not a function call.

### 2.7 Security architecture

| Control | Rank | Role |
|---|---|---|
| Permission tiers + mandatory confirmation above `readOnly` | **1** | The actual defense. Nothing above `readOnly` executes without a human. |
| Schema-validated structured tool calls | 2 | Stops malformed/ambiguous calls. Does **not** stop a valid-but-wrong call. |
| Max iterations + loop detection | 3 | Bounds damage from a confused or manipulated agent. |
| Audit logging | 4 | After-the-fact visibility. Not prevention. |
| Sandboxing, context isolation, I/O validation | 5 | Defense in depth. |

`NetworkPolicyGuard` validates the whole configuration at construction: with `.never`, a BYO-LLM provider that requires network is a **startup error**, not a runtime surprise.

---

## 3. Technology stack

### 3.1 Language & build

| | Choice | Why |
|---|---|---|
| Language | **Swift 6.x**, strict concurrency, complete checking | The PRD demands actors/`Sendable`/`AsyncSequence`; strict mode makes the concurrency model verifiable rather than aspirational. |
| Package manager | **Swift Package Manager**, multi-target | Zero-friction consumption (`.package(url:)`); targets enforce the layering rule. |
| Min deployment | iOS 26+ / macOS 26+ (iPadOS shares the iOS floor; visionOS 26.0 already carries the same `FoundationModels` availability per the real `.swiftinterface` — not "to follow" as this table previously said) | `FoundationModels`'s real availability annotations are the floor — see `docs/phase-0-findings.md`. Framework name corrected from "Core AI" — see open question 1, now resolved. |
| Xcode | Latest release + latest beta side by side | The beta toolchain is required to run the FR-029 harness against OS betas (R4). |

*The exact SDK availability and the framework module names have now been verified against the shipping Xcode — see open questions 1–3 in §6 and `docs/phase-0-findings.md`. `Core AI` does not exist in the shipping SDK; the real model framework is `FoundationModels` (`SystemLanguageModel`/`LanguageModelSession`) only.*

### 3.2 Apple frameworks

| Framework | Used for | Isolated in |
|---|---|---|
| **Foundation Models** | Primary inference; BYO-LLM + MLX registration | `FoundationModelProvider` |
| **Core AI** | Custom/local model execution | `CoreAIModelProvider` |
| **Natural Language** (`NLEmbedding`) | Default on-device embeddings for RAG v0.3 | `NLEmbeddingProvider` |
| **SwiftData** | Memory persistence (working/conversation/semantic/episodic) | `SwiftDataMemoryStore` |
| **Vision** | OCR, classification, detection, document understanding | `AppleVisionProvider` |
| **Speech** / **AVFoundation** | STT and TTS | `AppleSpeechProvider` |
| **EventKit** | Calendar + Reminders tools | `LocalAgentKitTools` |
| **Contacts** | Contacts tool | `LocalAgentKitTools` |
| **PDFKit** | PDF text extraction for RAG | `LocalAgentKitTools` / RAG ingestion |
| **App Intents** | Siri / Apple Intelligence surface | `LocalAgentKitAppIntents` |
| **SwiftUI** | Optional integration + demo app | `LocalAgentKitSwiftUI`, `Examples/` |
| **OSLog / Signposts** | Structured logging, instrumentation | Runtime |

### 3.3 Third-party dependencies

**Target: zero runtime dependencies in the shipping SDK.** A privacy-first SDK that drags in a transitive dependency tree is a contradiction, and every dependency is a supply-chain question an enterprise reviewer will ask.

Permitted exceptions, dev/test-only, not linked into consumer apps:

| Package | Scope | Purpose |
|---|---|---|
| `swift-testing` (bundled) | test | Primary test framework; XCTest only where needed |
| `swift-docc-plugin` | build | API documentation generation |
| `swift-format` | dev | Formatting, CI-enforced |
| `swift-argument-parser` | eval target only | CLI for the FR-029 harness |
| `package-benchmark` *(evaluate)* | benchmarks only | Regression-tracked performance measurement |

Any proposal to add a runtime dependency needs an explicit written justification in the PR.

### 3.4 Storage

- **Memory:** SwiftData first (`SwiftDataMemoryStore`), `MemoryStore` protocol keeps SQLite/GRDB viable later.
- **Vectors:** start with an in-memory + file-backed flat store. Brute-force cosine similarity is genuinely fine for the tens-of-thousands-of-chunks scale a single user's document set produces on a phone. Introduce an ANN index only when a benchmark — not intuition — says it's needed.
- **Audit log:** append-only, local, exportable, never network-synced.

### 3.5 Testing & quality

| Layer | Tooling |
|---|---|
| Unit | `swift-testing`, `MockModelProvider`, `ScriptedModelProvider` — no device required |
| Integration | Real providers on simulator/device |
| Agent evaluation | Scenario suite: goal → expected tools → expected result → max iterations → permission expectations |
| Reliability regression (FR-029) | `LocalAgentKitEval` — runs per release **and per OS beta** |
| Performance | `Benchmarks/` — latency, peak memory, model load/unload |
| Coverage | 80%+ on core components (M4), CI-gated |

---

## 4. Required tools

### 4.1 Development environment (must be installed)

| Tool | Version / notes | Purpose |
|---|---|---|
| **macOS** | Current major release | Required for the SDKs |
| **Xcode** | Latest release | Primary IDE, simulators, Instruments |
| **Xcode beta** | Latest beta, side-by-side | R4 — running the reliability harness against OS betas |
| **Swift toolchain** | 6.x (bundled with Xcode) | Build, test, SwiftPM |
| **Apple silicon Mac** | M-series | On-device model inference is not usable on Intel |
| **Physical iPhone/iPad** | Apple Intelligence-capable | Foundation Models behavior, thermals, and battery cannot be measured in the simulator |
| **Apple Developer account** | Paid | Device provisioning, EventKit/Contacts entitlements, TestFlight |
| **git** | — | Version control (**note: this directory is not a git repo yet — `git init` is task #1**) |
| **swift-format** | Latest | Formatting, CI-enforced |
| **Instruments** | Bundled | Time Profiler, Allocations, Energy Log, Signposts |
| **`gh` CLI** | Optional | PR/issue workflow |

### 4.2 CI

| Need | Choice |
|---|---|
| Runner | macOS runner with current Xcode (GitHub Actions `macos-latest`, or self-hosted Apple silicon) |
| Per-PR | build all targets · `swift test` · swift-format lint · coverage gate · **layering check** |
| Per-release | full eval scenario suite + FR-029 harness on device |
| Per-OS-beta | FR-029 harness → drift report (R4) |
| Docs | DocC build + publish |

**Layering check** (cheap, high-value): fail the build if `LocalAgentKitCore` or `LocalAgentKitRuntime` contains an `import` of `FoundationModels`, `CoreAI`, `SwiftData`, `Vision`, `Speech`, `EventKit`, `Contacts`, or `SwiftUI`. Grep-level is sufficient. This is the one test that keeps M3 ("replace the model provider without touching AgentCore") true a year from now.

### 4.3 Agent tool catalog (the tools the SDK ships *to* agents)

Distinct from developer tooling — these are `AgentTool` conformances.

| Tool | Permission | Framework | Ships in |
|---|---|---|---|
| `CalculatorTool` | `.none` | — | **MVP** |
| `CalendarTool` (read) | `.readOnly` | EventKit | **MVP** |
| `ReminderTool` (create) | `.userConfirmation` | EventKit | **MVP** |
| `DocumentSearchTool` | `.readOnly` | RAG | **MVP** |
| `NotesTool` (create/search) | `.userConfirmation` / `.readOnly` | Local store | v0.2 |
| `ContactsTool` (search) | `.sensitive` | Contacts | v0.2 |
| `FilesTool` (search) | `.readOnly` | FileManager | v0.2 |
| *File delete, message send, etc.* | `.destructive` | — | Post-MVP; used to exercise the destructive tier |

Every tool must declare: `name`, `description`, `schema`, `permission`, whether it is **parallel-safe**, and whether it is **cancellable**. The last two are additions to the PRD's `AgentTool` protocol that the runtime needs in order to schedule and cancel correctly.

### 4.4 Repository scaffolding still to create

Nothing but the PRD exists yet. The bootstrap list:

- [ ] `git init` + `.gitignore` (Swift/Xcode)
- [ ] `Package.swift` with the multi-target layout from §2.2
- [ ] `CLAUDE.md` — conventions, layering rule, build/test commands
- [ ] `README.md` — positioning, quick start, install
- [ ] `.github/workflows/ci.yml` — build, test, lint, coverage, layering check
- [ ] `.swift-format`
- [ ] `CONTRIBUTING.md` + `SECURITY.md` (M13 depends on extension being genuinely easy)
- [ ] DocC catalog
- [ ] `Examples/LocalAgentDemo` Xcode project

---

## 5. Execution plan

### Phase 0 — Feasibility spike **(gates everything)**

Nothing in §2.2 gets built until this reports. It is a throwaway spike, not the beginning of the SDK.

Measure, against the real shipping on-device model:

1. **Structured tool-call validity rate** — a fixed set of representative goals with known-correct tool calls.
2. **Multi-step completion rate** — 3–5 step tasks, end to end.
3. **Guardrail refusal rate** on *ordinary* business tasks (expenses, scheduling, notes) — the R3 signal.
4. **Context budget behavior** under realistic conversation + RAG + plan load — the R2 signal.

**Go/no-go:** does `ModelDrivenPlanner` or `StateMachinePlanner` become the v0.1 default (§2.4)? Below the >95% M5 target, it is the state machine — and that is a *successful, shippable* outcome, not a failure.

The throwaway spike code becomes the seed of `LocalAgentKitEval` (FR-029).

### Milestones

| | Scope | Key exit criterion |
|---|---|---|
| **Phase 0** | Feasibility spike | Planner decision made and written down |
| **v0.1** | Runtime · Foundation Models provider · tools · registry · permissions · events · conversation memory · basic RAG · FR-029 harness · SwiftUI demo | Demo runs the four-turn scenario end to end; M5/M6/M7 measured |
| **v0.2** | SwiftData memory: conversation + semantic | Context survives app restart |
| **v0.3** | RAG: PDF ingestion, chunking, embeddings, vector search | Demo answers from a real user PDF |
| **v0.4** | Multimodal: Vision, OCR, Speech | Receipt → structured expense works |
| **v0.5** | Advanced agents: planning, replanning, parallel tools, dependencies, loop detection | M8 (loop detection) verified |
| **v1.0** | Stable API, docs, examples, perf, security audit, full test suite | Harness results published in release notes |

### Definition of done (every PR)

Builds warning-free under strict concurrency · unit-tested with mocks · no new `Core`/`Runtime` framework imports · public API documented · typed errors, no `fatalError` in library code · no new runtime dependency without written justification · events emitted for any new observable state.

---

## 6. Open questions

Carried from the PRD's risk register plus what this plan surfaced. These need answers, not assumptions. Numbers are kept stable (tasks reference them by number) even as items resolve — resolved items stay in place, marked, rather than being renumbered or deleted.

1. **RESOLVED — 2026-09-02, see [`docs/phase-0-findings.md`](./docs/phase-0-findings.md) §1–2.** Exact Foundation Models / Core AI API surface. Answer, verified directly against the shipping SDK's `.swiftinterface`: **`CoreAI.framework` does not exist** (this SDK still ships `CoreML.framework`, unreplaced), and **Foundation Models has no third-party/BYO-LLM/MLX registration API** — `SystemLanguageModel.Adapter` is Apple's own fine-tuning-adapter mechanism for specializing Apple's base model, not a way to swap in an external model. The PRD's §1/R5 premise that Apple now provides model-abstraction is not true of this shipping SDK. If anything this makes `LocalModelProvider` *more* load-bearing than the PRD assumed, not less — see the findings doc for why. **This needs a decision on whether/how to correct the PRD**, not just this file; flagged to the user, not resolved unilaterally.
2. **RESOLVED — 2026-09-02, see `docs/phase-0-findings.md` §3.** Context window size and tokenizer access. Answer: yes, both are real public API — `SystemLanguageModel.contextSize` (verified at runtime: `4096`) and `tokenCount(for:)` overloads for prompts, instructions, tools, schemas, and transcript entries. `ContextBudgeter` can budget against a real count, not an estimate — though 4096 tokens is a tight budget, which raises the *importance* of budgeting even as it resolves the *feasibility* of measuring it.
3. **RESOLVED — 2026-09-02, see `docs/phase-0-findings.md` §4.** Guardrail refusal detectability. Answer: yes, unambiguously — `LanguageModelSession.GenerationError` has distinct `.guardrailViolation(Context)` and `.refusal(Refusal, Context)` cases, verified at runtime by actually triggering one. Bonus: the same enum has `.exceededContextWindowSize(Context)`, `.rateLimited`, and `.concurrentRequests` — real typed failure modes FR-025's `AgentError` should incorporate.
4. **Embedding quality from `NLEmbedding`** for RAG retrieval, versus a small MLX embedding model. The "via Core AI" framing in the original version of this question is void per question 1 — Core AI doesn't exist, so an MLX-backed alternative would mean direct MLX Swift integration, not a Core AI-mediated path. Still open: measure `NLEmbedding` retrieval quality before committing — retrieval quality caps the whole RAG feature.
5. **Permission UX ownership.** Does the SDK ship a SwiftUI confirmation sheet, or only the suspension protocol and event? Leaning toward: protocol + event required, sheet provided as an opt-in convenience in `LocalAgentKitSwiftUI`.
6. **Model lifecycle across agents.** Multiple `LocalAgent` instances in one app should not each hold a model in memory. Needs a shared, reference-counted provider — design this before v0.1 rather than retrofitting it.
7. **Audit log retention and export format.** Enterprise (Persona 3) will ask. Decide by v0.2.
8. **NEW.** `AgentTool` vs. Foundation Models' own `Tool<Arguments, Output>` protocol (see `docs/phase-0-findings.md` §7). `AgentTool` should be designed as a wrapper/bridge to Apple's real `Tool` protocol — adding the permission tier, richer schema validation, and parallel-safety/cancellability declarations `Tool` doesn't have — rather than an independent reinvention. Affects task M1-CO-03.
