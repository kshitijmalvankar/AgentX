import Foundation

/// Credentials and other secrets on disk that the assistant may never touch.
///
/// agent-core's policy (agent-core/src/policy.ts) enforces the same rules on
/// every tool call Claude makes; this copy guards the Mac tools themselves,
/// so a bug in one layer doesn't expose your keys. Keep the two lists in step
/// (PathGuardTests and policy.test.ts check the same examples).
enum PathGuard {
    struct Rule: Sendable {
        let pattern: NSRegularExpression
        let label: String

        init(_ pattern: String, _ label: String) {
            self.pattern = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.label = label
        }
    }

    /// Matched against the absolute path with the home folder written as ~.
    static let rules: [Rule] = [
        Rule(#"^~/\.ssh(/|$)"#, "SSH keys"),
        Rule(#"^~/\.aws(/|$)"#, "AWS credentials"),
        Rule(#"^~/\.gnupg(/|$)"#, "GPG keys"),
        Rule(#"^~/\.config/gh(/|$)"#, "GitHub CLI login"),
        Rule(#"^~/\.config/gcloud(/|$)"#, "Google Cloud credentials"),
        Rule(#"^~/\.azure(/|$)"#, "Azure credentials"),
        Rule(#"^~/\.netrc$"#, "saved logins (.netrc)"),
        Rule(#"^~/\.docker/config\.json$"#, "Docker login"),
        Rule(#"^~/\.kube(/|$)"#, "Kubernetes credentials"),
        Rule(#"^~/\.npmrc$"#, "npm token"),
        Rule(#"^~/\.pypirc$"#, "PyPI token"),
        Rule(#"^~/\.git-credentials$"#, "saved Git passwords"),
        Rule(#"^~/Library/Keychains(/|$)"#, "the Keychain"),
        Rule(#"^~/Library/Cookies(/|$)"#, "browser cookies"),
        Rule(#"^~/Library/Messages(/|$)"#, "Messages history"),
        Rule(#"^~/Library/Mail(/|$)"#, "Mail's database"),
        Rule(#"^~/Library/Safari(/|$)"#, "Safari's data"),
        Rule(#"^~/Library/Application Support/(Google/Chrome|BraveSoftware|Microsoft Edge|Arc|Firefox|Vivaldi)(/|$)"#, "a browser profile"),
        Rule(#"^~/Library/Containers/com\.apple\.Safari(/|$)"#, "Safari's data"),
        Rule(#"^~/Library/Group Containers/[^/]*\.(1password|com\.1password)[^/]*(/|$)"#, "a password manager"),
        Rule(#"^~/\.claude/\.credentials\.json$"#, "Claude Code's login"),
        Rule(#"^~/\.claude\.json$"#, "Claude Code's account file"),
        Rule(#"^~/Library/Application Support/AgentX( Dev)?/(route-token|activity\.jsonl)$"#, "AgentX's security files"),
        Rule(#"(^|/)\.env(\.[^/]*)?$"#, "an .env file"),
        Rule(#"\.(pem|p12|pfx|keystore|jks)$"#, "a private key or certificate"),
        Rule(#"(^|/)[^/]*(private|server|tls|ssl|signing)[^/]*\.key$"#, "a private key"),
        Rule(#"(^|/)id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$"#, "an SSH key"),
    ]

    static let exceptionsKey = "pathExceptions"

    /// Paths you allowed in Settings → Security.
    static var exceptions: [String] { UserDefaults.standard.stringArray(forKey: exceptionsKey) ?? [] }

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path }

    /// `/Users/you/x` → `~/x`.
    static func display(_ path: String, home: String = home) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Why this file is off-limits (checking where symlinks really point), or nil.
    static func reason(for url: URL, home: String = home, exceptions: [String] = exceptions) -> String? {
        let plain = url.standardizedFileURL.path
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        for path in Set([plain, real]) {
            if let reason = reason(forPath: path, home: home, exceptions: exceptions) { return reason }
        }
        return nil
    }

    static func reason(forPath path: String, home: String = home, exceptions: [String] = exceptions) -> String? {
        let shown = display(path, home: home)
        for exception in exceptions {
            let e = display((exception as NSString).expandingTildeInPath, home: home)
            let prefix = e.hasSuffix("/") ? e : e + "/"
            if shown == e || shown.hasPrefix(prefix) { return nil }
        }
        let range = NSRange(shown.startIndex..., in: shown)
        return rules.first { $0.pattern.firstMatch(in: shown, range: range) != nil }?.label
    }
}
