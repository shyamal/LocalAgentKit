import LocalAgentKitCore
import Testing

@testable import LocalAgentKitRuntime

@Suite struct EventBusTests {
  private func collect(_ stream: AsyncStream<AgentEvent>) async -> [String] {
    var names: [String] = []
    for await event in stream {
      if case .responseToken(let token) = event { names.append(token) }
    }
    return names
  }

  @Test func everySubscriberSeesEveryEvent() async {
    let bus = EventBus()
    let a = await bus.subscribe()
    let b = await bus.subscribe()
    await bus.publish(.responseToken("1"))
    await bus.publish(.responseToken("2"))
    await bus.finish()
    #expect(await collect(a) == ["1", "2"])
    #expect(await collect(b) == ["1", "2"])
  }

  @Test func lateSubscriberMissesEarlierEvents() async {
    let bus = EventBus()
    await bus.publish(.responseToken("early"))
    let late = await bus.subscribe()
    await bus.publish(.responseToken("late"))
    await bus.finish()
    #expect(await collect(late) == ["late"])
  }

  @Test func subscribingAfterFinishGivesAnEndedStream() async {
    let bus = EventBus()
    await bus.finish()
    #expect(await collect(await bus.subscribe()).isEmpty)
    await bus.publish(.started)
  }

  @Test func consumerThatStopsIsRemoved() async throws {
    let bus = EventBus()
    do {
      let stream = await bus.subscribe()
      var iterator = stream.makeAsyncIterator()
      await bus.publish(.started)
      _ = await iterator.next()
    }
    for _ in 0..<50 where await bus.subscriberCount > 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await bus.subscriberCount == 0)
  }
}
