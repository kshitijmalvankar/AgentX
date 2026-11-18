import AppKit
import Foundation

/// One row under the launcher's field.
struct LauncherResult: Identifiable {
    enum Kind: Equatable { case command, calculation, app, file, setting, web, doOnMac, askClaude, code }

    enum Icon {
        case image(NSImage)
        case symbol(String)
    }

    enum Action {
        case open(URL)
        case copy(String)
        /// Run one of AgentX's Mac tools right away (you picked it, and it's reversible).
        case tool(name: String, args: JSONValue, done: String)
        /// A command known without the model ("volume 30", "what's on tomorrow").
        case local(LocalPlan)
        /// Ask Apple's on-device model what you mean, then do it.
        case doOnMac(String)
        case askClaude(String)
        case code(String)
        /// A question about the text you selected, answered on this Mac.
        case aboutSelection(String)
        /// A question about the window in front, read and answered on this Mac.
        case aboutScreen(String)
    }

    let id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var icon: Icon
    /// What Return does, shown on the selected row ("Open", "Copy", "Ask").
    var verb: String
    var action: Action
    /// Higher comes first.
    var score: Double
}

/// Fuzzy name matching for apps and settings: exact, prefix, word prefix,
/// initials ("vsc" → Visual Studio Code), contains. 0 means no match.
enum NameMatch {
    static func score(_ name: String, _ query: String) -> Double {
        let n = fold(name), q = fold(query)
        guard !q.isEmpty, !n.isEmpty else { return 0 }
        if n == q { return 100 }
        if n.hasPrefix(q) { return 90 - min(20, Double(n.count - q.count) * 0.5) }
        let words = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 70 }
        if q.count >= 2, String(words.compactMap(\.first)).hasPrefix(q) { return 60 }
        if n.contains(q) { return 45 }
        return 0
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The apps on this Mac, read from the usual folders (no Spotlight needed).
@MainActor
final class AppIndex {
    static let shared = AppIndex()

    struct App { let name: String; let url: URL }

    private(set) var apps: [App] = []
    private var loadedAt: Date?
    private var icons: [URL: NSImage] = [:]

    nonisolated private static let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                                  "/System/Applications/Utilities", "/System/Library/CoreServices/Applications",
                                  // Safari lives here; /Applications/Safari.app is a hidden link to it.
                                  "/System/Cryptexes/App/System/Applications",
                                  NSHomeDirectory() + "/Applications"]

    /// Re-read every 10 minutes at most (new installs show up).
    func refreshIfNeeded() {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 600 { return }
        loadedAt = Date()
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run {
                AppIndex.shared.apps = found
                // Rows typed before the list was ready get their apps now.
                if !LauncherController.shared.query.isEmpty { LauncherController.shared.updateResults() }
            }
        }
    }

    nonisolated private static func scan() -> [App] {
        let fm = FileManager.default
        var seen = Set<String>(), out: [App] = []
        func add(_ url: URL) {
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            guard seen.insert(name.lowercased()).inserted else { return }
            out.append(App(name: name, url: url))
        }
        for folder in folders {
            let base = URL(fileURLWithPath: folder)
            // Not .skipsHiddenFiles: macOS marks some app links hidden (Safari). Dot-files are still skipped.
            guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { continue }
            for item in items where !item.lastPathComponent.hasPrefix(".") {
                if item.pathExtension == "app" { add(item); continue }
                // One level into folders like "Microsoft Office" or "Adobe Photoshop".
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue,
                      let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                inner.filter { $0.pathExtension == "app" }.forEach(add)
            }
        }
        // Finder lives in CoreServices.
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return out
    }

    func icon(for url: URL) -> NSImage {
        if let cached = icons[url] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = image
        return image
    }

    func matches(_ query: String, limit: Int = 6) -> [(App, Double)] {
        apps.compactMap { app -> (App, Double)? in
            let s = NameMatch.score(app.name, query)
            return s > 0 ? (app, s) : nil
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.count < $1.0.name.count }
        .prefix(limit).map { $0 }
    }
}

/// System Settings pages, by name and a few other words people use.
enum SettingsPanes {
    struct Pane { let name: String; let keywords: [String]; let id: String }

    static let all: [Pane] = [
        Pane(name: "Wi-Fi", keywords: ["wifi", "wireless", "network"], id: "com.apple.wifi-settings-extension"),
        Pane(name: "Bluetooth", keywords: ["airpods", "headphones"], id: "com.apple.BluetoothSettings"),
        Pane(name: "Network", keywords: ["vpn", "ethernet", "firewall"], id: "com.apple.Network-Settings.extension"),
        Pane(name: "Notifications", keywords: ["alerts"], id: "com.apple.Notifications-Settings.extension"),
        Pane(name: "Sound", keywords: ["volume", "audio", "output", "microphone"], id: "com.apple.Sound-Settings.extension"),
        Pane(name: "Focus", keywords: ["do not disturb", "dnd"], id: "com.apple.Focus-Settings.extension"),
        Pane(name: "Screen Time", keywords: [], id: "com.apple.Screen-Time-Settings.extension"),
        Pane(name: "General", keywords: ["about", "this mac"], id: "com.apple.systempreferences.GeneralSettings"),
        Pane(name: "Software Update", keywords: ["update", "upgrade"], id: "com.apple.Software-Update-Settings.extension"),
        Pane(name: "Storage", keywords: ["disk", "space"], id: "com.apple.settings.Storage"),
        Pane(name: "Appearance", keywords: ["dark mode", "light mode", "accent"], id: "com.apple.Appearance-Settings.extension"),
        Pane(name: "Accessibility", keywords: ["zoom", "voiceover"], id: "com.apple.Accessibility-Settings.extension"),
        Pane(name: "Control Centre", keywords: ["control center", "menu bar"], id: "com.apple.ControlCenter-Settings.extension"),
        Pane(name: "Apple Intelligence & Siri", keywords: ["siri", "apple intelligence"], id: "com.apple.Siri-Settings.extension"),
        Pane(name: "Privacy & Security", keywords: ["privacy", "security", "permissions"], id: "com.apple.settings.PrivacySecurity.extension"),
        Pane(name: "Desktop & Dock", keywords: ["dock", "mission control", "stage manager", "hot corners"], id: "com.apple.Desktop-Settings.extension"),
        Pane(name: "Displays", keywords: ["display", "resolution", "brightness", "night shift", "monitor"], id: "com.apple.Displays-Settings.extension"),
        Pane(name: "Wallpaper", keywords: ["background"], id: "com.apple.Wallpaper-Settings.extension"),
        Pane(name: "Battery", keywords: ["energy", "power", "sleep"], id: "com.apple.Battery-Settings.extension"),
        Pane(name: "Lock Screen", keywords: ["screen saver", "lock"], id: "com.apple.Lock-Screen-Settings.extension"),
        Pane(name: "Touch ID & Password", keywords: ["touch id", "fingerprint", "password"], id: "com.apple.Touch-ID-Settings.extension"),
        Pane(name: "Users & Groups", keywords: ["users", "accounts"], id: "com.apple.Users-Groups-Settings.extension"),
        Pane(name: "Internet Accounts", keywords: ["mail accounts", "google account"], id: "com.apple.Internet-Accounts-Settings.extension"),
        Pane(name: "Keyboard", keywords: ["shortcuts", "dictation", "input sources"], id: "com.apple.Keyboard-Settings.extension"),
        Pane(name: "Trackpad", keywords: ["gestures", "tap to click"], id: "com.apple.Trackpad-Settings.extension"),
        Pane(name: "Mouse", keywords: [], id: "com.apple.Mouse-Settings.extension"),
        Pane(name: "Printers & Scanners", keywords: ["printer", "scanner"], id: "com.apple.Print-Scan-Settings.extension"),
        Pane(name: "Date & Time", keywords: ["clock", "time zone"], id: "com.apple.Date-Time-Settings.extension"),
        Pane(name: "Sharing", keywords: ["airdrop", "screen sharing", "file sharing"], id: "com.apple.Sharing-Settings.extension"),
        Pane(name: "Login Items", keywords: ["startup", "login"], id: "com.apple.LoginItems-Settings.extension"),
        Pane(name: "Time Machine", keywords: ["backup"], id: "com.apple.Time-Machine-Settings.extension"),
    ]

    static func matches(_ query: String) -> [(Pane, Double)] {
        all.compactMap { pane -> (Pane, Double)? in
            let s = ([NameMatch.score(pane.name, query)] + pane.keywords.map { NameMatch.score($0, query) * 0.9 }).max() ?? 0
            return s >= 45 ? (pane, s) : nil
        }
        .sorted { $0.1 > $1.1 }
    }

    static func url(_ pane: Pane) -> URL { URL(string: "x-apple.systempreferences:\(pane.id)")! }
}

/// Files and folders by name, from Spotlight's index (your home folder),
/// most recently used first. Never opens or reads a file.
@MainActor
final class FileSearch: NSObject {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var onResults: (([URL]) -> Void)?
    private var term = ""

    func search(_ text: String, limit: Int = 6, onResults: @escaping ([URL]) -> Void) {
        cancel()
        let term = text.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { onResults([]); return }
        self.term = term
        // LIKE treats * and ? as wildcards: escape them in what you typed.
        let escaped = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.predicate = NSPredicate(format: "%K LIKE[cd] %@ AND NOT (%K == 'com.apple.application-bundle')",
                                  NSMetadataItemFSNameKey, "*\(escaped)*", "kMDItemContentType")
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        self.onResults = onResults
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
            MainActor.assumeIsolated { self.finish(limit: limit) }
        }
        query = q
        q.start()
    }

    private func finish(limit: Int) {
        guard let q = query else { return }
        q.disableUpdates()
        var found: [(url: URL, score: Double, order: Int)] = []
        for i in 0..<min(q.resultCount, 400) {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !Self.isNoise(path) else { continue }
            let url = URL(fileURLWithPath: path)
            found.append((url, NameMatch.score(url.deletingPathExtension().lastPathComponent, term), i))
        }
        // Names that start with what you typed first, then the most recently used.
        let urls = found.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.prefix(limit).map(\.url)
        onResults?(Array(urls))
        cancel()
    }

    /// Files nobody means: app internals, Library, hidden folders, and what build tools and package managers leave behind.
    nonisolated static func isNoise(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/Library/") || path.contains("/.") || path.contains(".app/") { return true }
        let noisy = ["/node_modules/", "/DerivedData/", "/Pods/", "/__pycache__/", "/venv/", "/site-packages/", "/build/", "/dist/", "/target/", "/Caches/"]
        return noisy.contains { path.contains($0) }
    }

    /// Files of a kind, from a time, in a folder ("the PDFs I downloaded this week"), newest first.
    static func find(kind: String?, words: String?, since: Date?, folder: String?, limit: Int = 9) async -> [URL] {
        let home = NSHomeDirectory()
        let scope: Any = switch folder {
        case "downloads": home + "/Downloads"
        case "desktop": home + "/Desktop"
        case "documents": home + "/Documents"
        default: NSMetadataQueryUserHomeScope
        }
        let q = NSMetadataQuery()
        q.searchScopes = [scope]
        q.predicate = predicate(kind: kind, words: words, since: since)
        // Newest first: when it arrived (downloads, screenshots), not when it was last opened.
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemDateAdded", ascending: false)]
        // Spotlight answers when it has gathered; give up after a few seconds with what it has.
        let finished = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let once = Once(done)
            once.observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
                MainActor.assumeIsolated { once.finish(true) }
            }
            guard q.start() else { once.finish(false); return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                once.finish(true)
            }
        }
        q.disableUpdates()
        defer { q.stop() }
        guard finished else { return [] }
        var urls: [URL] = []
        for i in 0..<min(q.resultCount, 400) where urls.count < limit {
            guard let path = (q.result(at: i) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !isNoise(path) else { continue }
            urls.append(URL(fileURLWithPath: path))
        }
        return urls
    }

    /// The Spotlight query for a file search. Spotlight throws (an Objective-C exception
    /// Swift can't catch, which damages the app) on an AND or OR with fewer than two
    /// parts, so a single condition always stands alone. Tests check every shape.
    nonisolated static func predicate(kind: String?, words: String?, since: Date?) -> NSPredicate {
        func all(_ p: [NSPredicate]) -> NSPredicate { p.count == 1 ? p[0] : NSCompoundPredicate(andPredicateWithSubpredicates: p) }
        func any(_ p: [NSPredicate]) -> NSPredicate { p.count == 1 ? p[0] : NSCompoundPredicate(orPredicateWithSubpredicates: p) }
        var parts: [NSPredicate] = []
        let types: [String] = switch kind {
        case "pdf": ["com.adobe.pdf"]
        case "screenshot": ["public.image"]
        case "image": ["public.image"]
        case "video": ["public.movie"]
        case "audio": ["public.audio"]
        case "spreadsheet": ["public.spreadsheet"]
        case "presentation": ["public.presentation"]
        case "document": ["com.adobe.pdf", "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages", "public.rtf", "public.plain-text"]
        default: []
        }
        if types.isEmpty {
            parts.append(NSPredicate(format: "kMDItemContentType != 'com.apple.application-bundle'"))
            parts.append(NSPredicate(format: "kMDItemContentType != 'public.folder'"))
        } else {
            parts.append(any(types.map { NSPredicate(format: "kMDItemContentTypeTree == %@", $0) }))
        }
        if kind == "screenshot" { parts.append(NSPredicate(format: "kMDItemIsScreenCapture == 1")) }
        if let words = words?.trimmingCharacters(in: .whitespaces), !words.isEmpty {
            let escaped = words.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
            parts.append(NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(escaped)*"))
        }
        if let since {
            parts.append(any([NSPredicate(format: "kMDItemDateAdded >= %@", since as NSDate),
                              NSPredicate(format: "kMDItemFSCreationDate >= %@", since as NSDate)]))
        }
        return all(parts)
    }

    /// Resumes a search's continuation exactly once (gathered, or timed out).
    @MainActor private final class Once {
        private var done: CheckedContinuation<Bool, Never>?
        var observer: NSObjectProtocol?
        init(_ done: CheckedContinuation<Bool, Never>) { self.done = done }
        func finish(_ ok: Bool) {
            guard let done else { return }
            self.done = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            done.resume(returning: ok)
        }
    }

    func cancel() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// Web addresses and searches.
enum WebTarget {
    /// "example.com", "https://x.y/z" → a URL to open (nil for ordinary words).
    static func url(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.contains(" "), t.count >= 4 else { return nil }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) }
        guard t.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        // "report.pdf" is a file name: only treat file-like endings as a site with "www." or a path.
        let host = t.split(separator: "/").first.map(String.init) ?? t
        let ending = host.split(separator: ".").last.map { $0.lowercased() } ?? ""
        if fileEndings.contains(ending), !host.lowercased().hasPrefix("www."), !t.contains("/") { return nil }
        return URL(string: "https://" + t)
    }

    private static let fileEndings: Set<String> = [
        "pdf", "doc", "docx", "txt", "md", "rtf", "png", "jpg", "jpeg", "gif", "heic", "zip", "dmg", "swift", "py", "js", "ts",
        "json", "csv", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "mov", "mp4", "mp3", "wav", "html", "htm", "sh", "log",
    ]

    static func search(_ text: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: text)]
        return c?.url
    }
}
