import Foundation
import SwiftUI
import Testing
@testable import AgentXKit

@Suite("GitHub parsing")
struct GitHubParsingTests {
    private func viewer() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"login":"octo","name":"Octo Cat","avatarUrl":"https://avatars.githubusercontent.com/u/1",
         "contributionsCollection":{"contributionCalendar":{"totalContributions":7,"weeks":[
           {"contributionDays":[{"date":"2026-11-13","contributionCount":0,"contributionLevel":"NONE"},
                                {"date":"2026-11-14","contributionCount":3,"contributionLevel":"SECOND_QUARTILE"}]},
           {"contributionDays":[{"date":"2026-11-15","contributionCount":2,"contributionLevel":"FIRST_QUARTILE"},
                                {"date":"2026-11-16","contributionCount":2,"contributionLevel":"FOURTH_QUARTILE"},
                                {"date":"2026-11-17","contributionCount":0,"contributionLevel":"NONE"}]}]}},
         "repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
           {"nameWithOwner":"octo/AgentX","name":"AgentX","description":"Mac app","url":"https://github.com/octo/AgentX",
            "isPrivate":false,"isFork":false,"isArchived":false,"pushedAt":"2026-11-16T19:17:40Z","stargazerCount":3,
            "primaryLanguage":{"name":"Swift","color":"#F05138"},"issues":{"totalCount":2},"pullRequests":{"totalCount":1}},
           {"nameWithOwner":"octo/old","name":"old","description":null,"url":"https://github.com/octo/old",
            "isPrivate":true,"isFork":true,"isArchived":true,"pushedAt":null,"stargazerCount":0,
            "primaryLanguage":null,"issues":{"totalCount":0},"pullRequests":{"totalCount":0}}]}}
        """#.utf8))
    }

    @Test func parsesProfileCalendarAndRepos() throws {
        let v = try viewer()
        #expect(GitHubParser.profile(v).login == "octo")
        let cal = GitHubParser.calendar(v)
        #expect(cal.total == 7 && cal.weeks.count == 2 && cal.days.count == 5)
        #expect(cal.days.map(\.level) == [0, 2, 1, 4, 0])
        let repos = GitHubParser.repos(v)
        #expect(repos.count == 2)
        #expect(repos[0].language == "Swift" && repos[0].openIssues == 2 && repos[0].openPRs == 1 && repos[0].pushedAt != nil)
        #expect(repos[1].isPrivate && repos[1].isFork && repos[1].isArchived && repos[1].pushedAt == nil && repos[1].language == nil)
        #expect(Color(hexString: repos[0].languageColor) != nil)
    }

    @Test func streaksIgnoreAnUnfinishedToday() throws {
        let cal = GitHubParser.calendar(try viewer())
        // ... 14 (3), 15 (2), 16 (2), 17 today (0) → today doesn't break the streak.
        #expect(cal.currentStreak == 3)
        #expect(cal.longestStreak == 3)
        #expect(cal.activeDays == 3)
    }

    @Test func recognisesGitHubRemotes() {
        #expect(GitHubParser.repoKey(fromRemote: "https://github.com/Octo/AgentX.git") == "octo/agentx")
        #expect(GitHubParser.repoKey(fromRemote: "git@github.com:octo/AgentX.git\n") == "octo/agentx")
        #expect(GitHubParser.repoKey(fromRemote: "ssh://git@github.com/octo/AgentX") == "octo/agentx")
        #expect(GitHubParser.repoKey(fromRemote: "https://gitlab.com/octo/AgentX.git") == nil)
        #expect(GitHubParser.repoKey(fromRemote: "https://github.com/octo") == nil)
    }

    @Test func parsesGitStatus() {
        let porcelain = """
        # branch.oid 1234
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 abc abc README.md
        ? new.swift
        """
        let s = GitHubParser.status(porcelain)
        #expect(s.branch == "main" && s.changes == 2 && s.ahead == 2 && s.behind == 1)
        let clone = LocalClone(path: "/x", branch: "main", changes: 2, ahead: 2, behind: 1)
        #expect(clone.summary == "2 changes · 2 to push · 1 to pull")
        #expect(LocalClone(path: "/x", branch: nil, changes: 0, ahead: 0, behind: 0).summary == "Up to date")
    }
}

@Suite("GitHub on this Mac")
struct GitHubLiveTests {
    /// AGENTX_LIVE_GITHUB=1 swift test --filter GitHubLive   (uses your gh login; prints counts only)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTX_LIVE_GITHUB"] != nil))
    func fetchesRealSnapshot() async throws {
        let gh = try #require(GitHubService.locateCLI(shellPath: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"))
        let s = try await GitHubService.fetch(gh: gh, path: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(!s.profile.login.isEmpty)
        #expect(s.calendar.weeks.count >= 52)
        #expect(!s.repos.isEmpty)
        let clones = await GitHubService.localClones(candidates: [])
        let matched = s.repos.filter { clones[$0.nameWithOwner.lowercased()] != nil }.count
        print("=== GitHub live: \(s.repos.count) repos, \(s.calendar.total) contributions, streak \(s.calendar.currentStreak), \(clones.count) local clones (\(matched) matched to your repos), \(clones.values.filter { !$0.isClean }.count) with local work")
    }
}

@Suite("Keeping clones current")
struct CloneWatchTests {
    private let dirs = ["/users/me/projects/agentx/.git": "/Users/me/Projects/AgentX",
                        "/users/me/projects/news/.git": "/Users/me/Projects/news"]

    @Test func aCommitRechecksThatRepoOnly() {
        let change = GitHubParser.repoChanges([
            "/Users/me/Projects/AgentX/.git/index",
            "/Users/me/Projects/AgentX/.git/refs/heads/main",
            "/Users/me/Projects/AgentX/.git/logs/HEAD",
        ], gitDirs: dirs)
        #expect(change.repos == ["/Users/me/Projects/AgentX"])
        #expect(!change.remoteMoved)
    }

    @Test func aPushMovesTheRemoteBranch() {
        let change = GitHubParser.repoChanges(["/Users/me/Projects/news/.git/refs/remotes/origin/main"], gitDirs: dirs)
        #expect(change.repos == ["/Users/me/Projects/news"])
        #expect(change.remoteMoved)
    }

    @Test func objectsLocksAndOtherFoldersAreIgnored() {
        let change = GitHubParser.repoChanges([
            "/Users/me/Projects/AgentX/.git/objects/ab/cdef",
            "/Users/me/Projects/AgentX/.git/index.lock",
            "/Users/me/Projects/AgentX/README.md",
            "/Users/me/Projects/agentx-old/.git/index",
        ], gitDirs: dirs)
        #expect(change.repos.isEmpty)
    }

    @Test func findsTheGitFolderOfAWorktree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentx-gitdir-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo"), worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: ../repo/.git/worktrees/wt\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(GitHubService.gitDirectory(of: repo.path) == repo.path + "/.git")
        #expect(GitHubService.gitDirectory(of: worktree.path) == repo.path + "/.git/worktrees/wt")
        #expect(GitHubService.gitDirectory(of: root.path) == nil)
    }
}
