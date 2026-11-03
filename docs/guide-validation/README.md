# Maintainer guide smoke checks

These runs check integration, not independent developer metrics or statistical
model reliability. The newcomer sessions in `../developer-validation.md` remain
outstanding.

## Custom tool, 2026-11-03

Command: `swift run --package-path Examples/CustomTool CustomTool --device`

Host: Apple silicon Mac, macOS 26.6.2, Xcode 27.2 (27B52), Swift 6.4.2.
Source: based on main `2b29827`, with this change adding the custom-tool
`--device` mode. No SDK runtime or provider source changed.

The retained log shows two actual `convert_temperature` executions, each returning
68.0 degrees Fahrenheit. The model ended with the correct numeric answer but an
incorrect formula (`9/5 * (Celsius - 32)`). This is an observed explanation error,
not a claim of correct model reasoning or a tool-selection success rate. The tool
uses `celsius * 9 / 5 + 32` and its four deterministic tests pass.

The default scripted run returned one tool call and 68.0 degrees Fahrenheit.
Application source totals 76 physical lines (30 for the tool, 46 for the executable),
including both model modes and event handling; manifest and tests are excluded.
