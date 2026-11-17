import Foundation

/// Spots text that looks like a secret: API keys and tokens, private keys,
/// passwords written out, card numbers, US social security numbers. Memory
/// refuses to save it, and the launcher won't attach a selection that
/// contains it. Errs on the side of refusing.
enum SecretDetector {
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "a private key"),
        (#"\b(sk|rk|pk)-[A-Za-z0-9_-]{20,}"#, "an API key"),
        (#"\bsk-ant-[A-Za-z0-9_-]{20,}"#, "an Anthropic API key"),
        (#"\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"#, "a GitHub token"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "an AWS access key"),
        (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, "a Slack token"),
        (#"\bAIza[0-9A-Za-z_-]{35}\b"#, "a Google API key"),
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, "a login token"),
        (#"(?i)\b(password|passwd|passcode|pin|secret|api[ _-]?key|token)\s*(is|:|=)\s*\S{4,}"#, "a password or key"),
        (#"\b\d{3}-\d{2}-\d{4}\b"#, "a social security number"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// What kind of secret the text seems to contain, or nil.
    static func find(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for (pattern, label) in patterns where pattern.firstMatch(in: text, range: range) != nil {
            return label
        }
        if containsCardNumber(text) { return "a card number" }
        return nil
    }

    /// 13–19 digits (spaces or dashes allowed) that pass the Luhn check.
    static func containsCardNumber(_ text: String) -> Bool {
        let candidates = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){12,18}\d\b"#)
        let range = NSRange(text.startIndex..., in: text)
        for match in candidates.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let digits = text[r].compactMap(\.wholeNumberValue)
            if (13...19).contains(digits.count), luhn(digits) { return true }
        }
        return false
    }

    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}
