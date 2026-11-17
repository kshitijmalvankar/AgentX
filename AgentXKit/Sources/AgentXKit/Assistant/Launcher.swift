import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Opens the launcher from anywhere. Changeable in Settings. AgentX Dev
    /// defaults to ⌃⌥Space so it doesn't fight the installed app for ⌥Space.
    static let toggleLauncher = Self("toggleLauncher", initial: AppChannel.current.isDev
        ? .init(.space, modifiers: [.control, .option])
        : .init(.space, modifiers: [.option]))
}

/// The floating ⌥Space launcher: ask the assistant anything, or
/// `/code <project> <task>` to start a coding session.
@MainActor
@Observable
final class LauncherController {
    static let shared = LauncherController()

    /// The conversation the launcher is showing (continues until you start a new one).
    var conversationID: String?
    var error: String?
    /// Bumped on every show so the text field takes focus.
    private(set) var focusToken = 0

    @ObservationIgnored private var panel: LauncherPanel?
    private var model: AppModel { AppModel.shared }

    var conversation: Conversation? { conversationID.flatMap { model.sessions.conversations[$0] } }

    static func registerHotkey() {
        KeyboardShortcuts.onKeyUp(for: .toggleLauncher) {
            MainActor.assumeIsolated { LauncherController.shared.toggle() }
        }
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        if panel == nil {
            panel = LauncherPanel(rootView: LauncherView().environment(model))
        }
        guard let panel else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.maxY - panel.frame.height - visible.height * 0.12))
        }
        error = nil
        panel.makeKeyAndOrderFront(nil)
        focusToken += 1
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func newConversation() {
        conversationID = nil
        error = nil
        focusToken += 1
    }

    func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        error = nil
        if text == "/code" || text.hasPrefix("/code ") {
            startCoding(String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            return
        }
        Task {
            if let conversation {
                await model.askAssistant(text, in: conversation)
            } else {
                let c = await model.askAssistant(text)
                conversationID = c.id
            }
        }
    }

    /// `/code <project> <task>`: start a coding session in a recent project.
    private func startCoding(_ rest: String) {
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        let projects = model.sessions.recentProjects
        guard let query = parts.first, parts.count == 2 else {
            error = "Use /code <project> <what to do>. Recent projects: " + projects.prefix(6).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return
        }
        let q = query.lowercased()
        let names = projects.map { (path: $0, name: ($0 as NSString).lastPathComponent.lowercased()) }
        guard let project = names.first(where: { $0.name == q })?.path
                ?? names.first(where: { $0.name.hasPrefix(q) })?.path
                ?? names.first(where: { $0.name.contains(q) })?.path else {
            error = "No recent project matches \"\(query)\". Recent: " + projects.prefix(6).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return
        }
        hide()
        model.sidebar = .sessions
        model.showMainWindow()
        Task { await model.sessions.startNew(cwd: project, prompt: parts[1], model: nil, mode: .default) }
    }

    func openInApp() {
        hide()
        model.sidebar = .assistant
        model.sessions.selectAssistant(conversation?.sessionId ?? conversationID)
        model.showMainWindow()
    }
}

/// Borderless floating panel that can take keyboard focus without
/// activating AgentX (like Spotlight). Esc or clicking elsewhere hides it.
final class LauncherPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        contentView = NSHostingView(rootView: rootView.frame(width: 720, height: 600, alignment: .top))
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

struct LauncherView: View {
    @Environment(AppModel.self) private var model
    @State private var launcher = LauncherController.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                TextField("Ask anything, or /code <project> <task>", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit {
                        launcher.submit(text)
                        text = ""
                    }
                if let c = launcher.conversation, c.isWorking {
                    ProgressView().controlSize(.small)
                    Button("Stop", systemImage: "stop.fill") { Task { await model.sessions.interrupt(c) } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            .padding(18)

            if let error = launcher.error {
                Divider()
                Text(error).font(.callout).foregroundStyle(.secondary).padding(14)
            } else if let c = launcher.conversation {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(c.items) { item in TranscriptRow(item: item, cwd: c.cwd) }
                            if !c.draftText.isEmpty {
                                Text(c.draftText).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: c.items.count) { proxy.scrollTo("end") }
                    .onChange(of: c.draftText.count / 200) { proxy.scrollTo("end") }
                }
                ApprovalList(conversation: c)
                    .padding(.bottom, 8)
                Divider()
                HStack {
                    Button("New", systemImage: "square.and.pencil") { launcher.newConversation() }
                    Spacer()
                    Text("esc to close").font(.caption).foregroundStyle(.tertiary)
                    Button("Open in AgentX", systemImage: "arrow.up.forward.app") { launcher.openInApp() }
                }
                .secondaryButton()
                .controlSize(.small)
                .padding(12)
            } else {
                Divider()
                FlowSuggestions { suggestion in launcher.submit(suggestion) }
                    .padding(16)
            }
        }
        .frame(width: 680)
        // The panel's shape is the container: cards and controls inside follow its corners.
        .containerShape(.rect(cornerRadius: Radius.panel))
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.panel))
        .padding(20)
        .onChange(of: launcher.focusToken) { focused = true }
        .onAppear { focused = true }
    }
}
