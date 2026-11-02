# Execution and permissions

Validation, confirmation, and context limits apply to every agent run.

## Tool execution order

The executor validates arguments, checks the permission gate, executes the tool,
and returns an observation. Any tier above read-only requires explicit human
confirmation. Schema validity does not make a call authorized, and text from an
ingested document cannot grant permission. A pending human prompt suspends via a
continuation rather than holding a thread or lock.

## Model limits

Context budgeting allocates space to instructions and tools, conversation,
retrieved chunks, and plan state. Trimming may remove information needed for an
answer; fitting input also does not guarantee that generation will fit. Treat
context errors and guardrail refusals as observable outcomes. Refusals are terminal
and are not retried as a strategy for bypassing platform policy.

## Reliability evidence

The repository's evaluation harness measures validity, completion, refusals, and
context failures independently of the demo. Its fixture-tool M5 assessment cannot
establish success for actual device backends. The published API pages and these
architecture notes do not replace a device measurement or a human permission test.
