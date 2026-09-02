# Project skills

Workflows specific to LocalAgentKit. Claude Code loads these automatically when a task matches the description; invoke one directly with `/<name>`.

| Skill | Use when |
|---|---|
| **add-agent-tool** | Adding an `AgentTool` — permission tier, schema, parallel-safety, the required permission-gate test |
| **add-provider** | Adding a model / memory / embedding / vector / vision / speech provider without breaking the layering rule |
| **pr-check** | Before any commit or PR — build, tests, format, coverage, layering check, review checklist |
| **update-tasks** | After work lands, or when asking "where are we" — task hygiene, 🔒 gates, resolved open questions |

Each skill encodes decisions already made in `PLANNING.md` and the PRD, so they don't get re-litigated per task. When a skill and the PRD disagree, the PRD wins — and the skill needs fixing.

## Not yet written

- **run-eval** — driving the FR-029 reliability harness and comparing runs. Deferred until `LocalAgentKitEval` exists (tasks M1-EV-01…08); a skill for unbuilt code would just be a guess about its CLI.
