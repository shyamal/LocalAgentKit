import Testing

@testable import LocalAgentKitTools

@Suite struct ArithmeticTests {
  @Test func basicOperators() {
    #expect(Arithmetic.evaluate("2 + 3") == 5)
    #expect(Arithmetic.evaluate("10 - 4") == 6)
    #expect(Arithmetic.evaluate("6 * 7") == 42)
    #expect(Arithmetic.evaluate("9 / 2") == 4.5)
  }

  @Test func precedenceAndParentheses() {
    #expect(Arithmetic.evaluate("2 + 3 * 4") == 14)
    #expect(Arithmetic.evaluate("(2 + 3) * 4") == 20)
    #expect(Arithmetic.evaluate("2 * (3 + (4 - 1))") == 12)
  }

  @Test func unaryMinus() {
    #expect(Arithmetic.evaluate("-5 + 3") == -2)
    #expect(Arithmetic.evaluate("3 * -2") == -6)
    #expect(Arithmetic.evaluate("-(2 + 3)") == -5)
  }

  @Test func decimalsAndWhitespace() {
    #expect(Arithmetic.evaluate("0.175 * 2480") == 434)
    #expect(Arithmetic.evaluate("  1.5   +  2.25 ") == 3.75)
  }

  /// findings §11c: the model wrote loose formats despite the tool asking for plain numbers.
  @Test func looseFormatsFromFindings() {
    #expect(Arithmetic.evaluate("17.5% of 2,480") == 434)
    #expect(Arithmetic.evaluate("$186.40 / 4") == 46.6)
  }

  @Test func trailingPercent() {
    #expect(Arithmetic.evaluate("50%") == 0.5)
    #expect(Arithmetic.evaluate("20% + 5%") == 0.25)
    #expect(Arithmetic.evaluate("(20 + 30)%") == 0.5)
  }

  @Test func ofIsCaseInsensitiveAndWholeWord() {
    #expect(Arithmetic.evaluate("10% OF 200") == 20)
    #expect(Arithmetic.evaluate("2 office") == nil)  // "of" must be a whole word
  }

  @Test func currencyAndThousandsSeparators() {
    #expect(Arithmetic.evaluate("$1,234.50 + £5") == 1239.5)
  }

  @Test func malformedInputReturnsNil() {
    #expect(Arithmetic.evaluate("") == nil)
    #expect(Arithmetic.evaluate("2 +") == nil)
    #expect(Arithmetic.evaluate("(2 + 3") == nil)
    #expect(Arithmetic.evaluate("2 3") == nil)
    #expect(Arithmetic.evaluate("abc") == nil)
  }

  @Test func divisionByZeroIsNotFinite() {
    #expect(Arithmetic.evaluate("1 / 0") == nil)
  }
}
