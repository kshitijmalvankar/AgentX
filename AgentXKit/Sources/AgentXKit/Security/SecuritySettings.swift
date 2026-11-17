import Foundation

/// Security settings that need a little logic.
enum SecuritySettings {
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
