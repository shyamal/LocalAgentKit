---
name: add-agent-tool
description: Add a new AgentTool to LocalAgentKit — choosing the permission tier, writing the ToolSchema, declaring parallel-safety and cancellability, registering it, and writing the required permission-gate test. Use whenever the task is "add a tool", "make the agent able to X", "expose <capability> to the agent", or when implementing any M1-TL / M2 tool task from TASKS.md.
---

# Adding an AgentTool

A tool is the *only* way an agent affects the world. Every tool is a new entry in the threat model, so the permission tier is the first decision, not the last.

Target: a complete tool in **under 100 lines of application code** (metric M2). If you're past that, the tool is doing too much — split it.

## 1. Choose the permission tier (do this first)

This is the SDK's primary defense against prompt injection (PRD §19). A schema-valid tool call from an injected instruction is stopped *here* and nowhere else. Choose by asking **"what happens if a manipulated model calls this with attacker-chosen arguments?"** — never by how the tool is normally used.

| Tier | Use when | Confirmation |
|---|---|---|
| `.none` | Pure computation. No I/O, no user data, no side effects. `CalculatorTool` is the only obvious case. | No |
| `.readOnly` | Reads data the app already has access to. No mutation, no exfiltration path. | No |
| `.userConfirmation` | Creates or modifies user data. Recoverable if wrong. | **Yes** |
| `.sensitive` | Touches personal data whose *reading* is itself the risk — contacts, health, location, messages. | **Yes** |
| `.destructive` | Deletes, sends, spends, or is otherwise irreversible. | **Yes** |

Rules that are not negotiable:

- **When torn between two tiers, take the higher one.** A too-strict tool is an annoyance; a too-loose one is a vulnerability.
- Anything that **sends** data anywhere (message, email, share sheet, upload) is `.destructive`, regardless of how routine it feels.
- A tool that reads data *and* accepts a free-text destination parameter is an exfiltration primitive. Split it into a read tool and a send tool with separate tiers.
- Never add a config flag that lets an app downgrade a tool's tier at runtime.

## 2. Write the schema before the implementation

The schema is what the model sees. Argument validation runs *before* the permission gate, so a tight schema reduces how often a human gets prompted with nonsense.

- Constrain aggressively: enums over free strings, ranges over open numbers, explicit optionality.
- No argument should be a free-text field that becomes a file path, URL, or identifier without validation in `execute`.
- `description` is a prompt, not documentation. Write it for the model: say what the tool does, when to choose it, and when *not* to. Name the units and formats of every parameter.

## 3. Implement

Live in `Sources/LocalAgentKitTools/`. Tools may import Apple frameworks — `Core` and `Runtime` may not.

```swift
struct <Name>Tool: AgentTool {
    let name = "<snake_case_verb_noun>"        // e.g. create_reminder
    let description = "<written for the model>"
    let permission: ToolPermission = .<tier>
    let schema = ToolSchema(...)

    let isParallelSafe = <Bool>     // false if it mutates shared state or racy resources
    let isCancellable  = <Bool>     // false if execute() cannot honor Task cancellation

    func execute(arguments: ToolArguments) async throws -> ToolResult {
        // 1. Decode + validate arguments beyond what the schema can express
        // 2. Handle authorization (EventKit/Contacts) with a typed, recoverable error
        // 3. Check Task.isCancelled at each await point if isCancellable
        // 4. Return .success(...) — or throw a typed AgentError, never fatalError
    }
}
```

Checklist:

- [ ] `name` is `snake_case`, verb-first, unique in the registry
- [ ] `isParallelSafe` is `false` unless you can argue two concurrent calls are safe
- [ ] `isCancellable` is honest — a tool that lies here breaks FR-024 cancellation
- [ ] Authorization failures are typed and recoverable, not crashes
- [ ] Errors thrown are `AgentError` cases; no `fatalError` in library code
- [ ] The tool returns a result the *model* can read — structured and compact, not a raw framework object dump that blows the context budget (R2)

## 4. Register and document

- Export it from `LocalAgentKitTools`
- Add it to the agent tool catalog table in `PLANNING.md` §4.3 (tier, framework, milestone)
- Add DocC comments to the public type

## 5. Tests (all four are required)

1. **Happy path** — valid arguments produce the expected `ToolResult`, using `MockModelProvider`.
2. **Invalid arguments** — schema validation rejects them before `execute` is reached.
3. **Permission gate** — for any tier above `.readOnly`, assert the tool does **not** execute without confirmation. This is the M6 metric ("no unauthorized tool execution"); a tool without this test is not done.
4. **Cancellation** — if `isCancellable`, assert an in-flight call honors `Task` cancellation.

For anything above `.readOnly`, also add an **injection test**: a tool call originating from adversarial text in an ingested document must still stop at the gate (task M1-SE-04 established the pattern).

Tests must run with **no device and no network** (M1-TS-05). If the tool wraps EventKit or Contacts, put the framework behind a small internal protocol so the unit test can fake it.

## 6. Close the loop

- Add an evaluation scenario to the harness suite: goal → expected tool → expected arguments → permission expectation (PRD §18)
- Tick the matching `M1-TL-*` / `M2-*` task in `TASKS.md`
- If the tool is new to the roadmap, add a task ID rather than leaving it untracked
