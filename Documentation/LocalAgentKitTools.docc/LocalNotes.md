# Create and search app-local notes

Use the Notes capability as two separate tools: `CreateNoteTool` (`create_note`,
`.userConfirmation`) and `SearchNotesTool` (`search_notes`, `.readOnly`). A single
action-switching tool would give a read operation write authority or require a
prompt for every search. `NotesTool.tools(store:)` returns both registrations over
one store.

```swift
let directory = appSupportURL.appendingPathComponent("Notes", isDirectory: true)
let store = NoteStore(directory: directory)
let runtime = try AgentRuntime(
  configuration: AgentConfiguration(model: model),
  tools: StaticToolSource(NotesTool.tools(store: store)))
```

The store holds this app's notes. Search does not read Apple Notes, arbitrary
files or indexed RAG documents, and it takes no destination/path parameter. The
runtime enforces validation → permission → execute → observe. Direct tool calls
are host APIs and do not prompt; use the runtime to enforce confirmation.

## Storage and compatibility

The backend retains the demo's original `notes.json` array of `Note` values:
identity, title, body and creation date. Existing files open without conversion;
no SwiftData migration or new runtime dependency is introduced. The app supplies
a local file URL (or directory) and shares one `NoteStore` actor per file. Cached
instances and independent process writers are not coordinated.

A missing file begins empty and the directory is created on the first save.
Unreadable/corrupt files throw `AgentError.memoryFailure`, are not treated as
empty and are not overwritten on a later save. Failed loads can be retried after
the host repairs the file. A save atomically writes a candidate JSON array before
updating the cache, so a failed write does not leave an unsaved note in memory.
Non-file URLs are rejected before any read, preventing accidental network access.
This remains a small JSON store; it is not a database or full-text index.

## Search results

Search matches a word/phrase as a localized case/diacritic-insensitive substring
in title or body. Results are newest first, with UUID-string ascending for equal
dates. `NoteStore.search` allows empty text to browse; the model-facing tool
requires a non-blank query. Tool result limits are clamped to 1...10 (default 5).
Each result contains an ID, a title preview of at most 120 characters plus an
ellipsis and the first 400 body characters plus an ellipsis. Both the readable
text and structured result use these same bounded previews. Matches beyond the
body prefix may not appear in the preview; full content remains in `NoteStore`.
The tool reports “No saved notes found.” with `isEmpty` when there are no matches.
Storage failures propagate rather than masquerading as an empty search.

Create preserves the submitted full title/body, rejecting blank fields. Search
never modifies notes and never requests approval. Text found inside a note is
untrusted input: even if it induces a valid `create_note` call, a person must still
approve that new write. An approved save's receipt is not authority for later writes.

## Cancellation and evaluation

Tools/store check task cancellation at work boundaries and search also checks after
awaiting the store. Synchronous filesystem reads and an atomic write already in
progress cannot be interrupted. Cancellation does not promise rollback of a write
that has already committed. The shared actor serializes concurrent saves/searches.

The supplemental `notes-local` harness suite covers note creation/search selection,
arguments and confirmation expectations. It runs through the single-call probe
without executing tools; it is separate from the immutable Phase 0 baseline.
Runtime tests exercise actual local persistence, approved/denied writes and
adversarial saved-note content. No new real-model accuracy measurement is claimed.
