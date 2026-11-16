import Foundation
import LocalAgentKitCore

/// Conservative suggestions only. Missing/conflicting fields still require explicit review.
enum ReceiptTextParser {
  static func rows(_ result: VisionResult) -> String {
    let ordered = result.recognizedText.sorted {
      let a = $0.boundingBox
      let b = $1.boundingBox
      return a.y + a.height / 2 == b.y + b.height / 2
        ? a.x < b.x : a.y + a.height / 2 > b.y + b.height / 2
    }
    var rows: [[VisionTextObservation]] = []
    for item in ordered {
      if let last = rows.last?.first {
        let a = item.boundingBox
        let b = last.boundingBox
        let tolerance = max(0.003, min(a.height, b.height) * 0.6)
        if a.height < 0.15, b.height < 0.15,
          abs(a.y + a.height / 2 - b.y - b.height / 2) <= tolerance
        {
          rows[rows.count - 1].append(item)
          continue
        }
      }
      rows.append([item])
    }
    let text = rows.map {
      $0.sorted { $0.boundingBox.x < $1.boundingBox.x }.map(\.text).joined(separator: " ")
    }.joined(separator: "\n")
    return text.isEmpty ? result.text : text
  }

  static func date(_ text: String) -> String {
    var values: Set<String> = []
    func add(_ year: Int, _ month: Int, _ day: Int) {
      let value = String(format: "%04d-%02d-%02d", year < 100 ? year + 2000 : year, month, day)
      if ReceiptExpense.validDate(value) { values.insert(value) }
    }
    for parts in matches("\\b((?:19|20)[0-9]{2})[-/.]([0-9]{1,2})[-/.]([0-9]{1,2})\\b", text) {
      add(Int(parts[0]) ?? 0, Int(parts[1]) ?? 0, Int(parts[2]) ?? 0)
    }
    for parts in matches("\\b([0-9]{1,2})[-/.]([0-9]{1,2})[-/.]([0-9]{4}|[0-9]{2})\\b", text) {
      let first = Int(parts[0]) ?? 0
      let second = Int(parts[1]) ?? 0
      let year = Int(parts[2]) ?? 0
      if first > 12 {
        add(year, second, first)
      } else if second > 12 {
        add(year, first, second)
      } else if first == second {
        add(year, first, second)
      }
      // Two plausible month/day orders remain blank, even if another printed date exists.
      else {
        return ""
      }
    }
    let month =
      "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
    let names = [
      "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]
    for parts in matches(
      "(?i)\\b([0-9]{1,2})(?:st|nd|rd|th)?[ ./-]+" + month + "[ ,./-]+([0-9]{4}|[0-9]{2})\\b", text)
    {
      if let index = names.firstIndex(of: String(parts[1].lowercased().prefix(3))) {
        add(Int(parts[2]) ?? 0, index + 1, Int(parts[0]) ?? 0)
      }
    }
    for parts in matches(
      "(?i)\\b" + month + "[ ./-]+([0-9]{1,2})(?:st|nd|rd|th)?[ ,./-]+([0-9]{4}|[0-9]{2})\\b", text)
    {
      if let index = names.firstIndex(of: String(parts[0].lowercased().prefix(3))) {
        add(Int(parts[2]) ?? 0, index + 1, Int(parts[1]) ?? 0)
      }
    }
    return values.count == 1 ? values.first ?? "" : ""
  }

  static func total(_ text: String) -> String {
    let lines = text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    let label =
      "(?i)^(?:grand\\s*total|net\\s*total|total(?:\\s+(?:amount|due))?|amount\\s+due|balance\\s+due|net\\s+amount|amount\\s+payable)\\b"
    var values: Set<String> = []
    for (index, line) in lines.enumerated() {
      guard let range = line.range(of: label, options: .regularExpression),
        line.range(
          of: "(?i)\\b(?:items?|qty|quantity|savings?|discount)\\b", options: .regularExpression)
          == nil
      else { continue }
      let tail = String(line[range.upperBound...])
      if let value = money(tail) {
        values.insert(value)
        continue
      }
      // Only cross nearby line boundaries after a bare label/currency, never another numeric field.
      guard !tail.contains(where: \.isNumber) else { continue }
      for next in lines.dropFirst(index + 1).prefix(2) {
        if let value = money(next) {
          values.insert(value)
          break
        }
        if next.range(
          of: "(?i)^[():= $£€]*(?:LKR|USD|EUR|GBP|Rs\\.?)?[():= $£€]*$", options: .regularExpression
        ) == nil {
          break
        }
      }
    }
    return values.count == 1 ? values.first ?? "" : ""
  }

  static func money(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(
      in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":=")))
    text = text.replacingOccurrences(
      of: "(?i)^\\(?\\s*(?:(?:LKR|USD|EUR|GBP|Rs\\.?)\\s*\\)?|[$£€])\\s*[:=]?\\s*", with: "",
      options: .regularExpression)
    text = text.replacingOccurrences(
      of: "(?i)\\s*(?:/[=-]|LKR|USD|EUR|GBP|Rs\\.?)\\s*$", with: "", options: .regularExpression
    )
    .trimmingCharacters(in: .whitespaces)
    guard text.range(of: "^[0-9]+(?:[., ][0-9]+)*$", options: .regularExpression) != nil else {
      return nil
    }
    let dots = text.filter { $0 == "." }.count
    let commas = text.filter { $0 == "," }.count
    var integer = text
    var fraction = "00"
    if let separator = text.lastIndex(where: { $0 == "." || $0 == "," }) {
      let ending = String(text[text.index(after: separator)...])
      if (1...2).contains(ending.count), dots <= 1 && commas <= 1 || dots > 0 && commas > 0 {
        integer = String(text[..<separator])
        fraction = ending.padding(toLength: 2, withPad: "0", startingAt: 0)
        // Grouping cannot reuse the decimal separator.
        guard !integer.contains(text[separator]) else { return nil }
      }
    }
    let groups = integer.split(whereSeparator: { ",. ".contains($0) }).map(String.init)
    guard let first = groups.first,
      groups.count == 1
        || ((1...3).contains(first.count) && groups.dropFirst().allSatisfy { $0.count == 3 }),
      Set(integer.filter { ",. ".contains($0) }).count <= 1,
      let units = Int(groups.joined()), units <= 1_000_000,
      let cents = Int(fraction), units * 100 + cents > 0, units * 100 + cents <= 100_000_000
    else { return nil }
    return String(format: "%d.%02d", units, cents)
  }

  private static func matches(_ pattern: String, _ text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
      (1..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
      }
    }
  }
}
