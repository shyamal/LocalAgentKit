# ``LocalAgentKitSwiftUI``

Observable agent state and an optional permission confirmation interface for SwiftUI apps.

## Overview

Use the view model to render turns and tool activity and to answer pending human
input. Apps can instead consume runtime events and implement their own permission
gate; using the runtime does not require SwiftUI. The Foundation Models provider
streams tool-free final answers through the runtime. Fragments update a provisional
assistant turn; completion replaces it, while failures discard it. Other providers
can use the non-streaming fallback.

## Restored conversations

Pass completed display turns through `initialTurns` after separately restoring the
runtime’s conversation memory. An optional `onRunCompleted` async throwing callback
runs after a successful `runtime.run` returns and records history. Use it to
checkpoint memory. Sending remains disabled until it finishes. Callback failures
appear in `lastFailure` without removing the answer or retrying tool actions.
The `.finishing` state describes host bookkeeping after the existing terminal
runtime event; it introduces no new engine behavior or event. Persistence is
disabled by default, and the host owns the callback’s storage and network policy.

## Topics

### Present an agent

- ``AgentViewModel``
- ``PermissionConfirmationSheet``
