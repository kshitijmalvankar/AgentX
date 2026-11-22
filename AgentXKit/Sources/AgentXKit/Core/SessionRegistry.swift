import Darwin
import Foundation

/// A Claude Code process outside AgentX that has a session open
/// (the Claude app, a terminal, VS Code, ...).
public struct ExternalSession: Sendable, Hashable {
    public let pid: Int32
    public let entrypoint: String?
    /// The app it runs under, when it's an AgentX ("AgentX", "AgentX Dev").
    public var hostApp: String? = nil

    public var appName: String {
        if let hostApp { return hostApp }
        return switch entrypoint {
        case "claude-desktop": "the Claude app"
        case "cli": "a terminal"
        case let e? where e.contains("vscode"): "VS Code"
        case let e? where e.contains("jetbrains"): "a JetBrains IDE"
        case let e? where e.hasPrefix("sdk"): "another Agent SDK app"
        default: "another Claude Code window"
        }
    }
}

/// Reads Claude Code's registry of running sessions (~/.claude/sessions/<pid>.json)
/// to tell which sessions are open in other apps right now.
enum SessionRegistry {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    private struct Entry: Decodable {
        let pid: Int32
        let sessionId: String
        let entrypoint: String?
    }

    /// sessionId → processes outside AgentX that have it open. Processes whose
    /// parent is in `ownParents` (agent-core, or AgentX's own Terminal tab) are skipped.
    static func scan(in directory: URL = directory, ownParents: Set<Int32>) -> [String: [ExternalSession]] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: [ExternalSession]] = [:]
        for file in files where file.pathExtension == "json" && Int32(file.deletingPathExtension().lastPathComponent) != nil {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  isAlive(entry.pid) else { continue }
            if let parent = parentPID(of: entry.pid), ownParents.contains(parent) { continue }
            let host = entry.entrypoint?.hasPrefix("sdk") == true ? agentXApp(above: entry.pid) : nil
            result[entry.sessionId, default: []].append(ExternalSession(pid: entry.pid, entrypoint: entry.entrypoint, hostApp: host))
        }
        return result
    }

    /// "AgentX" or "AgentX Dev" when one of them runs this process (through its agent-core).
    static func agentXApp(above pid: Int32) -> String? {
        var current = pid
        for _ in 0..<4 {
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            if let name = appName(ofPath: executablePath(of: parent)) { return name }
            current = parent
        }
        return nil
    }

    /// The AgentX app an executable belongs to, from its path.
    static func appName(ofPath path: String?) -> String? {
        guard let path else { return nil }
        if path.contains("/AgentX Dev.app/") { return "AgentX Dev" }
        if path.contains("/AgentX.app/") { return "AgentX" }
        return nil
    }

    private static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Whether any of these processes has quit (its entry can stay behind, so the folder doesn't change).
    static func anyQuit(_ pids: [Int32]) -> Bool {
        pids.contains { !isAlive($0) }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }
}
