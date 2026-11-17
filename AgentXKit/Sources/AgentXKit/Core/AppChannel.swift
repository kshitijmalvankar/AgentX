import Foundation

/// Which copy of AgentX this is. The installed app (`scripts/install.sh`) is
/// **stable**; the one you build while developing (`scripts/run-dev.sh`,
/// `swift run AgentXDev`, tests) is **dev**. They keep separate data,
/// hotkeys and URL schemes so both can run at once.
public enum AppChannel: String, Sendable {
    case stable, dev

    /// Read from the `AgentXChannel` Info.plist key (set by Config/*.xcconfig).
    public static let current: AppChannel = {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "AgentXChannel") as? String,
           let channel = AppChannel(rawValue: raw.lowercased()) {
            return channel
        }
        return .dev
    }()

    public var isDev: Bool { self == .dev }

    public var displayName: String { isDev ? "AgentX Dev" : "AgentX" }

    /// Folder name under ~/Library/Application Support.
    public var dataFolderName: String { isDev ? "AgentX Dev" : "AgentX" }

    public var urlScheme: String { isDev ? "agentx-dev" : "agentx" }

    /// ~/Library/Application Support/AgentX (or "AgentX Dev").
    public var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(dataFolderName, isDirectory: true)
    }

    public func dataFile(_ name: String) -> URL { dataDirectory.appendingPathComponent(name) }
}

/// Files AgentX writes about you: only you can read them (0600, in a 0700 folder).
enum SecureFile {
    static func prepareDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func write(_ data: Data, to url: URL) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Append one line, creating the file 0600 if needed.
    static func append(_ line: Data, to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try prepareDirectory(url.deletingLastPathComponent())
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
