# Phase 0 spike

Task **P0-01**: a bare app that talks to the on-device model directly. There are **no LocalAgentKit imports, no protocols, no abstractions**, on purpose. It's disposable: when Phase 0 reports, the code can be deleted. The *findings* live in [`docs/phase-0-findings.md`](../docs/phase-0-findings.md), and the eval *suites* live in [`EvalSuites/`](../EvalSuites/) (P0-18). Neither belongs here.

It's a separate Xcode project, not part of the Swift package, so it can't affect the package's build, coverage, lint, or layering gates.

## What it runs

`SessionChecks.swift` holds the **P0-02** checks: model availability, cold vs. prewarmed latency, multi-turn session reuse, restoring a transcript through `Codable`, concurrent requests, cancellation (by task cancel and by breaking the loop), the abandoned-stream timeline, text streaming, `@Generable` structured output (plain and streamed), and a runtime-built `DynamicGenerationSchema`.

Each result is one line, `check=<id> result=<pass|fail|observed> key=value …`, printed to stdout with a `P0|` prefix and shown in the app window.

## Build and run

The project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen). The generated `.xcodeproj` is committed, so opening it only needs Xcode. XcodeGen is needed only to change the project:

```bash
xcodegen generate
```

**macOS** (this Mac, macOS 26.4+):

```bash
xcodebuild -project Phase0Spike.xcodeproj -scheme Phase0Spike -destination 'platform=macOS' -derivedDataPath .build CODE_SIGN_IDENTITY=- build
```

```bash
.build/Build/Products/Debug/Phase0Spike.app/Contents/MacOS/Phase0Spike --run-and-exit
```

**iPhone** (iOS 27, Apple Intelligence on, phone unlocked). No team ID is committed; pass yours:

```bash
xcodebuild -project Phase0Spike.xcodeproj -scheme Phase0Spike -destination 'id=<device-udid>' -derivedDataPath .build-ios DEVELOPMENT_TEAM=<team-id> -allowProvisioningUpdates build
```

```bash
xcrun devicectl device install app --device <device-udid> .build-ios/Build/Products/Debug-iphoneos/Phase0Spike.app
```

```bash
xcrun devicectl device process launch --device <device-udid> --console --terminate-existing dev.localagentkit.spike.phase0 --run-and-exit
```

With a free Personal Team, the first launch is refused until you trust the developer on the phone: **Settings → General → VPN & Device Management**.

## Launch arguments

| Argument | Effect |
|---|---|
| `--run-and-exit` | Exit when the checks finish, so the console log is the artifact |
| `--only a,b` / `--skip a,b` | Run or omit checks by id |
| `--full-errors` | Don't truncate error descriptions |
| `--same-session` | `cancellation-break`: send the next request on the abandoned session. **Reproduces the reuse crash** |
| `--idle-ms N` | `cancellation-break`: wait N ms before the next request |
| `--break-after-ms N` | `cancellation-break`: abandon the stream N ms in (default 800) |
| `--schema-variant v` | `dynamic-schema`: `unanchored` (default), `anchored` (reproduces the rejection), `no-pattern`, `required-anchored` |
