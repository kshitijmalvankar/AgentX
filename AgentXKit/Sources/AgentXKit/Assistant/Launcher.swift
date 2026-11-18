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

    /// The conversation the launcher is showing (until you click New or close the launcher).
    var conversationID: String?
    var error: String?
    /// Bumped on every show so the text field takes focus.
    private(set) var focusToken = 0
    /// What's typed in the field.
    var query = ""

    // MARK: On this Mac (no Claude)

    /// Apps, files, settings, commands and calculations for what's typed (LauncherLocal.swift).
    var results: [LauncherResult] = []
    var selectedResult = 0
    /// A command being worked out or done on this Mac, shown as a card instead of the results.
    var local: LocalState?
    /// The app in front when the launcher opened, AgentX included ("where's the New Chat button?").
    @ObservationIgnored var openedOver: NSRunningApplication?
    @ObservationIgnored let fileSearch = FileSearch()
    @ObservationIgnored var fileURLs: [URL] = []
    @ObservationIgnored var fileQuery = ""
    @ObservationIgnored var fileTask: Task<Void, Never>?

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

    // MARK: Where it opens, voice, answers

    /// Opened from the selection bubble or at the pointer: narrower, next to the pointer.
    private(set) var compact = false
    /// Opened from the selection bubble: shows quick actions for the selection.
    private(set) var fromSelection = false
    /// Listening while you hold the shortcut (or after clicking the microphone).
    private(set) var listening = false
    /// The app your last message's selection came from, for Replace Selection.
    private(set) var replaceTarget: NSRunningApplication?
    @ObservationIgnored private var keyIsDown = false
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var speakTask: Task<Void, Never>?

    enum Anchor { case automatic, center, point(NSPoint) }

    /// Settings → Assistant → Launcher and pointer.
    enum Position: String, CaseIterable, Identifiable {
        case center, pointer
        var id: String { rawValue }
        var label: String { self == .center ? "In the middle of the screen" : "Next to the pointer" }
        static var current: Position { Position(rawValue: UserDefaults.standard.string(forKey: "launcherPosition") ?? "") ?? .center }
    }

    var cardWidth: CGFloat { compact ? 540 : 680 }

    /// Settings → Assistant: include what's on screen automatically, only when you click, or not at all.
    enum ContextMode: String, CaseIterable, Identifiable {
        case include, ask, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .include: "Include it when I ask about it (\"this\", \"the page\")"
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

    /// Tap the shortcut to open or close the launcher; hold it to talk.
    static func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleLauncher) {
            MainActor.assumeIsolated { LauncherController.shared.hotkeyDown() }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleLauncher) {
            MainActor.assumeIsolated { LauncherController.shared.hotkeyUp() }
        }
    }

    private func hotkeyDown() {
        guard !keyIsDown else { return }
        keyIsDown = true
        SpeechOutput.shared.stop()
        guard VoiceInput.holdToTalk else { return }
        holdTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, self.keyIsDown else { return }
            await self.startListening()
        }
    }

    private func hotkeyUp() {
        keyIsDown = false
        holdTask?.cancel()
        holdTask = nil
        if listening {
            Task { await finishListening() }
        } else {
            toggle()
        }
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show(prefill: String? = nil, anchor: Anchor = .automatic, fromSelection: Bool = false) {
        let opening = panel?.isVisible != true
        // Each time it opens, start clean. Earlier conversations (even one still
        // answering) carry on in Chats → On this Mac.
        if opening {
            conversationID = nil
            replaceTarget = nil
            error = nil
            local = nil
            query = ""
            openedOver = NSWorkspace.shared.frontmostApplication
            AppIndex.shared.refreshIfNeeded()
            LocalCommands.shared.prewarm()
        }
        // Prefill from an agentx://launcher?q= link: put in the field, never sent automatically.
        if let prefill { query = prefill }
        self.fromSelection = fromSelection
        var anchor = anchor
        if case .automatic = anchor {
            anchor = Position.current == .pointer ? .point(NSEvent.mouseLocation) : .center
        }
        if case .point = anchor { compact = true } else { compact = false }
        captureContext()
        if panel == nil {
            panel = LauncherPanel(rootView: LauncherView().environment(model))
        }
        guard let panel else { return }
        place(panel, anchor: anchor)
        if opening {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.14; panel.animator().alphaValue = 1 }
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        focusToken += 1
    }

    /// Centered near the top of the screen, or with its corner by the pointer (kept on screen).
    private func place(_ panel: NSPanel, anchor: Anchor) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let inset = LauncherPanel.inset, size = panel.frame.size
        var origin: NSPoint
        switch anchor {
        case .point(let p):
            // The card's top-left goes just below and right of the point.
            origin = NSPoint(x: p.x + 8 - inset, y: p.y - 10 + inset - size.height)
        default:
            origin = NSPoint(x: visible.midX - cardWidth / 2 - inset, y: visible.maxY - visible.height * 0.12 + inset - size.height)
        }
        origin.x = min(max(origin.x, visible.minX - inset), visible.maxX - cardWidth - inset)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height + inset)
        panel.setFrameOrigin(origin)
    }

    func hide() {
        if listening { VoiceInput.shared.cancel(); listening = false }
        fileSearch.cancel()
        panel?.orderOut(nil)
    }

    /// Esc: back out of a command card first, then close.
    func escape() {
        if local != nil { local = nil; updateResults() } else { hide() }
    }

    func newConversation() {
        conversationID = nil
        replaceTarget = nil
        error = nil
        focusToken += 1
    }

    // MARK: Voice

    func toggleListening() {
        if listening { Task { await finishListening() } } else { Task { await startListening() } }
    }

    private func startListening() async {
        SpeechOutput.shared.stop()
        if panel?.isVisible != true { show() }
        listening = true
        if await !VoiceInput.shared.start() {
            listening = false
            error = VoiceInput.shared.error
        }
    }

    private func finishListening() async {
        guard listening else { return }
        let heard = await VoiceInput.shared.stop()
        listening = false
        guard !heard.isEmpty else { return }
        routeSpoken(heard)
    }

    // MARK: Sending

    /// Quick actions for a selection (from the bubble, or any time there's one).
    /// Done on this Mac (Apple's on-device model, or Apple's Translation); `prompt` is what Claude gets if you ask it instead.
    static let selectionActions: [SelectionAction] = [
        SelectionAction(title: "Summarize", icon: "text.alignleft", job: .summarize, prompt: "Summarize this in a few short bullet points."),
        SelectionAction(title: "Explain", icon: "lightbulb", job: .explain, prompt: "Explain this simply."),
        SelectionAction(title: "Fix the Writing", icon: "wand.and.stars", job: .fix,
                        prompt: "Fix the spelling, grammar and flow of this, keeping my voice. Reply with only the corrected text."),
        SelectionAction(title: "Make It Shorter", icon: "arrow.down.right.and.arrow.up.left", job: .shorten,
                        prompt: "Make this shorter and clearer. Reply with only the new text."),
        SelectionAction(title: "Reply", icon: "arrowshape.turn.up.left", job: .reply, prompt: "Draft a reply to this. Reply with only the draft."),
        SelectionAction(title: "Translate", icon: "character.bubble", job: nil, prompt: "Translate this."),
    ]

    func submit(_ text: String, spoken: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !(text == "/code" || text.hasPrefix("/code ")) { LocalUsage.noteClaude() }
        error = nil
        SpeechOutput.shared.stop()
        if text == "/code" || text.hasPrefix("/code ") {
            startCoding(String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            return
        }
        // Add the screen context you kept (used once, for this message).
        var prompt = text
        var taint: String?
        var images: [JSONValue] = []
        // Only when the words are about the screen, you came from the Ask button, or
        // you clicked Include This: "what's my latest email?" goes without a window title.
        if wantsScreen(for: text), let shared = sharedContext {
            prompt = shared.promptBlock() + "\n\n" + text
            taint = shared.taintReason
            replaceTarget = shared.selectedText != nil ? contextApp : nil
        }
        if let picture {
            images = [["mediaType": "image/jpeg", "data": .string(picture.jpeg.base64EncodedString())]]
            taint = taint ?? "a picture of your screen (\(picture.appName))"
        }
        clearContext()
        fromSelection = false
        query = ""
        local = nil
        results = []
        Task {
            let c: Conversation
            if let conversation {
                c = conversation
                await model.askAssistant(prompt, in: conversation, taint: taint, images: images)
            } else {
                c = await model.askAssistant(prompt, taint: taint, images: images)
                conversationID = c.id
            }
            if spoken, SpeechOutput.readAloud { speakWhenDone(c) }
        }
    }

    /// Whether a message with these words takes the screen context along.
    func wantsScreen(for text: String) -> Bool {
        fromSelection || ContextMode.current == .ask || ScreenContext.refersToScreen(text)
    }

    /// Read the answer aloud once Claude finishes (you asked by voice).
    private func speakWhenDone(_ c: Conversation) {
        speakTask?.cancel()
        speakTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            for _ in 0..<1_200 where c.isWorking {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, let answer = Self.lastAnswer(in: c) else { return }
            SpeechOutput.shared.speak(answer)
        }
    }

    /// Claude's reply to your latest message.
    static func lastAnswer(in c: Conversation) -> String? {
        var parts: [String] = []
        for item in c.items.reversed() {
            if case .user = item.kind { break }
            if case .assistant(let text) = item.kind { parts.insert(text, at: 0) }
        }
        let answer = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? nil : answer
    }

    func copyAnswer() {
        guard let c = conversation, let answer = Self.lastAnswer(in: c) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    /// Paste the answer over the selection it was about, in that app.
    func replaceSelection() {
        guard let c = conversation, let answer = Self.lastAnswer(in: c), let app = replaceTarget, !app.isTerminated else { return }
        hide()
        Task {
            app.activate()
            try? await Task.sleep(for: .milliseconds(200))
            if !(await SelectionCopier.paste(answer, into: app)) {
                show()
                error = "Couldn't paste into \(app.localizedName ?? "that app"). The answer is still here to copy."
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
            let captured = await ContextCapture.capture(front, copyIfHidden: true)
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
    /// Room around the card for its shadow.
    static let inset: CGFloat = 20

    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 700),
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
        contentView = NSHostingView(rootView: rootView.frame(width: 720, height: 700, alignment: .topLeading))
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { LauncherController.shared.escape() }
    override func resignKey() {
        super.resignKey()
        LauncherController.shared.hide()
    }
}

struct LauncherView: View {
    @Environment(AppModel.self) private var model
    @State private var launcher = LauncherController.shared
    @State private var voice = VoiceInput.shared
    @State private var speech = SpeechOutput.shared
    @FocusState private var focused: Bool

    /// Spotlight's glass, tinted with the window colour so text stays readable over busy pages.
    private static let glass = Glass.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.45))

    /// The selection that will go with the next message, if any (for quick actions).
    private var selection: String? {
        launcher.includeContext && !launcher.dropped.contains(.selection) ? launcher.context?.selectedText : nil
    }

    /// Like Spotlight: a floating search bar, and a panel under it only when there's something to show.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchBar
            if hasPanel {
                panel.transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .frame(width: launcher.cardWidth)
        .padding(LauncherPanel.inset)
        .animation(.snappy(duration: 0.2), value: hasPanel)
        .animation(.snappy(duration: 0.22), value: launcher.conversationID)
        .animation(.snappy(duration: 0.22), value: launcher.listening)
        .onChange(of: launcher.focusToken) { focused = true }
        .onAppear { focused = true }
    }

    private var hasPanel: Bool {
        showChips || launcher.error != nil || launcher.conversation != nil || launcher.local != nil
            || !launcher.results.isEmpty || (selection != nil && launcher.query.isEmpty)
    }

    private var searchBar: some View {
        HStack(spacing: 14) {
            if launcher.listening {
                AgentMark(listening: true, level: voice.level)
                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.text.isEmpty ? "Listening…" : voice.text)
                        .font(.system(size: 22))
                        .foregroundStyle(voice.text.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                    Text("Let go of the shortcut to send").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $launcher.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24))
                    .focused($focused)
                    .onSubmit { launcher.returnPressed() }
                    .onKeyPress(.downArrow) { launcher.moveSelection(1) ? .handled : .ignored }
                    .onKeyPress(.upArrow) { launcher.moveSelection(-1) ? .handled : .ignored }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        launcher.askClaude()
                        return .handled
                    }
                    // ⌘1–⌘9: the row with that number.
                    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                        guard press.modifiers == .command, let n = Int(press.characters) else { return .ignored }
                        return launcher.performNumbered(n) ? .handled : .ignored
                    }
                    .onChange(of: launcher.query) { launcher.updateResults() }
            }
            if let c = launcher.conversation, c.isWorking {
                ProgressView().controlSize(.small)
                iconButton("Stop", "stop.fill") { Task { await model.sessions.interrupt(c) } }
            }
            if speech.isSpeaking {
                iconButton("Stop Reading", "speaker.slash") { speech.stop() }
            }
            if showChips, launcher.picture == nil {
                iconButton(launcher.takingPicture ? "Looking…" : "Look at \(launcher.contextApp?.localizedName ?? "the") Window", "eye") {
                    launcher.takePicture()
                }
                .disabled(launcher.takingPicture)
            }
            iconButton(launcher.listening ? "Send" : "Talk", launcher.listening ? "stop.circle.fill" : "mic", highlight: launcher.listening) {
                launcher.toggleListening()
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 20)
        .frame(height: 62)
        .glassEffect(Self.glass, in: .capsule)
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            if showChips {
                ContextChips(launcher: launcher, goesWithMessage: launcher.wantsScreen(for: launcher.query))
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }
            if let error = launcher.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(18)
            } else if let local = launcher.local {
                LocalCommandCard(state: local)
                    .padding(18)
            } else if launcher.showsResults {
                LauncherResultsList()
                    .padding(8)
            } else if let c = launcher.conversation {
                conversation(c)
            } else if selection != nil, launcher.query.isEmpty {
                SelectionActions { action in launcher.runOnSelection(action) }
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerShape(shape)
        .glassEffect(Self.glass, in: shape)
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

    /// What's on screen shows only when it's in play: your words are about it,
    /// text is selected, or you took a picture. Otherwise the launcher stays clean.
    private var showChips: Bool {
        guard launcher.contextApp != nil else { return false }
        return launcher.wantsScreen(for: launcher.query) || selection != nil
            || launcher.picture != nil || launcher.takingPicture || launcher.pictureError != nil
    }

    private var placeholder: String {
        if selection != nil { return "Ask about what you selected…" }
        if launcher.conversation != nil { return "Search, do something, or ask a follow-up" }
        return "Search or ask"
    }

    private func iconButton(_ title: String, _ icon: String, highlight: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 18))
            .foregroundStyle(highlight ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .help(title)
    }

    @ViewBuilder private func conversation(_ c: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(c.items) { item in
                        TranscriptRow(item: item, cwd: c.cwd)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if !c.draftText.isEmpty {
                        Text(c.draftText).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !c.isWorking, let answer = LauncherController.lastAnswer(in: c) {
                        AnswerActions(answer: answer, canReplace: launcher.replaceTarget != nil,
                                      replaceInto: launcher.replaceTarget?.localizedName)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(18)
                .animation(.snappy(duration: 0.22), value: c.items.count)
            }
            .frame(maxHeight: launcher.compact ? 320 : 400)
            .onChange(of: c.items.count) { proxy.scrollTo("end") }
            .onChange(of: c.draftText.count / 200) { proxy.scrollTo("end") }
            .onChange(of: c.isWorking) { proxy.scrollTo("end") }
        }
        ApprovalList(conversation: c)
            .padding(.bottom, 8)
        Divider().opacity(0.6)
        HStack {
            Button("New", systemImage: "square.and.pencil") { launcher.newConversation() }
            Spacer()
            Text("esc to close").font(.caption).foregroundStyle(.tertiary)
            Button("Open in AgentX", systemImage: "arrow.up.forward.app") { launcher.openInApp() }
        }
        .secondaryButton()
        .controlSize(.small)
        .padding(12)
    }
}

/// AgentX's mark in the launcher: a gradient disc that breathes with your voice while listening.
private struct AgentMark: View {
    let listening: Bool
    let level: Float

    var body: some View {
        ZStack {
            if listening {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .scaleEffect(1 + CGFloat(level) * 0.7)
                    .animation(.easeOut(duration: 0.12), value: level)
            }
            Circle()
                .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.mix(with: .purple, by: 0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: listening ? "waveform" : "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: listening)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 30, height: 30)
    }
}

/// One-click things to do with a selection.
/// One of the Ask button's actions.
struct SelectionAction: Sendable {
    let title: String
    let icon: String
    /// What the on-device writer does; nil for Translate.
    let job: LocalWriter.Job?
    let prompt: String
}

private struct SelectionActions: View {
    let run: (SelectionAction) -> Void

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(LauncherController.selectionActions, id: \.title) { action in
                Button(action.title, systemImage: action.icon) { run(action) }
                    .secondaryButton()
                    .lineLimit(1)
            }
        }
    }
}

/// Under a finished answer: copy it, paste it over the selection it was about, or hear it.
private struct AnswerActions: View {
    let answer: String
    let canReplace: Bool
    let replaceInto: String?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                LauncherController.shared.copyAnswer()
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            if canReplace {
                Button("Replace Selection", systemImage: "arrow.left.arrow.right") { LauncherController.shared.replaceSelection() }
                    .help("Paste this over what you selected\(replaceInto.map { " in \($0)" } ?? "")")
            }
            Button("Read Aloud", systemImage: "speaker.wave.2") { SpeechOutput.shared.speak(answer) }
        }
        .secondaryButton()
        .controlSize(.small)
        .contentTransition(.symbolEffect(.replace))
    }
}

/// What the launcher will send about your screen, as chips. Click one to see
/// exactly what it sends; ✕ leaves it out.
private struct ContextChips: View {
    @Bindable var launcher: LauncherController
    /// Your words so far are about the screen (or you came from the Ask button).
    var goesWithMessage = true
    @State private var preview: Preview?

    enum Preview: Hashable { case place, selection, files, picture }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if let app = launcher.contextApp {
                    chip(app.localizedName ?? "App", icon: nil, nsIcon: app.icon, removable: nil, preview: nil)
                }
                if let c = launcher.context {
                    if let tab = c.browserTab, !launcher.dropped.contains(.place) {
                        chip(tab.title.isEmpty ? tab.url : tab.title, icon: "globe", removable: .place, preview: .place)
                    } else if let title = c.windowTitle ?? c.documentPath.map({ ($0 as NSString).lastPathComponent }), !launcher.dropped.contains(.place) {
                        chip(title, icon: "macwindow", removable: .place, preview: .place)
                    }
                    if let text = c.selectedText, !launcher.dropped.contains(.selection) {
                        chip("Selection: \(text.prefix(40))\(text.count > 40 ? "…" : "")", icon: "text.cursor", removable: .selection, preview: .selection)
                    }
                    if !c.finderSelection.isEmpty, !launcher.dropped.contains(.files) {
                        let names = c.finderSelection.map { ($0 as NSString).lastPathComponent }
                        chip(names.count == 1 ? names[0] : "\(names.count) files", icon: "doc.on.doc", removable: .files, preview: .files)
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
                }
                if !launcher.includeContext, launcher.sharedContextIfIncluded != nil {
                    Button("Include this", systemImage: "plus.circle") { launcher.includeContext = true }
                        .secondaryButton()
                        .controlSize(.small)
                }
            }
            .opacity(launcher.includeContext && goesWithMessage ? 1 : 0.55)
            .animation(.easeOut(duration: 0.15), value: goesWithMessage)
            if launcher.includeContext, !goesWithMessage, launcher.sharedContextIfIncluded != nil {
                Text("Goes along only if you ask about it (\"this\", \"the page\", \"the selected text\").")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if let error = launcher.pictureError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            if let preview {
                previewBox(preview)
            }
        }
    }

    private func chip(_ text: String, icon: String?, nsIcon: NSImage? = nil,
                      removable: LauncherController.ContextPart?, preview part: Preview?) -> some View {
        let open = part != nil && preview == part
        return HStack(spacing: 5) {
            HStack(spacing: 5) {
                if let nsIcon { Image(nsImage: nsIcon).resizable().frame(width: 14, height: 14) }
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                Text(text).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .leading)
            }
            .contentShape(.rect)
            .onTapGesture { if let part { preview = open ? nil : part } }
            .help(part == nil ? "" : "Click to see exactly what's sent")
            if let removable {
                Button("Remove", systemImage: "xmark") {
                    launcher.dropped.insert(removable)
                    if open { preview = nil }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Don't send this")
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(open ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .capsule)
    }

    private func pictureChip(_ picture: ScreenGrabber.Picture) -> some View {
        let open = preview == .picture
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                if let image = NSImage(data: picture.jpeg) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 28, height: 18).clipShape(.rect(cornerRadius: 3))
                }
                Text("Picture of \(picture.appName)'s window").lineLimit(1)
            }
            .contentShape(.rect)
            .onTapGesture { preview = open ? nil : .picture }
            .help("Click to see the picture")
            Button("Remove", systemImage: "xmark") {
                launcher.dropPicture()
                if open { preview = nil }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.tint.opacity(open ? 0.3 : 0.15), in: .capsule)
    }

    /// The full text (or picture) behind a chip, exactly as it goes to Claude.
    @ViewBuilder private func previewBox(_ part: Preview) -> some View {
        let c = launcher.context
        switch part {
        case .place:
            if let tab = c?.browserTab {
                box("The tab", [tab.title, tab.url].filter { !$0.isEmpty }.joined(separator: "\n"))
            } else if let c, c.windowTitle != nil || c.documentPath != nil {
                box("The window", [c.windowTitle, c.documentPath].compactMap { $0 }.joined(separator: "\n"))
            }
        case .selection:
            if let text = c?.selectedText {
                box("Selected text (\(text.count) characters\(text.count > 8_000 ? ", the first 8,000 are sent" : ""))", text)
            }
        case .files:
            if let files = c?.finderSelection, !files.isEmpty {
                box("Selected in Finder", files.joined(separator: "\n"))
            }
        case .picture:
            if let picture = launcher.picture, let image = NSImage(data: picture.jpeg) {
                previewFrame("Picture of \(picture.appName)'s window") {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                        .clipShape(.rect(cornerRadius: Radius.inset))
                }
            }
        }
    }

    private func box(_ title: String, _ text: String) -> some View {
        previewFrame(title) {
            ViewThatFits(in: .vertical) {
                textBlock(text)
                ScrollView { textBlock(text) }
            }
            .frame(maxHeight: 150)
        }
    }

    private func textBlock(_ text: String) -> some View {
        Text(text).font(.callout).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func previewFrame<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Hide", systemImage: "chevron.up") { preview = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide")
            }
            content()
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Radius.inset))
    }

    private func note(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary)
    }
}
