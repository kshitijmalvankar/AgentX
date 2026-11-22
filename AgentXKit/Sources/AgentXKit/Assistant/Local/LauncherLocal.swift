import AppKit
import Foundation

/// A command being worked out or done on this Mac (no Claude).
enum LocalState: Equatable {
    /// Apple's on-device model is reading it.
    case thinking(String)
    /// Ready; waits for Return (creating something, quitting an app, running a Shortcut).
    case confirm(LocalPlan)
    case working(LocalPlan)
    case done(String)
    /// Something to read (your calendar, your reminders).
    case info(title: String, text: String)
    /// It couldn't be done; the text can still go to Claude.
    case failed(String, text: String)
    /// Not a command (a question, writing…): offer Claude.
    case notACommand(String)
    /// Text written on this Mac: a summary, a fix, a translation, an answer.
    case text(LocalText)
    /// macOS doesn't let AgentX see this folder (Files & Folders).
    case blockedFolder(String)
}

/// What the on-device writer produced, and what to do with it.
struct LocalText: Equatable {
    var title: String
    var text: String
    /// What it was made from (to translate again into another language).
    var source: String
    /// A translation into this language (nil: not a translation, or no language chosen yet).
    var language: String?
    var isTranslation = false
    /// Whether it can be pasted over your selection (fixes, shorter versions, translations).
    var replaces: Bool
    /// What goes to Claude if you want more ("Ask Claude").
    var claudePrompt: String
}

/// The launcher's Spotlight side: apps, files, System Settings, calculations,
/// web addresses, and commands done on this Mac with Apple's on-device model.
/// Claude is one row (⌘Return) for everything else.
extension LauncherController {
    static var searchEnabled: Bool { UserDefaults.standard.object(forKey: "launcherSearch") as? Bool ?? true }

    /// Rebuild the rows for what's typed. Files arrive a moment later.
    func updateResults() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .thinking = local {} else if local != nil { local = nil }
        // After an answer, what you type is a new request like any other: apps, commands and
        // files are handled here; only a question goes on to Claude, as a follow-up.
        guard !text.isEmpty else {
            results = []
            fileSearch.cancel()
            return
        }
        results = buildResults(text, files: fileQuery == text ? fileURLs : [])
        selectedResult = 0
        // "latest PDF in downloads": Spotlight answers, newest first, no model.
        if let find = fileSearch(for: text) {
            guard fileQuery != text else { return }
            fileTask?.cancel()
            fileTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let urls = await searchFiles(find)
                guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                fileQuery = text
                fileURLs = urls
                results = buildResults(text, files: urls)
                selectedResult = 0
                if urls.isEmpty {
                    let state = await nothingFound(find)
                    if query.trimmingCharacters(in: .whitespacesAndNewlines) == text { local = state }
                }
            }
            return
        }
        guard Self.searchEnabled, fileQuery != text else { return }
        fileTask?.cancel()
        fileTask = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            fileSearch.search(text) { [weak self] urls in
                guard let self, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                self.fileQuery = text
                self.fileURLs = urls
                let selectedID = self.results.indices.contains(self.selectedResult) ? self.results[self.selectedResult].id : nil
                self.results = self.buildResults(text, files: urls)
                self.selectedResult = self.results.firstIndex { $0.id == selectedID } ?? 0
            }
        }
    }

    /// The rows for what's typed: the one thing you most likely mean, or a
    /// short list when you're searching. Which engine does it (Apple's on-device
    /// model, Claude) never shows; Return just does the right thing.
    func buildResults(_ text: String, files: [URL]) -> [LauncherResult] {
        if text == "/code" || text.hasPrefix("/code ") {
            return [LauncherResult(id: "code", kind: .code, title: "Start a coding session", subtitle: String(text.dropFirst(5)),
                                   icon: .symbol("chevron.left.forwardslash.chevron.right"), verb: "Start", action: .code(text), score: 1)]
        }
        let isCommand = LocalCommands.looksLikeCommand(text), isQuestion = LocalCommands.looksLikeQuestion(text)
        let hasSelection = includeContext && !dropped.contains(.selection) && context?.selectedText != nil

        // Exact things first: each is the answer on its own.
        if let quick = LocalCommands.quick(text), quick.toolCall != nil || [.pointAt, .newWindow, .newTab].contains(quick.action) {
            let icon = switch quick.action {
            case .setVolume: "speaker.wave.2"
            case .showCalendar: "calendar"
            case .showReminders: "checklist"
            case .pointAt: "hand.point.up.left"
            case .newWindow: "macwindow.badge.plus"
            case .newTab: "plus.square.on.square"
            default: "circle.lefthalf.filled"
            }
            let subtitle = quick.action == .showCalendar ? (quick.when?.date ?? Date()).formatted(.dateTime.weekday(.wide).day().month(.abbreviated)) : nil
            return [LauncherResult(id: "quick", kind: .command, title: quick.headline, subtitle: subtitle, icon: .symbol(icon),
                                   verb: [.showCalendar, .showReminders, .pointAt].contains(quick.action) ? "Show" : "Do",
                                   action: .local(quick), score: 1000)]
        }
        if let value = Calculator.evaluate(text) {
            let shown = Calculator.format(value)
            return [LauncherResult(id: "calc", kind: .calculation, title: "= \(shown)", subtitle: text, icon: .symbol("equal.circle"),
                                   verb: "Copy", action: .copy(shown), score: 990)]
        }
        if fileSearch(for: text) != nil {
            // The files, newest first (they arrive a moment after typing; Return waits for them).
            return files.map(fileRow)
        }
        if Self.searchEnabled, let site = WebTarget.url(from: text) {
            return [LauncherResult(id: "url", kind: .web, title: site.host() ?? text, subtitle: site.absoluteString,
                                   icon: .symbol("safari"), verb: "Open", action: .open(site), score: 900)]
        }

        var matches: [LauncherResult] = []
        if Self.searchEnabled, !hasSelection {
            // "open spotify", "quit safari", or just "spot".
            let lower = text.lowercased()
            let quitting = lower.hasPrefix("quit ") || lower.hasPrefix("close ")
            let opening = lower.hasPrefix("open ") || lower.hasPrefix("launch ") || lower.hasPrefix("start ")
            let appQuery = quitting || opening ? String(text.drop(while: { $0 != " " }).dropFirst()) : text
            var appMatches = AppIndex.shared.matches(appQuery, limit: 4)
            if appMatches.isEmpty, opening || quitting {
                // "open safari new window": the app is the first word or two.
                let words = appQuery.split(separator: " ")
                for n in stride(from: min(3, words.count - 1), through: 1, by: -1) where appMatches.isEmpty {
                    appMatches = AppIndex.shared.matches(words.prefix(n).joined(separator: " "), limit: 1)
                }
            }
            for (app, s) in appMatches {
                if quitting {
                    guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: app.url)?.bundleIdentifier ?? "").first != nil else { continue }
                    matches.append(LauncherResult(id: "quit:" + app.url.path, kind: .app, title: "Quit \(app.name)", subtitle: nil,
                                                  icon: .image(AppIndex.shared.icon(for: app.url)), verb: "Quit",
                                                  action: .tool(name: "apps_quit", args: ["name": .string(app.name)], done: "Quit \(app.name)"), score: 700 + s))
                } else {
                    matches.append(LauncherResult(id: "app:" + app.url.path, kind: .app, title: app.name, subtitle: nil,
                                                  icon: .image(AppIndex.shared.icon(for: app.url)), verb: "Open", action: .open(app.url),
                                                  score: (opening ? 800 : 500) + s))
                }
            }
            // "open safari", "quit mail": that app is the answer.
            if (opening || quitting), let best = matches.max(by: { $0.score < $1.score }), best.score >= (quitting ? 760 : 860) {
                return [best]
            }
            for (pane, s) in SettingsPanes.matches(text).prefix(2) {
                matches.append(LauncherResult(id: "pane:" + pane.id, kind: .setting, title: pane.name, subtitle: "System Settings",
                                              icon: .symbol("gearshape"), verb: "Open", action: .open(SettingsPanes.url(pane)), score: 300 + s))
            }
            for (i, url) in files.prefix(4).enumerated() {
                let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                matches.append(LauncherResult(id: "file:" + url.path, kind: .file, title: url.lastPathComponent, subtitle: folder,
                                              icon: .image(NSWorkspace.shared.icon(forFile: url.path)), verb: "Open", action: .open(url),
                                              score: 260 - Double(i)))
            }
        }

        // The thing to do with your words: a command, a question about your selection or the
        // window (answered on this Mac), or a question for Claude.
        let localReady = LocalCommands.shared.isAvailable
        let aboutScreen = !hasSelection && wantsScreen(for: text) && (picture != nil || ScreenGrabber.hasPermission)
        let action: LauncherResult.Action =
            isCommand && localReady ? .doOnMac(text)
            : hasSelection && localReady ? .aboutSelection(text)
            : aboutScreen && localReady && contextApp != nil ? .aboutScreen(text)
            : .askClaude(text)
        let doIt = if case .doOnMac = action { true } else { false }
        let answer = LauncherResult(id: "answer", kind: doIt ? .doOnMac : .askClaude, title: text, subtitle: nil,
                                    icon: .symbol(doIt ? "wand.and.stars" : "sparkles"), verb: doIt ? "Do" : "Ask",
                                    action: action, score: 0)
        // A command, a question or a selection: that's what you mean. A search: what matched.
        if isCommand || isQuestion || hasSelection || matches.isEmpty { return [answer] }
        let sorted = matches.sorted { $0.score > $1.score }
        // A name typed in full ("safari", "wi-fi") is the one; otherwise a short list.
        if let first = sorted.first, first.kind == .app || first.kind == .setting,
           NameMatch.score(first.title, text) == 100 { return [first] }
        return Array(sorted.prefix(5))
    }

    /// A file search, unless the words are an app's name ("photos", "music", "keynote" open the app).
    func fileSearch(for text: String) -> LocalPlan? {
        guard Self.searchEnabled, let find = LocalCommands.fileQuery(text) else { return nil }
        if AppIndex.shared.matches(text, limit: 1).first?.1 == 100 { return nil }
        return find
    }

    func fileRow(_ url: URL) -> LauncherResult {
        let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate)
            .map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""
        return LauncherResult(id: "file:" + url.path, kind: .file, title: url.lastPathComponent,
                              subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath + added,
                              icon: .image(NSWorkspace.shared.icon(forFile: url.path)), verb: "Open", action: .open(url), score: 0)
    }

    /// Whether the rows are what's on screen. Over an answer, only when they're about doing
    /// something here (an app, a command, a file); a question shows the conversation, and
    /// Return sends it as a follow-up.
    var showsResults: Bool {
        guard let first = results.first else { return false }
        guard conversation != nil else { return true }
        if case .askClaude = first.action { return false }
        return !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// ↑/↓ in the field. False when there's no list to move in.
    func moveSelection(_ delta: Int) -> Bool {
        guard local == nil, showsResults else { return false }
        selectedResult = min(max(0, selectedResult + delta), results.count - 1)
        return true
    }

    /// ⌘1–⌘9: do the row with that number (false when there isn't one).
    func performNumbered(_ n: Int) -> Bool {
        guard local == nil, n >= 1, results.indices.contains(n - 1), showsResults else { return false }
        selectedResult = n - 1
        perform(results[n - 1])
        return true
    }

    /// Return: confirm a command card, do the selected row, or (in a conversation) send a follow-up.
    func returnPressed() {
        switch local {
        case .confirm(let plan)?:
            Task { await execute(plan) }
            return
        case .notACommand(let text)?, .failed(_, let text)?:
            submit(text)
            return
        case .thinking?, .working?:
            return
        case .done?, .info?:
            local = nil
            return
        case .blockedFolder?:
            FolderAccess.openSettings()
            return
        case .text(let written)?:
            returnOnText(written)
            return
        case nil:
            break
        }
        if results.indices.contains(selectedResult) {
            perform(results[selectedResult])
        } else if let find = fileSearch(for: query) {
            openNewestFile(find)
        } else {
            submit(query)
        }
    }

    /// Return on a card: confirm, paste or copy the written text, or send it on.
    private func returnOnText(_ written: LocalText) {
        guard !written.text.isEmpty else { return }
        if written.replaces, contextApp != nil, context?.selectedText != nil {
            replaceSelection(with: written.text)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(written.text, forType: .string)
            hide()
        }
    }

    /// ⌘Return: always Claude.
    func askClaude() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        local = nil
        submit(text)
    }

    /// Whether a row may run without you seeing it first (Siri, Shortcuts and Spotlight's
    /// "Ask AgentX"): opening apps, files and Settings, showing things, and asking (Claude
    /// gets it as outside text; commands that create or send still wait for your OK).
    /// Quitting an app, opening a web page and starting a coding session wait for you.
    nonisolated static func runsByItself(_ action: LauncherResult.Action) -> Bool {
        switch action {
        case .open(let url): url.isFileURL || url.scheme == "x-apple.systempreferences"
        case .copy, .doOnMac, .askClaude, .aboutSelection, .aboutScreen: true
        case .local(let plan): !plan.needsConfirmation
        case .tool, .code: false
        }
    }

    func perform(_ result: LauncherResult) {
        switch result.action {
        case .open(let url):
            NSWorkspace.shared.open(url)
            hide()
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            local = .done("Copied \(text)")
        case .tool(let name, let args, let done):
            Task { await run(name: name, args: args, done: done, closeAfter: true) }
        case .local(let plan):
            if [.showCalendar, .showReminders, .pointAt, .newWindow, .newTab].contains(plan.action) {
                Task { await execute(plan) }
            } else if let call = plan.toolCall {
                Task { await run(name: call.name, args: call.args, done: plan.headline, closeAfter: true) }
            }
        case .doOnMac(let text):
            doOnMac(text)
        case .askClaude(let text), .code(let text):
            submit(text)
        case .aboutSelection(let question):
            guard let selection = context?.selectedText else { submit(question); return }
            write(.ask, text: selection, question: question, claudePrompt: question)
        case .aboutScreen(let question):
            answerAboutScreen(question)
        }
    }

    /// Ask Apple's on-device model what `text` means, then do it (or show it for your OK).
    func doOnMac(_ text: String) {
        local = .thinking(text)
        let selection = includeContext && !dropped.contains(.selection) ? context?.selectedText : nil
        Task {
            do {
                var plan = try await LocalCommands.shared.plan(text, about: selection)
                if plan.action == .sendMessage || plan.action == .draftEmail, let who = plan.recipient {
                    if let found = await ContactLookup.find(who, wantPhone: plan.action == .sendMessage) {
                        plan.recipient = found.name
                        plan.address = found.address
                    } else if plan.action == .sendMessage {
                        local = .failed("Couldn't find “\(who)” in Contacts.", text: text)
                        return
                    }
                }
                guard local == .thinking(text) else { return }   // you typed something else meanwhile
                if plan.action == .none {
                    // Not a command after all (a question, writing…): just answer it.
                    local = nil
                    submit(text)
                } else if let missing = plan.missing {
                    local = .failed(missing, text: text)
                } else if plan.needsConfirmation {
                    local = .confirm(plan)
                } else {
                    await execute(plan)
                }
            } catch {
                // The on-device model couldn't (unavailable, or it refused): answer it the other way.
                local = nil
                submit(text)
            }
        }
    }

    func execute(_ plan: LocalPlan) async {
        switch plan.action {
        case .findFiles: await findFiles(plan); return
        case .pointAt: await pointAt(plan.target ?? ""); return
        case .newWindow, .newTab: await openNew(plan); return
        case .draftEmail:
            let args: JSONValue = ["to": .array(plan.address.map { [.string($0)] } ?? []), "subject": .string(plan.subject ?? ""),
                                   "body": .string(plan.message ?? "")]
            await run(name: "mail_draft", args: args, done: plan.address == nil
                      ? "Opened a draft in Mail. “\(plan.recipient ?? "")” isn't in Contacts, so add their address."
                      : "Opened a draft to \(plan.recipient ?? "") in Mail.", closeAfter: false)
            return
        case .sendMessage:
            guard let address = plan.address else { return }
            await run(name: "messages_send", args: ["to": .string(address), "text": .string(plan.message ?? "")],
                      done: "Sent to \(plan.recipient ?? address).", closeAfter: false)
            return
        default: break
        }
        guard let call = plan.toolCall else { return }
        local = .working(plan)
        let isRead = plan.action == .showCalendar || plan.action == .showReminders
        await run(name: call.name, args: call.args, done: plan.headline, closeAfter: false, readTitle: isRead ? plan.headline : nil)
    }

    /// Run one of AgentX's Mac tools for you, and log it.
    func run(name: String, args: JSONValue, done: String, closeAfter: Bool, readTitle: String? = nil) async {
        let output = await MacToolbox.invoke(name: name, arguments: args, origin: "Launcher")
        let text = output["text"]?.string ?? ""
        if output["isError"]?.bool == true {
            local = .failed(text, text: query)
            return
        }
        if readTitle == nil {
            AppModel.shared.activity.record(.tool, "ran", tool: "mcp__agentx__\(name)",
                                  detail: ToolPresentation.summary(name: "mcp__agentx__\(name)", input: args, cwd: nil),
                                  origin: "Launcher (on this Mac)")
        }
        LocalUsage.noteOnMac()
        if let readTitle {
            local = .info(title: readTitle, text: text)
        } else if closeAfter {
            hide()
        } else {
            local = .done(text.isEmpty ? done : text)
        }
    }

    // MARK: Text, screen and files, on this Mac

    /// One of the Ask button's actions on your selection: on this Mac when it can be.
    func runOnSelection(_ action: SelectionAction) {
        guard let selection = context?.selectedText else { submit(action.prompt); return }
        if action.job == nil {
            translate(selection, to: LocalWriter.defaultTarget(for: selection))
        } else if let job = action.job {
            write(job, text: selection, claudePrompt: action.prompt)
        }
    }

    /// Write something from `text` on this Mac; if that can't be done, offer Claude (never silently).
    func write(_ job: LocalWriter.Job, text: String, question: String? = nil, claudePrompt: String) {
        guard LocalCommands.shared.isAvailable else { submit(claudePrompt); return }
        local = .thinking(question ?? job.title)
        Task {
            do {
                let out = try await LocalWriter.run(job, text: text, question: question)
                local = .text(LocalText(title: job.title, text: out, source: text, replaces: job.replaces, claudePrompt: claudePrompt))
            } catch {
                local = .failed(error.localizedDescription, text: claudePrompt)
            }
        }
    }

    /// Translate on this Mac (Apple's Translation, or the on-device model). No target: pick a language first.
    func translate(_ text: String, to target: String?) {
        guard let target else {
            local = .text(LocalText(title: "Translate", text: "", source: text, isTranslation: true, replaces: true,
                                    claudePrompt: "Translate this."))
            return
        }
        let name = LocalWriter.name(of: target)
        local = .thinking("Translating into \(name)…")
        Task {
            do {
                let out = try await LocalWriter.translate(text, to: target)
                local = .text(LocalText(title: "In \(name)", text: out, source: text, language: target, isTranslation: true,
                                        replaces: true, claudePrompt: "Translate this into \(name)."))
            } catch {
                local = .failed(error.localizedDescription, text: "Translate this into \(name).")
            }
        }
    }

    /// A question about the window in front: read its text on this Mac, then answer from it.
    func answerAboutScreen(_ question: String) {
        guard let app = contextApp else { submit(question); return }
        local = .thinking(question)
        Task {
            do {
                let reading = try await ScreenText.read(app)
                guard !reading.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    local = .failed("There's no text to read in \(reading.appName)'s window.", text: question)
                    return
                }
                let out = try await LocalWriter.run(.ask, text: reading.text, question: question)
                local = .text(LocalText(title: "From \(reading.appName)", text: out, source: reading.text, replaces: false, claudePrompt: question))
            } catch {
                local = .failed(error.localizedDescription, text: question)
            }
        }
    }

    /// Spotlight, after making sure AgentX may see the folder (macOS asks the first time).
    func searchFiles(_ find: LocalPlan, limit: Int = 9) async -> [URL] {
        if let folder = FolderAccess.folder(for: find) { _ = await FolderAccess.ensure(folder) }
        return await FileSearch.find(kind: find.fileKind, words: find.target, since: find.since, folder: find.folder, limit: limit)
    }

    /// Nothing found: say whether it's because macOS hides the folder from AgentX.
    func nothingFound(_ find: LocalPlan) async -> LocalState {
        if let folder = FolderAccess.folder(for: find), !(await FolderAccess.ensure(folder)) {
            return .blockedFolder(folder.lastPathComponent)
        }
        return .failed("No files like that.", text: query)
    }

    /// Return pressed before a file search finished: open the newest match when it comes.
    private func openNewestFile(_ find: LocalPlan) {
        local = .thinking(query)
        Task {
            let urls = await searchFiles(find, limit: 1)
            if let first = urls.first {
                local = nil
                NSWorkspace.shared.open(first)
                hide()
            } else {
                local = await nothingFound(find)
            }
        }
    }

    /// "Find the PDFs I downloaded this week": the files, as rows to open.
    func findFiles(_ plan: LocalPlan) async {
        let urls = await searchFiles(plan)
        LocalUsage.noteOnMac()
        guard !urls.isEmpty else { local = await nothingFound(plan); return }
        local = nil
        results = urls.map(fileRow)
        selectedResult = 0
    }

    /// Point at something in the app in front: by its label (Accessibility), or its words on screen (Vision).
    func pointAt(_ target: String) async {
        // The app you were looking at; AgentX's own window when the launcher opened over it.
        guard let app = contextApp ?? openedOver, !target.isEmpty else { return }
        local = .thinking("Looking for “\(target)”…")
        let pid = app.processIdentifier
        var spot = await Task.detached(priority: .userInitiated) { ScreenTargets.find(target, pid: pid).best?.frame }.value
        if spot == nil, ScreenGrabber.hasPermission { spot = try? await ScreenText.locate(target, in: app) }
        guard let spot else {
            local = .failed("Couldn't find “\(target)” in \(app.localizedName ?? "that window").", text: query)
            return
        }
        LocalUsage.noteOnMac()
        local = nil
        hide()
        PointerOverlay.shared.point(at: spot, label: target)
    }

    /// A new window or tab in an app: open it (or bring it forward), then ⌘N or ⌘T there.
    /// No app named: the one you were in.
    func openNew(_ plan: LocalPlan) async {
        let key = CGKeyCode(plan.action == .newTab ? 0x11 : 0x2D)   // T, N
        var target: NSRunningApplication?
        var justLaunched = false
        if let name = plan.app, let app = AppIndex.shared.matches(name, limit: 1).first?.0 {
            let bundleID = Bundle(url: app.url)?.bundleIdentifier ?? ""
            justLaunched = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            target = try? await NSWorkspace.shared.openApplication(at: app.url, configuration: config)
        } else if let front = openedOver, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target = front
            front.activate()
        }
        guard let target else {
            local = .failed("Couldn't find “\(plan.app ?? "that app")”.", text: query)
            return
        }
        hide()
        LocalUsage.noteOnMac()
        // An app that was just opened shows a window of its own.
        guard !justLaunched || plan.action == .newTab else { return }
        for _ in 0..<30 where !target.isActive { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(150))
        _ = SelectionCopier.press(key, in: target.processIdentifier)
    }

    /// Paste text over your selection in the app it came from.
    func replaceSelection(with text: String) {
        guard let app = contextApp, !app.isTerminated else { return }
        hide()
        Task {
            app.activate()
            try? await Task.sleep(for: .milliseconds(200))
            if !(await SelectionCopier.paste(text, into: app)) {
                show()
                error = "Couldn't paste into \(app.localizedName ?? "that app")."
            }
        }
    }

    /// Spoken: the same choice as typing (a command, an app, a question about your
    /// selection or screen on this Mac); questions for Claude keep read-aloud.
    func routeSpoken(_ heard: String) {
        query = heard
        // Spoken file searches show the files to pick from.
        if fileSearch(for: heard) != nil { updateResults(); return }
        let rows = buildResults(heard, files: [])
        guard let first = rows.first else { submit(heard, spoken: true); return }
        if case .askClaude = first.action {
            submit(heard, spoken: true)
        } else if rows.count == 1 {
            perform(first)
        } else {
            results = rows   // several matches: pick one
            selectedResult = 0
        }
    }
}
