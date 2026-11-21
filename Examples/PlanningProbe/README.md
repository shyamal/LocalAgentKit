# Planning probe (M5-03)

Developer-only iPhone host for the same evaluation sources used by LocalAgentKitEval.
It runs the fixed multi-step suite three times with each planner, then the twenty
single-tool goals five times. Deadlines are sixty seconds. It uses the real local
model, synthetic fixtures, real calculator arithmetic and synthetic confirmation;
no calendar, contacts, notes, microphone or user documents are accessed.

The host compiles `Sources/LocalAgentKitEval` directly and copies its Suites folder.
Its Bundle.module shim points to the app bundle. This keeps the internal evaluation
support target out of the SDK's public library products; fixture code is shared by
source reference, not copied. No ArgumentParser dependency enters the app.

```bash
xcodegen generate --spec Examples/PlanningProbe/project.yml
xcodebuild -project Examples/PlanningProbe/PlanningProbe.xcodeproj \
  -scheme PlanningProbe -configuration Debug -destination 'id=<device-udid>' \
  -derivedDataPath /tmp/planning-probe DEVELOPMENT_TEAM=<team-id> \
  -allowProvisioningUpdates build
```

Install and open on an unlocked Apple Intelligence-capable iPhone. Tap Run fixed
planning protocol and keep the app visible. The idle timer is disabled during the
run and restored afterward. Backgrounding cancels work; reports without all three
phases and finished.json are incomplete. Cancel is available throughout. Missing
model assets are recorded as failures, not installed by the host.

Optional autorun uses environment JSON with LOCALAGENTKIT_PLANNING_AUTORUN=1 and
LOCALAGENTKIT_PLANNING_RUN_ID=<fresh UUID>. Manual starts always choose a new UUID.
Reports are under Documents/planning-<UPPERCASE-UUID> and never overwritten.
Retrieve only that synthetic report directory after Finished. Its schema-3 reports
can be replayed with LocalAgentKitEval assess-m5 on the host. Nonzero assessment
exits for inconclusive/below-target outcomes are expected; retain those outcomes.

The host records OS, start/end thermal state and phase results. It is not an energy
or latency benchmark; it does not continuously sample thermal conditions. Fixture
success does not verify real-tool behavior, and no result changes the SDK's default.
The build is Debug to match the paired Mac protocol. Record binary/source hashes
before launch, keep OS results separate, and never substitute a simulator run.
