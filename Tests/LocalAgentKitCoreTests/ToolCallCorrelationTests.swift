import Foundation
import LocalAgentKitCore
import Testing

@Suite struct ToolCallCorrelationTests {
  @Test func oldPayloadsDecodeWithoutPlanIdentityAndNewPayloadsRoundTrip() throws {
    let old = Data(#"{"id":"c","name":"read","arguments":{"values":{}}}"#.utf8)
    #expect(try JSONDecoder().decode(ToolCall.self, from: old).planStepID == nil)
    let call = ToolCall(id: "c", name: "read", planStepID: "step")
    #expect(try JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(call)) == call)
  }
}
