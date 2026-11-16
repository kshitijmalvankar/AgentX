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
        Window("AgentX", id: "main") {
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
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare `AgentXDev` binary (no .app bundle).
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
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
        case .assistant:
            ComingSoonView(item: .assistant, milestone: "M3",
                           blurb: "Ask anything and let Claude act on your Mac: Calendar, Reminders, Files, Apps, Shortcuts, Mail, Notes and Messages. Summon it anywhere with ⌥Space.")
        case .system:
            ComingSoonView(item: .system, milestone: "M2",
                           blurb: "Live CPU, memory, disk, battery, network and top processes, with an “Ask Claude” button to explain what's going on.")
        case .automations:
            ComingSoonView(item: .automations, milestone: "M4",
                           blurb: "Scheduled agent jobs: a morning brief, a nightly repo check, tidying Downloads, all running on your plan.")
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
                        .badge(item == .sessions ? model.sessions.approvals.count : 0)
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
                Button("Retry") { Task { await model.restartEngine() } }
            }
        } else if let account = model.account?.account, !account.isSignedIn {
            banner("Claude Code isn't signed in on this Mac. Sign in with your Claude account to use your plan.", symbol: "person.crop.circle.badge.exclamationmark", tint: .orange) {
                Button("Sign In…") { model.showLogin = true }
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
        .glassEffect(.regular.tint(tint.opacity(0.12)), in: .rect(cornerRadius: 14))
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
                    .clipShape(.rect(cornerRadius: 8))
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
                .buttonStyle(.glassProminent)
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
