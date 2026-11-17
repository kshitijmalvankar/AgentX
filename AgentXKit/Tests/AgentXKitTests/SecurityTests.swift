import Foundation
import Testing
@testable import AgentXKit

@Suite("Path guard")
struct PathGuardTests {
    let home = "/Users/alex"

    // The same examples as agent-core/test/policy.test.ts, so the two copies of the rules stay in step.
    @Test(arguments: [
        "/Users/alex/.ssh/id_ed25519",
        "/Users/alex/.ssh",
        "/Users/alex/.aws/credentials",
        "/Users/alex/.config/gh/hosts.yml",
        "/Users/alex/Library/Keychains/login.keychain-db",
        "/Users/alex/Library/Cookies/Cookies.binarycookies",
        "/Users/alex/Library/Application Support/Google/Chrome/Default/Login Data",
        "/Users/alex/.claude/.credentials.json",
        "/Users/alex/Projects/app/.env",
        "/Users/alex/Projects/app/.env.local",
        "/Users/alex/Downloads/server.pem",
        "/Users/alex/certs/tls-private.key",
        "/Users/alex/Library/Application Support/AgentX/route-token",
        "/Users/alex/Library/Application Support/AgentX Dev/activity.jsonl",
    ])
    func blocksSecrets(_ path: String) {
        #expect(PathGuard.reason(forPath: path, home: home, exceptions: []) != nil, "\(path)")
    }

    @Test(arguments: [
        "/Users/alex/Documents/Budget.numbers",
        "/Users/alex/Desktop/Talk.key",
        "/Users/alex/Projects/app/src/env.ts",
        "/Users/alex/.sshrc-notes.md",
        "/Users/alex/Library/Application Support/AgentX/automations.json",
    ])
    func allowsOrdinaryFiles(_ path: String) {
        #expect(PathGuard.reason(forPath: path, home: home, exceptions: []) == nil, "\(path)")
    }

    @Test func exceptionsOpenOneFolderOnly() {
        let exceptions = ["/Users/alex/.config/gh"]
        #expect(PathGuard.reason(forPath: "/Users/alex/.config/gh/config.yml", home: home, exceptions: exceptions) == nil)
        #expect(PathGuard.reason(forPath: "/Users/alex/.config/ghost/x", home: home, exceptions: exceptions) == nil)
        #expect(PathGuard.reason(forPath: "/Users/alex/.ssh/id_rsa", home: home, exceptions: exceptions) != nil)
    }

    @Test func symlinksAreFollowed() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathguard-\(UUID().uuidString)").resolvingSymlinksInPath()
        let ssh = root.appendingPathComponent(".ssh")
        try fm.createDirectory(at: ssh, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))
        let desktop = root.appendingPathComponent("Desktop")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: desktop.appendingPathComponent("keys"), withDestinationURL: ssh)
        defer { try? fm.removeItem(at: root) }

        let viaLink = desktop.appendingPathComponent("keys/id_ed25519")
        #expect(PathGuard.reason(for: viaLink, home: root.path, exceptions: []) != nil)
        #expect(PathGuard.reason(for: desktop.appendingPathComponent("notes.txt"), home: root.path, exceptions: []) == nil)
    }

    @Test func macToolsRefuseProtectedPaths() {
        let args = ToolArguments(values: ["path": "~/.ssh/id_ed25519"])
        #expect(throws: ToolError.self) { try args.path("path") }
        let fine = ToolArguments(values: ["path": "~/Desktop/notes.txt"])
        #expect((try? fine.path("path")) != nil)
    }
}

@Suite("Links")
struct URLRouteTests {
    let token = String(repeating: "ab", count: 32)

    func parse(_ s: String) -> Result<URLRoute, URLRoute.Refusal> {
        URLRoute.parse(URL(string: s)!, scheme: "agentx", token: token)
    }

    @Test func sectionsAndLauncherNeedNoToken() {
        #expect(parse("agentx://system") == .success(.section(.system)))
        #expect(parse("agentx://launcher") == .success(.launcher(prefill: nil)))
        #expect(parse("agentx://ask?q=summarize%20this") == .success(.launcher(prefill: "summarize this")))
        #expect(parse("agentx://approvals") == .success(.approvals))
    }

    @Test func prefillIsCapped() throws {
        let long = String(repeating: "x", count: 5000)
        guard case .success(.launcher(let text)) = parse("agentx://ask?q=\(long)") else { Issue.record("not a launcher link"); return }
        #expect(text?.count == URLRoute.prefillLimit)
    }

    @Test func actionsNeedTheToken() {
        let id = UUID()
        #expect(parse("agentx://run/\(id.uuidString)") == .failure(.missingToken))
        #expect(parse("agentx://run/\(id.uuidString)?t=nope") == .failure(.missingToken))
        #expect(parse("agentx://run/\(id.uuidString)?t=\(token)") == .success(.runAutomation(id)))
        #expect(parse("agentx://stop") == .failure(.missingToken))
        #expect(parse("agentx://stop?t=\(token)") == .success(.stopEverything))
    }

    @Test func otherSchemesAndUnknownLinksAreRefused() {
        #expect(parse("agentx-dev://system") == .failure(.wrongScheme))
        #expect(parse("https://system") == .failure(.wrongScheme))
        #expect(parse("agentx://format-disk") == .failure(.unknown))
        #expect(parse("agentx://run/not-a-uuid?t=\(token)") == .failure(.unknown))
    }

    @Test func tokenIsCreatedOnceAndPrivate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("token-\(UUID().uuidString)/route-token")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = RouteToken.current(at: url)
        #expect(first.count == 64)
        #expect(RouteToken.current(at: url) == first)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(RouteToken.matches(first, token: first))
        let wrong = String(first.dropLast()) + (first.hasSuffix("0") ? "1" : "0")
        #expect(!RouteToken.matches(wrong, token: first))
        #expect(!RouteToken.matches(nil, token: first))
    }
}

@Suite("Activity log")
@MainActor
struct ActivityLogTests {
    @Test func appendsAndReloadsNewestFirst() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)/activity.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = ActivityLog(fileURL: url)
        log.record(.tool, "ran", tool: "mcp__agentx__notes_create", detail: "Groceries")
        log.record(.policy, "blocked", tool: "Read", detail: "SSH keys")
        #expect(log.recent.first?.action == "blocked")
        #expect(log.recent.first?.toolLabel == "Read")
        #expect(log.recent.last?.toolLabel == "notes_create")

        // Writes happen on a background queue; wait for them.
        let deadline = Date().addingTimeInterval(2)
        while (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 0 < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let reloaded = ActivityLog(fileURL: url)
        #expect(reloaded.recent.map(\.action) == ["blocked", "ran"])
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func dropsEntriesPastRetention() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)/activity.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let old = ActivityEntry(date: Date().addingTimeInterval(-40 * 86_400), kind: .tool, action: "ran", detail: "old")
        let new = ActivityEntry(kind: .tool, action: "ran", detail: "new")
        let body = try [old, new].map { try encoder.encode($0) + Data([0x0A]) }.reduce(Data(), +)
        try SecureFile.write(body, to: url)

        let log = ActivityLog(fileURL: url)
        #expect(log.recent.map(\.detail) == ["new"])
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
    }
}

@Suite("Security settings")
struct SecuritySettingsTests {
    @Test func broadFoldersAreNeverTrusted() {
        let home = "/Users/alex"
        let roots = SecuritySettings.trustedRoots(from: [
            "/Users/alex", "/Users/alex/Downloads", "/Users/alex/Downloads/unzipped", "/Users/alex/Desktop",
            "/Users/alex/Projects/AgentX", "/Users/alex/Projects/AgentX", "/Users/alex/Library/Mobile Documents/x",
            "/Users/alex/.config/thing", "/tmp/scratch", "/Users/alex/Code/site/",
        ], home: home)
        #expect(roots == ["/Users/alex/Projects/AgentX", "/Users/alex/Code/site"])
    }

    @Test func untrustedToolsAreMarked() throws {
        let defs = try #require(MacToolbox.definitions.array)
        let untrusted = Set(defs.filter { $0["untrusted"]?.string != nil }.compactMap { $0["name"]?.string })
        #expect(untrusted == ["mail_recent", "notes_search", "calendar_events", "clipboard_read"])
    }

    @Test func devIsTheDefaultChannelOutsideTheApp() {
        // Tests and `swift run AgentXDev` have no Info.plist channel: they must never touch the installed app's data.
        #expect(AppChannel.current == .dev)
        #expect(AppChannel.current.dataDirectory.lastPathComponent == "AgentX Dev")
        #expect(AppChannel.stable.urlScheme == "agentx")
        #expect(AppChannel.dev.urlScheme == "agentx-dev")
    }
}
