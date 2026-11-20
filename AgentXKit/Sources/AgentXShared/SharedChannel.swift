import Foundation

/// Which AgentX the widget extension belongs to: the installed app ("AgentX",
/// agentx://) or the one you're developing ("AgentX Dev", agentx-dev://). Read
/// from Info.plist keys that Config/*.xcconfig fills in, so AgentX Dev's widgets
/// and controls show Dev's data and open Dev.
public enum SharedChannel {
    /// "AgentX" or "AgentX Dev": the app's name and its folder in Application Support.
    public static var appName: String { info("AgentXDataFolder") ?? "AgentX" }

    public static var urlScheme: String { info("AgentXURLScheme") ?? "agentx" }

    /// ~/Library/Application Support/AgentX (or "AgentX Dev"), the real one even inside the sandbox.
    public static var dataDirectory: URL {
        URL(fileURLWithPath: WidgetSnapshot.realHome)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    /// agentx://<route>, with the route token when `secured` (links that do something need it).
    public static func url(_ route: String, secured: Bool = false) -> URL {
        url(route, scheme: urlScheme, token: secured ? routeToken() : nil)
    }

    static func url(_ route: String, scheme: String, token: String?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        let parts = route.split(separator: "/", maxSplits: 1).map(String.init)
        components.host = parts.first
        if parts.count > 1 { components.path = "/" + parts[1] }
        if let token { components.queryItems = [URLQueryItem(name: "t", value: token)] }
        return components.url ?? URL(string: "\(scheme)://dashboard")!
    }

    /// The secret AgentX keeps in its data folder for links that do something.
    public static func routeToken() -> String? {
        guard let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("route-token")),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              token.count >= 32 else { return nil }
        return token
    }

    private static func info(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
