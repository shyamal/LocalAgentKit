/// Evaluates `+ - * /` arithmetic with parentheses and unary minus, tolerant of the loose formats
/// a model actually writes rather than the plain numbers a tool description asks for: a currency
/// symbol, comma thousands separators, a trailing `%`, and `"N% of X"` (findings §11c: the model
/// wrote "17.5% of 2,480" and "$186.40 / 4" despite being asked for `+ - * /`).
///
/// `%` is a postfix operator (divide by 100) and `of` is a synonym for `*`, both handled at parse
/// time rather than by rewriting the input, so ordinary compound expressions work unmodified.
enum Arithmetic {
  static func evaluate(_ text: String) -> Double? {
    var parser = Parser(text)
    guard let value = parser.sum(), parser.atEnd, value.isFinite else { return nil }
    return value
  }

  private struct Parser {
    private let chars: [Character]
    private var index = 0

    init(_ text: String) {
      // Currency symbols and thousands-separator commas are noise, not operators.
      chars = Array(text.filter { !"$£€,".contains($0) })
    }

    var atEnd: Bool { index >= chars.count }

    mutating func sum() -> Double? {
      guard var value = product() else { return nil }
      while true {
        skipSpaces()
        guard index < chars.count, chars[index] == "+" || chars[index] == "-" else { break }
        let op = chars[index]
        index += 1
        guard let rhs = product() else { return nil }
        value = op == "+" ? value + rhs : value - rhs
      }
      return value
    }

    private mutating func product() -> Double? {
      guard var value = unary() else { return nil }
      while true {
        skipSpaces()
        if index < chars.count, chars[index] == "*" || chars[index] == "/" {
          let op = chars[index]
          index += 1
          guard let rhs = unary() else { return nil }
          value = op == "*" ? value * rhs : value / rhs
        } else if matchWord("of") {
          guard let rhs = unary() else { return nil }
          value *= rhs
        } else {
          break
        }
      }
      return value
    }

    private mutating func unary() -> Double? {
      skipSpaces()
      if index < chars.count, chars[index] == "-" {
        index += 1
        return unary().map { -$0 }
      }
      if index < chars.count, chars[index] == "(" {
        index += 1
        guard let value = sum() else { return nil }
        skipSpaces()
        guard index < chars.count, chars[index] == ")" else { return nil }
        index += 1
        return percent(of: value)
      }
      let start = index
      while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
      guard index > start, let value = Double(String(chars[start..<index])) else { return nil }
      return percent(of: value)
    }

    /// A trailing `%` divides by 100.
    private mutating func percent(of value: Double) -> Double {
      skipSpaces()
      guard index < chars.count, chars[index] == "%" else { return value }
      index += 1
      return value / 100
    }

    private mutating func matchWord(_ word: String) -> Bool {
      skipSpaces()
      let letters = Array(word)
      guard index + letters.count <= chars.count else { return false }
      for offset in letters.indices
      where chars[index + offset].lowercased() != letters[offset].lowercased() {
        return false
      }
      let after = index + letters.count
      if after < chars.count, chars[after].isLetter { return false }
      index = after
      return true
    }

    private mutating func skipSpaces() {
      while index < chars.count, chars[index].isWhitespace { index += 1 }
    }
  }
}
