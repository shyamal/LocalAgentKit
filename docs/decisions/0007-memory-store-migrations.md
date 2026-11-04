# 0007 — Explicit local-store migration histories

Date: 2026-11-04

Status: accepted (M2-08; FR-011/FR-012)

## Decision

Keep each released SwiftData schema immutable. Text memories and conversation
checkpoints retain independent files, schemas and migration plans. Production
currently ships only MemorySchemaV1 and ConversationSchemaV1 (both 1.0.0). Each
plan contains that version and zero stages. Do not create an unused production V2
or increment only the version number without a real storage-shape change.

For a storage change, add a new VersionedSchema, append it to the appropriate plan
and add an adjacent upgrade stage. Preserve every supported predecessor definition
and stage, and point the provider at the latest schema. Use lightweight stages for
compatible additive changes; use custom stages for explicit transformations that
cannot be inferred. Custom transformations must be deterministic, local and
fallible; they must not invoke a model, network service or permission UI. Test the
full supported upgrade chain against old files before shipping. Removing support
for a predecessor is an explicit compatibility change, never a silent reset.

Semantic/episodic metadata formats and conversation JSON payload versions are
separate compatibility boundaries. A SwiftData schema upgrade does not imply that
an unknown payload is safe. Existing typed decoding failures remain in force;
future payload transformations need their own tests and policy.

## Guard before opening an existing file

Testing found that supplying an explicit V1-only SchemaMigrationPlan did **not**
stop SwiftData from opening a test V2 store with the old V1 schema. Migration plans
alone are insufficient to prohibit a downgrade.

StoreCompatibility reads existing SQLite store metadata using public Core Data
APIs with the read-only option before constructing the writable SwiftData
container. The file must identify one supported schema version and the same set
of entity names as that version of the selected store family. Unknown/missing
version metadata and wrong families fail with AgentError.memoryFailure. The guard
checks version identifiers and entity names, not an authenticity signature or a
full property/hash equivalence proof. Released schema immutability and the
framework's migration checks still matter. Unknown or damaged store metadata
fails initialization; the provider never deletes/recreates the file as recovery.

Core Data is an Apple framework used only in Providers for metadata inspection;
no third-party runtime dependency or framework type crosses into Core/Runtime.
The layering check now also rejects CoreData imports in those two targets.

## Ownership and recovery

One app-owned store instance per file serializes ordinary operations. Schema
upgrades require exclusive ownership: close other instances/process writers and
quiesce access before changing the app's SDK/storage version. The metadata check
and subsequent open are not a cross-process lock or an atomic compare-and-open.
Do not run different SDK versions against the same live file.

The host owns backup/export and recovery UX. Obtain a consistent backup of the
whole store, including pending WAL state, before an irreversible upgrade; copying
only a live SQLite main file is not a backup strategy. This SDK does not introduce
an automatic backup/export format or promise downgrade support. On an unsupported
version or migration failure, preserve the file and surface the typed failure so
the host can offer an update or an explicitly authorized restore/reset. Never
catch an open error and replace user data with an empty store automatically.

## Evidence and limitations

The installed Xcode 27.2 SwiftData interface verifies SchemaMigrationPlan,
MigrationStage.lightweight/custom and ModelContainer's migrationPlan initializer.
Core Data headers verify metadataForPersistentStore, the read-only option and
model version/hash metadata keys. Implementation/tests ran on macOS 26.6.2.

Six tests exercise real temporary SQLite files:

- Pre-plan V1 text records (ordinary, semantic and episodic) open through the new
  plan with identity, dates, Unicode content and metadata unchanged.
- Pre-plan V1 conversation payload bytes survive opening and decode unchanged.
- Test-only additive V2 schemas upgrade both stores. Existing values and payload
  bytes survive; optional fields begin nil and can hold new data.
- Production V1 providers reject those newer files. Reopening with the V2 fixture
  verifies both original and V2-only data remain present.
- Opening one store family with the other provider fails without deleting rows.
- A deliberately throwing custom text-store migration leaves the V1 file readable.

Test-only V2 schemas are not shipping schemas. These checks establish the current
strategy and baseline; they do not prove an arbitrary future migration is safe,
that every failure mode is atomic, or that Apple will preserve behavior across OS
updates. Each future migration must bring its own preservation/failure evidence.
