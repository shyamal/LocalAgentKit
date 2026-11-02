# ``LocalAgentKitSwiftUI``

Observable agent state and an optional permission confirmation interface for SwiftUI apps.

## Overview

Use the view model to render turns and tool activity and to answer pending human
input. Apps can instead consume runtime events and implement their own permission
gate; using the runtime does not require SwiftUI. The Foundation Models provider
streams tool-free final answers through the runtime. Fragments update a provisional
assistant turn; completion replaces it, while failures discard it. Other providers
can use the non-streaming fallback.

## Topics

### Present an agent

- ``AgentViewModel``
- ``PermissionConfirmationSheet``
