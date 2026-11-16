import Foundation

/// Local git repositories (used by the Repo check automation).
enum CodeTools {
    static var all: [MacTool] {[
        MacTool("repos_status", area: "Code", summary: "Check local repositories", risk: .read,
                description: "Status of the git repositories on this Mac that come from GitHub: branch, uncommitted changes, and commits to push or pull. Looks in ~/Projects, ~/Developer, ~/Code and folders used with Claude Code. Read-only.") { _ in
            let projects = await MainActor.run { AppModel.shared.sessions.recentProjects }
            let clones = await GitHubService.localClones(candidates: projects)
            guard !clones.isEmpty else { return "No GitHub repositories found on this Mac." }
            // Repos with work in them first.
            return clones.sorted { a, b in
                a.value.isClean != b.value.isClean ? !a.value.isClean : a.key < b.key
            }.map { key, clone in
                "• \(key) at \((clone.path as NSString).abbreviatingWithTildeInPath) on \(clone.branch ?? "a detached HEAD"): \(clone.summary)"
            }.joined(separator: "\n")
        },
    ]}
}
