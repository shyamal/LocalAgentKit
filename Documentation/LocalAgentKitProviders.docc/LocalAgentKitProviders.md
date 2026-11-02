# ``LocalAgentKitProviders``

Concrete on-device model, embedding, and vector-store implementations.

## Overview

The Foundation Models adapter translates platform output and errors into Core
values. Model availability and downloaded language assets are device state, not
something a successful compile proves. Guardrail refusals are terminal outcomes.

## Topics

### Runtime diagnostics

- ``OSLogRuntimeInstrumentation``
- <doc:RuntimeDiagnostics>

### Generation

- ``FoundationModelProvider``

### Retrieval storage

- ``NLEmbeddingProvider``
- ``InMemoryVectorStore``
