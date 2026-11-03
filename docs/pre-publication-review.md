# Pre-publication review — 2026-11-03

Repository: `shyamal/LocalAgentKit`. Reviewed remote main `bb4b8fb` and fetched
GitHub branch/tag/PR-head history. The initial review kept the repository private. After the review, the owner
explicitly authorized publication; visibility was changed to public on 2026-11-03.

## Result

No credential matches were found by Gitleaks 8.30.1. The owner subsequently authorized publication with the reviewed author identity
in history. Private vulnerability reporting was enabled and verified after the
visibility change. This is a
publication/privacy review, not a complete library security audit.

## Findings

### License decision (resolved after the review)

At the reviewed remote snapshot, no LICENSE existed and M0-10 was deferred.
The user subsequently selected Apache-2.0 on 2026-11-03. The working tree now
includes the unchanged official license, project NOTICE and updated README and
contributor guidance. The change must land on GitHub before its license detection
can be checked.

### Private vulnerability reporting (resolved after publication)

The initial private-repository API returned 404. After the authorized visibility
change, GitHub private vulnerability reporting was enabled and its API returned
`enabled: true`. SECURITY.md now links the working private reporting channel.

### Git author identity will be visible

Commit metadata contains the maintainer's real name and personal Gmail address.
This is author identity, not a leaked credential. Decide whether that existing
identity is acceptable before publication. Setting a noreply address for future
commits does not remove older metadata. No history rewrite was performed or
proposed as automatically necessary.

### Signing identifier is local, not in the fetched GitHub history

The initial all-local-refs scan found an Apple development team identifier in a
stash and uncommitted Xcode signing configuration. Rechecking reachability from
GitHub branches and PR heads found zero signing-team matches there. Preserve
those local signing edits and exclude them from publication commits. No certificate,
provisioning profile, private key or device UDID was found in the scanned history.

### Evaluation logs contain fixture content and system metadata

The checked-in evaluation runner serves fixture results. Reviewed email-like
strings use example/test domains; absolute user-path matches were generic
`/Users/shared` adversarial test fixtures. Logs also disclose OS versions, device
model identifiers, run dates, timings and model-generated business/health/legal
example text. The device acceptance report contains a save timestamp and body
length, but not the saved note's body or identifier. Actual device note snapshots
used in this session remain under /tmp and are not tracked. No personal calendar
or note contents were identified in the reviewed material; the owner should still
approve publication of the measurement reports and author identity.

### Public-contribution automation checks

Repository workflow-token defaults are read-only; Actions cannot approve PRs.
CI and documentation PR builds use hosted runners and do not persist checkout
credentials. The model-evaluation workflow uses opt-in self-hosted jobs without
a PR trigger and checks out the release tag/default branch. Runner inventory is
empty and repository Actions secrets list is empty. Keep external PRs off future
persistent model runners and review contributor-workflow approval settings after
the repository becomes public (the approval API currently rejects private repos).
Action references use version tags rather than immutable SHAs; pinning is a
hardening follow-up, not evidence of an existing compromise.

## Evidence and scope

- Refreshed GitHub remote branches and all 32 available pull-request heads.
- 103 GitHub-reachable commits and 631 historical blobs, about 8.15 MB.
- Gitleaks git patch scan: no findings (72 commits with scannable changes;
  merge/empty commits account for the different total).
- Independent Gitleaks directory scan of all reachable blob contents: no findings.
- Also scanned all local reachable refs including stash: 105 commits/636 blobs,
  about 8.26 MB, no credential findings. Local-only metadata is distinguished above.
- Exported and scanned 32 issue/PR bodies and one issue comment; no review or commit
  comments were returned. No credential matches in the exported text.
- Targeted path/content checks for keys, credential files, signing identifiers,
  device identifiers, author emails and personal filesystem paths.
- Read current workflows, repository permission/secret/runner inventories,
  README.md, CONTRIBUTING.md, SECURITY.md and evaluation provenance.

Gitleaks reports were redacted and stored locally under /tmp. Matching no scanner
rules is not a guarantee that no secret or private data exists. Workflow logs,
artifact contents, release assets, GitHub caches/unreachable objects, external
systems and every dependency's upstream history were not exhaustively audited.
Swift tests were not repeated because this review changed no executable code.

## Before changing visibility

1. Land the selected Apache-2.0 license and resolve the security reporting channel.
2. Approve the existing author identity and measurement-data disclosure, or specify
   which metadata needs removing. Any history cleanup needs its own reviewed plan.
3. Recheck new commits since this snapshot, then change visibility only after the
   owner authorizes the reviewed result.
4. Configure public-contributor workflow approval and verify security reporting;
   enable Pages and run the prepared deployment/HTTP checks.
