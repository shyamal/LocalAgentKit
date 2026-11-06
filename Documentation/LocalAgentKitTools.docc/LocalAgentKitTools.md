# ``LocalAgentKitTools``

Built-in tool implementations for arithmetic, calendar access, reminders, contacts, retrieval, and local note creation/search.

## Overview

A tool's permission tier is enforced after argument validation and before execution.
Device authorization, such as EventKit access, remains necessary in addition to
agent confirmation. Returned calendar content and ingested documents are untrusted
input; they cannot authorize writes.

## Topics

### Extend the agent

- <doc:WriteACustomTool>

### Built-in actions

- ``CalculatorTool``
- ``CalendarTool``
- ``ContactsTool``
- ``FilesTool``
- <doc:FileSearch>
- <doc:ContactSearch>
- ``ReminderTool``
- ``CreateNoteTool``
- ``SearchNotesTool``
- ``NotesTool``
- ``NoteStore``
- ``Note``
- <doc:LocalNotes>
- ``DocumentSearchTool``

Search tools may opt in to Core `RetrievalConfiguration` for bounded candidates,
score filtering and text/ID deduplication. Their existing limit-only behavior and
read-only permissions remain unchanged; no score cutoff is calibrated.

### Load documents

- ``DocumentExtractor``
- <doc:DocumentExtraction>
- ``PDFDocumentLoader``
- <doc:PDFIngestion>
