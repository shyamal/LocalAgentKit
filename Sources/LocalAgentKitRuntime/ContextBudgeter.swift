import LocalAgentKitCore

/// How the window is divided (M1-RT-04). Shares are relative weights, not fractions of a fixed
/// whole: what one section leaves unused, the others may use.
public struct ContextBudgetConfiguration: Sendable, Hashable {
  /// Instructions and tool definitions. Tools alone are ~26% of a 4,096-token window (findings §10).
  public var systemAndToolsShare: Double
  /// Relative weight for retained conversation turns.
  public var conversationShare: Double
  /// Relative weight for retrieved passages.
  public var retrievalShare: Double
  /// Relative weight for serialized plan state.
  public var planShare: Double
  /// Tokens kept free for the model's answer. Input and output share the window, so a request at
  /// 90% can still fail if the reply runs long (findings §10).
  public var responseReserveTokens: Int
  /// Used when neither the provider nor `ExecutionLimits` gives a window. 4,096 is the on-device
  /// model's (findings §3).
  public var fallbackWindowTokens: Int
  /// Tool outputs in older turns are cut to this many characters before any turn is dropped.
  public var olderToolOutputCharacterLimit: Int
  /// Target token allowance supplied to the conversation summarizer; must be positive.
  public var summaryMaxTokens: Int

  /// Creates relative context shares and reserve, fallback-window and compaction limits.
  /// Inspect `issue` for invalid settings before fitting a request.
  public init(
    systemAndToolsShare: Double = 0.30,
    conversationShare: Double = 0.40,
    retrievalShare: Double = 0.20,
    planShare: Double = 0.10,
    responseReserveTokens: Int = 512,
    fallbackWindowTokens: Int = 4096,
    olderToolOutputCharacterLimit: Int = 240,
    summaryMaxTokens: Int = 160
  ) {
    self.systemAndToolsShare = systemAndToolsShare
    self.conversationShare = conversationShare
    self.retrievalShare = retrievalShare
    self.planShare = planShare
    self.responseReserveTokens = responseReserveTokens
    self.fallbackWindowTokens = fallbackWindowTokens
    self.olderToolOutputCharacterLimit = olderToolOutputCharacterLimit
    self.summaryMaxTokens = summaryMaxTokens
  }

  /// Default relative shares, a 512-token reply reserve and a 4096-token fallback window.
  public static let `default` = ContextBudgetConfiguration()

  /// The first invalid share, reserve, fallback-window or summary limit, or nil when valid.
  public var issue: ConfigurationIssue? {
    let shares = [systemAndToolsShare, conversationShare, retrievalShare, planShare]
    if shares.contains(where: { $0 < 0 || !$0.isFinite }) || shares.reduce(0, +) <= 0 {
      return .invalidLimit("context shares must be non-negative and not all zero")
    }
    if responseReserveTokens < 0 { return .invalidLimit("responseReserveTokens is negative") }
    if fallbackWindowTokens < 1 { return .invalidLimit("fallbackWindowTokens must be positive") }
    if summaryMaxTokens < 1 { return .invalidLimit("summaryMaxTokens must be positive") }
    return nil
  }
}

/// Everything that may go into one model call, before fitting.
public struct ContextInputs: Sendable {
  /// System instructions retained as the base of the assembled request.
  public var instructions: String
  /// In priority order: when tools must go, the last ones go first.
  public var tools: [ToolDescriptor]
  /// Tools that are never dropped, such as the one the current plan step needs.
  public var requiredToolNames: Set<String>
  /// The whole conversation including the current turn, which begins at the last `.user` message
  /// and is never dropped.
  public var conversation: [ModelMessage]
  /// Retrieved passages, most relevant first: when chunks must go, the last ones go first.
  public var retrievedChunks: [String]
  /// Optional serialized planning state included in the system context.
  public var planState: String?

  /// Creates unfitted context from instructions, ordered tools, transcript, retrieval and plan state.
  public init(
    instructions: String,
    tools: [ToolDescriptor] = [],
    requiredToolNames: Set<String> = [],
    conversation: [ModelMessage],
    retrievedChunks: [String] = [],
    planState: String? = nil
  ) {
    self.instructions = instructions
    self.tools = tools
    self.requiredToolNames = requiredToolNames
    self.conversation = conversation
    self.retrievedChunks = retrievedChunks
    self.planState = planState
  }
}

/// What the budgeter had to give up to fit.
public struct TrimReport: Sendable, Hashable {
  /// Number of older tool-output messages shortened.
  public var compactedToolOutputs = 0
  /// Number of retrieved passages removed from the end of the ranking.
  public var droppedChunks = 0
  /// Number of older transcript messages replaced by a summary.
  public var summarizedMessages = 0
  /// Tool names removed to fit, excluding required tools.
  public var droppedToolNames: [String] = []
  /// Whether fitting shortened the supplied plan state.
  public var planTruncated = false

  /// Whether any compaction, removal, summarization or plan truncation occurred.
  public var isTrimmed: Bool {
    compactedToolOutputs > 0 || droppedChunks > 0 || summarizedMessages > 0
      || !droppedToolNames.isEmpty || planTruncated
  }
}

/// The fitted request together with its token utilization and degradation report.
public struct BudgetedContext: Sendable {
  /// Request safe to submit according to the budgeter's count or fallback estimate.
  public var request: ModelRequest
  /// Input-token utilization measured against the model window.
  public var utilization: ContextUtilization
  /// Changes made to the original context while fitting it.
  public var report: TrimReport
}

/// Fits a model call into the context window **before** the call, not after it fails (R2).
///
/// Degradation order, cheapest first: shorten old tool outputs, drop the lowest-ranked retrieved
/// chunks, replace the oldest whole turns with a summary, drop non-required tools. Only when all of
/// that fails does it throw `contextLimitExceeded`. Turns are removed whole so a tool call is never
/// separated from its output — iOS 27 rejects a transcript with an orphaned output (findings §10a).
///
/// Decisions use a pessimistic estimate calibrated against the provider's real token count; the
/// result is then verified against a real count where one exists. Where the provider cannot
/// count, only the estimate is available.
public struct ContextBudgeter: Sendable {
  /// Relative shares and degradation limits applied before each model call.
  public let configuration: ContextBudgetConfiguration
  private let summarizer: any ConversationSummarizer
  private static let maxPasses = 3

  /// Creates a budgeter and its summarization strategy; fitting validates the configuration.
  public init(
    configuration: ContextBudgetConfiguration = .default,
    summarizer: any ConversationSummarizer = ExtractiveSummarizer()
  ) {
    self.configuration = configuration
    self.summarizer = summarizer
  }

  /// Assembles the exact untrimmed request for diagnostics and token counting.
  /// Call `fit` before generation; this method alone does not enforce the window.
  public static func untrimmedRequest(for inputs: ContextInputs) -> ModelRequest {
    assemble(
      instructions: inputs.instructions, tools: inputs.tools, plan: inputs.planState,
      chunks: inputs.retrievedChunks, summary: nil, conversation: inputs.conversation)
  }

  /// - Parameter inputs: Instructions, tool definitions, history, retrieval, and plan state.
  /// - Parameter model: Supplies the context window and optional token counts.
  /// - Parameter limits: Optional execution limits that cap the context window.
  /// - Parameter events: When given, receives `.contextUtilization` (M1-RT-06).
  /// - Throws: `.contextLimitExceeded` if the call cannot be made to fit, `.invalidConfiguration`
  ///   for unusable shares, `.cancelled`.
  public func fit(
    _ inputs: ContextInputs,
    for model: any LocalModelProvider,
    limits: ExecutionLimits = .default,
    events: EventBus? = nil
  ) async throws -> BudgetedContext {
    if let issue = configuration.issue { throw AgentError.invalidConfiguration(issue) }
    var window = model.contextWindowTokens ?? configuration.fallbackWindowTokens
    if let cap = limits.maxContextTokens { window = min(window, cap) }
    let available = window - configuration.responseReserveTokens
    guard available > 0 else { throw AgentError.contextLimitExceeded }

    let context = try await fitted(inputs, model: model, window: window, available: available)
    await events?.publish(.contextUtilization(context.utilization))
    return context
  }

  private func fitted(
    _ inputs: ContextInputs, model: any LocalModelProvider, window: Int, available: Int
  ) async throws -> BudgetedContext {
    let full = Self.untrimmedRequest(for: inputs)
    let fullEstimate = TokenEstimator.tokens(full)
    let fullReal = await model.tokenCount(for: full)

    // Fast path: nothing to trim.
    if let real = fullReal, real <= available {
      return BudgetedContext(
        request: full,
        utilization: ContextUtilization(usedTokens: real, limitTokens: window),
        report: TrimReport())
    }

    var scale = 1.0
    if let real = fullReal, fullEstimate > 0 {
      scale = min(max(Double(real) / Double(fullEstimate), 0.5), 3.0)
    }

    var attempt = 0
    while true {
      try Task.checkCancellation()
      let (request, report) = try await fit(inputs, scale: scale, available: available)
      let estimate = TokenEstimator.tokens(request)
      let used: Int
      if let real = await model.tokenCount(for: request) {
        used = real
        if real > available && estimate > 0 {
          attempt += 1
          guard attempt < Self.maxPasses else { throw AgentError.contextLimitExceeded }
          // Trim harder next pass, and always by more than last time.
          scale = max(scale * 1.05, Double(real) / Double(estimate))
          continue
        }
      } else {
        used = Int((Double(estimate) * scale).rounded(.up))
        guard used <= available else { throw AgentError.contextLimitExceeded }
      }
      return BudgetedContext(
        request: request,
        utilization: ContextUtilization(
          usedTokens: used, limitTokens: window, wasTrimmed: report.isTrimmed),
        report: report)
    }
  }

  // MARK: - One fitting pass

  private func fit(
    _ inputs: ContextInputs, scale: Double, available: Int
  ) async throws -> (ModelRequest, TrimReport) {
    var report = TrimReport()
    func cost(_ tokens: Int) -> Int { Int((Double(tokens) * scale).rounded(.up)) }
    func cost(_ message: ModelMessage) -> Int { cost(TokenEstimator.tokens(message)) }

    // 1. Instructions and tools: fixed, except that the lowest-priority tools give way.
    let instructionCost = cost(
      TokenEstimator.perMessageOverhead + TokenEstimator.tokens(inputs.instructions))
    var tools = inputs.tools
    let systemCap = Int(Double(available) * fraction(configuration.systemAndToolsShare))
    func systemCost() -> Int {
      instructionCost + tools.reduce(0) { $0 + cost(TokenEstimator.tokens($1)) }
    }
    while systemCost() > systemCap,
      let index = tools.lastIndex(where: { !inputs.requiredToolNames.contains($0.name) })
    {
      report.droppedToolNames.append(tools.remove(at: index).name)
    }
    let remaining = available - systemCost()
    guard remaining > 0 else { throw AgentError.contextLimitExceeded }

    // 2. Split what remains among plan, conversation and retrieval, letting sections that need
    // less than their share give the rest to the others.
    let planNeed =
      inputs.planState.map { cost(TokenEstimator.perMessageOverhead + TokenEstimator.tokens($0)) }
      ?? 0
    let chunkCosts = inputs.retrievedChunks.map { cost(TokenEstimator.tokens($0) + 2) }
    let ragNeed =
      chunkCosts.isEmpty ? 0 : chunkCosts.reduce(0, +) + cost(TokenEstimator.perMessageOverhead + 8)
    let turns = Self.turns(of: inputs.conversation)
    let conversationNeed = inputs.conversation.reduce(0) { $0 + cost($1) }
    let allocation = Self.allocate(
      needs: [planNeed, conversationNeed, ragNeed],
      weights: [
        configuration.planShare, configuration.conversationShare, configuration.retrievalShare,
      ],
      total: remaining)

    // 3. Plan: keep the first lines.
    var plan = inputs.planState
    if let text = plan, planNeed > allocation[0] {
      var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      while lines.count > 1,
        cost(
          TokenEstimator.perMessageOverhead + TokenEstimator.tokens(lines.joined(separator: "\n")))
          > allocation[0]
      {
        lines.removeLast()
      }
      let kept = lines.joined(separator: "\n")
      plan =
        cost(TokenEstimator.perMessageOverhead + TokenEstimator.tokens(kept)) <= allocation[0]
        ? kept : nil
      report.planTruncated = true
    }

    // 4. Retrieval: drop the least relevant chunks.
    var chunks = inputs.retrievedChunks
    var ragCost = ragNeed
    while !chunks.isEmpty && ragCost > allocation[2] {
      ragCost -= chunkCosts[chunks.count - 1]
      chunks.removeLast()
      report.droppedChunks += 1
    }
    if chunks.isEmpty { ragCost = 0 }

    // 5. Conversation.
    let (conversation, summary) = try await fitConversation(
      turns, allocation: allocation[1], cost: cost, report: &report)

    let request = Self.assemble(
      instructions: inputs.instructions, tools: tools, plan: plan, chunks: chunks,
      summary: summary, conversation: conversation)
    return (request, report)
  }

  private func fitConversation(
    _ turns: [[ModelMessage]], allocation: Int, cost: (ModelMessage) -> Int,
    report: inout TrimReport
  ) async throws -> ([ModelMessage], String?) {
    func total(_ groups: [[ModelMessage]]) -> Int {
      groups.reduce(0) { $0 + $1.reduce(0) { $0 + cost($1) } }
    }
    guard let currentTurn = turns.last else { return ([], nil) }
    var older = Array(turns.dropLast())
    var current = currentTurn
    if total(turns) <= allocation { return (turns.flatMap { $0 }, nil) }

    // Cheapest first: shorten old tool outputs.
    let limit = configuration.olderToolOutputCharacterLimit
    func compact(_ turn: [ModelMessage]) -> [ModelMessage] {
      turn.map { message in
        guard message.role == .tool, message.content.count > limit else { return message }
        report.compactedToolOutputs += 1
        var shortened = message
        shortened.content = String(message.content.prefix(limit)) + " …[truncated]"
        return shortened
      }
    }
    older = older.map(compact)

    // Then replace the oldest whole turns with a summary.
    let summaryCost = cost(
      ModelMessage(
        role: .system, content: String(repeating: "x", count: configuration.summaryMaxTokens * 3)))
    var pulled: [ModelMessage] = []
    while !older.isEmpty
      && total(older + [current]) + (pulled.isEmpty ? 0 : summaryCost) > allocation
    {
      pulled += older.removeFirst()
      // `pulled` was compacted above, but the summarizer needs the original wording only for
      // user text, which compaction never touches.
    }
    if !pulled.isEmpty && total(older + [current]) + summaryCost > allocation {
      // Every older turn is gone and the current turn alone is too big: shorten its tool
      // outputs too, as a last resort.
      current = compact(current)
    }

    var summary: String?
    if !pulled.isEmpty {
      report.summarizedMessages += pulled.count
      summary = try await summarizer.summarize(pulled, maxTokens: configuration.summaryMaxTokens)
    } else if total(older + [current]) > allocation {
      current = compact(current)
    }
    return ((older + [current]).flatMap { $0 }, summary)
  }

  // MARK: - Helpers

  private func fraction(_ share: Double) -> Double {
    let sum =
      configuration.systemAndToolsShare + configuration.conversationShare
      + configuration.retrievalShare + configuration.planShare
    return share / sum
  }

  /// Turns start at each `.user` message. Anything before the first user message joins the first
  /// turn.
  static func turns(of messages: [ModelMessage]) -> [[ModelMessage]] {
    var turns: [[ModelMessage]] = []
    for message in messages {
      if message.role == .user || turns.isEmpty {
        turns.append([message])
      } else {
        turns[turns.count - 1].append(message)
      }
    }
    return turns
  }

  /// Water-filling: a section that needs less than its proportional share takes only what it
  /// needs, and the surplus is redistributed among the rest.
  static func allocate(needs: [Int], weights: [Double], total: Int) -> [Int] {
    var result = [Int](repeating: 0, count: needs.count)
    var active = Array(needs.indices).filter { weights[$0] > 0 }
    var remaining = total
    var settled = true
    repeat {
      settled = true
      let weightSum = active.reduce(0.0) { $0 + weights[$1] }
      guard weightSum > 0 else { break }
      for index in active
      where Double(needs[index]) <= Double(remaining) * weights[index] / weightSum {
        result[index] = needs[index]
        remaining -= needs[index]
        active.removeAll { $0 == index }
        settled = false
        break
      }
    } while !settled && !active.isEmpty
    let weightSum = active.reduce(0.0) { $0 + weights[$1] }
    for index in active {
      result[index] = Int(Double(remaining) * weights[index] / weightSum)
    }
    return result
  }

  static func assemble(
    instructions: String, tools: [ToolDescriptor], plan: String?, chunks: [String],
    summary: String?, conversation: [ModelMessage]
  ) -> ModelRequest {
    var messages = [ModelMessage(role: .system, content: instructions)]
    if let plan, !plan.isEmpty {
      messages.append(ModelMessage(role: .system, content: "Current plan:\n" + plan))
    }
    if !chunks.isEmpty {
      let body = chunks.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(
        separator: "\n")
      messages.append(ModelMessage(role: .system, content: "Relevant documents:\n" + body))
    }
    if let summary {
      messages.append(ModelMessage(role: .system, content: summary))
    }
    return ModelRequest(messages: messages + conversation, tools: tools)
  }
}
