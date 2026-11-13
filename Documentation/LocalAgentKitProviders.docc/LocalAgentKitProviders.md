# ``LocalAgentKitProviders``

Concrete on-device model, local memory, embedding, and vector-store implementations.

## Overview

The Foundation Models adapter translates platform output and errors into Core
values. Model availability and downloaded language assets are device state, not
something a successful compile proves. Guardrail refusals are terminal outcomes.

## Topics

### Recorded speech

- ``AppleSpeechRecognizer``
- <doc:RecordedSpeech>
- ``AppleSpeechSynthesizer``
- <doc:LocalSpeechSynthesis>

### Local image analysis

- ``AppleVisionProvider``
- <doc:LocalImageAnalysis>
- <doc:LocalDocumentAnalysis>

### App-owned OS 27 models

- ``LanguageModelProvider``
- <doc:BringYourOwnLanguageModel>

### Incremental answers

- <doc:ResponseStreaming>

### Device thermal pressure

- ``ProcessInfoThermalStateSource``
- <doc:ThermalManagement>

### Runtime diagnostics

- ``OSLogRuntimeInstrumentation``
- <doc:RuntimeDiagnostics>

### Generation

- ``FoundationModelProvider``

### Retrieval storage

- ``NLEmbeddingProvider``
- ``InMemoryVectorStore``
- ``FileVectorStore``
- <doc:PersistentVectors>

### Local text memory

- ``SwiftDataMemoryStore``
- ``SwiftDataConversationStore``
- <doc:LocalMemory>
- <doc:MemoryMigrations>
