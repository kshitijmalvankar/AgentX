import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Opens AgentX when you log in, so automations can run (macOS login item).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

extension Date {
    /// "Today 18:00", "Tomorrow 08:00", "Sun 10:00".
    var scheduleLabel: String {
        let time = formatted(.dateTime.hour().minute())
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today \(time)" }
        if cal.isDateInTomorrow(self) { return "Tomorrow \(time)" }
        return formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Automation?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    private var center: AutomationCenter { model.automations }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if center.isPaused {
                    HStack(spacing: 10) {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                        Text(AppChannel.current.isDev
                             ? "Paused in AgentX Dev, so your installed AgentX is the only one running automations. \"Run now\" still works."
                             : "Automations are paused (Stop everything, or you paused them). \"Run now\" still works.")
                            .font(.callout)
                        Spacer()
                        Button("Resume") { center.isPaused = false }.secondaryButton()
                    }
                    .padding(12)
                    .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .agentCard)
                }
                if let error = center.storageError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
                VStack(spacing: 12) {
                    ForEach(center.automations) { automation in
                        AutomationCard(automation: automation, edit: { editing = automation })
                    }
                }
                if !center.runs.isEmpty {
                    Text("Recent runs").font(.headline).padding(.top, 8)
                    VStack(spacing: 0) {
                        ForEach(center.runs.prefix(30)) { run in
                            RunRow(run: run)
                            Divider()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Automations")
        .sheet(item: $editing) { automation in
            AutomationEditor(original: automation)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automations").font(.largeTitle.bold())
                    Text("Tasks that run on a schedule or when something happens: Claude with the Assistant's tools and approvals, a briefing written on this Mac, or just a notification.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Automation", systemImage: "plus") {
                    editing = Automation(name: "", prompt: "", kind: .assistant, folder: nil,
                                         schedule: .daily(hour: 9, minute: 0, weekdays: []), enabled: true)
                }
                .primaryButton()
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Automations run only while AgentX is open (it can stay in the menu bar). Anything that needs your OK is sent as a notification and skipped after 10 minutes without an answer. Claude runs use your plan. A trigger starts its automation at most once every 10 minutes, and triggers start at most 20 runs a day.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle("Open AgentX at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .disabled(AppChannel.current.isDev)
                        .help(AppChannel.current.isDev ? "Only the installed AgentX opens at login." : "")
                        .onChange(of: launchAtLogin) { _, on in
                            do {
                                try LaunchAtLogin.set(on)
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                                launchAtLogin = LaunchAtLogin.isEnabled
                            }
                        }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .agentCard)
        }
    }
}

private struct AutomationCard: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    let edit: () -> Void
    @State private var confirmDelete = false

    private var center: AutomationCenter { model.automations }

    var body: some View {
        let running = center.isRunning(automation.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(automation.name.isEmpty ? "Untitled" : automation.name).font(.headline)
                    HStack(spacing: 6) {
                        Label(automation.whenLabel, systemImage: automation.trigger?.symbol ?? "clock")
                        Text("·")
                        Text(automation.kindLabel)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text(automation.prompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("On", isOn: Binding(get: { automation.enabled }, set: { center.setEnabled(automation.id, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(automation.enabled ? "Turn off" : "Turn on")
            }
            HStack(spacing: 12) {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Running now…").font(.callout).foregroundStyle(.secondary)
                } else if let next = center.nextRun(of: automation) {
                    Label("Next: \(next.scheduleLabel)", systemImage: "calendar").font(.callout)
                } else if automation.enabled, automation.trigger != nil {
                    Label("Watching", systemImage: "eye").font(.callout).help("Runs when it happens")
                } else {
                    Text("Off").font(.callout).foregroundStyle(.tertiary)
                }
                if let last = center.lastRun(of: automation), last.status != .running {
                    RunStatusIcon(status: last.status)
                    Text("Last run \(last.startedAt.relative)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run Now", systemImage: "play.fill") { center.runNow(automation) }
                    .disabled(running)
                    .help("Run it once now (uses your plan)")
                Button("Edit", action: edit)
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .labelStyle(.iconOnly)
            }
            .secondaryButton()
            .controlSize(.small)
        }
        .padding(16)
        .glassEffect(.regular, in: .agentCard)
        .confirmationDialog("Delete \"\(automation.name)\"?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { center.delete(automation.id) }
        } message: {
            Text("Its past runs stay in the history.")
        }
    }
}

struct RunStatusIcon: View {
    let status: AutomationRun.Status

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Viz.good).help("Finished")
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Viz.critical).help("Didn't finish")
        case .skipped: Image(systemName: "forward.circle.fill").foregroundStyle(Viz.warning).help("Skipped")
        }
    }
}

private struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: AutomationRun
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RunStatusIcon(status: run.status).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(run.automationName).fontWeight(.medium)
                    Text(run.startedAt.scheduleLabel).foregroundStyle(.secondary)
                    if run.trigger != .scheduled {
                        Text(run.trigger == .manual ? "run by you"
                             : run.trigger == .event ? "after: \(run.event ?? "its trigger")"
                             : "caught up after wake")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if let summary = run.summary, !summary.isEmpty {
                    if expanded {
                        MarkdownText(text: summary)
                    } else {
                        Text(summary).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if run.unansweredApprovals > 0 {
                    Label("\(run.unansweredApprovals) step\(run.unansweredApprovals == 1 ? "" : "s") skipped: no answer within 10 minutes",
                          systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            Spacer()
            if let summary = run.summary, summary.count > 160 {
                Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.link).font(.caption)
            }
            if let sessionId = run.sessionId {
                Button("Open") { model.openSession(sessionId) }
                    .secondaryButton()
                    .controlSize(.small)
                    .help("Open the full conversation")
            }
        }
        .padding(.vertical, 10)
    }
}

/// Create or edit an automation.
private struct AutomationEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: Automation
    @State private var draft: Automation
    @State private var everyHours = false
    @State private var time = Date()
    @State private var weekdays: Set<Int> = []
    @State private var hours = 3
    @State private var allowedText = ""
    @State private var starts: TriggerChoice = .schedule
    @State private var folder = NSHomeDirectory() + "/Downloads"
    @State private var pattern = ""
    @State private var minutesBefore = 10
    @State private var titleContains = ""
    @State private var app: (id: String, name: String)?
    @State private var batteryPercent = 20
    @State private var sender = ""

    init(original: Automation) {
        self.original = original
        _draft = State(initialValue: original)
        switch original.trigger {
        case nil: break
        case .fileAdded(let f, let p):
            _starts = State(initialValue: .fileAdded)
            _folder = State(initialValue: f)
            _pattern = State(initialValue: p ?? "")
        case .calendarEventSoon(let m, let t):
            _starts = State(initialValue: .calendar)
            _minutesBefore = State(initialValue: m)
            _titleContains = State(initialValue: t ?? "")
        case .appLaunched(let id, let name):
            _starts = State(initialValue: .appLaunched)
            _app = State(initialValue: (id, name))
        case .macWoke: _starts = State(initialValue: .macWoke)
        case .firstUnlockOfDay: _starts = State(initialValue: .firstUnlock)
        case .powerConnected: _starts = State(initialValue: .powerConnected)
        case .batteryBelow(let p):
            _starts = State(initialValue: .batteryLow)
            _batteryPercent = State(initialValue: p)
        case .mailFrom(let s):
            _starts = State(initialValue: .mail)
            _sender = State(initialValue: s)
        case .reviewRequested: _starts = State(initialValue: .reviewRequested)
        case .checksFailed: _starts = State(initialValue: .checksFailed)
        }
        switch original.schedule {
        case .daily(let hour, let minute, let days):
            _time = State(initialValue: Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date())
            _weekdays = State(initialValue: days)
        case .interval(let h):
            _everyHours = State(initialValue: true)
            _hours = State(initialValue: h)
        }
        _allowedText = State(initialValue: original.allowedTools.joined(separator: ", "))
    }

    private var isNew: Bool { !model.automations.automations.contains { $0.id == original.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Automation" : "Edit Automation").font(.title2.bold())
            Form {
                TextField("Name", text: $draft.name, prompt: Text("Morning brief"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.kind == .notify ? "Note in the notification (optional)"
                         : draft.kind == .onDevice ? "What to focus on (optional)" : "What should Claude do?")
                    TextEditor(text: $draft.prompt)
                        .font(.body)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Radius.field))
                }
                Picker("Runs as", selection: $draft.kind) {
                    Text("Assistant (Calendar, Files, Mail, …)").tag(Automation.Kind.assistant)
                    Text("Coding session in a folder").tag(Automation.Kind.coding)
                    Text("Briefing on this Mac (no Claude)").tag(Automation.Kind.onDevice)
                    Text("Just a notification (no Claude)").tag(Automation.Kind.notify)
                }
                if draft.kind == .notify {
                    Text("A notification saying what happened, with your note. Nothing else runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if draft.kind == .onDevice {
                    Text("Written on this Mac by Apple Intelligence from your calendar, reminders and unread mail, and shown as a notification. It doesn't use your Claude plan. Below, say what to focus on (or leave it empty).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if draft.kind == .coding {
                    Picker("Folder", selection: Binding(get: { draft.folder ?? "" }, set: { draft.folder = $0.isEmpty ? nil : $0 })) {
                        Text("Choose…").tag("")
                        ForEach(model.sessions.recentProjects.prefix(15), id: \.self) { Text($0.abbreviatingHome).tag($0) }
                    }
                    TextField("Commands it may run unattended", text: $allowedText,
                              prompt: Text("Bash(git status:*), Bash(npm test:*)"))
                    Text("Anything else that needs approval is sent to you and skipped after 10 minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Starts", selection: $starts) {
                    ForEach(TriggerChoice.allCases) { choice in
                        Label(choice.title, systemImage: choice.symbol).tag(choice)
                    }
                }
                if starts != .schedule {
                    triggerFields
                } else {
                Picker("Schedule", selection: $everyHours) {
                    Text("At a time").tag(false)
                    Text("Every few hours").tag(true)
                }
                .pickerStyle(.segmented)
                if everyHours {
                    Stepper("Every \(hours) hour\(hours == 1 ? "" : "s")", value: $hours, in: 1...24)
                } else {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    LabeledContent("Days") {
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { day in
                                let on = weekdays.contains(day)
                                Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                                    if on { weekdays.remove(day) } else { weekdays.insert(day) }
                                }
                                .buttonStyle(.plain)
                                .frame(width: 26, height: 26)
                                .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: .circle)
                                .foregroundStyle(on ? Color.white : Color.primary)
                            }
                        }
                    }
                    Text(weekdays.isEmpty ? "No days picked: runs every day." : "Runs on the highlighted days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }
                Toggle("On", isOn: $draft.enabled)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.secondaryButton().keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || ((draft.kind == .assistant || draft.kind == .coding) && draft.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                              || (draft.kind == .coding && draft.folder == nil)
                              || trigger == nil && starts != .schedule)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        draft.schedule = everyHours ? .interval(hours: hours)
            : .daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: weekdays)
        draft.trigger = trigger
        draft.allowedTools = allowedText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if draft.kind != .coding { draft.folder = nil; draft.allowedTools = [] }
        if isNew { model.automations.add(draft) } else { model.automations.update(draft) }
        dismiss()
    }
}

extension AutomationEditor {
    /// The trigger the fields describe (nil: on the schedule, or a field still missing).
    var trigger: AutomationTrigger? {
        let trimmed = { (text: String) -> String? in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        switch starts {
        case .schedule: return nil
        case .fileAdded: return folder.isEmpty ? nil : .fileAdded(folder: folder, pattern: trimmed(pattern))
        case .calendar: return .calendarEventSoon(minutesBefore: minutesBefore, titleContains: trimmed(titleContains))
        case .appLaunched: return app.map { .appLaunched(bundleID: $0.id, name: $0.name) }
        case .macWoke: return .macWoke
        case .firstUnlock: return .firstUnlockOfDay
        case .powerConnected: return .powerConnected
        case .batteryLow: return .batteryBelow(percent: batteryPercent)
        case .mail: return trimmed(sender).map { .mailFrom(sender: $0) }
        case .reviewRequested: return .reviewRequested
        case .checksFailed: return .checksFailed
        }
    }

    @ViewBuilder var triggerFields: some View {
        switch starts {
        case .schedule:
            EmptyView()
        case .fileAdded:
            LabeledContent("Folder") {
                HStack {
                    Text(folder.abbreviatingHome).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }
            TextField("Only files named", text: $pattern, prompt: Text("Any file (or e.g. *.pdf, *.png)"))
            note("Files added straight into the folder. Downloads still in progress and hidden files don't count.")
        case .calendar:
            Stepper("\(minutesBefore) minutes before it starts", value: $minutesBefore, in: 1...120)
            TextField("Only events with", text: $titleContains, prompt: Text("Any timed event (or words in the title)"))
            note("Needs Calendar access for AgentX (System Settings › Privacy & Security › Calendars). All-day events don't count.")
        case .appLaunched:
            LabeledContent("App") {
                HStack {
                    Text(app?.name ?? "None chosen").foregroundStyle(app == nil ? .secondary : .primary)
                    Button("Choose…") { chooseApp() }
                }
            }
        case .macWoke, .firstUnlock, .powerConnected:
            EmptyView()
        case .batteryLow:
            Stepper("Below \(batteryPercent)%", value: $batteryPercent, in: 5...80, step: 5)
            note("Once each time it drops below, while the Mac isn't plugged in.")
        case .mail:
            TextField("From", text: $sender, prompt: Text("Name or address, e.g. boss@company.com"))
            note("New unread mail in the Mail app, checked every 5 minutes while Mail is open.")
        case .reviewRequested, .checksFailed:
            note("Checked every few minutes through GitHub (the gh command line tool, signed in).")
        }
        if draft.kind == .assistant || draft.kind == .coding {
            note("Claude gets what happened (a file name, an event title, a mail subject…) as outside data it won't take instructions from. Sending anything out asks you first.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        app = (id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }
}

/// The "Starts" choices in the editor.
enum TriggerChoice: String, CaseIterable, Identifiable {
    case schedule, fileAdded, calendar, appLaunched, macWoke, firstUnlock, powerConnected, batteryLow, mail, reviewRequested, checksFailed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .schedule: "On a schedule"
        case .fileAdded: "When a file is added to a folder"
        case .calendar: "Before a calendar event"
        case .appLaunched: "When an app opens"
        case .macWoke: "When the Mac wakes"
        case .firstUnlock: "When I first unlock the Mac each day"
        case .powerConnected: "When the Mac is plugged in"
        case .batteryLow: "When the battery is low"
        case .mail: "When mail arrives from someone"
        case .reviewRequested: "When my review is requested on GitHub"
        case .checksFailed: "When checks fail on my pull request"
        }
    }

    var symbol: String {
        switch self {
        case .schedule: "clock"
        case .fileAdded: "folder.badge.plus"
        case .calendar: "calendar.badge.clock"
        case .appLaunched: "app.badge"
        case .macWoke: "sun.max"
        case .firstUnlock: "lock.open"
        case .powerConnected: "powerplug"
        case .batteryLow: "battery.25percent"
        case .mail: "envelope.badge"
        case .reviewRequested: "person.crop.circle.badge.questionmark"
        case .checksFailed: "xmark.octagon"
        }
    }
}

extension Automation {
    var kindLabel: String {
        switch kind {
        case .assistant: "Assistant"
        case .onDevice: "On this Mac"
        case .notify: "Notification"
        case .coding: "Coding in \(((folder ?? "~") as NSString).lastPathComponent)"
        }
    }
}

/// Dashboard: what runs next and how the last runs went.
struct AutomationsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let center = model.automations
        GlassCard("Automations", symbol: "clock.arrow.2.circlepath", tint: .teal) {
            Button("All") { model.sidebar = .automations }.buttonStyle(.link)
        } content: {
            let upcoming = center.upcoming.prefix(2)
            let recent = center.runs.filter { $0.status != .running }.prefix(2)
            if upcoming.isEmpty && recent.isEmpty {
                Text("Nothing scheduled. Turn on a starter like Morning brief in Automations.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(upcoming), id: \.automation.id) { item in
                HStack {
                    Image(systemName: center.isRunning(item.automation.id) ? "hourglass" : "clock").foregroundStyle(.secondary)
                    Text(item.automation.name).lineLimit(1)
                    Spacer()
                    Text(center.isRunning(item.automation.id) ? "Running" : item.date.scheduleLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !recent.isEmpty && !upcoming.isEmpty { Divider() }
            ForEach(Array(recent)) { run in
                Button {
                    if let id = run.sessionId { model.openSession(id) } else { model.sidebar = .automations }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        RunStatusIcon(status: run.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(run.automationName) · \(run.startedAt.relative)").font(.callout)
                            if let summary = run.summary {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 140)
    }
}
