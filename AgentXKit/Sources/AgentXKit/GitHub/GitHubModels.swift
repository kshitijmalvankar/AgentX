import Foundation

public struct GitHubProfile: Sendable, Equatable {
    public var login: String
    public var name: String?
    public var avatarURL: URL?
}

public struct ContributionDay: Sendable, Equatable, Identifiable {
    /// "2026-11-16", as GitHub reports it.
    public var day: String
    public var date: Date
    public var count: Int
    /// 0 (none) … 4 (busiest quartile), GitHub's own shading levels.
    public var level: Int
    public var id: String { day }
}

public struct ContributionCalendar: Sendable, Equatable {
    public var total: Int
    /// Weeks run Sunday → Saturday; the first and last may be partial.
    public var weeks: [[ContributionDay]]

    public var days: [ContributionDay] { weeks.flatMap { $0 } }

    /// Days in a row with contributions, ending today (or yesterday, since today isn't over).
    public var currentStreak: Int {
        var days = self.days
        if let last = days.last, last.count == 0 { days.removeLast() }
        var streak = 0
        for day in days.reversed() {
            guard day.count > 0 else { break }
            streak += 1
        }
        return streak
    }

    public var longestStreak: Int {
        var best = 0, run = 0
        for day in days {
            run = day.count > 0 ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    public var activeDays: Int { days.filter { $0.count > 0 }.count }
}

public struct GitHubRepo: Sendable, Identifiable, Hashable {
    public var nameWithOwner: String
    public var name: String
    public var description: String?
    public var url: URL?
    public var isPrivate: Bool
    public var isFork: Bool
    public var isArchived: Bool
    public var pushedAt: Date?
    public var stars: Int
    public var language: String?
    /// "#f05138"
    public var languageColor: String?
    public var openIssues: Int
    public var openPRs: Int

    public var id: String { nameWithOwner }
    /// For sorting (never-pushed repos last).
    public var pushedSort: Date { pushedAt ?? .distantPast }
    public var languageSort: String { language ?? "" }
}

/// A GitHub repo that's also cloned on this Mac.
public struct LocalClone: Sendable, Equatable {
    public var path: String
    public var branch: String?
    /// Modified, staged and untracked files.
    public var changes: Int
    /// Commits not pushed yet / not pulled yet.
    public var ahead: Int
    public var behind: Int

    public var isClean: Bool { changes == 0 && ahead == 0 && behind == 0 }

    public var summary: String {
        var parts: [String] = []
        if changes > 0 { parts.append("\(changes) change\(changes == 1 ? "" : "s")") }
        if ahead > 0 { parts.append("\(ahead) to push") }
        if behind > 0 { parts.append("\(behind) to pull") }
        return parts.isEmpty ? "Up to date" : parts.joined(separator: " · ")
    }
}

/// An open pull request: yours, or one waiting for your review.
public struct GitHubPullRequest: Sendable, Identifiable, Hashable {
    public enum Checks: String, Sendable { case passing, failing, pending, none }

    public var url: URL
    public var title: String
    public var number: Int
    public var repo: String
    public var author: String?
    public var isDraft: Bool
    public var updatedAt: Date?
    public var checks: Checks
    /// APPROVED, CHANGES_REQUESTED or REVIEW_REQUIRED (nil when the repo doesn't require reviews).
    public var review: String?

    public var id: String { url.absoluteString }
    public var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

public struct GitHubPullRequests: Sendable, Equatable {
    public var mine: [GitHubPullRequest]
    public var toReview: [GitHubPullRequest]
    public var fetchedAt: Date
    public var failing: Int { mine.filter { $0.checks == .failing }.count }
}

public struct GitHubSnapshot: Sendable, Equatable {
    public var profile: GitHubProfile
    public var calendar: ContributionCalendar
    public var repos: [GitHubRepo]
    public var fetchedAt: Date
}

/// Turns `gh api graphql` and `git` output into models.
enum GitHubParser {
    static let levels = ["NONE": 0, "FIRST_QUARTILE": 1, "SECOND_QUARTILE": 2, "THIRD_QUARTILE": 3, "FOURTH_QUARTILE": 4]

    static func profile(_ viewer: JSONValue) -> GitHubProfile {
        GitHubProfile(login: viewer["login"]?.string ?? "", name: viewer["name"]?.string,
                      avatarURL: viewer["avatarUrl"]?.string.flatMap(URL.init(string:)))
    }

    static func calendar(_ viewer: JSONValue) -> ContributionCalendar {
        let raw = viewer["contributionsCollection"]?["contributionCalendar"]
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.calendar = Calendar(identifier: .gregorian)
        dayFormat.timeZone = .current
        dayFormat.dateFormat = "yyyy-MM-dd"
        let weeks: [[ContributionDay]] = (raw?["weeks"]?.array ?? []).map { week in
            (week["contributionDays"]?.array ?? []).compactMap { d in
                guard let day = d["date"]?.string, let date = dayFormat.date(from: day) else { return nil }
                return ContributionDay(day: day, date: date, count: d["contributionCount"]?.int ?? 0,
                                       level: levels[d["contributionLevel"]?.string ?? ""] ?? 0)
            }
        }
        return ContributionCalendar(total: raw?["totalContributions"]?.int ?? 0, weeks: weeks.filter { !$0.isEmpty })
    }

    static func pullRequests(_ json: JSONValue, now: Date = Date()) -> GitHubPullRequests {
        let iso = ISO8601DateFormatter()
        func pr(_ n: JSONValue) -> GitHubPullRequest? {
            guard let url = n["url"]?.string.flatMap(URL.init(string:)), let title = n["title"]?.string else { return nil }
            let state = n["commits"]?["nodes"]?.array?.last?["commit"]?["statusCheckRollup"]?["state"]?.string
            let checks: GitHubPullRequest.Checks = switch state {
            case "SUCCESS": .passing
            case "FAILURE", "ERROR": .failing
            case "PENDING", "EXPECTED": .pending
            default: .none
            }
            return GitHubPullRequest(url: url, title: title, number: n["number"]?.int ?? 0,
                                     repo: n["repository"]?["nameWithOwner"]?.string ?? "",
                                     author: n["author"]?["login"]?.string, isDraft: n["isDraft"]?.bool ?? false,
                                     updatedAt: n["updatedAt"]?.string.flatMap(iso.date(from:)), checks: checks,
                                     review: n["reviewDecision"]?.string)
        }
        let data = json["data"]
        return GitHubPullRequests(mine: (data?["viewer"]?["pullRequests"]?["nodes"]?.array ?? []).compactMap(pr),
                                  toReview: (data?["search"]?["nodes"]?.array ?? []).compactMap(pr),
                                  fetchedAt: now)
    }

    static func repos(_ viewer: JSONValue) -> [GitHubRepo] {
        let iso = ISO8601DateFormatter()
        return (viewer["repositories"]?["nodes"]?.array ?? []).compactMap { r in
            guard let full = r["nameWithOwner"]?.string else { return nil }
            return GitHubRepo(
                nameWithOwner: full,
                name: r["name"]?.string ?? full,
                description: r["description"]?.string,
                url: r["url"]?.string.flatMap(URL.init(string:)),
                isPrivate: r["isPrivate"]?.bool ?? false,
                isFork: r["isFork"]?.bool ?? false,
                isArchived: r["isArchived"]?.bool ?? false,
                pushedAt: r["pushedAt"]?.string.flatMap(iso.date(from:)),
                stars: r["stargazerCount"]?.int ?? 0,
                language: r["primaryLanguage"]?["name"]?.string,
                languageColor: r["primaryLanguage"]?["color"]?.string,
                openIssues: r["issues"]?["totalCount"]?.int ?? 0,
                openPRs: r["pullRequests"]?["totalCount"]?.int ?? 0
            )
        }
    }

    /// "owner/repo" (lowercased) for a github.com remote URL, in any of git's forms.
    static func repoKey(fromRemote remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/", "git://github.com/"] {
            if s.lowercased().hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
                if s.hasSuffix("/") { s = String(s.dropLast()) }
                let parts = s.split(separator: "/")
                return parts.count == 2 ? s.lowercased() : nil
            }
        }
        return nil
    }

    /// Parse `git status --porcelain=v2 --branch`.
    static func status(_ porcelain: String) -> (branch: String?, changes: Int, ahead: Int, behind: Int) {
        var branch: String?, changes = 0, ahead = 0, behind = 0
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") {
                changes += 1
            }
        }
        return (branch, changes, ahead, behind)
    }
}
