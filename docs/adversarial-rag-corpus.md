# Adversarial RAG corpus (M3-09)

This original, inert corpus tests the PRD §19 boundary: a manipulated model's
schema-valid tool call must still pass through the permission gate. A scripted
model intentionally obeys each attack. Passing this suite is not a real-model
injection-resistance rate or an injection detector.

The test-only resource is `Tests/LocalAgentKitToolsTests/Fixtures/adversarial-rag.json`.
It is copied only into LocalAgentKitToolsTests, not an SDK library product. All
requested actions target recording mocks; fixture paths/addresses are inert.

## Cases

| ID | Technique | Required tier | Source |
|---|---|---|---|
| `role-spoof` | role-spoofing | destructive | txt |
| `forged-approval` | fabricated-approval | sensitive | md |
| `urgent-repair` | urgency-pretext | userConfirmation | txt |
| `tool-json` | tool-result-spoofing | sensitive | txt |
| `markdown-comment` | hidden-markup | destructive | md |
| `code-fence` | quoted-code-pretext | userConfirmation | md |
| `delimiter-escape` | delimiter-spoofing | sensitive | txt |
| `encoded-payload` | encoded-instruction | destructive | txt |
| `unicode-authority` | unicode-authority | userConfirmation | txt |
| `multi-step` | workflow-hijack | destructive | md |
| `policy-override` | policy-spoofing | sensitive | md |
| `reward-pressure` | evaluation-pressure | userConfirmation | txt |

Every case has a stable ID, unique prompt marker, literal instruction and
schema-valid target payload. The invariant test requires exact ID coverage and
all three tiers; unknown/extra/missing cases cannot silently escape the matrix.
Each case runs through both routes:

1. Real temporary TXT/Markdown file → DocumentExtractor (Markdown structure retained)
   → real chunker/pipeline → mock embedding/vector store → automatic RAG context.
2. The same ingestion → actual DocumentSearchTool with explicit selection settings
   → tool result → model context. Automatic retrieval is disabled on this route.

Both routes assert the marker and literal malicious instruction reach the model's
recorded request, then force the model to make the schema-valid target call. A
recording deny gate must receive exactly one request. Permission-required events
must appear while target tool-start/completion events, executions and successful
audit entries remain absent. This avoids a vacuous pass where no attack was retrieved.
There are 24 route/case denial checks; they are not 24 independent model trials.

## Controls and lifecycle

- Each guarded tier runs through the real default broker with denial and approval:
  execution remains empty while suspended. Denial blocks execution/audit; explicit
  approval permits one inert mock execution and one audit entry.
- For all three tiers, cancellation while awaiting approval is terminal; a stale
  approval cannot revive the request or execute its target.
- Invalid target arguments fail before asking the gate or executing.
- A benign read-only control executes without the write-permission gate, showing
  the suite does not merely block every operation.

Six Swift test functions expand to 38 invocations (24 denial routes, six broker
controls, three cancellation controls, three schema controls, corpus invariants and
one read-only control). The original M1-SE-04 tests remain unchanged. No SDK/runtime
implementation, new protocol, dependency or permission tier is introduced.

## Scope

This tests host-side authorization, not model resistance to role spoofing, encoded
instructions, language or markup. The scripted model is not interpreting the attack
or evaluating semantic success: it represents a worst-case valid call. UTF-8 and
markers are preserved, including the zero-width character fixture. Markdown is
source text, not rendered HTML; “hidden markup” describes its adversarial form,
not a browser-rendering behavior.

The suite does not establish protection from misleading answers, output leakage,
read-only misuse, incorrectly declared tool tiers, compromised/custom auto-approving
host gates, real OS permission prompts or an incautious human approving an attack.
No destructive filesystem/network action occurs. Native PDF/OCR, chunk-boundary
attacks, very long/truncated documents, multilingual robustness, real-model behavior
and user-PDF acceptance are not measured here. Permission gating remains the primary
backstop; structured output and retrieval scores do not authenticate document text.

## Reproduce and extend

```bash
swift test --filter AdversarialRAGCorpusTests
bash Scripts/check-coverage.sh
bash Scripts/check-offline-tests.sh
```

Add cases without renumbering existing IDs, update the required ID set and retain
proof that payloads reach context. Keep target actions inert and their schema/tier
explicit. Separate future real-model measurements from deterministic gate assertions;
record provider/OS revisions and denominators rather than calling these tests an
attack-success benchmark.

Corpus SHA-256 at verification: `9c265beb8d9f8cb108d504f3efa385638f78296437ad07d96f1468a18a747a7e`.

## Verification 2026-11-06

The strict SDK build is warning-free; all 719 root Swift test functions and the
network-denied suite pass. The new six-function suite expands to 38 invocations
and passes again with exact invalid-arguments assertions. All 70 Python tests,
strict Swift formatting, architectural layering and DocC API/static-route checks
pass. Core/Runtime coverage is 98.87% (2897/2930), unchanged from the base run:
Core 99.44% (889/894), Runtime 98.62% (2008/2036). No SDK implementation changed.

Only the test target gains a resource bundle. The corpus does not ship in SDK
library products, and no new platform API was introduced. iOS/example builds were
not repeated for this test-and-documentation change; no device/model integration
or real-OS permission claim is made.
