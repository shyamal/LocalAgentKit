import LocalAgentKitCore
import Testing

@Suite struct ContactSummaryTests {
  @Test func matchesNameCompanyAndRoleButNotContactDestinations() {
    let card = ContactSummary(
      id: "one", name: "José Silva", organization: "Design Team", jobTitle: "Engineer",
      emails: ["private@example.invalid"], phoneNumbers: ["12345"])
    #expect(card.matches(query: "jose"))
    #expect(card.matches(query: " DESIGN "))
    #expect(card.matches(query: "engineer"))
    #expect(!card.matches(query: "example.invalid"))
    #expect(!card.matches(query: "12345"))
    #expect(!card.matches(query: " \n "))
    #expect(DeviceCapability.contacts.description == "Contacts")
    #expect(AgentError.deviceAuthorizationDenied(.contacts).description.contains("Contacts"))
  }
}
