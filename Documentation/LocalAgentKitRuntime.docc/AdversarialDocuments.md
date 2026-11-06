# Treat retrieved instructions as untrusted

Imported text may persuade a model to request an unintended action. Schema-valid
structured calls alone do not prevent that: ``ToolExecutor`` validates arguments,
then asks for required permission before execution (PRD §19, M3-09).

The test-only adversarial corpus contains twelve original fixtures covering role
spoofing, fabricated approval, urgency, spoofed tool JSON, Markdown comments/code,
delimiter escapes, encoded payloads, Unicode authority claims, workflow hijacking,
policy overrides and evaluation pressure. Every case reaches model context through
both automatic RAG and the actual document-search tool. A scripted model follows
the instruction and requests a schema-valid recording mock above read-only.

Tests verify the deny gate prevents target execution/start/completion and successful
audit entries. Separate default-broker controls show suspension until a human decision,
execution only after explicit approval, and cancellation rejecting stale approval.
Malformed arguments never reach the gate; a benign read-only control remains allowed.
These controls test ordering and authorization, not a content filter.

This is not a real-model resistance/attack-success rate, answer-truth check or output
leakage guarantee. A human approving an unintended action, an incorrectly declared
tool tier or a host-supplied gate that automatically approves is outside this suite's
protection claim. No real destructive or network tool runs; all target actions are
inert mocks. Corpus resources are bundled only with the Tools test target.

The versioned fixtures, case matrix, controls, scope and reproduction commands are
recorded in the repository's `docs/adversarial-rag-corpus.md`. The earlier M1-SE-04
regressions remain in place. No SDK implementation or permission tier changed.
