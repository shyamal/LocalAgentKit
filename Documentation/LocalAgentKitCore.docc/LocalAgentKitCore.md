# ``LocalAgentKitCore``

Framework-independent contracts and values shared by the agent runtime and adapters.

## Overview

Core has no dependency on the concrete Apple frameworks. Implement its protocols
to swap a model, embedding backend, or memory store without changing the loop.
Every protocol has a test counterpart in LocalAgentKitTesting.

## Topics

### Diagnostic intervals

- ``RuntimeInstrumentation``
- ``RuntimeTraceEvent``
- ``RuntimeOperation``
- ``NoOpRuntimeInstrumentation``

### Architecture

- <doc:ExecutionAndPermissions>
- <doc:AppIntentsStatus>


### Model and configuration

- ``LocalModelProvider``
- ``ModelRequest``
- ``ModelResponse``
- ``AgentConfiguration``
- ``ExecutionLimits``

### Tool contracts

- ``AgentTool``
- ``ToolSchema``
- ``ToolPermission``
- ``ToolCall``
- ``ToolObservation``

### Retrieval and memory

- ``EmbeddingProvider``
- ``VectorStore``
- ``MemoryStore``

### Observable outcomes

- ``AgentEvent``
- ``AgentError``
