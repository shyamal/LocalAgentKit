# Retain and export audit snapshots

`AuditLogger` holds a session-only window of confirmed successful sensitive tool
returns. The default retains 1,000 newest recordings and at most 4,096 characters
per argument signature. Old entries are evicted by recording order, not timestamp.
This replaces the previously unbounded in-memory buffer; it is not durable storage.

```swift
let logger = AuditLogger(retention: AuditRetentionPolicy(
  maximumEntries: 1000, maximumSignatureCharacters: 4096))
let runtime = try AgentRuntime(
  configuration: configuration, tools: tools, auditLogger: logger)
// After a run, prepare metadata-only JSON; no file write or transmission occurs.
let data = try await runtime.exportAuditJSON()
```

Both policy bounds clamp non-positive values to one. Signatures remain raw
sensitive text in memory, possibly truncated with `argumentsWereTruncated: true`.
`auditEntries()` returns copied retained records. Injecting one logger into several
runtimes shares that entire window; it is not filtered by run or account.

## Explicit disclosure and clearing

`logger.exportJSON()` or `runtime.exportAuditJSON()` omits argument fields by
default. Opt in with `includeArguments: true` only when the host intends to expose
the retained text. Neither its stable signature rendering nor clipping is hashing
or anonymization. Full tool results are never part of an audit entry. Metadata
(tool names, times and IDs) can still be sensitive.

The host owns the destination, consent, protection and durable retention of any
bytes it writes or sends. The SDK supplies no automatic disk persistence, export
upload, calendar TTL or enterprise retention schedule. It also supplies no import,
merge or incremental-delivery API. Repeated exports can overlap; use record UUIDs
if the host needs to deduplicate its own collected snapshots.

`await logger.clear()` explicitly removes the current in-memory records; it does
not touch exported copies or guarantee secure physical memory erasure. The logger's
`discardedEntryCount` includes both capacity eviction and clearing, and survives
clear within that logger's lifetime. A new logger begins a new window/counter.

## Version-one JSON contract

```json
{
  "schemaVersion": 1,
  "exportedAt": 1730000000000,
  "includesArguments": false,
  "retention": {"maximumEntries": 1000, "maximumSignatureCharacters": 4096},
  "discardedEntryCount": 0,
  "entries": []
}
```

Each entry has `id` (UUID string), `timestamp` (numeric milliseconds since Unix
epoch, possibly fractional), `toolName`, `permission` and `wasEmpty`. Permission
is a string (`none`, `readOnly`, `userConfirmation`, `sensitive`, `destructive`),
not an enum ordinal. An opted-in export also includes `argumentsSignature` and
`argumentsWereTruncated`. Exported signatures cannot recover discarded characters.
Object keys are sorted; entries keep recording order. Incompatible wire changes
require a new `schemaVersion`. Non-finite dates/encoding failures throw typed
`AgentError.memoryFailure` and leave retained records unchanged.

## Audit limits and approval

The executor records successful confirmed returns above `.readOnly`; it does not
record validation failures, denials, failed/timed-out calls or full result data.
A timed-out underlying operation may still finish later, so missing records do not
prove that no side effect occurred. Host code may append/clear records directly;
this is not a tamper-evident or exhaustive ledger. Existing execution events stay
unchanged; these APIs do not add a planner state or an agent-controlled export tool.

Disabling collection with `SecurityPolicy.auditSensitiveExecutions` prevents new
executor records but does not erase a shared logger. Retention, clear and export
never change a tool's tier or bypass its human approval gate.
