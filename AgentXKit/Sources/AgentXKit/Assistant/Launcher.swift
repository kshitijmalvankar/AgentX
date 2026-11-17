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
    /// Text to put in the field on the next show (from an agentx://launcher?q= link). Never sent automatically.
    var pendingText: String?

    // MARK: Screen context

    /// The app that was in front when the launcher opened.
    private(set) var contextApp: NSRunningApplication?
    /// What was on screen (filled in a moment after the launcher opens).
    private(set) var context: ScreenContext?
    /// Parts you removed with ✕.
    var dropped: Set<ContextPart> = []
    /// "Show, include when I click" mode: chips start off.
    var includeContext = true
    /// A picture of the window, taken when you click Look at Window.
    private(set) var picture: ScreenGrabber.Picture?
    private(set) var takingPicture = false
    var pictureError: String?
    @ObservationIgnored private var captureTask: Task<Void, Never>?

    enum ContextPart: Hashable { case place, selection, files }

    /// Settings → Assistant: include what's on screen automatically, only when you click, or not at all.
    enum ContextMode: String, CaseIterable, Identifiable {
        case include, ask, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .include: "Include it (remove what you don't want)"
            case .ask: "Show it, include only when I click"
            case .off: "Don't look"
            }
        }
        static var current: ContextMode {
            ContextMode(rawValue: UserDefaults.standard.string(forKey: "contextMode") ?? "") ?? .include
        }
    }

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

    func show(prefill: String? = nil) {
        if let prefill { pendingText = prefill }
        captureContext()
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
        // Add the screen context you kept (used once, for this message).
        var prompt = text
        var taint: String?
        var images: [JSONValue] = []
        if let shared = sharedContext {
            prompt = shared.promptBlock() + "\n\n" + text
            taint = shared.taintReason
        }
        if let picture {
            images = [["mediaType": "image/jpeg", "data": .string(picture.jpeg.base64EncodedString())]]
            taint = taint ?? "a picture of your screen (\(picture.appName))"
        }
        clearContext()
        Task {
            if let conversation {
                await model.askAssistant(prompt, in: conversation, taint: taint, images: images)
            } else {
                let c = await model.askAssistant(prompt, taint: taint, images: images)
                conversationID = c.id
            }
        }
    }

    /// The context that will be sent: what was captured, minus what you removed (nil: nothing).
    var sharedContext: ScreenContext? { includeContext ? sharedContextIfIncluded : nil }

    /// What would be sent if you include it.
    var sharedContextIfIncluded: ScreenContext? {
        guard var c = context else { return nil }
        if dropped.contains(.place) { c.windowTitle = nil; c.documentPath = nil; c.browserTab = nil }
        if dropped.contains(.selection) { c.selectedText = nil }
        if dropped.contains(.files) { c.finderSelection = [] }
        return c.hasDetails ? c : nil
    }

    /// Read what's in front (unless Settings says not to). Runs as the launcher opens.
    private func captureContext() {
        let mode = ContextMode.current
        guard mode != .off, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            if panel?.isVisible != true { clearContext() }
            return
        }
        clearContext()
        contextApp = front
        includeContext = mode == .include
        captureTask = Task { [weak self] in
            let captured = await ContextCapture.capture(front)
            guard !Task.isCancelled else { return }
            self?.context = captured
        }
    }

    func clearContext() {
        captureTask?.cancel()
        context = nil
        contextApp = nil
        dropped = []
        picture = nil
        pictureError = nil
    }

    /// Look at Window: a picture of the app's front window, attached to your next message.
    func takePicture() {
        guard let app = contextApp, !takingPicture else { return }
        takingPicture = true
        pictureError = nil
        Task {
            do { picture = try await ScreenGrabber.captureFrontWindow(of: app) } catch { pictureError = error.localizedDescription }
            takingPicture = false
            focusToken += 1
        }
    }

    func dropPicture() { picture = nil }

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
        model.sidebar = .chats
        model.claudeMode = .mac
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

    private func takePendingText() {
        guard let pending = launcher.pendingText else { return }
        text = pending
        launcher.pendingText = nil
    }

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

            if launcher.contextApp != nil {
                ContextChips(launcher: launcher)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

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
        .onChange(of: launcher.focusToken) {
            focused = true
            takePendingText()
        }
        .onAppear {
            focused = true
            takePendingText()
        }
    }
}

/// What the launcher will send about your screen, as chips you can remove.
private struct ContextChips: View {
    @Bindable var launcher: LauncherController

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            if let app = launcher.contextApp {
                chip(app.localizedName ?? "App", icon: nil, nsIcon: app.icon, removable: nil)
            }
            if let c = launcher.context {
                if let tab = c.browserTab, !launcher.dropped.contains(.place) {
                    chip(tab.title.isEmpty ? tab.url : tab.title, icon: "globe", removable: .place)
                } else if let title = c.windowTitle ?? c.documentPath.map({ ($0 as NSString).lastPathComponent }), !launcher.dropped.contains(.place) {
                    chip(title, icon: "macwindow", removable: .place)
                }
                if let text = c.selectedText, !launcher.dropped.contains(.selection) {
                    chip("Selection: \(text.prefix(40))\(text.count > 40 ? "…" : "")", icon: "text.cursor", removable: .selection)
                }
                if !c.finderSelection.isEmpty, !launcher.dropped.contains(.files) {
                    let names = c.finderSelection.map { ($0 as NSString).lastPathComponent }
                    chip(names.count == 1 ? names[0] : "\(names.count) files", icon: "doc.on.doc", removable: .files)
                }
                if let withheld = c.selectionWithheld {
                    note("Selection left out: it looks like \(withheld)", icon: "lock")
                }
                if c.needsAccessibility {
                    Button("Allow Accessibility to include selected text", systemImage: "hand.raised") { AXReader.requestTrust() }
                        .buttonStyle(.link).font(.caption)
                }
                if let blocked = c.automationBlocked {
                    note("Allow AgentX to read \(blocked) in Settings → Assistant → Permissions", icon: "exclamationmark.triangle")
                }
            } else {
                ProgressView().controlSize(.mini)
            }
            if let picture = launcher.picture {
                pictureChip(picture)
            } else {
                Button(launcher.takingPicture ? "Looking…" : "Look at Window", systemImage: "eye") { launcher.takePicture() }
                    .secondaryButton()
                    .controlSize(.small)
                    .disabled(launcher.takingPicture)
                    .help("Attach a picture of \(launcher.contextApp?.localizedName ?? "the app")'s window to your next message. Only when you click; the picture goes to Claude and isn't saved.")
            }
            if !launcher.includeContext, launcher.sharedContextIfIncluded != nil {
                Button("Include this", systemImage: "plus.circle") { launcher.includeContext = true }
                    .secondaryButton()
                    .controlSize(.small)
            }
        }
        .opacity(launcher.includeContext ? 1 : 0.6)
        if let error = launcher.pictureError {
            Text(error).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chip(_ text: String, icon: String?, nsIcon: NSImage? = nil, removable: LauncherController.ContextPart?) -> some View {
        HStack(spacing: 5) {
            if let nsIcon { Image(nsImage: nsIcon).resizable().frame(width: 14, height: 14) }
            if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
            Text(text).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .leading)
            if let removable {
                Button("Remove", systemImage: "xmark") { launcher.dropped.insert(removable) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Don't send this")
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }

    private func pictureChip(_ picture: ScreenGrabber.Picture) -> some View {
        HStack(spacing: 6) {
            if let image = NSImage(data: picture.jpeg) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 28, height: 18).clipShape(.rect(cornerRadius: 3))
            }
            Text("Picture of \(picture.appName)'s window").lineLimit(1)
            Button("Remove", systemImage: "xmark") { launcher.dropPicture() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.15), in: .capsule)
    }

    private func note(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary)
    }
}
