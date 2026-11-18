import Foundation

/// Security settings that need a little logic.
enum SecuritySettings {
    /// Read-only connector tools (like Google Calendar's list_events) you let
    /// run without asking, even after a conversation read untrusted content.
    /// agent-core only honours names that read (list, get, search…).
    static let trustedToolsKey = "trustedConnectorTools"

    static var trustedTools: [String] {
        get { UserDefaults.standard.stringArray(forKey: trustedToolsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: trustedToolsKey) }
    }

    /// Every connected tool that only reads (list, get, search…) runs without asking. On unless you turn it off.
    static let trustConnectorReadsKey = "trustConnectorReads"
    static var trustConnectorReads: Bool { UserDefaults.standard.object(forKey: trustConnectorReadsKey) as? Bool ?? true }

    static func trust(_ tool: String) {
        guard !trustedTools.contains(tool) else { return }
        trustedTools.append(tool)
    }

    /// "mcp__claude_ai_Google_Calendar__list_events" → "Google Calendar · list events".
    static func displayName(ofTool tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return tool }
        var server = parts[0]
        if server.hasPrefix("claude_ai_") { server.removeFirst("claude_ai_".count) }
        let action = parts.dropFirst().joined(separator: " ")
        return server.replacingOccurrences(of: "_", with: " ") + " · " + action.replacingOccurrences(of: "_", with: " ")
    }

    /// Project folders whose files don't count as untrusted content. Broad
    /// places where downloads and other people's files land (your home
    /// folder itself, Downloads, Desktop, Documents, Library, hidden folders)
    /// never count, even if you once started a session there.
    static func trustedRoots(from projects: [String], home: String) -> [String] {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        let broad = Set(["", "/Desktop", "/Documents", "/Downloads", "/Library", "/Public", "/Movies", "/Music", "/Pictures"].map { home + $0 })
        let neverUnder = ["/Downloads/", "/Library/", "/."].map { home + $0 }
        var seen = Set<String>()
        return projects
            .map { ($0 as NSString).standardizingPath }
            .filter { path in
                path.hasPrefix(home + "/") && !broad.contains(path) && !neverUnder.contains { path.hasPrefix($0) }
            }
            .filter { seen.insert($0).inserted }
    }
}
