# LocalAgentKit — TASKS

**Companion documents:** [`LocalAgentKit-PRD-v0.2.md`](./LocalAgentKit-PRD-v0.2.md) (what & why) · [`PLANNING.md`](./PLANNING.md) (how)
**Last updated:** 2026-09-02

Task IDs are stable — reference them in commits and PRs (`M1-RT-03: add loop detector`). FR/NFR/R/M references point back to the PRD.

**Legend:** `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked · 🔒 gates later work

---

## Milestone 0 — Repository Bootstrap

*Nothing but the PRD exists. This milestone can run in parallel with Phase 0.*

### Version control & scaffolding
- [x] **M0-01** `git init`; set default branch to `main`; first commit of the PRD + PLANNING.md
- [x] **M0-02** Add Swift/Xcode `.gitignore` (`.build/`, `.swiftpm/`, `xcuserdata/`, `DerivedData/`, `*.xcuserstate`)
- [x] **M0-03** Create `Package.swift` with the multi-target layout from PLANNING §2.2 — empty targets are fine, structure is the point
- [x] **M0-04** Create the `Sources/` + `Tests/` directory tree, 1:1 mirrored, one placeholder file per target
- [x] **M0-05** Confirm `swift build` and `swift test` succeed on the empty skeleton before any real code lands

### Project documents
- [x] **M0-06** `README.md` — one-line positioning, quick start, install snippet, platform requirements
- [x] **M0-07** `CLAUDE.md` — build/test commands, the layering rule, naming conventions, PR definition-of-done
- [x] **M0-08** `CONTRIBUTING.md` — how to add a tool, how to add a provider (M13 depends on this being genuinely easy)
- [x] **M0-09** `SECURITY.md` — disclosure policy, threat model pointer (PRD §19)
- [!] **M0-10** `LICENSE` — decide license before any external contribution arrives *(deferred by user 2026-09-02, revisit before accepting outside contributions)*

### Tooling & CI
- [x] **M0-11** `.swift-format` config; format the tree; verify it is idempotent
- [x] **M0-12** `.github/workflows/ci.yml` — build all targets, `swift test`, format lint on every PR
- [x] **M0-13** 🔒 **Layering check script** — fail CI if `LocalAgentKitCore`/`LocalAgentKitRuntime` import `FoundationModels`, `CoreAI`, `SwiftData`, `Vision`, `Speech`, `EventKit`, `Contacts`, or `SwiftUI`. Wire into CI. *(This is what keeps M3 true; add it before there is anything to violate it.)*
- [x] **M0-14** Enable Swift 6 strict concurrency, complete checking, on every target from the first commit
- [x] **M0-15** Add code-coverage reporting; set the 80% gate on Core + Runtime only (M4)
- [x] **M0-16** Verify the Xcode beta toolchain builds the package side-by-side with the release toolchain (needed for R4 later) *(DONE 2026-09-10: Xcode 27.0 beta (27A5252f, Swift 6.4) installed alongside 26.6; `swift build` warning-free and `swift test` green under both toolchains. This also unblocked the beta SDK check in Phase 0 — see the environment table in docs/phase-0-findings.md.)*
- [x] **M0-17** Keep the toolchain gates working after Xcode 27.0 went GA *(unplanned; serves NFR tooling/CI. DONE 2026-09-18: `Xcode.app` auto-updated on 2026-09-15 to Xcode 27.0 (27A266a, Swift 6.4), whose swift-format rejects `.swift-format` for a missing `orderedImports.shouldGroupImports` key; added it with the tool's own default (`true`). Clean build, tests, layering, and `--strict` lint all pass on 27.0. CI still selects `Xcode_26*` on the runner — left as is, flagged.)*

**Exit:** empty package builds green in CI with strict concurrency, formatting, and the layering check all enforced.

---

## Phase 0 — Feasibility Spike 🔒

*Throwaway spike. **No SDK code is written until this reports.** Its output is a decision, not a library. (PRD §5 R1–R3, §21 Phase 0)*

### Setup
- [x] **P0-01** Bare Xcode app targeting the on-device model — no LocalAgentKit abstractions, no protocols, deliberately disposable *(DONE 2026-09-18, committed per the user's decision: `Spike/`, an XcodeGen-generated app for iOS 27 and macOS 26.4+. It compiles warning-free under Swift 6 strict concurrency for both platforms and runs headless on this Mac (`--run-and-exit`). It sits outside the Swift package, so the package gates are unaffected. The only new tool is XcodeGen, needed only to regenerate the committed `.xcodeproj`.)*
- [x] **P0-02** Verify Foundation Models availability, session lifecycle, and structured-output API on a physical Apple Intelligence device *(DONE 2026-09-18 on a physical **iPhone 15 Pro, iOS 27.0** and on macOS 26.6.2; see docs/phase-0-findings.md §9. Availability, multi-turn reuse, Codable transcript restore, concurrency rejection, streaming, `@Generable` and `DynamicGenerationSchema` all verified on both. Reusing a session right after abandoning a stream **crashes on macOS 26.6.2 (3/3) but not on iOS 27 (8/8)**; the rebuild-from-snapshot pattern is safe on both. Anchored regex guides are rejected on both, untyped on 26 and typed on 27. Transcript token cost looked OS-dependent (80 vs. 107); corrected by P0-08: totals for identical content agree within ~2%, and the gap is in instruction framing. Follow-ups recorded in the findings' Not yet done.)*
- [x] **P0-03** Confirm the real module names, availability annotations, and BYO-LLM registration API against the shipping SDK — resolves PLANNING §6 open question 1 🔒 *(RESOLVED 2026-09-10 against the Xcode 27.0 beta SDK. Both halves answered, reversing the provisional release-SDK reading: (1) `CoreAI.framework` EXISTS (@available macOS/iOS 27.0) with six SubFrameworks — but `CoreAIRuntime` is a tensor/NDArray inference API, not an LLM one, and `CoreML.framework` still ships beside it, so "Core AI replaced Core ML" overstates it; (2) Foundation Models DOES accept third-party models, via the new `LanguageModel` + `LanguageModelExecutor` protocols and generic `LanguageModelSession.init(model: some LanguageModel, ...)` — verified by compiling a non-Apple model warning-free under Swift 6 strict concurrency AND running it on the iOS 27 simulator. See docs/phase-0-findings.md §1-2. This raised PLANNING question 9, **resolved 2026-09-26 by docs/decisions/0004**: `LocalModelProvider` stays as the Core seam and the floor is macOS/iOS 26.4, with OS 27-only API behind `#available`.)*
- [x] **P0-04** Determine whether a token counter / tokenizer is exposed — resolves open question 2 🔒 *(RESOLVED 2026-09-02: yes — `SystemLanguageModel.contextSize` (4096, verified at runtime) and `tokenCount(for:)`; see docs/phase-0-findings.md §3)*

### Evaluation suites
- [x] **P0-05** Write ~20 single-tool goals with known-correct tool + arguments *(DONE 2026-09-18: `Sources/LocalAgentKitEval/Suites/phase0/single-tool.json`, 20 goals over the 8-tool shared catalog `Sources/LocalAgentKitEval/Suites/phase0/tools.json` (FR-008 built-ins + `search_documents`), with per-argument matchers and a pinned reference clock; structural validator `Scripts/validate-eval-suites.swift` runs in CI. Suites only — no runner yet; that is P0-09.)*
- [x] **P0-06** Write ~10 multi-step (3–5 step) goals with expected tool sequences *(DONE 2026-09-18: `Sources/LocalAgentKitEval/Suites/phase0/multi-step.json`, 10 goals of 3–5 steps on the shared catalog. The expected sequence is a dependency partial order, not a fixed order. Each goal carries fixture tool results (`calculate` is evaluated for real), `groundedIn` marks arguments that must come from earlier tool output, and `forbidden` catches a conditional firing when it shouldn't (ms-10). Validator extended and negative-tested. Suites only; no runner yet, which is P0-10.)*
- [x] **P0-07** Write ~20 *ordinary* business tasks touching health/finance/legal phrasing (expenses, scheduling, notes) for the refusal suite *(DONE 2026-09-18: `Sources/LocalAgentKitEval/Suites/phase0/refusal.json` has 20 benign goals (health 7, finance 7, legal 6; 17 tool calls, 9 text) plus 6 neutral controls, each paired with a sensitive goal so the wording effect can be isolated. Typed and soft refusals are scored separately, with 5 runs per goal. Validator extended and negative-tested. The M9 threshold P0-11 needed was agreed 2026-09-19: docs/decisions/0001-m9-refusal-threshold.md.)*
- [x] **P0-08** Build a realistic context-load fixture: long conversation + RAG chunks + plan state, sized to a real app *(DONE 2026-09-19: `Sources/LocalAgentKitEval/Suites/phase0/context-load.json` has 12 exchanges with tool traffic, 16 chunks, a 5-step plan, 6 planted-fact probes, and 4 profiles. It's sized with real `tokenCount` on **both** macOS 26.6.2 and the iPhone (iOS 27): light 43%, typical 66%, heavy 89–90%, stress 101–102% of the 4,096 context, with totals within ~2% across OS versions, so no per-OS resizing is needed. The 8 tool definitions cost ~1,050 tokens (26%), and tool traffic is ~45% of history. **iOS 27 rejects transcripts whose tool outputs don't carry their call's id** (untyped ModelManagerError 1001; macOS 26 accepts them). See docs/phase-0-findings.md §10.)*

### Measurements
- [x] **P0-09** **Structured tool-call validity rate** — % of calls with schema-valid arguments (R1) *(DONE 2026-09-19: single-tool suite, 20 goals × 5 runs per host. **First call fully correct: 51% on macOS 26.6.2, 63% on iOS 27.0** (iPhone 15 Pro); schema-valid calls 95% / 71%. Both are far below the M5 >95% bar. iOS 27 produced unparseable JSON for every date-time-argument goal (25/25); macOS 26 never fills optional arguments; no single declaration of a date field worked on both. Raw logs and scorer in docs/phase-0-results/; see docs/phase-0-findings.md §11.)*
- [x] **P0-10** **Multi-step completion rate** — % of multi-step goals completed end to end (R1) *(DONE 2026-09-19: 10 goals × 5 runs per configuration on macOS 26.6.2 and the iPhone (iOS 27.0). **14% completed as shipped on both; 28% (macOS, `--all-required`) and 20% (iOS, `--no-patterns`) with each OS's framework workaround.** Model-side failures are led by grounding (values from earlier tool output not carried into the next call); on iOS the model also repeated side-effecting calls, creating duplicate notes. One `respond()` hung for over 5 minutes on iOS, so the runners now enforce a per-run timeout. See docs/phase-0-findings.md §12.)*
- [x] **P0-11** **Guardrail refusal rate** on the ordinary-task suite (R3, M9) *(DONE 2026-09-26, both hosts, 130 runs each: **macOS 26.6.2 FAILS M9 on the per-goal bar** (`rf-h06`, dosage arithmetic, refused 4–5 of 5 while its paired control never is; overall 4–5%), **iOS 27.0 PASSES** (same goal 2/5, overall 2.0%, 0 control refusals). The seven iOS goals the date-JSON bug had left unmeasured were re-run under `--no-patterns`: all 35 runs reached the model with zero refusals, so the iOS pass is measured, not assumed. 0 soft refusals on either host after reading every completed answer. **Consequence per decision 0001: R3's fallback UX is v0.1 scope.** See docs/phase-0-findings.md §13/§13a.)*
- [x] **P0-12** **Context exhaustion rate** and failure mode under realistic load (R2) *(DONE 2026-09-23, both hosts, 72 runs per configuration each: typed exhaustion **0% context-only, 25% with tools registered** (the stress profile fails 18/18 on both). Exhaustion is not the main failure: **macOS 26 used only 55% of the facts present in its own window, while iOS 27 used 100%** — the widest OS gap in Phase 0. Over-budget requests fail as typed `exceededContextWindowSize` *or* untyped `tokengeneration 10`, and some above 4,096 tokens succeed. All 3 hallucinations were macOS at the lightest profile. See docs/phase-0-findings.md §14.)*
- [x] **P0-13** Determine whether a policy refusal is programmatically distinguishable from a normal response, or only by text heuristics — resolves open question 3 🔒 *(RESOLVED 2026-09-02: yes — `GenerationError.guardrailViolation`/`.refusal` are distinct typed cases, verified by actually triggering one at runtime; see docs/phase-0-findings.md §4)*
- [x] **P0-14** Record latency and thermal/battery behavior for a typical multi-step run *(DONE 2026-09-26: 15 minutes of continuous multi-step runs per host. **iPhone 15 Pro (on battery): `.serious` thermal state within 5 minutes and for 58 of 87 runs, ~39.4%/hour battery, p50 9.8 s per run (p90 13.4 s, worst 40.7 s), 5.7 runs/min.** macOS: `nominal` throughout, p50 3.3 s, 17.6 runs/min. Memory is not a per-run leak on either host. Implications: the runtime must observe `thermalState` and degrade deliberately, agent runs must be bounded and user-initiated, and latency budgets differ ~3× between hosts. See docs/phase-0-findings.md §16.)*

### Decision
- [x] **P0-15** 🔒 **GO/NO-GO: planner architecture.** Is `ModelDrivenPlanner` or `StateMachinePlanner` the v0.1 default? Below the >95% M5 bar it is the state machine — a successful, shippable outcome, not a failure *(DECIDED 2026-09-23: **`StateMachinePlanner` is the v0.1 default** — docs/decisions/0002-planner-default.md. Multi-step completion measured 14% as shipped on both hosts, 28% (macOS) and 20% (iOS) with each OS's framework workaround, against a >95% bar; single-call accuracy 51%/63%. The dominant model-side failure is grounding, which a deterministic planner removes by construction. `ModelDrivenPlanner` still ships and stays config-selectable; M5-03 gates promoting it.)*
- [x] **P0-16** Write `docs/phase-0-findings.md`: numbers, the decision, and the reasoning. This is the document the team argues with later *(DONE 2026-09-26: sections 1–16 — the API-surface findings, all five measurements (P0-09 to P0-12, P0-14) with raw logs and scorers in docs/phase-0-results/, and the P0-15 decision with its reasoning (§15). Two results are explicitly provisional and say so: P0-11's iOS verdict pending a 7-goal re-run, and the macOS-vs-iOS attribution throughout, since the hosts differ in platform and OS version.)*
- [x] **P0-17** Decide whether FR-026/FR-027 are MVP-blocking or deferred to v0.5 *(DECIDED 2026-09-26: **capabilities are MVP-blocking, implemented deterministically; model-driven planning and replanning defer to v0.5** — docs/decisions/0003-fr-026-027-scope.md. FR-026's bullets (sequential, conditional, dependencies, retries, completion detection) ship in v0.1 via `StateMachinePlanner` with guards evaluated in code; FR-027 ships as deterministic recovery only. The model emitting or revising whole plans is M5-01/M5-02, gated by M5-03. Corrects this file, which previously placed all of FR-026 in Milestone 5.)*
- [x] **P0-18** Port the spike's scenario suites into the seed of `LocalAgentKitEval` (FR-029) — the code is throwaway, the suites are not *(DONE 2026-09-23: the five suite files moved to `Sources/LocalAgentKitEval/Suites/phase0/` and ship as target resources; `SuiteLoader` loads the catalog and suites, `swift run LocalAgentKitEval` lists them, and 6 tests in `LocalAgentKitEvalTests` check counts, unique ids, the refusal suite's control pairing, and that no tool pattern is anchored (findings §11b). Scoring and execution are deliberately absent — that is M1-EV-01. The spike, the validator script and CI all read the new location.)*

**Exit:** findings documented, planner decision made and written down, open questions 1–3 answered.

---

## Milestone 1 — v0.1 Agent Core

*The MVP. Largest milestone; ordered so each group unblocks the next.*

### Core protocols & types (`LocalAgentKitCore`)
- [x] **M1-CO-01** `LocalModelProvider` protocol; `ModelRequest` / `ModelResponse` (FR-004) *(stays as the Core seam per decision 0004; Core must not import `FoundationModels` — the per-OS quirks live in the provider)*
- [x] **M1-CO-02** `ModelResponse` cases: `.text`, `.toolCall`, `.multipleToolCalls`, `.clarification`, `.refused(GuardrailRefusal)` (FR-005)
- [x] **M1-CO-03** `AgentTool` protocol — `name`, `description`, `schema`, `permission`, `execute` (FR-006)
- [x] **M1-CO-04** Add `isParallelSafe` and `isCancellable` to `AgentTool` — the runtime cannot schedule or cancel correctly without them *(addition to the PRD protocol)*
- [x] **M1-CO-05** `ToolSchema` + `ToolArguments` with JSON-Schema-shaped validation
- [x] **M1-CO-06** `ToolPermission` enum: `.none`, `.readOnly`, `.userConfirmation`, `.sensitive`, `.destructive` (FR-009)
- [x] **M1-CO-07** `AgentEvent` enum, all cases incl. `.guardrailRefused` and context-utilization reporting (FR-019, NFR context)
- [x] **M1-CO-08** `AgentError` typed errors, incl. `.guardrailRefusal` and `.contextLimitExceeded` (FR-025)
- [x] **M1-CO-09** `AgentConfiguration` — providers, security policy, execution limits, `networkPolicy` (FR-001, FR-023)
- [x] **M1-CO-10** `ExecutionLimits` — max iterations, max tool calls, max duration, max context (FR-003)
- [x] **M1-CO-11** `MemoryStore`, `EmbeddingProvider`, `VectorStore` protocol stubs so Core's shape is complete (FR-012, FR-014, FR-015)
- [x] **M1-CO-12** Verify Core compiles with **zero** Apple-framework imports (layering check must pass) *(DONE 2026-09-27 for the whole group M1-CO-01…12: Core is in `Sources/LocalAgentKitCore/{Model,Tools,Agent,Memory,RAG}`; 24 tests; build, format lint and layering grep clean. Design calls beyond the PRD: `isParallelSafe`/`isCancellable` have no default; `LocalModelProvider` gained `requiresNetwork`, `contextWindowTokens`, `tokenCount(for:)` (all defaulted) for FR-023 and the budgeter; `ExecutionLimits` adds `maxModelCallDuration`; `AgentConfiguration` has no `.default` because Core cannot name a model, defaults to `.never` network and `.stateMachine` planner; `SecurityPolicy` deliberately has no tier setting. `AgentPlan`/`PlanStep` are minimal placeholders that M1-RT-11 will extend.)*

### Runtime (`LocalAgentKitRuntime`)
- [ ] **M1-RT-01** `AgentRuntime` actor — owns all execution state; the iterate/observe loop (FR-003)
- [x] **M1-RT-02** `EventBus` — multicast `AsyncStream<AgentEvent>` so UI and logging can both subscribe (FR-019) *(DONE 2026-09-27: `EventBus` actor, per-subscriber `AsyncStream`, no replay for late subscribers, removes subscribers whose consumer stops)*
- [x] **M1-RT-03** `LoopDetector` — repeated `(tool, arguments)` signature detection; terminate or escalate to the user (FR-028, M8) *(DONE 2026-09-27: a loop is one full cycle plus one call (`A A A`, `A B A B A`), period up to 3; the PRD example is detected on the fifth call; a single repeat is not a loop)*
- [x] **M1-RT-04** `ContextBudgeter` — configurable shares for system+tools / conversation / RAG / plan state (NFR context, R2) *(DONE 2026-09-27: `ContextBudgeter` with configurable shares (relative weights, so an unused share flows to the others), a response reserve (default 512 tokens), and the window taken from the provider, `ExecutionLimits.maxContextTokens`, or a 4,096 fallback. Decisions use a pessimistic estimate calibrated once against the provider's real count of the untrimmed request, then verified with a real count in at most 3 passes. Core's `tokenCount(for:)` now takes a whole `ModelRequest` so tool definitions (~26% of the window, findings §10) are counted. Where a provider cannot count, only the estimate exists)*
- [x] **M1-RT-05** Trim-then-summarize degradation **before** throwing `contextLimitExceeded` — never the first line of defense *(DONE 2026-09-27: degradation order is shorten old tool outputs, drop the lowest-ranked chunks, replace the oldest whole turns with a summary, drop non-required tools, then throw `contextLimitExceeded`. Turns go whole so a tool call is never parted from its output (iOS 27 rejects orphans, findings §10a); the current turn is never dropped. The default `ExtractiveSummarizer` calls no model (battery, findings §16; macOS 26 ignores in-window facts, §14). Shares are soft: nothing is trimmed if everything fits)*
- [x] **M1-RT-06** Emit context utilization on the event stream for debugging (NFR context) *(DONE 2026-09-27: `fit(..., events:)` publishes `.contextUtilization` with used/limit tokens and whether it trimmed; `TrimReport` says what was given up)*
- [x] **M1-RT-07** `ToolExecutor` — validate args → permission gate → execute → observe, **in that order** (the injection mitigation is the ordering) *(DONE 2026-09-27: `ToolExecutor` validate → gate → execute → observe, with the order pinned by tests. It consults the `PermissionGate` only above `.readOnly` and denies those tiers when no gate is configured, so a gate cannot widen what runs. Tools are found through a `ToolSource` protocol because `ToolRegistry` lives in Tools, which depends on Runtime. The result is stamped with the call id (findings §10). M1-SE-04's executor-level half is covered here; its document-ingestion half waits on RAG)*
- [~] **M1-RT-08** Argument-repair path: bounded retries with schema feedback on invalid tool arguments *(PARTIAL 2026-09-27: `ArgumentRepairer` is bounded, gives schema feedback and treats a refusal as terminal, and is tested against `ScriptedModelProvider`; it is not yet called from the loop, which waits on M1-RT-01)*
- [ ] **M1-RT-09** Guardrail refusals terminate — **never** retried (R3)
- [ ] **M1-RT-10** Suspension via continuation for permission prompts and clarifications — no thread or lock held while waiting on a human (FR-010)
- [ ] **M1-RT-11** `AgentPlanner` protocol + `StateMachinePlanner` implementation *(the v0.1 default per P0-15. Design targets the measured failures: carry values between steps in `AgentContext` rather than through the model; ask one narrow, preferably closed question per step; validate and retry every model answer, assuming ~50–60% single-call accuracy; evaluate conditional guards in code.)*
- [ ] **M1-RT-12** `ModelDrivenPlanner` — built either way; P0-15 decided `StateMachinePlanner` is `.default` (FR-026), so this ships config-selectable and is promoted only if M5-03 re-measures above the >95% bar
- [ ] **M1-RT-13** Cooperative cancellation through model, RAG, tools; every `await` a cancellation point (FR-024)
- [ ] **M1-RT-14** Enforce all four execution limits with distinct typed errors *(includes a deadline **per model call**, not only per run: a single `respond()` hung for over 5 minutes in P0-10, and the worst sustained-load run took 40.7 s — findings §12, §16)*
- [ ] **M1-RT-15** OSLog + signpost instrumentation across the loop
- [ ] **M1-RT-16** Deterministic multi-step execution in `StateMachinePlanner`: sequential steps, tool dependencies resolved through `AgentContext`, bounded retries, completion detection, and **conditional guards evaluated in code** (FR-026 capabilities per decision 0003; the model ignored a goal's condition 4/5 — findings §12)
- [ ] **M1-RT-17** Deterministic recovery when a tool returns nothing or fails validation: declared alternative path, else a typed error (the v0.1 half of FR-027 per decision 0003)
- [ ] **M1-RT-18** Observe `ProcessInfo.thermalState` and degrade deliberately — fewer parallel tool executions, tighter context budget, no speculative calls (NFR performance; the iPhone reaches `.serious` within 5 minutes of sustained work and ~39%/hour battery — findings §16)

### Tools & registry (`LocalAgentKitTools`)
- [ ] **M1-TL-01** `ToolRegistry` actor — register, lookup, remove, metadata, schemas, permission metadata (FR-007)
- [ ] **M1-TL-02** Tool-descriptor serialization into the model prompt
- [ ] **M1-TL-03** `CalculatorTool` — `.none` (FR-008)
- [ ] **M1-TL-04** `CalendarTool` read via EventKit — `.readOnly` (FR-008)
- [ ] **M1-TL-05** `ReminderTool` create via EventKit — `.userConfirmation` (FR-008)
- [ ] **M1-TL-06** EventKit authorization handling with a typed, recoverable error path
- [ ] **M1-TL-07** `DocumentSearchTool` — `.readOnly`, backed by basic RAG

### Providers (`LocalAgentKitProviders`)
- [ ] **M1-PR-01** `FoundationModelProvider` — sits on top of Apple's BYO-LLM support, does not re-implement it (FR-004) *(per decision 0004 this adapts `LocalModelProvider` to `SystemLanguageModel` and owns the documented per-OS workarounds: required rather than optional arguments, no anchored or date pattern guides, lenient ISO-8601 parsing, and rebuilding a session from a pre-stream transcript snapshot after cancellation — findings §9a, §11a, §11b)*
- [ ] **M1-PR-02** Map Foundation Models structured output onto `ModelResponse`
- [ ] **M1-PR-03** Detect and surface guardrail refusals as `.refused` (per the P0-13 finding)
- [ ] **M1-PR-04** Model lifecycle: lazy load, unload, **shared reference-counted instance across agents** — resolves open question 6 before it becomes a retrofit (NFR memory)
- [ ] **M1-PR-05** Streaming token support → `.responseToken` events (NFR performance)
- [ ] **M1-PR-06** OS 27 adapter: wrap any `LanguageModel` conformance behind `#available`, so an app can bring its own model through Apple's protocol without `Core` knowing (decision 0004, FR-004)

### Basic RAG (enough for the demo; full pipeline is v0.3)
- [ ] **M1-RG-01** TXT + Markdown ingestion
- [ ] **M1-RG-02** Chunker with configurable size/overlap
- [ ] **M1-RG-03** `NLEmbeddingProvider` (default on-device embeddings)
- [ ] **M1-RG-04** In-memory flat `VectorStore`, brute-force cosine similarity — sufficient at single-user scale
- [ ] **M1-RG-05** Retrieval → `ContextBudgeter` → prompt injection path

### Conversation memory
- [ ] **M1-ME-01** In-memory `ConversationMemory` (SwiftData persistence lands in v0.2)
- [ ] **M1-ME-02** Turn assembly + trimming under the budgeter's conversation share

### Security
- [ ] **M1-SE-01** `PermissionManager` — enforce tiers; **nothing above `.readOnly` executes without explicit confirmation** (FR-009, M6)
- [ ] **M1-SE-02** `AuditLogger` — append-only local log of sensitive tool executions (FR-022)
- [ ] **M1-SE-03** `NetworkPolicyGuard` — validate the whole config at construction; `.never` + a network-requiring BYO-LLM provider is a **startup error** (FR-023)
- [ ] **M1-SE-04** Test: a schema-valid tool call originating from injected document text is still stopped at the permission gate (PRD §19)

### Testing infrastructure (`LocalAgentKitTesting`)
- [x] **M1-TS-01** `MockModelProvider` + `ScriptedModelProvider` for deterministic loop tests (FR-004, §18) *(DONE 2026-09-27: both in `Sources/LocalAgentKitTesting`, plus `MockTool`, `MockMemoryStore`, `MockEmbeddingProvider`, `MockVectorStore` so every Core protocol has a mock. `ScriptedModelProvider` steps: respond, fail, delay, hang; running past the script's end throws rather than passing silently. New target `LocalAgentKitTestingTests`, 15 tests. Testing still depends on Core only.)*
- [ ] **M1-TS-02** Unit tests: runtime, planner, registry, executor, budgeter, loop detector, permissions
- [ ] **M1-TS-03** Agent evaluation scenarios: goal → expected tools → expected result → max iterations → permission expectations (§18)
- [ ] **M1-TS-04** Reach the 80% coverage gate on Core + Runtime (M4)
- [ ] **M1-TS-05** Test that the full unit suite runs with **no device and no network**

### Reliability harness (`LocalAgentKitEval`, FR-029)
- [ ] **M1-EV-01** CLI harness target (swift-argument-parser)
- [ ] **M1-EV-02** Measure structured tool-call validity rate
- [ ] **M1-EV-03** Measure multi-step task completion rate
- [ ] **M1-EV-04** Measure guardrail refusal rate on the ordinary-task suite (M9) *(Threshold: docs/decisions/0001-m9-refusal-threshold.md, applied per OS version and per OS beta.)*
- [ ] **M1-EV-05** Measure context-budget exhaustion rate under realistic load
- [ ] **M1-EV-06** Machine-readable report output + run-over-run comparison
- [ ] **M1-EV-07** CI job: harness on every release **and every OS beta** → drift report (R4)
- [ ] **M1-EV-08** Wire harness results into the M5 metric so it is measured continuously, not observed informally

### SwiftUI demo (`Examples/LocalAgentDemo`)
- [ ] **M1-UI-01** `LocalAgentKitSwiftUI`: `AgentViewModel`, event → view-state bridging (FR-020)
- [ ] **M1-UI-02** Opt-in permission confirmation sheet — resolves open question 5 (protocol + event required; sheet is convenience)
- [ ] **M1-UI-03** Demo app shell: chat UI, streaming tokens, visible tool activity
- [ ] **M1-UI-04** Demo turn 1 — "What meetings do I have tomorrow?" (§13)
- [ ] **M1-UI-05** Demo turn 2 — "Find my notes related to those meetings."
- [ ] **M1-UI-06** Demo turn 3 — "Create a preparation checklist."
- [ ] **M1-UI-07** Demo turn 4 — "Save that as a note." (exercises the permission flow)
- [ ] **M1-UI-08** Verify a UIKit consumer works without importing the SwiftUI target (FR-020)

### Documentation
- [ ] **M1-DC-01** DocC catalog + CI publish
- [ ] **M1-DC-02** "Build your first agent" guide — validate it against the 30-minute M1 target with someone who has not seen the code
- [ ] **M1-DC-03** "Write a custom tool" guide — verify the <100-line M2 target end to end
- [ ] **M1-DC-04** Document every public API surface

**Exit:** the four-turn demo runs end to end on device; M5/M6/M7 measured by the harness; M1–M4 developer metrics verified with a real outside developer.

---

## Milestone 2 — v0.2 Memory

- [ ] **M2-01** SwiftData model definitions for `Memory` (FR-011)
- [ ] **M2-02** `SwiftDataMemoryStore` conforming to `MemoryStore` — save / search / delete (FR-012)
- [ ] **M2-03** Working memory — current task state
- [ ] **M2-04** Conversation memory persisted across app launches
- [ ] **M2-05** Semantic memory — durable facts and preferences
- [ ] **M2-06** Episodic memory — past events and actions
- [ ] **M2-07** Memory retrieval integrated into context assembly under the budgeter
- [ ] **M2-08** Memory-store migration strategy (schema evolution will happen; decide now)
- [ ] **M2-09** `NotesTool` — create `.userConfirmation` / search `.readOnly` (FR-008)
- [ ] **M2-10** `ContactsTool` search — `.sensitive` (FR-008)
- [ ] **M2-11** `FilesTool` search — `.readOnly` (FR-008)
- [ ] **M2-12** Decide audit-log retention + export format — resolves open question 7 (Persona 3 will ask)
- [ ] **M2-13** Memory-layer unit tests to the coverage gate
- [ ] **M2-14** Demo app: conversation survives restart

**Exit:** context survives app restart; all four memory categories usable through one protocol.

---

## Milestone 3 — v0.3 RAG

- [ ] **M3-01** PDF ingestion via PDFKit (FR-013)
- [ ] **M3-02** Extraction pipeline for PDF / TXT / MD / plain text
- [ ] **M3-03** Improved chunking — structure-aware, not fixed-width
- [ ] **M3-04** 🔒 **Benchmark `NLEmbedding` retrieval quality vs. a small MLX embedding model via Core AI** — resolves open question 4; retrieval quality caps the entire feature
- [ ] **M3-05** File-backed persistent vector store
- [ ] **M3-06** Background, batchable, **cancellable** ingestion with progress events — embedding a 300-page PDF on a phone is a battery event, not a function call (NFR battery)
- [ ] **M3-07** Retrieval tuning: top-k, thresholds, dedup
- [ ] **M3-08** Benchmark retrieval latency + memory at realistic corpus size; introduce an ANN index **only** if the benchmark demands it
- [ ] **M3-09** Prompt-injection test corpus: adversarial instructions embedded in ingested documents (PRD §19)
- [ ] **M3-10** Demo app: answer questions from a real user-supplied PDF

**Exit:** demo answers from a real user PDF; embedding-provider decision made on measured data.

---

## Milestone 4 — v0.4 Multimodal

- [ ] **M4-01** `VisionProvider` protocol + `AppleVisionProvider` (FR-016)
- [ ] **M4-02** OCR
- [ ] **M4-03** Image classification + object detection
- [ ] **M4-04** Document understanding + structured extraction
- [ ] **M4-05** `SpeechRecognizer` protocol + Apple STT implementation (FR-017)
- [ ] **M4-06** `SpeechSynthesizer` protocol + Apple TTS implementation (FR-017)
- [ ] **M4-07** Multimodal input types on `agent.run` — image, audio, document, combined (FR-002, FR-018)
- [ ] **M4-08** Multimodal orchestration pipeline: camera → vision → structured data → agent → tool (FR-018)
- [ ] **M4-09** Cancellation propagates into vision and speech (FR-024)
- [ ] **M4-10** Battery/thermal measurement for vision + speech paths (NFR battery)
- [ ] **M4-11** Demo: receipt photo → structured expense record
- [ ] **M4-12** Voice input → agent → spoken response, end to end

**Exit:** receipt → structured expense works on device; multimodal inputs flow through one `run` API.

---

## Milestone 5 — v0.5 Advanced Agents

*Scope settled by P0-15 and P0-17: the state machine is the v0.1 default (decision 0002) and the deterministic planning capabilities ship in Milestone 1, so this milestone is where **model-driven** planning is re-attempted with better evidence (decision 0003). M5-03 gates promoting it.*

- [ ] **M5-01** **Model-driven** planning: the model emits a whole plan end to end (the deferred half of FR-026 per decision 0003; the deterministic capabilities ship in v0.1 as M1-RT-16)
- [ ] **M5-02** **Model-driven** replanning: the model revises its plan from unexpected observations (the deferred half of FR-027 per decision 0003; deterministic recovery ships in v0.1 as M1-RT-17)
- [ ] **M5-03** Re-run the Phase 0 planning measurements against the current model before promoting `ModelDrivenPlanner` to default
- [ ] **M5-04** Parallel tool execution for tools declaring `isParallelSafe` (NFR performance)
- [ ] **M5-05** Task dependency graph + scheduling
- [ ] **M5-06** Hardened loop detection: semantic repetition, not just exact `(tool, args)` matches (FR-028)
- [ ] **M5-07** Plan visualization in the demo — `.planCreated` rendered as a live checklist
- [ ] **M5-08** Multi-step evaluation scenarios expanded in the harness
- [ ] **M5-09** Verify M8 (loop detection) with deliberately loop-inducing scenarios

**Exit:** M8 verified; planner promotion decided on fresh measurements, not the Phase 0 numbers.

---

## Milestone 6 — v1.0 Production SDK

### API stability
- [ ] **M6-01** Full public API review; mark internal surfaces `internal`
- [ ] **M6-02** Semantic versioning policy + deprecation strategy
- [ ] **M6-03** Freeze public API; document the stability guarantee

### Quality
- [ ] **M6-04** Performance pass against the `Benchmarks/` baselines — latency, peak memory, model load/unload
- [ ] **M6-05** Battery/thermal profiling of a full agent session on device
- [ ] **M6-06** External security audit (PRD §19 threat model)
- [ ] **M6-07** Verify M10 — **zero** network requests in offline mode, proven by traffic capture, not by inspection
- [ ] **M6-08** Verify M11 — user documents never leave the device unless explicitly exported
- [ ] **M6-09** Extensive test suite; sustained coverage gate

### Documentation & adoption
- [ ] **M6-10** Complete DocC reference
- [ ] **M6-11** Example applications for 3+ reference use cases (PRD §16)
- [ ] **M6-12** Migration guide from raw Foundation Models usage
- [ ] **M6-13** Publish harness results in release notes so developers see what changed in agent behavior between OS versions (§21 v1.0)
- [ ] **M6-14** Instrument M12 — time from package-add to first successful `agent.run()`
- [ ] **M6-15** Track M13 — community-contributed tools and providers
- [ ] **M6-16** Track M14 — issue volume on guardrail refusals and context limits as the early R2/R3 warning signal

**Exit:** stable API, audited, benchmarked, documented; offline and privacy guarantees proven rather than asserted.

---

## Continuous — every milestone

- [ ] **C-01** Run the FR-029 harness on every OS beta; triage drift immediately (R4)
- [ ] **C-02** Keep the layering check green — it is the only thing keeping M3 true over time
- [ ] **C-03** Every new observable state emits an `AgentEvent`
- [ ] **C-04** Every new error is typed and recoverable where possible; no `fatalError` in library code
- [ ] **C-05** No new runtime dependency without written justification in the PR
- [ ] **C-06** Every new protocol ships with a mock in `LocalAgentKitTesting`
- [ ] **C-07** Update `PLANNING.md` §6 as open questions get answered — an answered question moves to a decision record, it does not just vanish
