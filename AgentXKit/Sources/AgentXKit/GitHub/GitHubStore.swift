import Foundation
import Observation

/// Your GitHub snapshot, refreshed when something shows it (at most every 10
/// minutes, and soon after you push), and your clones on this Mac, kept
/// current as you commit, push and pull.
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

    // Clones: a full scan now and then, and a watch on each one's git folder in between.
    @ObservationIgnored private var clonesScannedAt: Date?
    @ObservationIgnored private var isScanningClones = false
    @ObservationIgnored private var repoWatcher: DirectoryWatcher?
    /// Lowercased git folder → repo folder.
    @ObservationIgnored private var gitDirs: [String: String] = [:]
    @ObservationIgnored private var checking: Set<String> = []
    @ObservationIgnored private var checkAgain: Set<String> = []
    @ObservationIgnored private var afterPush: Task<Void, Never>?

    public init() {}

    public var ghPath: String? { GitHubService.locateCLI(shellPath: context().shellPath) }

    public func clone(of repo: GitHubRepo) -> LocalClone? { clones[repo.nameWithOwner.lowercased()] }

    /// GitHub when it's older than `maxAge`; your clones when they're older than half a minute
    /// (commits and pushes show up by themselves, but edits to files don't).
    public func refreshIfStale(maxAge: TimeInterval = 600) {
        if let fetched = snapshot?.fetchedAt, Date().timeIntervalSince(fetched) < maxAge {
            if Date().timeIntervalSince(clonesScannedAt ?? .distantPast) > 30 { scanClones() }
            return
        }
        refresh()
    }

    /// GitHub and your clones, now.
    public func refresh() {
        scanClones()
        refreshRemote()
    }

    private func refreshRemote() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if snapshot == nil { state = .loading }
        let shellPath = context().shellPath
        refreshTask = Task {
            defer { isRefreshing = false }
            guard let gh = GitHubService.locateCLI(shellPath: shellPath) else {
                state = .needsCLI
                return
            }
            let path = shellPath ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
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
        }
    }

    // MARK: Clones on this Mac

    private func scanClones() {
        guard !isScanningClones else { return }
        isScanningClones = true
        let projects = context().projects
        Task {
            let found = await GitHubService.localClones(candidates: projects)
            if found != clones { clones = found }
            clonesScannedAt = Date()
            isScanningClones = false
            watch(found.values.map(\.path))
        }
    }

    /// Watch each clone's git folder, so a commit, push, pull or checkout re-reads that clone.
    private func watch(_ folders: [String]) {
        var dirs: [String: String] = [:]
        for folder in folders {
            guard let dir = GitHubService.gitDirectory(of: folder) else { continue }
            // FSEvents reports real paths.
            dirs[URL(fileURLWithPath: dir).resolvingSymlinksInPath().path.lowercased()] = folder
        }
        guard dirs != gitDirs || repoWatcher == nil else { return }
        repoWatcher?.stop()
        gitDirs = dirs
        let watcher = DirectoryWatcher(paths: Array(dirs.keys), latency: 1) { [weak self] paths in
            Task { @MainActor in self?.gitChanged(paths) }
        }
        watcher.start()
        repoWatcher = watcher
    }

    private func gitChanged(_ paths: [String]) {
        let (repos, remoteMoved) = GitHubParser.repoChanges(paths, gitDirs: gitDirs)
        repos.forEach(recheck)
        if remoteMoved { refreshAfterPush() }
    }

    /// Re-read one clone (one at a time per folder, again if it changed meanwhile).
    private func recheck(_ folder: String) {
        guard !checking.contains(folder) else { checkAgain.insert(folder); return }
        checking.insert(folder)
        Task {
            if let (key, clone) = await GitHubService.localClone(at: folder) {
                // If a repo is cloned twice, the one with work in it stays.
                let existing = clones[key]
                let keepOther = existing.map { $0.path != folder && $0.changes + $0.ahead >= clone.changes + clone.ahead } ?? false
                if !keepOther, existing != clone { clones[key] = clone }
            }
            checking.remove(folder)
            if checkAgain.remove(folder) != nil { recheck(folder) }
        }
    }

    /// A branch moved on GitHub (you pushed): reload GitHub in a few seconds, and once more
    /// a minute later, since GitHub can take a moment to count the commits.
    private func refreshAfterPush() {
        afterPush?.cancel()
        afterPush = Task {
            for delay in [5, 60] {
                do {
                    try await Task.sleep(for: .seconds(delay))
                    while isRefreshing { try await Task.sleep(for: .seconds(1)) }
                } catch { return }
                refreshRemote()
            }
        }
    }
}
