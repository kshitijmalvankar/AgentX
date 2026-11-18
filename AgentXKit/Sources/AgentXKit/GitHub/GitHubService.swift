import Foundation

enum GitHubError: LocalizedError, Equatable {
    case cliMissing
    case notSignedIn
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cliMissing: "The GitHub CLI (gh) isn't installed."
        case .notSignedIn: "The GitHub CLI isn't signed in."
        case .failed(let message): message
        }
    }
}

/// Reads GitHub through the `gh` CLI you're already signed in to, so AgentX
/// never sees or stores a GitHub token. Local clone status comes from `git`.
enum GitHubService {
    static let query = """
    query($after: String) {
      viewer {
        login
        name
        avatarUrl(size: 96)
        contributionsCollection {
          contributionCalendar {
            totalContributions
            weeks { contributionDays { date contributionCount contributionLevel } }
          }
        }
        repositories(first: 100, after: $after, orderBy: {field: PUSHED_AT, direction: DESC},
                     ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]) {
          pageInfo { hasNextPage endCursor }
          nodes {
            nameWithOwner name description url isPrivate isFork isArchived pushedAt stargazerCount
            primaryLanguage { name color }
            issues(states: OPEN) { totalCount }
            pullRequests(states: OPEN) { totalCount }
          }
        }
      }
    }
    """

    /// Your open pull requests (with their checks) and the ones waiting for your review.
    static let pullRequestQuery = """
    query {
      viewer {
        pullRequests(first: 15, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            title url number isDraft updatedAt reviewDecision
            repository { nameWithOwner }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
      search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 15) {
        nodes {
          ... on PullRequest {
            title url number isDraft updatedAt
            author { login }
            repository { nameWithOwner }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    static func fetchPullRequests(gh: String, path: String) async throws -> GitHubPullRequests {
        let result = try await ProcessRunner.run(gh, ["api", "graphql", "-f", "query=\(pullRequestQuery)"], timeout: 30, path: path)
        guard result.status == 0 else { throw classify(result.stderr) }
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
        return GitHubParser.pullRequests(json)
    }

    /// Find `gh` on your login shell's PATH (Homebrew puts it in /opt/homebrew/bin).
    static func locateCLI(shellPath: String?) -> String? {
        let dirs = (shellPath ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { "\($0)/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Profile, contribution calendar and repos (up to 500).
    static func fetch(gh: String, path: String) async throws -> GitHubSnapshot {
        var after: String?
        var profile: GitHubProfile?
        var calendar: ContributionCalendar?
        var repos: [GitHubRepo] = []
        for _ in 0..<5 {
            var args = ["api", "graphql", "-f", "query=\(query)"]
            if let after { args += ["-f", "after=\(after)"] }
            let result = try await ProcessRunner.run(gh, args, timeout: 30, path: path)
            guard result.status == 0 else { throw classify(result.stderr) }
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
            if let errors = json["errors"]?.array, !errors.isEmpty {
                throw GitHubError.failed(errors.compactMap { $0["message"]?.string }.joined(separator: "\n"))
            }
            guard let viewer = json["data"]?["viewer"] else { throw GitHubError.failed("GitHub returned no data.") }
            if profile == nil {
                profile = GitHubParser.profile(viewer)
                calendar = GitHubParser.calendar(viewer)
            }
            repos += GitHubParser.repos(viewer)
            let page = viewer["repositories"]?["pageInfo"]
            guard page?["hasNextPage"]?.bool == true, let cursor = page?["endCursor"]?.string else { break }
            after = cursor
        }
        guard let profile, let calendar else { throw GitHubError.failed("GitHub returned no profile.") }
        return GitHubSnapshot(profile: profile, calendar: calendar, repos: repos, fetchedAt: Date())
    }

    private static func classify(_ stderr: String) -> GitHubError {
        let text = stderr.lowercased()
        if text.contains("gh auth login") || text.contains("not logged") || text.contains("authentication") { return .notSignedIn }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gh failed." : stderr)
    }

    /// Git repos in your project folders that point at github.com, keyed by "owner/repo".
    static func localClones(candidates: [String]) async -> [String: LocalClone] {
        let fm = FileManager.default
        var folders = Set(candidates)
        let home = fm.homeDirectoryForCurrentUser.path
        for root in ["Projects", "Developer", "Code", "GitHub", "src", "repos"] {
            let dir = "\(home)/\(root)"
            if let names = try? fm.contentsOfDirectory(atPath: dir) {
                for name in names where !name.hasPrefix(".") { folders.insert("\(dir)/\(name)") }
            }
        }
        let repos = folders.filter { fm.fileExists(atPath: "\($0)/.git") }.sorted().prefix(120)

        return await withTaskGroup(of: (String, LocalClone)?.self) { group in
            for folder in repos {
                group.addTask {
                    guard let remote = try? await ProcessRunner.run("/usr/bin/git", ["-C", folder, "remote", "get-url", "origin"], timeout: 5),
                          remote.status == 0, let key = GitHubParser.repoKey(fromRemote: remote.stdout) else { return nil }
                    let status = try? await ProcessRunner.run("/usr/bin/git", ["-C", folder, "status", "--porcelain=v2", "--branch"], timeout: 10)
                    let parsed = GitHubParser.status(status?.stdout ?? "")
                    return (key, LocalClone(path: folder, branch: parsed.branch, changes: parsed.changes, ahead: parsed.ahead, behind: parsed.behind))
                }
            }
            var result: [String: LocalClone] = [:]
            for await item in group {
                guard let (key, clone) = item else { continue }
                // If a repo is cloned twice, keep the one with work in it.
                if let existing = result[key], existing.changes + existing.ahead >= clone.changes + clone.ahead { continue }
                result[key] = clone
            }
            return result
        }
    }
}
