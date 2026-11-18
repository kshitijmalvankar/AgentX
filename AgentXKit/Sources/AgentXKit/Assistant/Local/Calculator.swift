import Foundation

/// Arithmetic typed into the launcher ("12*4.5", "(3+4)^2", "250 / 7").
/// A small parser of its own: never NSExpression, which raises on bad input
/// and accepts far more than numbers.
enum Calculator {
    /// The value, or nil if the text isn't a calculation (it needs at least one operator).
    static func evaluate(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty, cleaned.count <= 200,
              cleaned.allSatisfy({ "0123456789.+-*/^()%".contains($0) }),
              cleaned.contains(where: { "+-*/^%".contains($0) }),
              cleaned.contains(where: \.isNumber) else { return nil }
        var parser = Parser(chars: Array(cleaned))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        // "-5" alone is a number, not a calculation.
        if cleaned.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        return value
    }

    /// "42", "3.1415926536", "1.2e+21".
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(format: "%.0f", value) }
        let f = NumberFormatter()
        f.numberStyle = abs(value) >= 1e15 || (abs(value) < 1e-6 && value != 0) ? .scientific : .decimal
        f.maximumSignificantDigits = 11
        f.usesGroupingSeparator = false
        return f.string(from: value as NSNumber) ?? String(value)
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        var atEnd: Bool { i == chars.count }

        mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }

        // expression := term (('+'|'-') term)*
        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let rhs = term() else { return nil }
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term := power (('*'|'/'|'%') power)*
        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1
                guard let rhs = power() else { return nil }
                switch c {
                case "*": value *= rhs
                case "/": guard rhs != 0 else { return nil }; value /= rhs
                default: guard rhs != 0 else { return nil }; value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        // power := unary ('^' power)?
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        // unary := '-' unary | primary
        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            return primary()
        }

        // primary := number | '(' expression ')'
        mutating func primary() -> Double? {
            if peek() == "(" {
                i += 1
                guard let value = expression(), peek() == ")" else { return nil }
                i += 1
                return value
            }
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            guard i > start else { return nil }
            return Double(String(chars[start..<i]))
        }
    }
}
