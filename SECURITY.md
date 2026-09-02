# Security Policy

## Reporting a vulnerability

**No dedicated security contact exists yet.** This repository has no public host or maintainer contact channel configured (task M0-10, license, is still pending, and typically lands alongside a repo going public). Until a channel is set up here:

- If this repository is hosted on GitHub by the time you're reading this, use **GitHub's private security advisory** feature ("Report a vulnerability" under the Security tab) rather than a public issue.
- Do not open a public issue for a suspected vulnerability.

This section needs a real disclosure channel (email or advisory link) filled in before the project accepts outside contributions — see `CONTRIBUTING.md`.

## Scope

LocalAgentKit is a framework, not a hosted service — there is no server-side deployment to compromise. Relevant reports are things like:

- a way for a tool call to execute above its declared permission tier without user confirmation
- a way for `networkPolicy: .never` to still allow a network request
- a memory or RAG store that persists or exposes data it shouldn't
- a way for adversarial content in an ingested document to bypass the permission gate

## Known, designed-for risks

The PRD's threat model (`LocalAgentKit-PRD-v0.2.md` §19) already names several risks the architecture is built to mitigate rather than eliminate — reports that restate these without a concrete bypass aren't new findings:

- **Prompt injection** — text in an ingested document attempting to manipulate the agent into an unintended tool call. Structured tool calls alone do **not** prevent this; the permission system is the actual backstop (any tool above `.readOnly` requires explicit user confirmation, regardless of why the model requested it).
- **Tool abuse** — mitigated by the permission tiers, not by inspecting the model's intent.
- **Infinite loops** — mitigated by loop detection (FR-028), not prevented outright.
- **Audit logging** — after-the-fact visibility, not a preventive control.

A genuine finding in this area looks like: "the permission gate can be bypassed under condition X," not "the model can be prompted to request a sensitive tool call" (it can — that's why the gate exists).

## Supported versions

No version has been released yet. This section will be updated once the project reaches its first tagged release.
