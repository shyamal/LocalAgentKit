# ``LocalAgentKitTools``

Built-in tool implementations for arithmetic, calendar access, reminders, retrieval, and local note creation/search.

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
- ``ReminderTool``
- ``CreateNoteTool``
- ``SearchNotesTool``
- ``NotesTool``
- ``NoteStore``
- ``Note``
- <doc:LocalNotes>
- ``DocumentSearchTool``
