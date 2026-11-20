import AppKit
import SwiftUI

/// All of AgentX's windows. Both the Xcode app target and `AgentXDev` use this:
///
///     @main struct AgentXApp: App {
///         @NSApplicationDelegateAdaptor(AgentXAppDelegate.self) var delegate
///         var body: some Scene { AgentXScenes() }
///     }
public struct AgentXScenes: Scene {
    @State private var model = AppModel.shared

    public init() {}

    public var body: some Scene {
        Window(AppChannel.current.displayName, id: "main") {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { model.showNewSession = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                    Button(item.title) { model.sidebar = item }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .task { await model.bootstrap() }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// App-level hooks SwiftUI doesn't cover.
@MainActor
public final class AgentXAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationWillFinishLaunching(_ notification: Notification) {
        // agentx:// links come here instead of to SwiftUI, which brings the main window
        // forward for every link (and so closed the launcher a link had just opened).
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        AppModel.shared.handle(url)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare `AgentXDev` binary (no .app bundle).
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        // AgentX Dev wears a badge so it's never mistaken for the installed app.
        if AppChannel.current.isDev { NSApp.dockTile.badgeLabel = "DEV" }
        LauncherController.registerHotkey()
        KillSwitch.registerHotkey()
        // Start the engine (and the automation scheduler) even if no window opens.
        Task { await AppModel.shared.bootstrap() }
    }

    /// Keep running in the menu bar after the window closes.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.terminals.stopAll()
        AppModel.shared.client.stop()
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .overlay(alignment: .top) { EngineBanner() }
        }
        .sheet(isPresented: $model.showNewSession) { NewSessionSheet().environment(model) }
        .sheet(isPresented: $model.showLogin) { LoginSheet().environment(model) }
    }

    @ViewBuilder private var detail: some View {
        switch model.sidebar ?? .dashboard {
        case .dashboard: DashboardView()
        case .chats: ChatsView()
        case .sessions: SessionsView()
        case .github: GitHubView()
        case .system: SystemView()
        case .automations: AutomationsView()
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(badge(for: item))
                        .tag(item)
                }
            }
            let phoneSynced = model.terminals.remoteControlled
            if !phoneSynced.isEmpty {
                Section("On your phone") {
                    ForEach(phoneSynced) { terminal in
                        let c = model.sessions.conversations[terminal.id]
                        Button {
                            model.openSession(c?.sessionId ?? terminal.id)
                        } label: {
                            Label(c?.title ?? "Claude Code session", systemImage: "iphone.radiowaves.left.and.right")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !model.sessions.liveConversations.isEmpty {
                Section("Running") {
                    ForEach(model.sessions.liveConversations) { c in
                        Button {
                            model.openSession(c.sessionId ?? c.id)
                        } label: {
                            HStack {
                                Image(systemName: c.liveState?.symbol ?? "bolt")
                                    .foregroundStyle(c.liveState == .waiting ? .orange : .blue)
                                Text(c.title).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { EngineStatusFooter().padding(10) }
    }

    /// Approvals waiting: coding sessions on Sessions, Mac conversations on Chats.
    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .sessions: model.sessions.approvalCount(kind: .coding)
        case .chats: model.sessions.approvalCount(kind: .assistant)
        default: 0
        }
    }
}

/// Engine status in the sidebar footer.
private struct EngineStatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).lineLimit(1)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var label: String {
        switch model.client.status {
        case .ready: model.account?.account.planLabel ?? "Engine ready"
        case .starting: "Starting engine…"
        case .stopped: "Engine stopped"
        case .failed: "Engine error"
        }
    }

    private var color: Color {
        switch model.client.status {
        case .ready: model.account?.account.isSignedIn == false ? .orange : .green
        case .starting: .yellow
        case .stopped, .failed: .red
        }
    }
}

/// Shown across the top when the engine failed or nobody is signed in.
private struct EngineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .failed(let why) = model.client.status {
            banner(why, symbol: "exclamationmark.triangle.fill", tint: .red) {
                Button("Retry") { Task { await model.restartEngine() } }.secondaryButton()
            }
        } else if let account = model.account?.account, !account.isSignedIn {
            banner("Claude Code isn't signed in on this Mac. Sign in with your Claude account to use your plan.", symbol: "person.crop.circle.badge.exclamationmark", tint: .orange) {
                Button("Sign In…") { model.showLogin = true }.secondaryButton()
            }
        }
    }

    private func banner(_ text: String, symbol: String, tint: Color, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer()
            action()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(tint.opacity(0.12)), in: .agentCard)
        .padding(12)
    }
}

/// Runs the real `claude` CLI so you can type /login.
struct LoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Claude Code").font(.title2.bold())
            Text("Type **/login** below and follow the browser prompt to sign in with your Claude account. AgentX never sees your password; Claude Code stores the login in your Keychain.")
                .foregroundStyle(.secondary)
            if let terminal = model.terminals.session(for: Self.terminalID) {
                TerminalView(session: terminal)
                    .frame(minHeight: 360)
                    .clipShape(.rect(cornerRadius: Radius.inset))
            } else if model.client.paths?.claude == nil {
                Text("The Claude Code CLI wasn't found.").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Done") {
                    model.terminals.stop(Self.terminalID)
                    dismiss()
                    Task { await model.reloadAccount() }
                }
                .primaryButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .onAppear {
            guard let claude = model.client.paths?.claude else { return }
            model.terminals.start(id: Self.terminalID, executable: claude, arguments: [], directory: NSHomeDirectory(),
                                  environment: model.terminalEnvironment)
        }
    }

    private static let terminalID = "login"
}
