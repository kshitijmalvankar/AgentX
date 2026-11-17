import Foundation
import Security

/// A random secret only AgentX (and its own widgets and controls) know.
/// Links that *do* something (run an automation, stop everything) must carry
/// it, so a web page or document can't trigger them by opening agentx://….
///
/// It lives in a file only you can read rather than the Keychain: the threat
/// is web content, not other programs running as you, and a Keychain item
/// would prompt for access after every development build.
enum RouteToken {
    static var fileURL: URL { AppChannel.current.dataFile("route-token") }

    /// The token, created on first use.
    static func current(at url: URL = fileURL) -> String {
        if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), s.count >= 32 {
            return s
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? SecureFile.write(Data(token.utf8), to: url)
        return token
    }

    /// Constant-time comparison (doesn't leak how much of a guess was right).
    static func matches(_ candidate: String?, token: String) -> Bool {
        guard let candidate else { return false }
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

/// What an agentx:// link asks for.
public enum URLRoute: Equatable, Sendable {
    /// Show a section of the main window.
    case section(SidebarItem)
    /// Open the launcher, optionally with text typed in (never sent).
    case launcher(prefill: String?)
    /// Show the approvals waiting for you.
    case approvals
    /// Run an automation now. Needs the token.
    case runAutomation(UUID)
    /// The kill switch. Needs the token.
    case stopEverything

    public var needsToken: Bool {
        switch self {
        case .runAutomation, .stopEverything: true
        case .section, .launcher, .approvals: false
        }
    }

    public enum Refusal: Error, Equatable, Sendable {
        case wrongScheme, unknown, missingToken
    }

    /// Longest prefill accepted from a link.
    static let prefillLimit = 2000

    static func parse(_ url: URL, scheme: String, token: String) -> Result<URLRoute, Refusal> {
        guard url.scheme?.lowercased() == scheme else { return .failure(.wrongScheme) }
        guard let host = url.host?.lowercased() else { return .failure(.unknown) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let path = url.pathComponents.filter { $0 != "/" }

        let route: URLRoute
        switch host {
        case "launcher", "ask":
            let text = query["q"].map { String($0.prefix(prefillLimit)) }
            route = .launcher(prefill: text?.isEmpty == false ? text : nil)
        case "approvals":
            route = .approvals
        case "run":
            guard let raw = path.first, let id = UUID(uuidString: raw) else { return .failure(.unknown) }
            route = .runAutomation(id)
        case "stop":
            route = .stopEverything
        default:
            guard let item = SidebarItem(rawValue: host) else { return .failure(.unknown) }
            route = .section(item)
        }
        if route.needsToken, !RouteToken.matches(query["t"], token: token) { return .failure(.missingToken) }
        return .success(route)
    }
}
