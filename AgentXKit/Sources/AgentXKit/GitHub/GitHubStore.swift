import Foundation
import Observation

/// Your GitHub snapshot, refreshed when something shows it (at most every 10 minutes).
@MainActor
@Observable
public final class GitHubStore {
    public enum State: Equatable {
        case idle, loading, loaded
        case needsCLI, needsSignIn
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var snapshot: GitHubSnapshot?
    /// Your open pull requests and the ones waiting for your review (dashboard).
    public private(set) var pullRequests: GitHubPullRequests?
    /// "owner/repo" (lowercased) → clone on this Mac.
    public private(set) var clones: [String: LocalClone] = [:]
    public private(set) var isRefreshing = false

    /// Supplies the login shell PATH and known project folders (set by AppModel).
    @ObservationIgnored var context: @MainActor () -> (shellPath: String?, projects: [String]) = { (nil, []) }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Called after each successful refresh (e.g. to update the widgets).
    @ObservationIgnored var onUpdate: (() -> Void)?

    public init() {}

    public var ghPath: String? { GitHubService.locateCLI(shellPath: context().shellPath) }

    public func clone(of repo: GitHubRepo) -> LocalClone? { clones[repo.nameWithOwner.lowercased()] }

    public func refreshIfStale(maxAge: TimeInterval = 600) {
        guard !isRefreshing else { return }
        if let fetched = snapshot?.fetchedAt, Date().timeIntervalSince(fetched) < maxAge { return }
        refresh()
    }

    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if snapshot == nil { state = .loading }
        let (shellPath, projects) = context()
        refreshTask = Task {
            defer { isRefreshing = false }
            guard let gh = GitHubService.locateCLI(shellPath: shellPath) else {
                state = .needsCLI
                return
            }
            let path = shellPath ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            async let local = GitHubService.localClones(candidates: projects)
            do {
                snapshot = try await GitHubService.fetch(gh: gh, path: path)
                state = .loaded
                pullRequests = try? await GitHubService.fetchPullRequests(gh: gh, path: path)
                onUpdate?()
            } catch GitHubError.notSignedIn {
                state = .needsSignIn
            } catch {
                // Keep showing the last snapshot if there is one.
                if snapshot == nil { state = .failed(error.localizedDescription) }
            }
            clones = await local
        }
    }
}
