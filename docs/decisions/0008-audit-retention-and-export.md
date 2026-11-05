# 0008 — Bounded session audit retention and explicit JSON export

Date: 2026-11-04

Status: accepted (M2-12; FR-022; PLANNING question 7)

## Decision

Keep SDK audit storage in memory for the lifetime of its AuditLogger. Default to
1,000 newest recordings and 4,096 grapheme characters per argument signature.
AuditRetentionPolicy makes both bounds explicit, immutable per logger and
configurable by the host; non-positive values clamp to one. Evict by recording
order, not timestamps, so clock changes or caller-supplied dates do not control
capacity. Mark signatures that were truncated. This changes the unbounded v0.1
buffer into a bounded retained window; it is not an everlasting append-only log.

No automatic disk storage, network synchronization, calendar TTL or regulatory
retention schedule is introduced. The owning app chooses its durable retention,
protection and export policy. This is a concrete SDK boundary, not a promise that
durability will silently arrive later. An enterprise app needing history beyond
the window must explicitly capture/store appropriate exports and reconcile them
according to its own requirements. Snapshots can overlap; UUIDs identify records,
but the SDK does not supply an incremental export cursor or delivery guarantee.

Explicit clear removes the in-memory window. A lifetime discard counter includes
capacity eviction and clearing, so a later export does not imply a complete
history. Releasing/replacing the logger starts a new lifetime/counter. Clearing
or eviction does not remove exported copies or guarantee physical memory wiping.
Sharing one logger shares its whole retained window across runtimes; isolate
loggers by account/session as appropriate.

## Export format

AuditLogger.exportJSON and AgentRuntime.exportAuditJSON return version-one UTF-8
JSON bytes only. They do not write a file, choose a destination, upload or share.
Default export omits argument signatures and truncation flags. Including retained
argument text requires an explicit includeArguments option; an export cannot
recover characters already removed by retention. In-memory signatures still
contain raw sensitive values. Neither their stable rendering nor clipping is
hashing, anonymization or redaction. Even metadata can identify an activity.

Version-one envelope fields:

- schemaVersion: integer 1.
- exportedAt: numeric milliseconds since Unix epoch (possibly fractional).
- includesArguments: Boolean describing field inclusion.
- retention: maximumEntries and maximumSignatureCharacters.
- discardedEntryCount: lifetime records evicted/cleared before this snapshot.
- entries: recording-order array of id (UUID string), timestamp (numeric epoch
  milliseconds), toolName, permission, wasEmpty, and optionally
  argumentsSignature/argumentsWereTruncated.

Permission labels are stable strings: none, readOnly, userConfirmation, sensitive,
destructive. Do not export enum ordinals as the wire contract. Object keys are
sorted for reproducibility, while array order is retained. Future incompatible
wire changes require a new schemaVersion; runtime structs are not the wire schema.
No SDK import/restore/merge API or cryptographic signature is provided. Non-finite
dates or encoding failures are typed memoryFailure errors and leave entries intact.

## What the trail proves

The executor records confirmed successful returns for tiers above readOnly,
including ToolResult.isEmpty. It does not record full tool results, denials,
validation failures or failed/timed-out calls. A timeout can leave an underlying
operation running, so absence of a record does not prove absence of side effects.
Host code can also append entries directly. This is neither a tamper-evident
ledger nor an exhaustive attempt/history log. The permission gate remains the
prevention boundary, independent of recording, clearing or export policy.

These are host-driven audit storage/read operations, not a new planner/run state.
Existing execution events remain unchanged. Collection remains controlled by
SecurityPolicy.auditSensitiveExecutions; disabling collection does not clear an
already populated shared logger and cannot bypass approval.

## Evidence

Before this change AuditLogger stored an unbounded array and raw argument
signatures. Existing tests explicitly retained a contact query containing a
person's name. PRD FR-022 requires a sensitive-execution trail but specifies no
durable store, retention duration or export format. Keeping automatic I/O absent
preserves the SDK's explicit network/storage ownership and avoids treating a
product default as an enterprise compliance policy.

New tests verify recording-order eviction, Unicode-safe signature caps, copied
snapshots, metadata-only/default versus opt-in export, numeric date units, string
permission labels, clear/discard accounting, concurrency, typed encoding failures
and runtime export without tool-result disclosure. Existing executor tests retain
approval/denial and read-only exclusion coverage. No real audit data is exported
or written during this implementation; test records are synthetic.
