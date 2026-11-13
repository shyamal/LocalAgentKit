# ``LocalAgentKitTesting``

Mocks and scripted providers for deterministic tests without hardware or model downloads.

## Overview

Use a scripted provider when the number and order of model calls matter. Use a
closure-backed mock when a test needs to inspect the request. Synthetic outputs
verify wiring and behavior under a script; they do not measure model reliability.

## Topics

### Speech doubles

- ``MockSpeechRecognizer``

### Image analysis doubles

- ``MockVisionProvider``

### Runtime trace tests

- ``MockRuntimeInstrumentation``
- ``MockThermalStateSource``

### Model doubles

- ``MockModelProvider``
- ``ScriptedModelProvider``

### Tool doubles

- ``MockTool``
