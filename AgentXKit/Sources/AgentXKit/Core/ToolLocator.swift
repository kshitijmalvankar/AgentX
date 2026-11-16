import Foundation

/// Where AgentX found the programs it depends on.
public struct ToolPaths: Sendable, Equatable, Codable {
    /// Node.js, used to run the agent-core sidecar.
    public var node: String?
    /// The `claude` CLI, used by the Terminal tab.
    public var claude: String?
    /// The agent-core folder (contains src/index.ts and node_modules).
    public var agentCore: String?
    /// PATH from your login shell. Apps launched from Finder get a minimal
    /// PATH, so we borrow your shell's so Claude's Bash tool finds git, npm, ...
    public var shellPath: String
}

/// Finds node, claude and agent-core without relying on the app's own PATH.
public enum ToolLocator {
    public static let nodePathOverrideKey = "nodePathOverride"
    public static let agentCorePathOverrideKey = "agentCorePathOverride"

    /// Variables child processes (agent-core, Claude Code, the Terminal tab)
    /// may inherit from AgentX. Everything else is dropped: if AgentX itself
    /// was started from inside another Claude Code session, its environment
    /// carries that session's id, API proxy and sockets, and passing those on
    /// would make Claude Code borrow the other app's login and identity.
    static let inheritedVariables: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
        "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING",
    ]

    /// A clean environment for child processes. Callers set PATH (usually
    /// `ToolPaths.shellPath`) and anything else they need explicitly.
    public static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { inheritedVariables.contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    /// Runs on a background thread: it may start a login shell.
    public static func resolve() async -> ToolPaths {
        await Task.detached(priority: .userInitiated) { resolveSync() }.value
    }

    private static let cacheKey = "cachedToolPaths"

    /// The paths found last time, if those programs still exist. Starting a
    /// login shell costs about half a second, so launches use this and
    /// re-check in the background.
    public static func cached() -> ToolPaths? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let paths = try? JSONDecoder().decode(ToolPaths.self, from: data),
              let node = paths.node, FileManager.default.isExecutableFile(atPath: node),
              let core = paths.agentCore, FileManager.default.fileExists(atPath: "\(core)/src/index.ts"),
              UserDefaults.standard.string(forKey: nodePathOverrideKey).map({ $0.isEmpty || $0 == node }) ?? true,
              UserDefaults.standard.string(forKey: agentCorePathOverrideKey).map({ $0.isEmpty || $0 == core }) ?? true
        else { return nil }
        return paths
    }

    public static func remember(_ paths: ToolPaths) {
        if let data = try? JSONEncoder().encode(paths) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }

    /// Cached paths now (and a fresh lookup saved for next time), or a lookup if there's no cache.
    public static func fast() async -> ToolPaths {
        if let cached = cached() {
            Task.detached(priority: .background) { remember(resolveSync()) }
            return cached
        }
        let fresh = await resolve()
        remember(fresh)
        return fresh
    }

    private static func resolveSync() -> ToolPaths {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let shell = loginShellLookup()
        let shellPath = shell.path ?? env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        let agentCore = firstExisting([
            defaults.string(forKey: agentCorePathOverrideKey),
            env["AGENTX_CORE_PATH"],
            Bundle.main.object(forInfoDictionaryKey: "AgentXCorePath") as? String,
            Bundle.main.resourceURL?.appendingPathComponent("agent-core").path,
        ], isDirectory: true)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let node = firstExisting([
            defaults.string(forKey: nodePathOverrideKey),
            env["AGENTX_NODE"],
            shell.node,
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            newestNvmNode(home: home),
        ])

        let bundledClaude = agentCore.map { "\($0)/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude" }
        let claude = firstExisting([
            shell.claude,
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            bundledClaude,
        ])

        return ToolPaths(node: node, claude: claude, agentCore: agentCore, shellPath: shellPath)
    }

    private static func firstExisting(_ candidates: [String?], isDirectory: Bool = false) -> String? {
        let fm = FileManager.default
        for case let path? in candidates where !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDir) else { continue }
            if isDirectory ? isDir.boolValue : (!isDir.boolValue && fm.isExecutableFile(atPath: expanded)) {
                return expanded
            }
        }
        return nil
    }

    private static func newestNvmNode(home: String) -> String? {
        let dir = "\(home)/.nvm/versions/node"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let newest = versions.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last
        return newest.map { "\(dir)/\($0)/bin/node" }
    }

    /// Ask an interactive login shell for PATH, node and claude (nvm and
    /// friends are usually set up in ~/.zshrc, which only interactive shells read).
    private static func loginShellLookup() -> (path: String?, node: String?, claude: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = #"printf '\n__AGENTX__\n%s\n%s\n%s\n' "$PATH" "$(command -v node)" "$(command -v claude)""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", script]
        process.environment = baseEnvironment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (nil, nil, nil) }

        // Don't let a slow shell config hang startup.
        let deadline = DispatchTime.now() + 5
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { process.waitUntilExit(); group.leave() }
        if group.wait(timeout: deadline) == .timedOut { process.terminate(); return (nil, nil, nil) }

        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let marker = text.range(of: "__AGENTX__\n") else { return (nil, nil, nil) }
        let lines = text[marker.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func value(_ i: Int) -> String? { lines.indices.contains(i) && !lines[i].isEmpty ? lines[i] : nil }
        return (value(0), value(1), value(2))
    }
}
