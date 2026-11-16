import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders
import LocalAgentKitRuntime
import Observation

struct ReceiptExpense: Codable, Sendable, Equatable, Identifiable {
  let id: UUID
  let merchant: String
  let date: String
  let totalMinorUnits: Int
  let currency: String
  let createdAt: Date
  static let currencies = ["USD", "EUR", "GBP", "LKR"]
  var formattedTotal: String {
    String(format: "%d.%02d %@", totalMinorUnits / 100, totalMinorUnits % 100, currency)
  }

  func validate() throws {
    guard !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, merchant.count <= 160,
      merchant.utf8.count <= 640,
      (1...100_000_000).contains(totalMinorUnits), Self.currencies.contains(currency),
      Self.validDate(date), createdAt.timeIntervalSince1970.isFinite
    else {
      throw AgentError.inputFailure("Review merchant, ISO date, total and currency before saving.")
    }
  }

  static func validDate(_ value: String) -> Bool {
    guard value.utf8.count == 10,
      value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
    else {
      return false
    }
    let parts = value.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return false }
    var calendar = Calendar(identifier: .gregorian)
    guard let zone = TimeZone(secondsFromGMT: 0) else { return false }
    calendar.timeZone = zone
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
    guard let date = calendar.date(from: components) else { return false }
    let roundtrip = calendar.dateComponents([.year, .month, .day], from: date)
    return roundtrip.year == parts[0] && roundtrip.month == parts[1] && roundtrip.day == parts[2]
  }
}

struct ReceiptDraft: Sendable {
  var merchant = ""
  var date = ""
  var total = ""
  var currency = ""
  var sourceText = ""

  static func suggested(from text: String) -> Self {
    let lines = text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    var draft = Self()
    draft.sourceText = text
    if let first = lines.first, first.count <= 160 { draft.merchant = first }
    draft.total = ReceiptTextParser.total(text)
    let codes = ReceiptExpense.currencies.filter {
      text.range(of: "\\b" + $0 + "\\b", options: .regularExpression) != nil
    }
    if codes.count == 1 { draft.currency = codes[0] }
    draft.date = ReceiptTextParser.date(text)
    return draft
  }

  func reviewed(id: UUID = UUID(), now: Date = Date()) throws -> ReceiptExpense {
    let value = total.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.range(of: "^[0-9]{1,9}(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil
    else {
      throw AgentError.inputFailure("Enter a total using a dot and at most two decimal places.")
    }
    let parts = value.split(separator: ".").map(String.init)
    let cents =
      (Int(parts[0]) ?? 0) * 100
      + (parts.count == 2
        ? Int(parts[1].padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0 : 0)
    let record = ReceiptExpense(
      id: id, merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
      date: date, totalMinorUnits: cents, currency: currency, createdAt: now)
    try record.validate()
    return record
  }
}

/// One actor per file. Failed/corrupt loads never replace the existing local records.
actor ReceiptExpenseStore {
  static let shared = ReceiptExpenseStore(
    url: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory).appendingPathComponent(
        "LocalAgentDemo/expenses.json"))
  nonisolated let url: URL
  init(url: URL) { self.url = url }

  func all() throws -> [ReceiptExpense] {
    try Task.checkCancellation()
    guard url.isFileURL else {
      throw AgentError.memoryFailure("Expense store requires a local file.")
    }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else {
        throw AgentError.memoryFailure("Expense store exceeds its demo size limit.")
      }
      let records = try JSONDecoder().decode([ReceiptExpense].self, from: Data(contentsOf: url))
      guard records.count <= 1000, Set(records.map(\.id)).count == records.count else {
        throw AgentError.memoryFailure("Expense store contains invalid records.")
      }
      for record in records { try record.validate() }
      return records
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] } catch {
      throw AgentError.memoryFailure("Could not read the expense store: \(error)")
    }
  }

  func save(_ record: ReceiptExpense) throws {
    try Task.checkCancellation()
    try record.validate()
    let records = try all()
    if let existing = records.first(where: { $0.id == record.id }) {
      guard existing == record else {
        throw AgentError.memoryFailure("Expense identity already has different fields.")
      }
      return
    }
    guard records.count < 1000 else {
      throw AgentError.memoryFailure("Expense demo supports up to 1,000 records.")
    }
    do {
      let data = try JSONEncoder().encode(records + [record])
      guard data.count <= 1_048_576 else {
        throw AgentError.memoryFailure("Expense store exceeds its demo size limit.")
      }
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Task.checkCancellation()
      try data.write(to: url, options: .atomic)
    } catch is CancellationError { throw AgentError.cancelled } catch {
      throw AgentError.memoryFailure("Could not save the expense: \(error)")
    }
  }
}

private struct SaveReceiptExpenseTool: AgentTool {
  let store: ReceiptExpenseStore
  let name = "save_receipt_expense"
  let description = "Save the reviewed receipt fields to the local expense store."
  let schema = ToolSchema(
    parameters: ["record": ToolParameter(.string, description: "Reviewed expense JSON")],
    required: ["record"])
  let permission = ToolPermission.userConfirmation
  let isParallelSafe = true
  let isCancellable = true
  func execute(arguments: ToolArguments) async throws -> ToolResult {
    try Task.checkCancellation()
    guard let json = arguments.string("record"), let data = json.data(using: .utf8),
      data.count < 4096,
      let record = try? JSONDecoder().decode(ReceiptExpense.self, from: data)
    else { throw AgentError.inputFailure("Reviewed expense is invalid.") }
    try await store.save(record)
    return ToolResult(
      callID: "", toolName: name,
      text: "Saved expense: \(record.merchant), \(record.formattedTotal).",
      structured: .string(record.id.uuidString))
  }
}

private struct ReceiptNoGeneration: LocalModelProvider {
  func generate(request: ModelRequest) async throws -> ModelResponse {
    throw AgentError.modelUnavailable(
      reason: "The reviewed receipt workflow does not require model generation.")
  }
}

struct ReceiptSession {
  static func runtime(
    store: ReceiptExpenseStore, model: any LocalModelProvider = ReceiptNoGeneration()
  ) throws -> AgentRuntime {
    try AgentRuntime(
      configuration: AgentConfiguration(model: model),
      tools: StaticToolSource([SaveReceiptExpenseTool(store: store)]),
      planner: StateMachinePlanner(
        workflow: Workflow(
          name: "receipt", description: "Save a reviewed receipt",
          steps: [
            .tool(
              "save", "Save reviewed expense", "save_receipt_expense",
              ["record": .input(attachment: 0, path: "text")])
          ])))
  }
  static func input(_ record: ReceiptExpense) throws -> AgentInput {
    try record.validate()
    let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    return AgentInput(
      text: "Save this reviewed expense after approval.",
      attachments: [.document(Document(title: "Reviewed receipt", text: json))])
  }
}

@MainActor @Observable final class ReceiptController {
  var draft: ReceiptDraft?
  private(set) var records: [ReceiptExpense] = []
  private(set) var imageData: Data?
  private(set) var busy = false
  private(set) var pendingCall: ToolCall?
  private(set) var failure: String?
  private(set) var notice: String?
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var runtime: AgentRuntime?
  @ObservationIgnored private var revision = UUID()
  private let vision: any VisionProvider
  let store: ReceiptExpenseStore

  init(vision: any VisionProvider, store: ReceiptExpenseStore = .shared) {
    self.vision = vision
    self.store = store
  }

  func refresh() async {
    do { records = try await store.all() } catch { failure = String(describing: error) }
  }

  @discardableResult func read(_ image: ImageInput) -> Task<Void, Never> {
    cancel(clearDraft: true)
    busy = true
    let token = revision
    let vision = vision
    let task = Task {
      do {
        guard !image.data.isEmpty, image.data.count <= 16 * 1024 * 1024 else {
          throw AgentError.inputFailure("Choose an image up to 16 MiB.")
        }
        let result = try await vision.analyze(image: image)
        try Task.checkCancellation()
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          result.text.utf8.count <= 64 * 1024
        else {
          throw AgentError.inputFailure("No usable receipt text was found. Try a clearer photo.")
        }
        guard revision == token else { return }
        imageData = image.data
        var proposed = ReceiptDraft.suggested(from: ReceiptTextParser.rows(result))
        proposed.sourceText = result.text
        draft = proposed
      } catch {
        guard revision == token else { return }
        if !Task.isCancelled { failure = String(describing: error) }
      }
      guard revision == token else { return }
      busy = false
      operation = nil
    }
    operation = task
    return task
  }

  @discardableResult func save() -> Task<Void, Never>? {
    guard !busy, let draft else { return nil }
    let record: ReceiptExpense
    do { record = try draft.reviewed() } catch {
      failure = String(describing: error)
      return nil
    }
    busy = true
    failure = nil
    notice = nil
    let token = revision
    let task = Task {
      do {
        let runtime = try ReceiptSession.runtime(store: store)
        self.runtime = runtime
        let events = await runtime.events()
        let observer = Task {
          for await event in events {
            guard revision == token, !Task.isCancelled else { return }
            if case .permissionRequired(let call) = event { pendingCall = call }
          }
        }
        let result: Result<AgentResponse, any Error>
        do { result = .success(try await runtime.run(ReceiptSession.input(record))) } catch {
          result = .failure(error)
        }
        await runtime.finishEvents()
        await observer.value
        guard revision == token, !Task.isCancelled else { return }
        let response = try result.get()
        records = try await store.all()
        notice = response.text
        self.draft = nil
        imageData = nil
      } catch {
        guard revision == token else { return }
        if !Task.isCancelled { failure = String(describing: error) }
      }
      guard revision == token else { return }
      pendingCall = nil
      busy = false
      runtime = nil
      operation = nil
    }
    operation = task
    return task
  }

  func resolve(_ approved: Bool) {
    guard let call = pendingCall, let runtime else { return }
    pendingCall = nil
    Task { await runtime.resolvePermission(callID: call.id, approved: approved) }
  }

  func cancel(clearDraft: Bool = false) {
    revision = UUID()
    operation?.cancel()
    if let runtime { Task { await runtime.cancelCurrentRun() } }
    operation = nil
    runtime = nil
    pendingCall = nil
    busy = false
    failure = nil
    notice = nil
    if clearDraft {
      draft = nil
      imageData = nil
    }
  }
}
