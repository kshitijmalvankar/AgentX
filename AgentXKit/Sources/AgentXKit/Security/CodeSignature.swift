import Foundation
import Security

/// Code-signature checks: is the Claude Code binary really Anthropic's, and
/// how is AgentX itself signed?
public enum CodeSignature {
    /// Anthropic PBC's Apple Developer team.
    static let anthropicTeam = "Q6L2SF6YDW"

    public enum Status: Equatable, Sendable {
        case verified(team: String)
        case failed(String)
        case missing

        public var isVerified: Bool { if case .verified = self { true } else { false } }
    }

    /// Checks that `path` is signed by `team` with a valid Developer ID
    /// signature. Hashing a ~350 MB binary takes about a second, so the result
    /// is cached until the file changes (size, modification date, inode).
    static func verify(path: String, team: String = anthropicTeam, cache: UserDefaults = .standard) -> Status {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return .missing }
        let fingerprint = [
            path, team,
            "\(attrs[.size] ?? "")",
            "\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)",
            "\(attrs[.systemFileNumber] ?? "")",
        ].joined(separator: "|")
        let cacheKey = "codeSignatureVerified"
        if cache.string(forKey: cacheKey) == fingerprint { return .verified(team: team) }

        let status = check(path: path, requirement: "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        if status.isVerified { cache.set(fingerprint, forKey: cacheKey) }
        return status
    }

    static func check(path: String, requirement text: String) -> Status {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return .failed("Couldn't read its signature.")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return .failed("Bad signature requirement.")
        }
        var error: Unmanaged<CFError>?
        let result = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement, &error)
        guard result == errSecSuccess else {
            let message = (error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "error \(result)"
            return .failed(message)
        }
        let team = teamIdentifier(of: code) ?? "?"
        return .verified(team: team)
    }

    static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// How AgentX itself is signed: a team id, or nil for an ad-hoc signature
    /// (macOS then forgets permissions like Accessibility after each build).
    static func ownTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }
}
