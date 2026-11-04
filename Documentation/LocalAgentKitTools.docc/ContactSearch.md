# Search contacts with explicit approval

`ContactsTool` registers `search_contacts` with the `.sensitive` tier. Reading
contact data itself requires confirmation, even though the operation does not
modify anything. The runtime validates the schema, asks the human, then invokes
the backend. A denied/missing agent gate prevents OS authorization requests and
contact reads; direct calls to `execute` are host APIs and do not prompt through
the agent gate.

```swift
let runtime = try AgentRuntime(
  configuration: AgentConfiguration(model: model),
  tools: StaticToolSource([ContactsTool(limit: 5)]))
// Consume permissionRequired and resolve it through the app's approval UI.
let response = try await runtime.run("Find Priya in my contacts")
```

## Host app configuration and OS permission

Set a meaningful `NSContactsUsageDescription` in the host app's Info.plist before
requesting OS access. Apple documents this purpose string in
[NSContactsUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nscontactsusagedescription).
For sandboxed/hardened macOS apps, configure the appropriate Contacts/Address Book
capability in Xcode; see Apple's
[address book entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.addressbook).
These OS capabilities are independent of the runtime's per-call approval.

The device adapter lazily creates its CNContactStore only during an approved tool
execution. It requests OS access only if undetermined, and refuses to request it
without a non-blank purpose string. Denied/restricted access produces
`AgentError.deviceAuthorizationDenied(.contacts)`; a missing purpose string is a
typed `toolFailed` configuration diagnostic. OS authorization failures are not
reported as an empty address book. iOS limited authorization searches only the
contacts the OS makes accessible; this state is unavailable on macOS. Empty
results say “No accessible contacts found,” not that the person has no contacts.

## Query and disclosure

Queries match localized case/diacritic-insensitive substrings of name, company or
job title. They are not email/phone searches, semantic role inference, arbitrary
predicates or destination parameters. The adapter enumerates accessible unified
contacts in the user's preferred store order, matches locally and stops after
the limit. Company/title matching requires a local scan; no network search or
contact mutation is performed by the adapter.

Results are clamped to 1...10 cards (default 5). Each card includes an opaque ID,
name, organization, job title, at most two email addresses and two phone numbers.
String previews are bounded: ID 200 characters, name/company/title 120 each,
email 160 each and phone 80 each, with an ellipsis when clipped. Readable and
structured results use the same bounded fields. No photo, birthday, postal
address, contact note or relationship fields are fetched. A match outside the
accessible/limited subset is not discoverable through this tool.

Cards and query arguments contain personal data. Default runtime sensitive-tool
auditing can retain the query signature; apply the same access/retention controls
as for the request. Data returned by contacts or an ingested document is not
permission to read more contacts, send a message or execute another tool.

## Testing and cancellation

Core's `ContactSearching` protocol and `ContactSummary` value isolate framework
objects. `MockContactStore` in LocalAgentKitTesting supports deterministic local
queries, typed failures and query recording. Custom backends must remain local-only
and honor matching, limits and cancellation; no flag can downgrade the tool tier.

```swift
let store = MockContactStore([
  ContactSummary(id: "fixture", name: "Priya Rao", organization: "Design")
])
let tool = ContactsTool(store: store)
```

Cancellation is checked before/after backend work and during enumeration. An OS
prompt or synchronous framework operation already in progress may finish later;
the runtime's deadline/cancellation handling can abandon the call. The tool does
not publish cards returned by a cancelled backend.

Tests use synthetic CNMutableContact values and mocks; they never read the user's
address book or trigger TCC prompts. The production source is typechecked against
macOS and iOS SDKs, including iOS-only limited access. The supplemental
`contacts-local` probe records model selection/arguments without executing tools.
The existing demo does not register this new sensitive capability automatically.
A real app-bundle OS-consent/limited-access check remains manual: configure purpose
and capabilities, approve an agent request, exercise OS allow/deny/limited paths,
and confirm an agent denial does not invoke the backend. No physical-device
consent check or new real-model accuracy measurement is claimed here.
