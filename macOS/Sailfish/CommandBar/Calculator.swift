import Foundation

// The inline calculator: arithmetic typed into the command bar is answered in its own row.
enum Calculator {
  // The result of `text` as shown, nil unless the whole text is an expression with an operator.
  static func evaluate(_ text: String) -> String? {
    let text = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
    guard text.dropFirst().contains(where: { "+-*/^".contains($0) }) else { return nil }
    var parser = Parser(Array(text))
    guard let value = parser.expression(), parser.isAtEnd, value.isFinite else { return nil }
    return format(value)
  }

  private static func format(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(format: "%.10g", value)
  }

  private struct Parser {
    let characters: [Character]
    var index = 0

    init(_ characters: [Character]) {
      self.characters = characters
    }

    var isAtEnd: Bool {
      characters[index...].allSatisfy { $0 == " " }
    }

    private mutating func peek() -> Character? {
      while index < characters.count, characters[index] == " " { index += 1 }
      return index < characters.count ? characters[index] : nil
    }

    private mutating func take(_ options: String) -> Character? {
      guard let character = peek(), options.contains(character) else { return nil }
      index += 1
      return character
    }

    mutating func expression() -> Double? {
      guard var value = term() else { return nil }
      while let sign = take("+-") {
        guard let next = term() else { return nil }
        value = sign == "+" ? value + next : value - next
      }
      return value
    }

    private mutating func term() -> Double? {
      guard var value = unary() else { return nil }
      while let sign = take("*/") {
        guard let next = unary() else { return nil }
        value = sign == "*" ? value * next : value / next
      }
      return value
    }

    // A leading minus binds looser than ^, so -2^2 is -4.
    private mutating func unary() -> Double? {
      if take("-") != nil { return unary().map { -$0 } }
      return power()
    }

    private mutating func power() -> Double? {
      guard let base = primary() else { return nil }
      guard take("^") != nil else { return base }
      guard let exponent = unary() else { return nil }
      return pow(base, exponent)
    }

    private mutating func primary() -> Double? {
      if take("(") != nil {
        guard let value = expression(), take(")") != nil else { return nil }
        return value
      }
      guard let first = peek(), first.isNumber || first == "." else { return nil }
      var digits = ""
      while index < characters.count, characters[index].isNumber || characters[index] == "." {
        digits.append(characters[index])
        index += 1
      }
      guard let value = Double(digits) else { return nil }
      return take("%") != nil ? value / 100 : value
    }
  }
}
