# ``LocalAgentKitRuntime``

The agent loop, planning, permissions, conversation state, and context management.

## Overview

The runtime depends on Core. Concrete model and device frameworks stay in adapters.
A run plans, requests a decision, validates tool arguments, asks for any required
permission, executes, and observes the result before continuing. Context is fitted
before every model call; a provider can still report overflow during generation.

## Topics

### Run an agent

- ``AgentRuntime``
- ``StaticToolSource``
- ``ConversationMemory``
- ``EventBus``

### Plan and execute

- ``AgentPlanner``
- ``StateMachinePlanner``
- ``Workflow``
- ``ToolExecutor``
- ``PermissionGate``

### Budget and bound work

- ``ContextBudgeter``
- ``ContextBudgetConfiguration``
- ``ContextInputs``
- ``LoopDetector``
