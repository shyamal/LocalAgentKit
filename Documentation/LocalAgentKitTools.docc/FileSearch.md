# Search filenames inside app-approved folders

`FilesTool` registers `search_files` with the `.readOnly` tier. The host supplies
the directories to search; model arguments contain only a filename query and an
optional extension category. There is no home/device-wide default, model-supplied
root/path, sending, deletion, file opening or document-content read capability.

```swift
let files = try FilesTool(roots: [appDocumentsURL], limit: 5, maxEntries: 1000)
let runtime = try AgentRuntime(
  configuration: AgentConfiguration(model: model),
  tools: StaticToolSource([files]))
let response = try await runtime.run("Find Budget PDFs in the approved folders")
```

## Scope and access ownership

Supply non-empty local directory URLs that the app is already authorized to read.
The tool does not present a document picker, request sandbox permission, resolve
security-scoped bookmarks or extend access on its own. If a picker/bookmark grants
security-scoped access, the host starts it before the call and keeps it active
until the call finishes. Use local roots, not network-mounted or provider-backed
locations when the app requires local-only operation.

Roots are canonicalized when the tool is constructed, then checked again during
each search. Child symbolic links and Finder aliases are excluded; resolved child
paths must remain beneath the canonical root. Hidden items, package directories
and their descendants, and ubiquitous/iCloud items are skipped. Ubiquitous roots
are rejected. The tool never requests a content download.

These checks prevent ordinary link traversal and reject an anchored root replaced
by a link before the scan. They are not a kernel sandbox or atomic protection
against a concurrent filesystem attacker replacing paths between checks. The OS
sandbox and host's directory ownership remain the access boundary. Results are
metadata observations, not durable authority to open a returned path later.

## Matching and bounded results

Query text is a localized case/diacritic-insensitive filename substring. It does
not inspect contents, extract document text or perform semantic metadata search.
`file_type` is one of `any`, `pdf`, `image`, `document`, `spreadsheet`, classified
by a documented extension list in the implementation, not verified file contents.
A misleading `.pdf` extension can match the PDF filter without being a real PDF.
Package-based documents and excluded cloud placeholders are not searched.

Result limits are clamped to 1...10 (default 5), with 1...10,000 enumerated entries
across all roots (default 1000). Directories count toward the scan budget. Traversal
uses filesystem order, not relevance ranking or a globally sorted listing.
Overlapping roots do not duplicate a discovered file. Paths longer than 1000
characters or filenames longer than 255 characters are omitted rather than
returning unusable clipped locations.

Readable results contain names and root-relative paths. Structured results are an
object with `matches` and `is_partial`; each file has `root_index` (one-based into the
host-supplied roots), `name`, `relative_path`, `size_bytes` and `modified_at`.
Metadata can be null when the filesystem does not supply it. Absolute root paths
and file contents are not returned in successful results.

Reaching either limit stops the scan conservatively with `is_partial: true`, even
if the final match might have been the last file. The leading result text warns
that only a scanned portion is covered. The structured flag sorts before matches
in workflow facts so it survives the planner's bounded rendering. Zero hits may still be partial; `isEmpty`
means no hits in that portion, not proof that no matching files exist anywhere.
Unavailable roots and enumeration/metadata failures throw typed `toolFailed`
errors rather than pretending there were no matches. Names/paths and diagnostics
can contain personal data and should be handled accordingly.

## Cancellation and verification

Cancellation is checked before work, between entries and before returning. A
synchronous filesystem call already in progress is not interruptible; runtime
deadlines can abandon the operation. Search performs no file mutations.

Tests scan only temporary fixture directories. They verify filename/category
matching, root/symlink exclusions, partial scans, no content in results, invalid
arguments, cancellation and an adversarial filename being unable to approve a
sensitive contact read. The supplemental `files-local` harness probe records
selection/arguments without scanning actual directories or changing Phase 0
baselines. No real-model accuracy or live sandbox-picker validation is claimed.
The demo does not automatically gain access to new filesystem locations.
