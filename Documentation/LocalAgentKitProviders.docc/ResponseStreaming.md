# Response streaming

Deliver incremental final-answer text while keeping internal decisions private.

## Runtime behavior

The built-in planners mark final-answer requests with `ModelRequest.Purpose.answer`.
All other requests default to `.decision`. The budgeted wrapper enables callbacks
only for an answer request whose tool list is empty; planner choices, proposed
plans, argument generation and repair do not emit user-facing fragments.
Custom planners must mark their final-answer request explicitly to opt in.

`AgentEvent.responseToken` carries an append-only text fragment, which may contain
several model tokens or a partial word. The final `.completed` response remains
authoritative. UI consumers should append fragments to one provisional assistant
turn and replace that turn with the final answer on completion.

`AgentViewModel` implements that behavior. On failure, policy refusal or clarification
it discards the provisional turn; a clarification or refusal is then shown through
its usual event path. Other event consumers need to handle the same terminal
outcomes. Incremental text is provisional until the run completes.

## Foundation Models provider

For tool-free requests the streaming overload consumes `LanguageModelSession`'s
`streamResponse(to:)` snapshots from a fresh session. Snapshots contain cumulative
text, so the adapter emits only the appended UTF-8 suffix. This handles combining
marks and extended emoji without splitting a UTF-8 code point. Duplicate snapshots
produce no fragment. A revision of previously emitted bytes is a typed model error,
because the append-only event API cannot retract earlier text.

Requests declaring tools keep the existing capture-and-hand-back path and do not
stream raw model/tool output. Validation and human permission remain in the runtime.
Malformed output can be retried only before any fragment has been delivered;
after partial delivery a failure is terminal, avoiding duplicated text. Refusals
are never retried. Each attempt uses a fresh session, including after cancellation.

Budgets and thermal admission checks still run before generation, and the model
call keeps its deadline. If a timeout abandons a provider that ignores cancellation,
the runtime closes its response channel before reporting the error. Later callbacks
on that channel are ignored, including during a subsequent run on the same runtime.
This prevents stale text from contaminating another turn; it does not assert that
the abandoned provider stopped doing work.

## Provider contract and fallback

`LocalModelProvider.generate(request:onToken:)` returns the same `ModelResponse`
as ordinary generation. A streaming implementation awaits its Sendable async
callback for each ordered fragment, respects cancellation and maps errors to
`AgentError`. The default implementation calls ordinary generation and delivers
no fragments, so existing custom providers keep working without pretending to
support incremental output.

`ScriptedModelProvider.Step.stream(_:then:)` and `streamFailure(_:error:)` provide
deterministic fragment sequences for tests. An ordinary non-streaming call consumes
the response or error without exposing those fragments. These scripts test the
runtime path without loading model assets.

## Verification scope

Unit tests cover fragment ordering, private-decision suppression, fallback,
Unicode suffixes, stale callbacks after a deadline and cleanup of partial UI turns.
Opt-in `FoundationModelDeviceTests` check real incremental generation and fresh-session
behavior after cancellation. This does not establish a latency improvement, iPhone
streaming performance or a general real-model task success rate.
