# ``LocalAgentKitSwiftUI``

Observable agent state and an optional permission confirmation interface for SwiftUI apps.

## Overview

Use the view model to render turns and tool activity and to answer pending human
input. Apps can instead consume runtime events and implement their own permission
gate; using the runtime does not require SwiftUI. Token rendering depends on the
provider emitting streaming events, which is not yet implemented by the current
Foundation Models provider.

## Topics

### Present an agent

- ``AgentViewModel``
- ``PermissionConfirmationSheet``
