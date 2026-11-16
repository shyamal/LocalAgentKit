# Receipt photo demo (M4-11)

Implementation and physical receipt path verified on 2026-11-16. M4-11 adds a Receipt expense sheet to the
existing LocalAgentDemo, with camera capture on iPhone, system photo/file selection,
a synthetic sample, preview, editable OCR proposals, runtime approval and durable
structured expense history. Product scope and the remaining physical checklist
are in [receipt acceptance](../Examples/LocalAgentDemo/RECEIPT-VALIDATION.md).

## Boundaries

All new implementation lives in the example application. Core/Runtime stay free
of native-framework imports; no SDK source, provider protocol, runtime dependency
or default changed. Native Vision prepares the image once. A conservative parser
suggests fields, the host reviews them, and AgentRuntime deterministically carries
the immutable reviewed record through an input binding to an authorized tool.
There is no generative extraction, amount calculation by a model, or generated
confirmation message standing in for a tool result.

Amounts use integer two-decimal minor units. Invalid/ambiguous proposals require
correction. Persistence contains only validated reviewed fields and generated
record identity/time. The existing runtime permission broker controls every write.
Raw photos/OCR are ephemeral, and saved records do not enter the chat conversation.
An atomic app-owned JSON store bounds size/count, preserves corruption and rejects
conflicting reuse of a UUID. Same-ID retries are idempotent.

## Acceptance and validation

- Demo package: 37 registered test functions, up from 26. Added parser/field limits,
  exact money, approval/denial and reopened storage, corruption/idempotence,
  pending-approval cancellation, stale OCR replacement, empty input and frozen
  approval payload checks.
- Explicit native bundled-receipt acceptance passed on macOS: Vision OCR produced
  the expected four fields; the runtime awaited approval; a reopened temporary
  store matched the record; the scripted model received zero calls.
- Warning-free SDK build; full 822-function default suite/offline suite pass.
- Core/Runtime coverage 98.98% (3312/3346), unchanged from M4-10. Core 99.59%
  (980/984); Runtime 98.73% (2332/2362). SDK source was unchanged.
- All 80 Python checks, strict example formatting and layering passed. The added
  packaging regression verifies that the sample PNG is actually referenced in the
  generated app resource phase, not merely available to host tests.
- Signed iPhone and macOS demo builds passed. Existing AppIntents metadata and
  iOS orientation warnings remain; no receipt-source compiler warnings were silenced.
- The updated app was installed and launched on the connected iPhone in receipt
  mode. The user reported missing fields/empty recognized text. Inspection found
  the sample PNG missing from the generated resource phase even though host tests
  could read it from the checkout. Regenerating the project bundled the image;
  the corrected app was verified to contain the PNG and camera usage description,
  then reinstalled and relaunched. The user confirmed the expected sample fields
  appeared and approval/saving worked. Read-only metadata confirms expenses.json
  now exists in the app container; its contents were not exported. Physical
  camera/date/price initially failed because OCR missed those lines. The plain
  capture was replaced with VisionKit document scanning, single-page cropping
  and upright high-quality rendering; parser/geometry regression checks were
  expanded. The user then confirmed scanned date/total extraction and approved
  saving followed by a surviving row after closing/reopening the receipt sheet.

Early compilation caught missing explicit tool capability flags and immutable URL
actor isolation; both were corrected. A separate alert presentation Boolean avoids
turning SwiftUI's presentation dismissal into an unintended permission denial.
The malformed/negative-total, conflicting-date and trailing-newline date regressions
pass. One later full demo run crashed with signal 11 in Core Data trigger SQL
generation (`_generateTriggerSQL`); the unchanged retry and explicit native test
passed. No tests were disabled and no causal link to receipt code is established.
The preserved failure log is `/tmp/lak-m411-demo-crash.log`.

Logs use `/tmp/lak-m411-`: `demo`, `native`, `sdk-build`, `coverage`, `offline`,
`python`, `format`, `layering`, `ios`, `macos`, `install`, `launch` and `docs`.
No personal receipt/photo was read by automated tests. No development-team ID is
committed. The sample is synthetic and its generator is included.

## Physical acceptance and limits

M4-11's scanned receipt → reviewed structured fields → approved save → reopened
row path is user-confirmed on the iPhone. Missing sample packaging and the initial
plain-photo OCR failure were corrected before this confirmation. Numeric/date
parsing now supports common printed forms and split OCR columns, while ambiguity
still requires review. Other receipt layouts, low-light photos, picker/camera
permission denial and full app relaunch are additional manual coverage, not
universal production accuracy claims. Native STT and other pending
M4-05/09/10 acceptance are unaffected. M4-12's voice interaction is subsequent work.

For privacy, an attempted verification copy of the complete device expense store
was rejected by automatic approval review because it could include unrelated
records. No copy was executed. Device verification instead uses the user's
confirmation and file-presence metadata, without exporting expense contents.

The final camera delegate uses an explicit MainActor-isolated VisionKit protocol
conformance, as recommended by the Swift compiler, rather than suppressing
concurrency checking. Scanner support and callbacks and UIKit image-rendering
APIs were verified in the installed SDK. The new date/amount-format and OCR-column
functions bring added demo tests to eleven; the native fixture check also passes.
