import Foundation

/// Parses the date-time shapes Phase 0 observed the on-device model actually write, rather than
/// the one shape a schema pattern would enforce — a pattern guide itself is what broke date
/// arguments on iOS 27 (findings §9b, §11a), so the tool must accept looseness the schema no
/// longer constrains: `yyyy-MM-dd'T'HH:mm`, with or without `:ss`, with `Z`, or with a `±HH:MM`
/// offset.
///
/// Hand-rolled rather than built on `DateFormatter`: a `DateFormatter` pattern ending in a
/// literal `'Z'` matched input with **no** `Z` at all in testing here, silently parsing it in the
/// formatter's default time zone instead of the caller's — the wrong answer with no error. A
/// fixed grammar has no such leniency to misfire.
enum LenientISO8601 {
  static func date(from text: String, timeZone: TimeZone = .current) -> Date? {
    guard let parsed = parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = parsed.timeZone ?? timeZone
    var components = DateComponents()
    (components.year, components.month, components.day) = (parsed.year, parsed.month, parsed.day)
    (components.hour, components.minute, components.second) = (
      parsed.hour, parsed.minute, parsed.second
    )
    guard let date = calendar.date(from: components) else { return nil }
    // Reject an out-of-range value (month 13, day 32, …) that `Calendar` silently normalized.
    let normalized = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    guard normalized.year == parsed.year, normalized.month == parsed.month,
      normalized.day == parsed.day
    else { return nil }
    return date
  }

  private struct Parsed {
    var year, month, day, hour, minute, second: Int
    var timeZone: TimeZone?
  }

  private static func parse(_ text: String) -> Parsed? {
    var scanner = FixedFieldScanner(text)
    guard let year = scanner.digits(4), scanner.consume("-"), let month = scanner.digits(2),
      scanner.consume("-"), let day = scanner.digits(2), scanner.consume("T"),
      let hour = scanner.digits(2), scanner.consume(":"), let minute = scanner.digits(2)
    else { return nil }

    var second = 0
    if scanner.consume(":") {
      guard let value = scanner.digits(2) else { return nil }
      second = value
    }

    var timeZone: TimeZone?
    if scanner.consume("Z") {
      timeZone = TimeZone(identifier: "UTC")
    } else if let sign = scanner.consumeOne(of: ["+", "-"]) {
      guard let offsetHour = scanner.digits(2), scanner.consume(":"),
        let offsetMinute = scanner.digits(2)
      else { return nil }
      let seconds = (offsetHour * 3600 + offsetMinute * 60) * (sign == "-" ? -1 : 1)
      guard let zone = TimeZone(secondsFromGMT: seconds) else { return nil }
      timeZone = zone
    }
    guard scanner.atEnd, (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
      (0...59).contains(minute), (0...59).contains(second)
    else { return nil }
    return Parsed(
      year: year, month: month, day: day, hour: hour, minute: minute, second: second,
      timeZone: timeZone)
  }
}

/// A minimal fixed-width scanner: exactly the operations `LenientISO8601`'s grammar needs.
private struct FixedFieldScanner {
  private let characters: [Character]
  private var index = 0

  init(_ text: String) { characters = Array(text) }

  var atEnd: Bool { index >= characters.count }

  mutating func digits(_ count: Int) -> Int? {
    guard index + count <= characters.count else { return nil }
    let slice = characters[index..<(index + count)]
    guard slice.allSatisfy(\.isASCII), slice.allSatisfy(\.isNumber) else { return nil }
    index += count
    return Int(String(slice))
  }

  mutating func consume(_ character: Character) -> Bool {
    guard index < characters.count, characters[index] == character else { return false }
    index += 1
    return true
  }

  mutating func consumeOne(of options: [Character]) -> Character? {
    guard index < characters.count, options.contains(characters[index]) else { return nil }
    defer { index += 1 }
    return characters[index]
  }
}
