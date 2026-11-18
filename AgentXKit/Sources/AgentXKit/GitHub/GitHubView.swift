import AppKit
import SwiftUI

/// GitHub section: profile, contribution calendar, and every repo with its
/// state on GitHub and on this Mac.
struct GitHubView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: RepoFilter = .all
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\GitHubRepo.pushedSort, order: .reverse)]
    @State private var selection: GitHubRepo.ID?

    private var store: GitHubStore { model.github }

    enum RepoFilter: String, CaseIterable, Identifiable {
        case all = "All", active = "Active", privateOnly = "Private", publicOnly = "Public", forks = "Forks", archived = "Archived"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if let snapshot = store.snapshot {
                content(snapshot)
            } else {
                GitHubSetupView()
            }
        }
        .navigationTitle("GitHub")
        .toolbar {
            Button {
                store.refresh()
            } label: {
                if store.isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .help("Refresh from GitHub")
            .disabled(store.isRefreshing)
        }
        .onAppear { store.refreshIfStale() }
    }

    private func content(_ snapshot: GitHubSnapshot) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                profileHeader(snapshot)
                stats(snapshot)
                GlassCard("Contributions", symbol: "square.grid.3x3.fill") {
                    Text("Streak \(snapshot.calendar.currentStreak) day\(snapshot.calendar.currentStreak == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } content: {
                    ContributionGraph(calendar: snapshot.calendar, cell: 12)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("Show", selection: $filter) {
                        ForEach(RepoFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    TextField("Filter repositories", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            repoTable(snapshot)
        }
    }

    // MARK: Header and stats

    private func profileHeader(_ s: GitHubSnapshot) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: s.profile.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
            }
            .frame(width: 48, height: 48)
            .clipShape(.circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.profile.name ?? s.profile.login).font(.title2.bold())
                Text("@\(s.profile.login) · updated \(s.fetchedAt.relative)").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open on GitHub", systemImage: "arrow.up.forward.square") {
                if let url = URL(string: "https://github.com/\(s.profile.login)") { NSWorkspace.shared.open(url) }
            }
            .secondaryButton()
        }
    }

    private func stats(_ s: GitHubSnapshot) -> some View {
        let privateCount = s.repos.filter(\.isPrivate).count
        let prs = s.repos.reduce(0) { $0 + $1.openPRs }
        let issues = s.repos.reduce(0) { $0 + $1.openIssues }
        let dirty = store.clones.values.filter { !$0.isClean }.count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            StatTile(title: "Repositories", value: "\(s.repos.count)", caption: "\(privateCount) private · \(s.repos.count - privateCount) public")
            StatTile(title: "Contributions", value: "\(s.calendar.total)", caption: "\(s.calendar.activeDays) active days this year")
            StatTile(title: "Current streak", value: "\(s.calendar.currentStreak)d", caption: "Longest \(s.calendar.longestStreak) days")
            StatTile(title: "Open PRs · issues", value: "\(prs) · \(issues)", caption: "Across your repositories")
            StatTile(title: "On this Mac", value: "\(store.clones.count)", caption: dirty == 0 ? "All clean" : "\(dirty) with unpushed or uncommitted work")
        }
    }

    // MARK: Repos

    private func filtered(_ s: GitHubSnapshot) -> [GitHubRepo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let ninetyDays = Date().addingTimeInterval(-90 * 86_400)
        return s.repos.filter { r in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .active: r.pushedSort > ninetyDays && !r.isArchived
            case .privateOnly: r.isPrivate
            case .publicOnly: !r.isPrivate
            case .forks: r.isFork
            case .archived: r.isArchived
            }
            let matchesSearch = q.isEmpty || r.nameWithOwner.lowercased().contains(q) || (r.description ?? "").lowercased().contains(q)
                || (r.language ?? "").lowercased().contains(q)
            return matchesFilter && matchesSearch
        }
        .sorted(using: sortOrder)
    }

    private func repoTable(_ s: GitHubSnapshot) -> some View {
        Table(filtered(s), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Repository", value: \.name) { repo in RepoNameCell(repo: repo) }
                .width(min: 220, ideal: 320)
            TableColumn("Language", value: \.languageSort) { repo in
                if let language = repo.language {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hexString: repo.languageColor) ?? .secondary).frame(width: 9, height: 9)
                        Text(language)
                    }
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Stars", value: \.stars) { repo in Text("\(repo.stars)").monospacedDigit() }
                .width(50)
            TableColumn("Issues", value: \.openIssues) { repo in count(repo.openIssues) }
                .width(50)
            TableColumn("PRs", value: \.openPRs) { repo in count(repo.openPRs) }
                .width(44)
            TableColumn("Last push", value: \.pushedSort) { repo in
                Text(repo.pushedAt?.relative ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("On this Mac") { repo in
                if let clone = store.clone(of: repo) {
                    Label(clone.summary, systemImage: clone.isClean ? "checkmark.circle" : "circle.dotted.circle")
                        .foregroundStyle(clone.isClean ? Color.secondary : Color.orange)
                        .help(clone.path.abbreviatingHome + (clone.branch.map { " · \($0)" } ?? ""))
                } else {
                    Text("Not cloned").foregroundStyle(.tertiary)
                }
            }
            .width(min: 120, ideal: 170)
        }
        .contextMenu(forSelectionType: GitHubRepo.ID.self) { ids in
            if let repo = ids.first.flatMap({ id in s.repos.first { $0.id == id } }) {
                Button("Open on GitHub", systemImage: "arrow.up.forward.square") { open(repo) }
                if let clone = store.clone(of: repo) {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: clone.path)])
                    }
                    Button("New Session Here", systemImage: "terminal") {
                        model.pendingNewSessionFolder = clone.path
                        model.showNewSession = true
                    }
                }
                Divider()
                Button("Copy URL", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(repo.url?.absoluteString ?? repo.nameWithOwner, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let repo = ids.first.flatMap({ id in s.repos.first { $0.id == id } }) { open(repo) }
        }
    }

    @ViewBuilder private func count(_ n: Int) -> some View {
        Text(n == 0 ? "—" : "\(n)").monospacedDigit().foregroundStyle(n == 0 ? .tertiary : .primary)
    }

    private func open(_ repo: GitHubRepo) {
        if let url = repo.url { NSWorkspace.shared.open(url) }
    }
}

private struct RepoNameCell: View {
    let repo: GitHubRepo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if repo.isPrivate { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                Text(repo.name).fontWeight(.medium)
                if repo.isFork { tag("fork") }
                if repo.isArchived { tag("archived") }
            }
            if let description = repo.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(repo.nameWithOwner)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: .capsule)
            .foregroundStyle(.secondary)
    }
}

/// A labelled number for the GitHub header.
struct StatTile: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .agentCard)
    }
}

/// Shown until GitHub is reachable: install gh, sign in, or retry.
struct GitHubSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showSignIn = false

    var body: some View {
        let store = model.github
        Group {
            switch store.state {
            case .idle, .loading, .loaded:
                ProgressView("Loading your GitHub…")
            case .needsCLI:
                ContentUnavailableView {
                    Label("Connect GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                } description: {
                    Text("AgentX reads GitHub through the GitHub CLI, so it never needs your password or a token. Install it with Homebrew: brew install gh")
                } actions: {
                    Button("Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install gh", forType: .string)
                    }
                    Button("Check Again") { store.refresh() }.secondaryButton()
                }
            case .needsSignIn:
                ContentUnavailableView {
                    Label("Sign in to GitHub", systemImage: "person.badge.key")
                } description: {
                    Text("The GitHub CLI isn't signed in. Sign in once in your browser; AgentX never sees your credentials.")
                } actions: {
                    Button("Sign In…") { showSignIn = true }.primaryButton()
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't reach GitHub", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { store.refresh() }.secondaryButton()
                }
            }
        }
        .sheet(isPresented: $showSignIn) { GitHubSignInSheet() }
    }
}

/// Runs `gh auth login` in a terminal so you can sign in with your browser.
private struct GitHubSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private static let terminalID = "gh-login"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to GitHub").font(.title2.bold())
            Text("Follow the prompts below. Choose GitHub.com and \"Login with a web browser\".")
                .foregroundStyle(.secondary)
            if let terminal = model.terminals.session(for: Self.terminalID) {
                TerminalView(session: terminal)
                    .frame(minHeight: 320)
                    .clipShape(.rect(cornerRadius: Radius.inset))
            }
            HStack {
                Spacer()
                Button("Done") {
                    model.terminals.stop(Self.terminalID)
                    dismiss()
                    model.github.refresh()
                }
                .primaryButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 500)
        .onAppear {
            guard let gh = model.github.ghPath else { return }
            model.terminals.start(id: Self.terminalID, executable: gh, arguments: ["auth", "login"],
                                  directory: NSHomeDirectory(), environment: model.terminalEnvironment)
        }
    }
}

/// Dashboard card: the contribution calendar and your most recently pushed repos.
struct GitHubActivityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.github
        GlassCard("GitHub Activity", symbol: "chevron.left.forwardslash.chevron.right", tint: Color(red: 0.2, green: 0.22, blue: 0.27)) {
            HStack(spacing: 10) {
                if let s = store.snapshot {
                    Text("@\(s.profile.login) · streak \(s.calendar.currentStreak)d")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Details") { model.sidebar = .github }.buttonStyle(.link)
            }
        } content: {
            if let s = store.snapshot {
                HStack(alignment: .top, spacing: 24) {
                    ContributionGraph(calendar: s.calendar, cell: 10)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recently pushed").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(s.repos.filter { !$0.isArchived }.prefix(4)) { repo in
                            RecentRepoRow(repo: repo, clone: store.clone(of: repo))
                        }
                    }
                    .frame(width: 250, alignment: .leading)
                }
            } else {
                switch store.state {
                case .needsCLI, .needsSignIn, .failed:
                    HStack {
                        Text("Connect GitHub to see your contributions and repositories.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Set Up") { model.sidebar = .github }.secondaryButton()
                    }
                default:
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { store.refreshIfStale() }
    }
}

private struct RecentRepoRow: View {
    let repo: GitHubRepo
    let clone: LocalClone?

    var body: some View {
        Button {
            if let url = repo.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(hexString: repo.languageColor) ?? .secondary).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.name).lineLimit(1)
                    Text([repo.pushedAt.map { "pushed \($0.relative)" }, clone.flatMap { $0.isClean ? nil : $0.summary }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(clone.map { $0.isClean } == false ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open \(repo.nameWithOwner) on GitHub")
    }
}

extension Color {
    /// "#f05138" → Color.
    init?(hexString: String?) {
        guard var s = hexString?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
