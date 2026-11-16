# ``LocalAgentKitRuntime``

The agent loop, planning, permissions, conversation state, and context management.

## Overview

The runtime depends on Core. Concrete model and device frameworks stay in adapters.
A run plans, requests a decision, validates tool arguments, asks for any required
permission, executes, and observes the result before continuing. Context is fitted
before every model call; a provider can still report overflow during generation.

## Topics

### Run an agent

- <doc:BuildYourFirstAgent>
- <doc:MultimodalInputs>
- ``AgentRuntime``
- ``StaticToolSource``
- ``ConversationMemory``
- <doc:PersistentConversations>
- <doc:TaskWorkingMemory>
- <doc:BudgetedMemoryRetrieval>
- ``EventBus``

### Background document ingestion

- ``IngestionJob``
- ``DocumentIngestionSource``
- <doc:BackgroundIngestion>

### Plan and execute

- ``AgentPlanner``
- ``StateMachinePlanner``
- ``ModelDrivenPlanner``
- ``Workflow``
- ``ToolExecutor``
- ``PermissionGate``

### Untrusted documents

- <doc:AdversarialDocuments>

### Audit snapshots

- ``AuditLogger``
- ``AuditEntry``
- ``AuditRetentionPolicy``
- <doc:AuditRetentionAndExport>

### Experimental planning

- <doc:ExperimentalModelPlanning>

### Budget and bound work

- ``ContextBudgeter``
- ``ContextBudgetConfiguration``
- ``ContextInputs``
- ``LoopDetector``
