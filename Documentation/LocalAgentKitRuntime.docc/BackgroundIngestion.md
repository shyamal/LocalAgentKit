# Own a cancellable ingestion job

Use ``IngestionJob`` for explicit utility-priority ingestion (M3-06). It evaluates
lazy sources, chunks each document, embeds sequentially, and inserts bounded
batches through the existing Core `RetrievalPipeline` providers. The job task is
detached from the caller's actor; a synchronous extractor in a source can therefore
run without inheriting the UI actor. Custom closures/providers still choose their
own isolation and cancellation behavior.

```swift
import LocalAgentKitCore
import LocalAgentKitRuntime
import LocalAgentKitTools

let sources = authorizedURLs.map { url in
  DocumentIngestionSource {
    try DocumentExtractor.load(contentsOf: url, preserveMarkdownStructure: true)
  }
}
let job = try IngestionJob.start(
  sources: sources, pipeline: pipeline, batchSize: 32)

let observer = Task {
  for await event in job.events {
    if case .ingestionProgress(let progress) = event {
      // Render cumulative counts and progress.state on your UI actor.
    }
  }
}
let result = try await job.value()
await observer.value
```

For already-decoded text use `DocumentIngestionSource(document:)`. Source IDs are
host-controlled progress identities and need not equal document/passage IDs. Hosts
own file authorization/security-scoped lifetimes through completion, protected
storage placement and provider-backed availability. A URL alone does not prove
cloud content is resident. Loading untrusted documents never authorizes tool calls;
normal permission gates continue to apply.

## Batches and partial success

The positive batch size limits embedded vectors waiting for insertion. Each source
is loaded/chunked sequentially; the final partial batch is flushed before the next
source, and empty documents count as completed without insertion. No parallel
model calls or provider batch API are assumed. Whole document text/chunks remain
in memory; this is not streaming extraction or a global memory bound.

Committed batches are retained on cancellation or later failure; there is no
job-wide transaction, rollback or automatic retry. A successful `VectorStore.insert`
call increments counts even if cancellation arrived during that call. An arbitrary
store that throws after partially writing cannot communicate that partial commit
through the existing protocol; progress counts only successful calls. Hosts own
cleanup/reindexing after partial jobs. Fresh chunk IDs mean restarting can duplicate
content unless the host/store implements its own replacement policy.

## Progress and cancellation

The job emits `AgentEvent.ingestionProgress` snapshots on its own stream, separate
from conversation events. Every snapshot includes a job ID, source count, completed
source count, current source ID, committed passages/batches and lifecycle state:
`running`, `completed`, `cancelled` or `failed(AgentError)`. Terminal snapshots retain
partial counts. Counts describe provider acknowledgements, not power-loss durability.

The stream is single-consumer and buffers only the newest snapshot. Slow consumers
may miss intermediate states; an unconsumed terminal snapshot is retained when the
stream finishes. It is not an audit log or multicast subscription. Stream consumption
is optional and does not backpressure work. Dropping/cancelling the observer does not
cancel ingestion: keep the handle and call `job.cancel()`. Cancelling a `value()`
waiter cancels the shared task for all waiters; an already completed task can still
return success. Dropping the handle alone does not cancel the detached task.

Checks occur before work and around source/embedding awaits, before insertion,
after recording successful commits and between sources. Pending uncommitted vectors
are discarded on cancellation. Native extraction, synchronous chunking and
uncooperative providers cannot be forcibly interrupted. Unknown source/provider
errors map to a generic typed retrieval failure; existing AgentErrors are preserved,
and CancellationError maps to `.cancelled`. Failures are terminal, without retries.

## Policy and scope

`networkPolicy` defaults to `.never`, rejecting network-declaring sources or
embedding providers before starting work. A custom source must declare network use
honestly, including cloud-file downloads. VectorStore has no network declaration;
hosts must provide a store consistent with policy. `.allowed` permits declared
network components but does not initiate a download or bypass permissions.
Invalid chunk/batch configuration fails before work. A cancelled caller cannot
start a new job. No new Core protocol or runtime dependency is needed.

Utility priority is not an OS background-task entitlement, durable queue, automatic
app-restart recovery or thermal/battery guarantee. The OS may suspend/terminate the
host. Hosts own lifecycle and admission policy; realistic resource measurements
remain M3-08/M6-05. The old direct `RetrievalPipeline.ingest` API stays unchanged as
a single-insert operation; callers explicitly choose the job API for this behavior.
