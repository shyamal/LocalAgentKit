# Open stores across SDK versions

Text memory and conversation checkpoints have separate immutable V1 schemas and
explicit migration plans. Only version 1.0.0 is shipped today; no artificial V2
schema or migration stage is added until a real storage change requires one.
Existing V1 files created before the plans were introduced open without rewriting
their logical records or conversation payload bytes.

## Compatibility checks

Before opening an existing file for writing, the provider reads its Core Data
store metadata with the read-only option. Its version identifier and entity names
must match a supported schema in the appropriate migration plan. A newer version,
unknown/missing version metadata, wrong store family or unreadable metadata fails
initialization with `AgentError.memoryFailure`. A conversation file must still be
separate from the text-memory file, even though both current schemas are 1.0.0.

The guard is necessary because a migration plan alone did not prevent SwiftData
from opening a test V2 file through the older V1 schema. It checks declared version
and entity names, not every property hash or file authenticity. The provider does
not erase, reset or silently replace an unsupported store. Existing payload
validation remains independent: unknown semantic/episodic metadata or conversation
JSON versions continue to throw typed failures.

## Upgrade ownership and recovery

Use exclusive access when upgrading: close other instances/process writers before
changing the app's SDK/storage version. The metadata read and writable open are
not a cross-process lock. Different SDK versions must not concurrently own the
same file.

The app owns consistent backups/exports and recovery UX. Include the complete
store state, including WAL data, in a backup; copying a live main SQLite file alone
is insufficient. Automatic backup, downgrade conversion and destructive reset are
not provided. Preserve an unsupported file and offer an app update or an explicitly
authorized restore instead of catching an error and starting with an empty store.

Future releases append schemas and adjacent lightweight/custom stages while
retaining supported predecessors. Each upgrade needs preservation and failure
tests. Current tests use temporary V2 fixtures to verify additive upgrades for
both families, retention of new fields after an older-provider rejection, and a
failed custom migration leaving the original V1 records readable. The fixtures
are not production schemas and do not guarantee arbitrary future migrations.
